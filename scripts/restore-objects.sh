#!/usr/bin/env bash
# 还原 backup-objects.sh 产物（序列 / 视图 / 函数 / 序列值）
#
# 用法:
#   bash restore-objects.sh ./backups/objects_YYYYmmdd_HHMMSS
#   CONTAINER=monitordb DB=monitor bash restore-objects.sh ./backups/objects_xxx
#
# 还原顺序:
#   1) 001_sequences.sql
#   2) 003_views.sql
#   3) 004_routines.sql
#   4) 006_sequence_values.sql
set -euo pipefail

CONTAINER="${CONTAINER:-monitordb}"
DB="${DB:-monitor}"
GAUSSHOME="${GAUSSHOME:-/usr/local/opengauss}"
GS_BIN="${GAUSSHOME}/bin/gsql"

SRC="${1:-}"
if [[ -z "${SRC}" ]]; then
  echo "用法: bash restore-objects.sh <备份目录>"
  echo "示例: bash restore-objects.sh ./backups/objects_20260715_161248"
  exit 1
fi
[[ -d "${SRC}" ]] || { echo "ERROR: 目录不存在: ${SRC}"; exit 1; }

run_file() {
  local host_file="$1"
  local label="$2"
  if [[ ! -f "${host_file}" ]]; then
    echo "跳过 ${label}（无文件: $(basename "${host_file}")）"
    return 0
  fi
  local base remote
  base="$(basename "${host_file}")"
  remote="/tmp/restore_${base}"
  echo "---- 还原 ${label}: ${base} ----"
  docker cp "${host_file}" "${CONTAINER}:${remote}"
  set +e
  docker exec -u omm \
    -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" \
    "${CONTAINER}" \
    "${GS_BIN}" -p 5432 -d "${DB}" -f "${remote}"
  local rc=$?
  set -e
  docker exec "${CONTAINER}" rm -f "${remote}" >/dev/null 2>&1 || true
  if [[ ${rc} -ne 0 ]]; then
    echo "WARN: ${label} 执行结束码=${rc}（请检查上方报错；常见为对象已存在可忽略）"
  else
    echo "OK: ${label}"
  fi
}

echo "==== 还原对象: container=${CONTAINER} db=${DB} src=${SRC} ===="

run_file "${SRC}/001_sequences.sql" "序列定义"
run_file "${SRC}/003_views.sql" "视图"
run_file "${SRC}/004_routines.sql" "函数/过程"
run_file "${SRC}/006_sequence_values.sql" "序列当前值"

echo
echo "==== 还原后校验 ===="
docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
  "${GS_BIN}" -p 5432 -d "${DB}" -c "
SELECT 'sequences' AS kind, count(*)::text AS cnt FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='S'
UNION ALL
SELECT 'views', count(*)::text FROM pg_views WHERE schemaname='public'
UNION ALL
SELECT 'routines', count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='public' AND l.lanname NOT IN ('internal','c');
"

echo "==== 还原完成 ===="
