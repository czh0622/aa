#!/usr/bin/env bash
# OID 3483 / gs_dump / CREATE FUNCTION 失败诊断
set -euo pipefail

CONTAINER="${CONTAINER:-monitordb}"
DB="${DB:-monitor}"
GAUSSHOME="${GAUSSHOME:-/usr/local/opengauss}"
GS="${GAUSSHOME}/bin/gsql"

run() {
  docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
    "${GS}" -p 5432 -d "${DB}" "$@"
}

echo "==== openGauss OID 3483 诊断 db=${DB} container=${CONTAINER} ===="

echo
echo "---- 1) OID 3483 是什么 ----"
run -c "SELECT oid, relname, relkind, relnamespace::regnamespace AS nsp FROM pg_class WHERE oid=3483;" || true
run -c "SELECT oid, relname, relkind FROM pg_class WHERE oid BETWEEN 3475 AND 3490 ORDER BY oid;" || true

echo
echo "---- 2) 流复制查询（gs_dump 失败点）----"
set +e
run -c "SELECT local_role FROM pg_catalog.pg_stat_get_stream_replications();" 2>&1
set -e

echo
echo "---- 3) CREATE FUNCTION 探测 ----"
for testdb in "${DB}" monitor monitor_test postgres; do
  echo ">> db=${testdb}"
  set +e
  docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
    "${GS}" -p 5432 -d "${testdb}" -c \
    "CREATE OR REPLACE FUNCTION public.__oid_probe_${testdb//-/_}() RETURNS int LANGUAGE sql AS 'SELECT 1';" 2>&1
  set -e
done

echo
echo "---- 4) 现有用户函数 ----"
run -c "SELECT p.oid, p.proname, l.lanname, length(p.prosrc) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='public' AND l.lanname NOT IN ('internal','c') ORDER BY 1;" || true

echo
echo "---- 5) 建议 ----"
cat <<'EOF'
若 CREATE FUNCTION 在 monitor_test 报 OID 3483：
  - 属于实例/库系统目录异常，脚本无法绕过
  - 表数据 COPY 克隆仍可用
  - 函数/视图需先修目录，或仅在 monitor 保留函数、测试库不建依赖视图

可尝试（需维护窗口，先备份）：
  VACUUM FULL;
  REINDEX DATABASE monitor_test;
若仍失败，考虑从 monitor 物理备份恢复或联系 openGauss 厂商支持。
EOF
