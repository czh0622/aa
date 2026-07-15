#!/usr/bin/env bash
# 将源库克隆到测试库（openGauss 不支持 CREATE DATABASE ... TEMPLATE monitor）
# 流程: template0 建库 -> 建表结构 -> COPY 数据 -> 序列/视图/函数
#
# 用法:
#   bash clone-db.sh
#   SRC_DB=monitor DST_DB=monitor_test bash clone-db.sh
#   bash clone-db.sh --data-only          # 假定目标库表已存在，只拷数据+对象
#   bash clone-db.sh --structure-only     # 只建库建表，不拷数据
set -euo pipefail

CONTAINER="${CONTAINER:-monitordb}"
SRC_DB="${SRC_DB:-monitor}"
DST_DB="${DST_DB:-monitor_test}"
GAUSSHOME="${GAUSSHOME:-/usr/local/opengauss}"
GS_BIN="${GAUSSHOME}/bin/gsql"
SCHEMA="${SCHEMA:-public}"
MODE=all   # all | data-only | structure-only

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-only) MODE=data-only; shift ;;
    --structure-only) MODE=structure-only; shift ;;
    -h|--help)
      echo "用法: SRC_DB=monitor DST_DB=monitor_test bash clone-db.sh [--data-only|--structure-only]"
      exit 0
      ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

run() {
  local db="$1"; shift
  docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
    "${GS_BIN}" -p 5432 -d "${db}" "$@"
}

echo "==== 克隆 ${SRC_DB} -> ${DST_DB} (mode=${MODE}) ===="

# 1) 建库（只能 template0）
EXISTS="$(run postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DST_DB}';" | tr -d '[:space:]' || true)"
if [[ "${EXISTS}" != "1" ]]; then
  echo "创建数据库 ${DST_DB} (TEMPLATE template0)"
  run postgres -c "CREATE DATABASE ${DST_DB} TEMPLATE template0 ENCODING 'UTF8';"
else
  echo "数据库已存在: ${DST_DB}"
fi

WORK="./backups/clone_${SRC_DB}_to_${DST_DB}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${WORK}"
run "${SRC_DB}" -tAc "SELECT tablename FROM pg_tables WHERE schemaname='${SCHEMA}' ORDER BY 1;" \
  | tr -d '\r' | sed '/^$/d' > "${WORK}/tables.list"
TABLE_N=$(grep -c . "${WORK}/tables.list" || echo 0)
echo "源库表数量: ${TABLE_N}"

# 2) 建表结构
if [[ "${MODE}" != "data-only" ]]; then
  echo "---- 复制表结构 ----"
  : > "${WORK}/002_tables.sql"
  echo "SET search_path TO ${SCHEMA}, public;" >> "${WORK}/002_tables.sql"

  while read -r t; do
    [[ -z "${t}" ]] && continue
    HAS="$(run "${DST_DB}" -tAc "SELECT 1 FROM information_schema.tables WHERE table_schema='${SCHEMA}' AND table_name='${t}';" | tr -d '[:space:]' || true)"
    if [[ "${HAS}" == "1" ]]; then
      echo "表已存在,跳过结构: ${t}"
      continue
    fi

    echo "建表: ${t}"
    DEF="$(run "${SRC_DB}" -tAc "SELECT pg_get_tabledef('${SCHEMA}.${t}');" 2>/dev/null | tr -d '\r' || true)"
    if [[ -n "${DEF}" ]]; then
      echo "${DEF}" >> "${WORK}/002_tables.sql"
      echo >> "${WORK}/002_tables.sql"
      continue
    fi

    # 兜底：用 information_schema 拼简易 CREATE TABLE（无约束/索引，后续尽量补主键）
    echo "WARN: pg_get_tabledef 失败，改用 information_schema 拼装: ${t}"
    COLS="$(run "${SRC_DB}" -tAc "
