#!/usr/bin/env bash
# 文件系统级克隆单库（绕过 CREATE FUNCTION / gs_dump）
# 停库后把 monitor 的 base/<oid> 目录覆盖到 monitor_test 的 base/<oid>
#
# 用法: bash clone-db-fs.sh --drop-dst
set -euo pipefail

CONTAINER="${CONTAINER:-monitordb}"
SRC_DB="${SRC_DB:-monitor}"
DST_DB="${DST_DB:-monitor_test}"
PGDATA="${PGDATA:-/var/lib/opengauss/data}"
GAUSSHOME="${GAUSSHOME:-/usr/local/opengauss}"
GS="${GAUSSHOME}/bin/gsql"
DROP_DST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --drop-dst) DROP_DST=true; shift ;;
    -h|--help) echo "用法: bash clone-db-fs.sh [--drop-dst]"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

run() {
  docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
    "${GS}" -p 5432 -d postgres "$@"
}

echo "==== 文件系统克隆 ${SRC_DB} -> ${DST_DB} ===="
echo "警告: 将完全覆盖 ${DST_DB}（含函数/视图/表），短暂停库"

if [[ "${DROP_DST}" == "true" ]]; then
  run -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('${SRC_DB}','${DST_DB}') AND pid<>pg_backend_pid();" >/dev/null 2>&1 || true
  run -c "DROP DATABASE IF EXISTS ${DST_DB};"
fi

EXISTS=$(run -tAc "SELECT 1 FROM pg_database WHERE datname='${DST_DB}';" | tr -d '[:space:]' || true)
if [[ "${EXISTS}" != "1" ]]; then
  run -c "CREATE DATABASE ${DST_DB} TEMPLATE template0 ENCODING 'UTF8';"
fi

SRC_OID=$(run -tAc "SELECT oid FROM pg_database WHERE datname='${SRC_DB}';" | tr -d '[:space:]')
DST_OID=$(run -tAc "SELECT oid FROM pg_database WHERE datname='${DST_DB}';" | tr -d '[:space:]')
echo "源 OID=${SRC_OID}  目标 OID=${DST_OID}"

echo "停止容器 ${CONTAINER}..."
docker stop "${CONTAINER}" >/dev/null

echo "复制 ${PGDATA}/base/${SRC_OID} -> ${PGDATA}/base/${DST_OID}"
docker run --rm --volumes-from "${CONTAINER}" busybox sh -c "
  set -e
  SRC='${PGDATA}/base/${SRC_OID}'
  DST='${PGDATA}/base/${DST_OID}'
  test -d \"\$SRC\" || { echo 'ERROR: 源目录不存在'; exit 1; }
  mkdir -p \"\$DST\"
  rm -rf \"\$DST\"/*
  cp -a \"\$SRC\"/. \"\$DST\"/
  echo done
" || {
  echo "busybox 不可用，尝试 docker start 后 exec 复制..."
  docker start "${CONTAINER}" >/dev/null
  sleep 3
  docker exec -u 0 "${CONTAINER}" bash -c "
    set -e
    rm -rf '${PGDATA}/base/${DST_OID}'/*
    cp -a '${PGDATA}/base/${SRC_OID}'/. '${PGDATA}/base/${DST_OID}'/
    chown -R omm:omm '${PGDATA}/base/${DST_OID}'
  "
  docker stop "${CONTAINER}" >/dev/null
}

docker start "${CONTAINER}" >/dev/null
for i in $(seq 1 40); do
  docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
    "${GS}" -p 5432 -d postgres -c 'SELECT 1;' >/dev/null 2>&1 && break
  sleep 2
done

echo "---- 校验 ${DST_DB} ----"
docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
  "${GS}" -p 5432 -d "${DST_DB}" -c "
SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' ORDER BY 1;
"
echo "==== 完成 ===="
