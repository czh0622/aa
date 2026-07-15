#!/usr/bin/env bash
# 不依赖 gs_dump 的逻辑备份（规避 pg_stat_get_stream_replications / OID 报错）
# 用法:
#   ./scripts/backup-gsql.sh
#   ./scripts/backup-gsql.sh --cleanup
#
# 产物目录结构:
#   backups/monitor_public_gsql_YYYYmmdd_HHMMSS/
#     meta.txt
#     001_schema.sql      # DDL（优先 pg_get_tabledef）
#     002_data.sql        # COPY 文本数据（可 gsql 还原）
#     tables.list
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

DO_CLEANUP=false
[[ "${1:-}" == "--cleanup" ]] && DO_CLEANUP=true
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && {
  echo "用法: backup-gsql.sh [--cleanup]"
  exit 0
}

load_config
require_docker
require_container
detect_tools
ensure_backup_dir

SCHEMA_NAME="${SCHEMA:-public}"
TS="$(timestamp)"
OUT_DIR="${BACKUP_DIR}/${DB_NAME}_${SCHEMA_NAME}_gsql_${TS}"
CONTAINER_OUT="/tmp/${DB_NAME}_${SCHEMA_NAME}_gsql_${TS}"
mkdir -p "${OUT_DIR}"

CONN_ARGS=()
while IFS= read -r _line; do
  [[ -n "${_line}" ]] && CONN_ARGS+=("${_line}")
done < <(db_conn_args)

log "开始 gsql 逻辑备份: db=${DB_NAME} schema=${SCHEMA_NAME}（绕过 gs_dump）"
docker_db_exec mkdir -p "${CONTAINER_OUT}"

# 表清单
TABLES="$(
  docker_db_exec "${SQL_BIN}" "${CONN_ARGS[@]}" -d "${DB_NAME}" -tAc \
    "SELECT tablename FROM pg_tables WHERE schemaname='${SCHEMA_NAME}' ORDER BY tablename;" \
    | tr -d '\r' | sed '/^$/d'
)"
echo "${TABLES}" > "${OUT_DIR}/tables.list"
TABLE_COUNT="$(grep -c . "${OUT_DIR}/tables.list" 2>/dev/null || echo 0)"
log "发现 ${TABLE_COUNT} 张表"

# 探测是否支持 pg_get_tabledef
HAS_TABLEDEF=false
if docker_db_exec "${SQL_BIN}" "${CONN_ARGS[@]}" -d "${DB_NAME}" -tAc \
    "SELECT 1 FROM pg_proc WHERE proname='pg_get_tabledef' LIMIT 1;" 2>/dev/null | grep -q 1; then
  HAS_TABLEDEF=true
  log "检测到 pg_get_tabledef，将导出完整建表语句"
fi

SCHEMA_SQL="${OUT_DIR}/001_schema.sql"
DATA_SQL="${OUT_DIR}/002_data.sql"
{
  echo "-- schema dump generated at $(date -Iseconds)"
  echo "-- database=${DB_NAME} schema=${SCHEMA_NAME}"
  echo "SET client_min_messages TO WARNING;"
  echo "CREATE SCHEMA IF NOT EXISTS ${SCHEMA_NAME};"
  echo "SET search_path TO ${SCHEMA_NAME}, public;"
} > "${SCHEMA_SQL}"

{
  echo "-- data dump generated at $(date -Iseconds)"
  echo "SET client_min_messages TO WARNING;"
  echo "SET search_path TO ${SCHEMA_NAME}, public;"
  echo "BEGIN;"
} > "${DATA_SQL}"

# 序列
SEQUENCES="$(
  docker_db_exec "${SQL_BIN}" "${CONN_ARGS[@]}" -d "${DB_NAME}" -tAc \
    "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='${SCHEMA_NAME}' AND c.relkind='S' ORDER BY 1;" \
    | tr -d '\r' | sed '/^$/d' || true
)"

if [[ -n "${SEQUENCES}" ]]; then
  while IFS= read -r seq; do
    [[ -z "${seq}" ]] && continue
    if [[ "${HAS_TABLEDEF}" == "true" ]]; then
      # 部分版本无序列 def，用 CREATE SEQUENCE + setval
      :
    fi
    LAST="$(
      docker_db_exec "${SQL_BIN}" "${CONN_ARGS[@]}" -d "${DB_NAME}" -tAc \
        "SELECT last_value, is_called FROM ${SCHEMA_NAME}.\"${seq}\";" 2>/dev/null | tr -d '\r' || echo "1|t"
    )"
    LAST_VAL="${LAST%%|*}"
    IS_CALLED="${LAST##*|}"
    {
      echo "CREATE SEQUENCE IF NOT EXISTS ${SCHEMA_NAME}.\"${seq}\";"
      echo "SELECT setval('${SCHEMA_NAME}.\"${seq}\"', ${LAST_VAL}, ${IS_CALLED});"
    } >> "${SCHEMA_SQL}"
  done <<< "${SEQUENCES}"