SELECT string_agg(
  quote_ident(column_name) || ' ' ||
  CASE
    WHEN data_type IN ('character varying','varchar') AND character_maximum_length IS NOT NULL
      THEN 'varchar(' || character_maximum_length || ')'
    WHEN data_type IN ('character','char') AND character_maximum_length IS NOT NULL
      THEN 'char(' || character_maximum_length || ')'
    WHEN data_type = 'numeric' AND numeric_precision IS NOT NULL
      THEN 'numeric(' || numeric_precision || ',' || COALESCE(numeric_scale,0) || ')'
    WHEN data_type = 'timestamp without time zone' THEN 'timestamp'
    WHEN data_type = 'timestamp with time zone' THEN 'timestamptz'
    WHEN data_type = 'time without time zone' THEN 'time'
    WHEN data_type = 'double precision' THEN 'float8'
    WHEN data_type = 'real' THEN 'float4'
    WHEN data_type = 'integer' THEN 'int4'
    WHEN data_type = 'bigint' THEN 'int8'
    WHEN data_type = 'smallint' THEN 'int2'
    WHEN data_type = 'boolean' THEN 'bool'
    WHEN data_type = 'text' THEN 'text'
    WHEN data_type = 'bytea' THEN 'bytea'
    WHEN data_type = 'json' THEN 'json'
    WHEN data_type = 'jsonb' THEN 'jsonb'
    WHEN data_type = 'uuid' THEN 'uuid'
    WHEN data_type = 'date' THEN 'date'
    WHEN udt_name IS NOT NULL THEN udt_name
    ELSE data_type
  END ||
  CASE WHEN is_nullable='NO' THEN ' NOT NULL' ELSE '' END,
  ', ' ORDER BY ordinal_position
)
FROM information_schema.columns
WHERE table_schema='${SCHEMA}' AND table_name='${t}';
" | tr -d '\r')"

    if [[ -z "${COLS}" ]]; then
      echo "ERROR: 无法获取列定义: ${t}" >&2
      continue
    fi
    echo "CREATE TABLE ${SCHEMA}.\"${t}\" (${COLS});" >> "${WORK}/002_tables.sql"
  done < "${WORK}/tables.list"

  docker cp "${WORK}/002_tables.sql" "${CONTAINER}:/tmp/clone_tables.sql"
  set +e
  run "${DST_DB}" -f /tmp/clone_tables.sql
  set -e
  docker exec "${CONTAINER}" rm -f /tmp/clone_tables.sql >/dev/null 2>&1 || true

  # 尝试补主键
  echo "---- 尝试复制主键 ----"
  while read -r t; do
    [[ -z "${t}" ]] && continue
    PKCOLS="$(run "${SRC_DB}" -tAc "
SELECT string_agg(quote_ident(kcu.column_name), ', ' ORDER BY kcu.ordinal_position)
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name=kcu.constraint_name AND tc.table_schema=kcu.table_schema
WHERE tc.table_schema='${SCHEMA}' AND tc.table_name='${t}' AND tc.constraint_type='PRIMARY KEY';
" | tr -d '\r' || true)"
    [[ -z "${PKCOLS}" ]] && continue
    set +e
    run "${DST_DB}" -c "ALTER TABLE ${SCHEMA}.\"${t}\" ADD PRIMARY KEY (${PKCOLS});" >/dev/null 2>&1
    set -e
  done < "${WORK}/tables.list"
fi

# 3) 拷数据
if [[ "${MODE}" != "structure-only" ]]; then
  echo "---- COPY 表数据 ----"
  while read -r t; do
    [[ -z "${t}" ]] && continue
    HAS="$(run "${DST_DB}" -tAc "SELECT 1 FROM information_schema.tables WHERE table_schema='${SCHEMA}' AND table_name='${t}';" | tr -d '[:space:]' || true)"
    if [[ "${HAS}" != "1" ]]; then
      echo "WARN: 目标库无表 ${t}，跳过数据"
      continue
    fi
    echo "数据: ${t}"
    run "${SRC_DB}" -c "COPY ${SCHEMA}.\"${t}\" TO '/tmp/clone_${t}.copy' WITH (FORMAT text, ENCODING 'UTF8');"
    set +e
    run "${DST_DB}" -c "TRUNCATE ${SCHEMA}.\"${t}\" CASCADE; COPY ${SCHEMA}.\"${t}\" FROM '/tmp/clone_${t}.copy' WITH (FORMAT text, ENCODING 'UTF8');"
    rc=$?
    set -e
    docker exec "${CONTAINER}" rm -f "/tmp/clone_${t}.copy" >/dev/null 2>&1 || true
    [[ ${rc} -eq 0 ]] && echo "OK: ${t}" || echo "WARN: ${t} 数据复制失败"
  done < "${WORK}/tables.list"
fi

# 4) 对象：序列/视图/函数（复用 backup-objects 逻辑的精简版）
if [[ "${MODE}" != "structure-only" ]]; then
  echo "---- 复制序列/视图/函数 ----"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "${SCRIPT_DIR}/backup-objects.sh" ]]; then
    OUT="${WORK}/objects"
    CONTAINER="${CONTAINER}" DB="${SRC_DB}" SCHEMA="${SCHEMA}" OUT="${OUT}" \
      bash "${SCRIPT_DIR}/backup-objects.sh"
    CONTAINER="${CONTAINER}" DB="${DST_DB}" \
      bash "${SCRIPT_DIR}/restore-objects.sh" "${OUT}"
  else
    echo "WARN: 未找到 backup-objects.sh，请手动:"
    echo "  DB=${SRC_DB} bash backup-objects.sh"
    echo "  DB=${DST_DB} bash restore-objects.sh ./backups/objects_xxx"
  fi
fi

echo
echo "==== 克隆完成: ${SRC_DB} -> ${DST_DB} ===="
echo "工作目录: ${WORK}"
run "${DST_DB}" -c "
SELECT 'tables' AS kind, count(*)::text AS cnt FROM information_schema.tables WHERE table_schema='${SCHEMA}' AND table_type='BASE TABLE'
UNION ALL
SELECT 'views', count(*)::text FROM pg_views WHERE schemaname='${SCHEMA}'
UNION ALL
SELECT 'routines', count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='${SCHEMA}' AND l.lanname NOT IN ('internal','c');
"
