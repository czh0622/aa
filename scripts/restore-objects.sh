#!/usr/bin/env bash
# 还原 backup-objects.sh 产物（序列 / 函数 / 视图 / 序列值）
#
# 顺序很重要：视图可能依赖函数，必须先函数后视图
#
# 用法:
#   DB=monitor_test bash restore-objects.sh ./backups/objects_xxx
#   DB=monitor_test bash restore-objects.sh --create-db ./backups/objects_xxx
set -euo pipefail

CONTAINER="${CONTAINER:-monitordb}"
DB="${DB:-monitor}"
GAUSSHOME="${GAUSSHOME:-/usr/local/opengauss}"
GS_BIN="${GAUSSHOME}/bin/gsql"
CREATE_DB=false
SRC=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --create-db) CREATE_DB=true; shift ;;
    -h|--help)
      echo "用法: DB=monitor_test bash restore-objects.sh [--create-db] <备份目录>"
      exit 0
      ;;
    *) SRC="$1"; shift ;;
  esac
done

[[ -n "${SRC}" && -d "${SRC}" ]] || {
  echo "用法: DB=monitor_test bash restore-objects.sh [--create-db] <备份目录>"
  exit 1
}

run_sql() {
  docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
    "${GS_BIN}" -p 5432 "$@"
}

if [[ "${CREATE_DB}" == "true" ]]; then
  EXISTS="$(run_sql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB}';" | tr -d '[:space:]' || true)"
  if [[ "${EXISTS}" != "1" ]]; then
    echo "创建数据库: ${DB}"
    run_sql -d postgres -c "CREATE DATABASE ${DB} TEMPLATE template0 ENCODING 'UTF8';"
  else
    echo "数据库已存在: ${DB}"
  fi
fi

run_file() {
  local host_file="$1"
  local label="$2"
  if [[ ! -f "${host_file}" ]]; then
    echo "跳过 ${label}（无文件: $(basename "${host_file}")）"
    return 0
  fi
  local base remote
  base="$(basename "${host_file}")"
  remote="/home/omm/_restore_${base}.$$"
  echo "---- 还原 ${label}: ${base} -> db=${DB} ----"
  docker cp "${host_file}" "${CONTAINER}:${remote}"
  docker exec -u 0 "${CONTAINER}" chown omm:omm "${remote}"
  docker exec -u 0 "${CONTAINER}" chmod 644 "${remote}"
  set +e
  docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
    "${GS_BIN}" -p 5432 -d "${DB}" -f "${remote}"
  local rc=$?
  set -e
  docker exec -u 0 "${CONTAINER}" rm -f "${remote}" >/dev/null 2>&1 || true
  if [[ ${rc} -ne 0 ]]; then
    echo "WARN: ${label} 执行结束码=${rc}"
  else
    echo "OK: ${label}"
  fi
}

echo "==== 还原对象: container=${CONTAINER} db=${DB} src=${SRC} ===="

# 探测：本实例能否 CREATE FUNCTION（OID 3483 常导致失败）
echo "---- 探测 CREATE FUNCTION ----"
set +e
PROBE_OUT="$(run_sql -d "${DB}" -c "CREATE OR REPLACE FUNCTION public.__probe_fn_restore() RETURNS integer LANGUAGE sql AS 'SELECT 1';" 2>&1)"
PROBE_RC=$?
set -e
echo "${PROBE_OUT}"
if echo "${PROBE_OUT}" | grep -q "OID 3483"; then
  echo
  echo "ERROR: 当前实例 CREATE FUNCTION 会触发 OID 3483，函数无法在 ${DB} 中创建。"
  echo "这是 openGauss 系统目录异常（与 gs_dump 失败同源），不是脚本语法问题。"
  echo "建议先在库内执行诊断："
  echo "  SELECT oid,relname,relkind FROM pg_class WHERE oid=3483;"
  echo "  SELECT oid,relname FROM pg_class WHERE oid BETWEEN 3470 AND 3490 ORDER BY 1;"
  echo "在目录修复前：表数据/序列仍可用；依赖函数的视图会失败。"
  echo "将跳过函数还原，仍尝试还原序列与不依赖函数的视图。"
  SKIP_FUNCS=true
else
  SKIP_FUNCS=false
  run_sql -d "${DB}" -c "DROP FUNCTION IF EXISTS public.__probe_fn_restore();" >/dev/null 2>&1 || true
fi

# 正确顺序：序列 -> 函数 -> 视图 -> 序列值
run_file "${SRC}/001_sequences.sql" "序列定义"
if [[ "${SKIP_FUNCS}" != "true" ]]; then
  # 优先用简化版（若存在）
  if [[ -f "${SRC}/004_routines_simple.sql" ]]; then
    run_file "${SRC}/004_routines_simple.sql" "函数/过程(simple)"
  else
    run_file "${SRC}/004_routines.sql" "函数/过程"
  fi
else
  echo "跳过函数还原（CREATE FUNCTION 不可用）"
fi
run_file "${SRC}/003_views.sql" "视图"
run_file "${SRC}/006_sequence_values.sql" "序列当前值"

echo
echo "==== 还原后校验 (db=${DB}) ===="
run_sql -d "${DB}" -c "
SELECT 'sequences' AS kind, count(*)::text AS cnt FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='S'
UNION ALL
SELECT 'views', count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='v'
UNION ALL
SELECT 'routines', count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='public' AND l.lanname NOT IN ('internal','c') AND p.proname <> '__probe_fn_restore';
"

echo "==== 还原完成 -> ${DB} ===="