fi

# 逐表导出 DDL + 数据
while IFS= read -r tbl; do
  [[ -z "${tbl}" ]] && continue
  log "导出表: ${SCHEMA_NAME}.${tbl}"

  if [[ "${HAS_TABLEDEF}" == "true" ]]; then
    docker_db_exec "${SQL_BIN}" "${CONN_ARGS[@]}" -d "${DB_NAME}" -tAc \
      "SELECT pg_get_tabledef('${SCHEMA_NAME}.${tbl}');" 2>/dev/null | tr -d '\r' >> "${SCHEMA_SQL}" || {
      echo "-- WARN: pg_get_tabledef failed for ${tbl}" >> "${SCHEMA_SQL}"
    }
    echo "" >> "${SCHEMA_SQL}"
  else
    # 兜底：仅记录表名，数据用 COPY；还原前需表已存在，或后续手工补 DDL
    echo "-- TABLE ${SCHEMA_NAME}.\"${tbl}\" (无 pg_get_tabledef，请确保目标库已有同结构表)" >> "${SCHEMA_SQL}"
  fi

  # 服务端 COPY 到容器临时文件（比 \\copy 更稳）
  CONT_COPY="${CONTAINER_OUT}/${tbl}.copy"
  set +e
  docker_db_exec "${SQL_BIN}" "${CONN_ARGS[@]}" -d "${DB_NAME}" -c \
    "COPY ${SCHEMA_NAME}.\"${tbl}\" TO '${CONT_COPY}' WITH (FORMAT text, ENCODING 'UTF8');"
  COPY_RC=$?
  set -e
  if [[ ${COPY_RC} -ne 0 ]]; then
    log "WARN: 表 ${tbl} COPY 失败，跳过数据"
    echo "-- SKIP DATA ${SCHEMA_NAME}.\"${tbl}\" (COPY failed)" >> "${DATA_SQL}"
    continue
  fi

  {
    echo "TRUNCATE TABLE ${SCHEMA_NAME}.\"${tbl}\" CASCADE;"
    echo "COPY ${SCHEMA_NAME}.\"${tbl}\" FROM stdin WITH (FORMAT text, ENCODING 'UTF8');"
  } >> "${DATA_SQL}"
  docker cp "${CONTAINER_NAME}:${CONT_COPY}" "${OUT_DIR}/${tbl}.copy"
  cat "${OUT_DIR}/${tbl}.copy" >> "${DATA_SQL}"
  printf '\\.\n\n' >> "${DATA_SQL}"
  rm -f "${OUT_DIR}/${tbl}.copy"
done <<< "${TABLES}"

echo "COMMIT;" >> "${DATA_SQL}"

# 索引/约束：若有 pg_get_tabledef 通常已含；否则尝试导出索引定义
if [[ "${HAS_TABLEDEF}" != "true" ]]; then
  {
    echo "-- indexes"
    docker_db_exec "${SQL_BIN}" "${CONN_ARGS[@]}" -d "${DB_NAME}" -tAc \
      "SELECT pg_get_indexdef(i.indexrelid) || ';' FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='${SCHEMA_NAME}' AND c.relkind='r' AND NOT i.indisprimary ORDER BY 1;" \
      2>/dev/null | tr -d '\r' || true
  } >> "${SCHEMA_SQL}"
fi

cat > "${OUT_DIR}/meta.txt" <<EOF
backup_time=$(date -Iseconds)
method=gsql-copy
container=${CONTAINER_NAME}
db_name=${DB_NAME}
schema=${SCHEMA_NAME}
table_count=${TABLE_COUNT}
has_tabledef=${HAS_TABLEDEF}
note=gs_dump bypass due to pg_stat_get_stream_replications/OID error
EOF

docker_db_exec rm -rf "${CONTAINER_OUT}" >/dev/null 2>&1 || true

# 打包便于拷贝
ARCHIVE="${OUT_DIR}.tar.gz"
tar -czf "${ARCHIVE}" -C "${BACKUP_DIR}" "$(basename "${OUT_DIR}")"
SIZE="$(du -sh "${ARCHIVE}" | awk '{print $1}')"
log "gsql 备份成功: ${ARCHIVE} (${SIZE})"
log "还原: ./scripts/restore-gsql.sh ${ARCHIVE}"

if [[ "${DO_CLEANUP}" == "true" ]]; then
  find "${BACKUP_DIR}" -maxdepth 1 -name "${DB_NAME}_${SCHEMA_NAME}_gsql_*.tar.gz" -mtime +"${KEEP_DAYS}" -print -delete 2>/dev/null || true
  find "${BACKUP_DIR}" -maxdepth 1 -type d -name "${DB_NAME}_${SCHEMA_NAME}_gsql_*" -mtime +"${KEEP_DAYS}" -print -exec rm -rf {} + 2>/dev/null || true
fi

echo "${ARCHIVE}"
