#!/usr/bin/env bash
# 克隆收尾：在表数据已存在于 monitor_test 时，补齐序列/函数/视图
#
# 用法:
#   bash finish-clone.sh
#   SRC_DB=monitor DST_DB=monitor_test bash finish-clone.sh
set -euo pipefail

CONTAINER="${CONTAINER:-monitordb}"
SRC_DB="${SRC_DB:-monitor}"
DST_DB="${DST_DB:-monitor_test}"
GAUSSHOME="${GAUSSHOME:-/usr/local/opengauss}"
GS="${GAUSSHOME}/bin/gsql"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run() {
  local db="$1"; shift
  docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
    "${GS}" -p 5432 -d "${db}" "$@"
}

echo "==== 克隆收尾 ${SRC_DB} -> ${DST_DB} ===="

# 表数量对比
SRC_T=$(run "${SRC_DB}" -tAc "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r';" | tr -d '[:space:]')
DST_T=$(run "${DST_DB}" -tAc "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r';" | tr -d '[:space:]')
echo "表数量: 源=${SRC_T} 目标=${DST_T}"
if [[ "${DST_T}" == "0" ]]; then
  echo "ERROR: 目标库没有表。请先: bash clone-db.sh --drop-dst"
  exit 1
fi

# 探测 CREATE FUNCTION
echo "---- 探测 ${DST_DB} CREATE FUNCTION ----"
set +e
PROBE=$(run "${DST_DB}" -c "CREATE OR REPLACE FUNCTION public.__finish_probe() RETURNS int LANGUAGE sql AS 'SELECT 1';" 2>&1)
PROBE_RC=$?
set -e
echo "${PROBE}"
CAN_FN=true
if echo "${PROBE}" | grep -q "OID 3483"; then
  CAN_FN=false
  echo "结论: CREATE FUNCTION 不可用（OID 3483）——函数/依赖视图无法装入 ${DST_DB}"
else
  run "${DST_DB}" -c "DROP FUNCTION IF EXISTS public.__finish_probe();" >/dev/null 2>&1 || true
  echo "结论: CREATE FUNCTION 可用"
fi

# 备份对象
OUT="./backups/finish_objects_$(date +%Y%m%d_%H%M%S)"
CONTAINER="${CONTAINER}" DB="${SRC_DB}" OUT="${OUT}" bash "${SCRIPT_DIR}/backup-objects.sh"

# 还原：序列总是做；函数按探测结果；视图在函数之后
CONTAINER="${CONTAINER}" DB="${DST_DB}" bash "${SCRIPT_DIR}/restore-objects.sh" "${OUT}"

# 若函数可用但失败，再试 install-functions
DST_FN=$(run "${DST_DB}" -tAc "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='public' AND l.lanname NOT IN ('internal','c') AND p.proname NOT LIKE '__%probe%';" | tr -d '[:space:]' || echo 0)
SRC_FN=$(run "${SRC_DB}" -tAc "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='public' AND l.lanname NOT IN ('internal','c');" | tr -d '[:space:]')

if [[ "${CAN_FN}" == "true" && "${DST_FN}" != "${SRC_FN}" ]]; then
  echo "---- 函数数量不一致(源=${SRC_FN} 目标=${DST_FN})，尝试 install-functions ----"
  set +e
  SRC_DB="${SRC_DB}" DST_DB="${DST_DB}" bash "${SCRIPT_DIR}/install-functions.sh"
  set -e
  # 再还原视图
  if [[ -f "${OUT}/003_views.sql" ]]; then
    CONTAINER="${CONTAINER}" DB="${DST_DB}" bash -c "
      source /dev/null
      remote=/home/omm/_views_\$\$.sql
      docker cp '${OUT}/003_views.sql' ${CONTAINER}:\$remote
      docker exec -u 0 ${CONTAINER} chown omm:omm \$remote
      docker exec -u omm -e LD_LIBRARY_PATH=${GAUSSHOME}/lib ${CONTAINER} ${GS} -p 5432 -d ${DST_DB} -f \$remote
      docker exec -u 0 ${CONTAINER} rm -f \$remote
    "
  fi
fi

echo
echo "==== 最终校验 ===="
run "${DST_DB}" -c "
SELECT 'tables' AS kind, count(*)::text AS cnt FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r'
UNION ALL
SELECT 'sequences', count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='S'
UNION ALL
SELECT 'views', count(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='v'
UNION ALL
SELECT 'routines', count(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='public' AND l.lanname NOT IN ('internal','c');
"

DST_FN=$(run "${DST_DB}" -tAc "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='public' AND l.lanname NOT IN ('internal','c');" | tr -d '[:space:]')
echo
if [[ "${CAN_FN}" == "false" ]]; then
  cat <<EOF
状态: 表/序列可用；函数因 OID 3483 无法迁入 ${DST_DB}。
建议:
  1) bash diagnose-oid3483.sh
  2) 维护窗口尝试: VACUUM FULL; REINDEX DATABASE ${DST_DB};
  3) 或测试时直接连源库 ${SRC_DB}（函数已在源库）
  4) 完整一致副本可用物理备份 scripts/backup-physical.sh（整实例）
EOF
elif [[ "${DST_FN}" == "${SRC_FN}" ]]; then
  echo "状态: 对象克隆完成（函数 ${DST_FN}/${SRC_FN}）"
else
  echo "状态: 部分完成（函数 目标=${DST_FN} 源=${SRC_FN}），请查看上方日志"
fi
