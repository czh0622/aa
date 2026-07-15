#!/usr/bin/env bash
# 将源库克隆到测试库（openGauss 不支持 CREATE DATABASE ... TEMPLATE monitor）
# 修复点:
#   1) SQL 用 stdin 喂给 gsql，避免 docker cp 到 /tmp 后 omm 无权限读
#   2) 避开 information_schema（会触发 OID 3483 / _pg_expandarray）
#   3) 表结构用 pg_catalog 拼装；主键可选且失败即跳过
#
# 用法:
#   bash clone-db.sh
#   SRC_DB=monitor DST_DB=monitor_test bash clone-db.sh
#   bash clone-db.sh --drop-dst          # 先删目标库再重建（推荐重跑）
#   bash clone-db.sh --data-only
#   bash clone-db.sh --structure-only
set -euo pipefail

CONTAINER="${CONTAINER:-monitordb}"
SRC_DB="${SRC_DB:-monitor}"
DST_DB="${DST_DB:-monitor_test}"
GAUSSHOME="${GAUSSHOME:-/usr/local/opengauss}"
GS_BIN="${GAUSSHOME}/bin/gsql"
SCHEMA="${SCHEMA:-public}"
MODE=all
DROP_DST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-only) MODE=data-only; shift ;;
    --structure-only) MODE=structure-only; shift ;;
    --drop-dst) DROP_DST=true; shift ;;
    -h|--help)
      echo "用法: SRC_DB=monitor DST_DB=monitor_test bash clone-db.sh [--drop-dst|--data-only|--structure-only]"
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

# 通过 stdin 执行 SQL 文件（解决 /tmp 权限 denied）
run_file() {
  local db="$1" file="$2"
  docker exec -i -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
    "${GS_BIN}" -p 5432 -d "${db}" -v ON_ERROR_STOP=0 -f - < "${file}"
}

# 仅用 pg_catalog 判断表是否存在
table_exists() {
  local db="$1" tbl="$2"
  run "${db}" -tAc "
SELECT 1 FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='${SCHEMA}' AND c.relname='${tbl}' AND c.relkind='r';
" 2>/dev/null | tr -d '[:space:]' || true
}

echo "==== 克隆 ${SRC_DB} -> ${DST_DB} (mode=${MODE}) ===="

# 1) 建库
if [[ "${DROP_DST}" == "true" ]]; then
  echo "删除目标库（若存在）: ${DST_DB}"
  run postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DST_DB}' AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
  run postgres -c "DROP DATABASE IF EXISTS ${DST_DB};" || true
fi

EXISTS="$(run postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DST_DB}';" | tr -d '[:space:]' || true)"
if [[ "${EXISTS}" != "1" ]]; then
  echo "创建数据库 ${DST_DB} (TEMPLATE template0)"
  run postgres -c "CREATE DATABASE ${DST_DB} TEMPLATE template0 ENCODING 'UTF8';"
else
  echo "数据库已存在: ${DST_DB}"
fi

WORK="./backups/clone_${SRC_DB}_to_${DST_DB}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${WORK}"
run "${SRC_DB}" -tAc "
SELECT c.relname FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='${SCHEMA}' AND c.relkind='r'
ORDER BY 1;
" | tr -d '\r' | sed '/^$/d' > "${WORK}/tables.list"
TABLE_N=$(grep -c . "${WORK}/tables.list" || echo 0)
echo "源库表数量: ${TABLE_N}"

# 2) 建表结构（pg_catalog，不用 information_schema）
if [[ "${MODE}" != "data-only" ]]; then
  echo "---- 复制表结构 ----"
  {
    echo "SET client_min_messages TO WARNING;"
    echo "SET search_path TO ${SCHEMA}, public;"
  } > "${WORK}/002_tables.sql"

  OK_STRUCT=0
  FAIL_STRUCT=0
  while read -r t; do
    [[ -z "${t}" ]] && continue
    if [[ "$(table_exists "${DST_DB}" "${t}")" == "1" ]]; then
      echo "表已存在,跳过结构: ${t}"
      continue
    fi

    echo "建表: ${t}"
    # 优先 pg_get_tabledef
    DEF="$(run "${SRC_DB}" -tAc "SELECT pg_get_tabledef('${SCHEMA}.${t}');" 2>/dev/null | tr -d '\r' || true)"
    if [[ -n "${DEF}" ]]; then
      echo "${DEF}" >> "${WORK}/002_tables.sql"
      echo >> "${WORK}/002_tables.sql"
      OK_STRUCT=$((OK_STRUCT + 1))
      continue
    fi

    # 兜底：pg_attribute + pg_type（避开 format_type / information_schema）
    echo "WARN: pg_get_tabledef 失败，改用 pg_catalog 拼装: ${t}"
    COLS="$(run "${SRC_DB}" -tAc "
