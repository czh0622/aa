#!/usr/bin/env bash
# 不依赖 gs_dump：导出 public（可配置）下的
#   序列 / 表结构 / 表数据 / 视图 / 函数 / 过程
# 用法:
#   ./scripts/backup-gsql.sh
#   ./scripts/backup-gsql.sh --cleanup
#   ./scripts/backup-gsql.sh --objects-only   # 只导出对象定义（不含表数据）
#
# 产物:
#   backups/<db>_<schema>_gsql_<ts>/
#     001_sequences.sql
#     002_tables.sql
#     003_views.sql
#     004_routines.sql
#     005_data.sql          # --objects-only 时不生成
#     006_sequence_values.sql
#     *.list / meta.txt
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

DO_CLEANUP=false
OBJECTS_ONLY=false

usage() {
  cat <<'EOF'
用法: backup-gsql.sh [选项]
  --cleanup        清理 KEEP_DAYS 天前的旧备份
  --objects-only   只备份序列/视图/函数/过程（及表DDL若可用），不含 COPY 数据
  -h, --help       帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup) DO_CLEANUP=true; shift ;;
    --objects-only) OBJECTS_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

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

sql() {
  docker_db_exec "${SQL_BIN}" "${CONN_ARGS[@]}" -d "${DB_NAME}" "$@"
}

sql_t() {
  sql -tAc "$1" 2>/dev/null | tr -d '\r' | sed '/^$/d' || true
}

log "开始 gsql 备份: db=${DB_NAME} schema=${SCHEMA_NAME} objects_only=${OBJECTS_ONLY}"
docker_db_exec mkdir -p "${CONTAINER_OUT}"

HAS_TABLEDEF=false
if sql_t "SELECT 1 FROM pg_proc WHERE proname='pg_get_tabledef' LIMIT 1;" | grep -q 1; then
  HAS_TABLEDEF=true
fi
HAS_PROKIND=false
if sql_t "SELECT 1 FROM information_schema.columns WHERE table_name='pg_proc' AND column_name='prokind' LIMIT 1;" | grep -q 1; then
  HAS_PROKIND=true
fi

SEQ_SQL="${OUT_DIR}/001_sequences.sql"
TBL_SQL="${OUT_DIR}/002_tables.sql"
VIEW_SQL="${OUT_DIR}/003_views.sql"
ROUT_SQL="${OUT_DIR}/004_routines.sql"
DATA_SQL="${OUT_DIR}/005_data.sql"
SEQVAL_SQL="${OUT_DIR}/006_sequence_values.sql"

header() {
  local f="$1" title="$2"
  {
    echo "-- ${title}"
    echo "-- generated at $(date -Iseconds) db=${DB_NAME} schema=${SCHEMA_NAME}"
    echo "SET client_min_messages TO WARNING;"
    echo "SET search_path TO ${SCHEMA_NAME}, public;"
    echo
  } > "${f}"
}

header "${SEQ_SQL}" "sequences"
header "${TBL_SQL}" "tables"
header "${VIEW_SQL}" "views"
header "${ROUT_SQL}" "functions & procedures"
header "${SEQVAL_SQL}" "sequence values (setval)"

# ---------- 序列定义 + 当前值 ----------
SEQUENCES="$(sql_t "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='${SCHEMA_NAME}' AND c.relkind='S' ORDER BY 1;")"
echo "${SEQUENCES}" > "${OUT_DIR}/sequences.list"
SEQ_COUNT=0
[[ -n "${SEQUENCES}" ]] && SEQ_COUNT="$(grep -c . "${OUT_DIR}/sequences.list" || true)"
log "序列: ${SEQ_COUNT}"

while IFS= read -r seq; do
  [[ -z "${seq}" ]] && continue
  # 从序列关系读属性（openGauss/PG 兼容）
  META="$(sql_t "SELECT increment_by || '|' || min_value || '|' || max_value || '|' || start_value || '|' || cache_value || '|' || CASE WHEN is_cycled THEN 'CYCLE' ELSE 'NO CYCLE' END || '|' || last_value || '|' || CASE WHEN is_called THEN 'true' ELSE 'false' END FROM ${SCHEMA_NAME}.\"${seq}\";" || true)"
  if [[ -z "${META}" ]]; then
    echo "CREATE SEQUENCE IF NOT EXISTS ${SCHEMA_NAME}.\"${seq}\";" >> "${SEQ_SQL}"
    continue
  fi
  IFS='|' read -r INC MINV MAXV START CACHE CYCLE LAST CALLED <<< "${META}"
  cat >> "${SEQ_SQL}" <<EOF
