#!/usr/bin/env bash
# 将方案 A 的表数据 (.copy) 还原到指定库（如 monitor_test）
#
# 用法:
#   DB=monitor_test bash restore-table-data.sh --create-db ./backups/gsql_时间戳
#   DB=monitor_test bash restore-table-data.sh ./backups/gsql_时间戳
#
# 注意: 目标库须已有同名表结构。空库可先用「整库克隆」建结构，或手工建表。
set -euo pipefail

CONTAINER="${CONTAINER:-monitordb}"
DB="${DB:-monitor_test}"
GAUSSHOME="${GAUSSHOME:-/usr/local/opengauss}"
GS_BIN="${GAUSSHOME}/bin/gsql"
CREATE_DB=false
DATA_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --create-db) CREATE_DB=true; shift ;;
    -h|--help)
      echo "用法: DB=monitor_test bash restore-table-data.sh [--create-db] <gsql备份目录>"
      exit 0
      ;;
    *) DATA_DIR="$1"; shift ;;
  esac
done

[[ -n "${DATA_DIR}" && -d "${DATA_DIR}" ]] || { echo "ERROR: 请指定方案A备份目录（含 tables.list 与 *.copy）"; exit 1; }
[[ -f "${DATA_DIR}/tables.list" ]] || { echo "ERROR: 缺少 tables.list"; exit 1; }

run_sql() {
  docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" "${GS_BIN}" -p 5432 "$@"
}

if [[ "${CREATE_DB}" == "true" ]]; then
  EXISTS="$(run_sql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB}';" | tr -d '[:space:]' || true)"
  if [[ "${EXISTS}" != "1" ]]; then
    echo "创建数据库: ${DB}"
    run_sql -d postgres -c "CREATE DATABASE ${DB} ENCODING 'UTF8';"
  else
    echo "数据库已存在: ${DB}"
  fi
fi

echo "==== 还原表数据 -> ${DB} 来自 ${DATA_DIR} ===="
while read -r t; do
  [[ -z "${t}" ]] && continue
  COPY_FILE="${DATA_DIR}/${t}.copy"
  if [[ ! -f "${COPY_FILE}" ]]; then
    echo "跳过 ${t}（无 ${t}.copy）"
    continue
  fi
  HAS="$(run_sql -d "${DB}" -tAc "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='${t}';" | tr -d '[:space:]' || true)"
  if [[ "${HAS}" != "1" ]]; then
    echo "WARN: ${DB} 中不存在表 ${t}，跳过。请先建表结构。"
    continue
  fi
  echo "还原表数据: ${t}"
  docker cp "${COPY_FILE}" "${CONTAINER}:/tmp/${t}.copy"
  set +e
  run_sql -d "${DB}" -c "TRUNCATE public.\"${t}\" CASCADE; COPY public.\"${t}\" FROM '/tmp/${t}.copy' WITH (FORMAT text, ENCODING 'UTF8');"
  rc=$?
  set -e
  docker exec "${CONTAINER}" rm -f "/tmp/${t}.copy" >/dev/null 2>&1 || true
  if [[ ${rc} -ne 0 ]]; then
    echo "WARN: 表 ${t} 数据还原失败"
  else
    echo "OK: ${t}"
  fi
done < "${DATA_DIR}/tables.list"

echo "==== 表数据还原完成 -> ${DB} ===="