SELECT string_agg(coldef, ', ' ORDER BY attnum) FROM (
  SELECT a.attnum,
    quote_ident(a.attname) || ' ' ||
    CASE
      WHEN t.typname IN ('varchar','bpchar') AND a.atttypmod > 4
        THEN t.typname || '(' || (a.atttypmod - 4) || ')'
      WHEN t.typname = 'numeric' AND a.atttypmod > 4
        THEN 'numeric(' || (((a.atttypmod - 4) >> 16) & 65535) || ',' || ((a.atttypmod - 4) & 65535) || ')'
      WHEN n2.nspname IS NOT NULL AND n2.nspname <> 'pg_catalog'
        THEN quote_ident(n2.nspname) || '.' || quote_ident(t.typname)
      ELSE t.typname
    END ||
    CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END AS coldef
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_type t ON t.oid = a.atttypid
  LEFT JOIN pg_namespace n2 ON n2.oid = t.typnamespace
  WHERE n.nspname='${SCHEMA}' AND c.relname='${t}' AND c.relkind='r'
    AND a.attnum > 0 AND NOT a.attisdropped
) s;
" 2>/dev/null | tr -d '\r' || true)"

    if [[ -z "${COLS}" ]]; then
      echo "ERROR: 无法获取列定义: ${t}" >&2
      FAIL_STRUCT=$((FAIL_STRUCT + 1))
      continue
    fi
    echo "CREATE TABLE ${SCHEMA}.\"${t}\" (${COLS});" >> "${WORK}/002_tables.sql"
    OK_STRUCT=$((OK_STRUCT + 1))
  done < "${WORK}/tables.list"

  echo "执行建表 SQL（stdin）..."
  set +e
  run_file "${DST_DB}" "${WORK}/002_tables.sql" | tee "${WORK}/002_tables.apply.log"
  set -e

  DST_TABLE_N=0
  while read -r t; do
    [[ -z "${t}" ]] && continue
    [[ "$(table_exists "${DST_DB}" "${t}")" == "1" ]] && DST_TABLE_N=$((DST_TABLE_N + 1))
  done < "${WORK}/tables.list"
  echo "结构结果: 计划写 ${OK_STRUCT} 张, 目标库现有 ${DST_TABLE_N}/${TABLE_N} 张表"

  # 主键：用 indkey::text 拆 attnum，避开 _pg_expandarray / information_schema
  echo "---- 尝试复制主键（失败可忽略）----"
  while read -r t; do
    [[ -z "${t}" ]] && continue
    [[ "$(table_exists "${DST_DB}" "${t}")" != "1" ]] && continue
    INDKEY="$(run "${SRC_DB}" -tAc "
SELECT i.indkey::text
FROM pg_index i
JOIN pg_class c ON c.oid=i.indrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='${SCHEMA}' AND c.relname='${t}' AND i.indisprimary
LIMIT 1;
" 2>/dev/null | tr -d '\r' || true)"
    [[ -z "${INDKEY}" ]] && continue
    PK_PARTS=()
    for attnum in ${INDKEY}; do
      [[ "${attnum}" == "0" ]] && continue
      col="$(run "${SRC_DB}" -tAc "
SELECT a.attname FROM pg_attribute a
JOIN pg_class c ON c.oid=a.attrelid
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='${SCHEMA}' AND c.relname='${t}' AND a.attnum=${attnum};
" 2>/dev/null | tr -d '\r' || true)"
      [[ -n "${col}" ]] && PK_PARTS+=("\"${col}\"")
    done
    [[ ${#PK_PARTS[@]} -eq 0 ]] && continue
    PKSQL="$(IFS=','; echo "${PK_PARTS[*]}")"
    set +e
    run "${DST_DB}" -c "ALTER TABLE ${SCHEMA}.\"${t}\" ADD PRIMARY KEY (${PKSQL});" >/dev/null 2>&1
    set -e
  done < "${WORK}/tables.list"
fi

# 3) 拷数据（COPY 文件写在容器 /tmp，由服务端进程创建，omm 可读写）
if [[ "${MODE}" != "structure-only" ]]; then
  echo "---- COPY 表数据 ----"
  OK_DATA=0
  SKIP_DATA=0
  while read -r t; do
    [[ -z "${t}" ]] && continue
    if [[ "$(table_exists "${DST_DB}" "${t}")" != "1" ]]; then
      echo "WARN: 目标库无表 ${t}，跳过数据"
      SKIP_DATA=$((SKIP_DATA + 1))
      continue
    fi
    echo "数据: ${t}"
    set +e
    run "${SRC_DB}" -c "COPY ${SCHEMA}.\"${t}\" TO '/tmp/clone_${t}.copy' WITH (FORMAT text, ENCODING 'UTF8');"
    run "${DST_DB}" -c "TRUNCATE ${SCHEMA}.\"${t}\" CASCADE; COPY ${SCHEMA}.\"${t}\" FROM '/tmp/clone_${t}.copy' WITH (FORMAT text, ENCODING 'UTF8');"
    rc=$?
    set -e
    docker exec "${CONTAINER}" rm -f "/tmp/clone_${t}.copy" >/dev/null 2>&1 || true
    if [[ ${rc} -eq 0 ]]; then
      echo "OK: ${t}"
      OK_DATA=$((OK_DATA + 1))
    else
      echo "WARN: ${t} 数据复制失败"
    fi
  done < "${WORK}/tables.list"
  echo "数据结果: 成功 ${OK_DATA}, 跳过(无表) ${SKIP_DATA}"
fi

# 4) 对象
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
    echo "WARN: 未找到 backup-objects.sh，请手动还原对象"
  fi
fi

echo
echo "==== 克隆完成: ${SRC_DB} -> ${DST_DB} ===="
echo "工作目录: ${WORK}"
run "${DST_DB}" -tAc "
SELECT 'tables|' || count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='${SCHEMA}' AND c.relkind='r'
UNION ALL
SELECT 'views|' || count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='${SCHEMA}' AND c.relkind='v'
UNION ALL
SELECT 'routines|' || count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='${SCHEMA}' AND l.lanname NOT IN ('internal','c');
"