CREATE SEQUENCE IF NOT EXISTS ${SCHEMA_NAME}."${seq}"
  INCREMENT BY ${INC}
  MINVALUE ${MINV}
  MAXVALUE ${MAXV}
  START WITH ${START}
  CACHE ${CACHE}
  ${CYCLE};

EOF
  echo "SELECT setval('${SCHEMA_NAME}.\"${seq}\"', ${LAST}, ${CALLED});" >> "${SEQVAL_SQL}"
done <<< "${SEQUENCES}"

# ---------- 表结构 ----------
TABLES="$(sql_t "SELECT tablename FROM pg_tables WHERE schemaname='${SCHEMA_NAME}' ORDER BY tablename;")"
echo "${TABLES}" > "${OUT_DIR}/tables.list"
TBL_COUNT=0
[[ -n "${TABLES}" ]] && TBL_COUNT="$(grep -c . "${OUT_DIR}/tables.list" || true)"
log "表: ${TBL_COUNT}"

while IFS= read -r tbl; do
  [[ -z "${tbl}" ]] && continue
  if [[ "${HAS_TABLEDEF}" == "true" ]]; then
    log "表结构: ${tbl}"
    DEF="$(sql_t "SELECT pg_get_tabledef('${SCHEMA_NAME}.${tbl}');" || true)"
    if [[ -n "${DEF}" ]]; then
      echo "${DEF}" >> "${TBL_SQL}"
      echo >> "${TBL_SQL}"
    else
      echo "-- WARN: pg_get_tabledef failed: ${SCHEMA_NAME}.${tbl}" >> "${TBL_SQL}"
    fi
  else
    echo "-- TABLE ${SCHEMA_NAME}.\"${tbl}\" (无 pg_get_tabledef)" >> "${TBL_SQL}"
  fi
done <<< "${TABLES}"

# 额外索引（pg_get_tabledef 已含时可忽略；再导一遍用 IF NOT EXISTS 不现实，仅无 tabledef 时）
if [[ "${HAS_TABLEDEF}" != "true" ]]; then
  sql_t "SELECT pg_get_indexdef(i.indexrelid) || ';' FROM pg_index i JOIN pg_class c ON c.oid=i.indrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='${SCHEMA_NAME}' AND c.relkind='r' AND NOT i.indisprimary ORDER BY 1;" >> "${TBL_SQL}" || true
fi

# ---------- 视图 ----------
VIEWS="$(sql_t "SELECT viewname FROM pg_views WHERE schemaname='${SCHEMA_NAME}' ORDER BY viewname;")"
echo "${VIEWS}" > "${OUT_DIR}/views.list"
VIEW_COUNT=0
[[ -n "${VIEWS}" ]] && VIEW_COUNT="$(grep -c . "${OUT_DIR}/views.list" || true)"
log "视图: ${VIEW_COUNT}"

while IFS= read -r v; do
  [[ -z "${v}" ]] && continue
  log "视图: ${v}"
  # 优先 pg_get_viewdef(oid)
  DEF="$(sql_t "SELECT pg_get_viewdef('${SCHEMA_NAME}.${v}'::regclass, true);" || true)"
  if [[ -z "${DEF}" ]]; then
    DEF="$(sql_t "SELECT definition FROM pg_views WHERE schemaname='${SCHEMA_NAME}' AND viewname='${v}';" || true)"
  fi
  if [[ -n "${DEF}" ]]; then
    # definition 可能已是完整 SELECT，也可能已带 AS
    cat >> "${VIEW_SQL}" <<EOF
CREATE OR REPLACE VIEW ${SCHEMA_NAME}."${v}" AS
${DEF};

EOF
  else
    echo "-- WARN: view def failed: ${v}" >> "${VIEW_SQL}"
  fi
done <<< "${VIEWS}"

# ---------- 函数 / 过程 ----------
if [[ "${HAS_PROKIND}" == "true" ]]; then
  ROUTINE_SQL_QUERY="SELECT p.oid::text || '|' || p.proname || '|' || COALESCE(p.prokind::text,'f') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='${SCHEMA_NAME}' AND p.prokind IN ('f','p') AND p.proname NOT LIKE 'pg_%' ORDER BY p.proname, p.oid;"
else
  # 老目录：导出非聚合函数；过程若以独立方式存在也会落在 pg_proc
  ROUTINE_SQL_QUERY="SELECT p.oid::text || '|' || p.proname || '|' || 'f' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='${SCHEMA_NAME}' AND NOT p.proisagg AND p.proname NOT LIKE 'pg_%' ORDER BY p.proname, p.oid;"
fi

ROUTINES="$(sql_t "${ROUTINE_SQL_QUERY}")"
echo "${ROUTINES}" > "${OUT_DIR}/routines.list"
ROUT_COUNT=0
[[ -n "${ROUTINES}" ]] && ROUT_COUNT="$(grep -c . "${OUT_DIR}/routines.list" || true)"
log "函数/过程: ${ROUT_COUNT}"

while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  OID="${line%%|*}"
  REST="${line#*|}"
  RNAME="${REST%%|*}"
  RKIND="${REST##*|}"
  log "例程(${RKIND}): ${RNAME} oid=${OID}"
  DEF="$(sql_t "SELECT pg_get_functiondef(${OID});" || true)"
  if [[ -n "${DEF}" ]]; then
    echo "${DEF};" >> "${ROUT_SQL}"
    echo >> "${ROUT_SQL}"
  else
    echo "-- WARN: pg_get_functiondef failed: ${RNAME} (${OID})" >> "${ROUT_SQL}"
  fi
done <<< "${ROUTINES}"

# ---------- 表数据 ----------
if [[ "${OBJECTS_ONLY}" != "true" ]]; then
  header "${DATA_SQL}" "table data"
  echo "BEGIN;" >> "${DATA_SQL}"
  while IFS= read -r tbl; do
    [[ -z "${tbl}" ]] && continue
    log "数据: ${tbl}"
    CONT_COPY="${CONTAINER_OUT}/${tbl}.copy"
    set +e
    sql -c "COPY ${SCHEMA_NAME}.\"${tbl}\" TO '${CONT_COPY}' WITH (FORMAT text, ENCODING 'UTF8');"
    COPY_RC=$?
    set -e
    if [[ ${COPY_RC} -ne 0 ]]; then
      log "WARN: COPY 失败 ${tbl}"
      echo "-- SKIP ${SCHEMA_NAME}.\"${tbl}\"" >> "${DATA_SQL}"
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
else
  echo "(objects-only, no data file)" > "${DATA_SQL}.skipped"
fi

cat > "${OUT_DIR}/meta.txt" <<EOF
backup_time=$(date -Iseconds)
method=gsql-full-objects
container=${CONTAINER_NAME}
db_name=${DB_NAME}
schema=${SCHEMA_NAME}
tables=${TBL_COUNT}
sequences=${SEQ_COUNT}
views=${VIEW_COUNT}
routines=${ROUT_COUNT}
objects_only=${OBJECTS_ONLY}
has_tabledef=${HAS_TABLEDEF}
has_prokind=${HAS_PROKIND}
restore_order=001_sequences.sql,002_tables.sql,003_views.sql,004_routines.sql,005_data.sql,006_sequence_values.sql
EOF

docker_db_exec rm -rf "${CONTAINER_OUT}" >/dev/null 2>&1 || true

ARCHIVE="${OUT_DIR}.tar.gz"
tar -czf "${ARCHIVE}" -C "${BACKUP_DIR}" "$(basename "${OUT_DIR}")"
SIZE="$(du -sh "${ARCHIVE}" | awk '{print $1}')"
log "备份成功: ${ARCHIVE} (${SIZE}) 表=${TBL_COUNT} 序列=${SEQ_COUNT} 视图=${VIEW_COUNT} 函数/过程=${ROUT_COUNT}"
log "还原: ./scripts/restore-gsql.sh ${ARCHIVE}"

if [[ "${DO_CLEANUP}" == "true" ]]; then
  find "${BACKUP_DIR}" -maxdepth 1 -name "${DB_NAME}_${SCHEMA_NAME}_gsql_*.tar.gz" -mtime +"${KEEP_DAYS}" -print -delete 2>/dev/null || true
  find "${BACKUP_DIR}" -maxdepth 1 -type d -name "${DB_NAME}_${SCHEMA_NAME}_gsql_*" -mtime +"${KEEP_DAYS}" -print -exec rm -rf {} + 2>/dev/null || true
fi

echo "${ARCHIVE}"
