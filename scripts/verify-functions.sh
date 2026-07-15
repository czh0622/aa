#!/usr/bin/env bash
# 对比源库/目标库函数，并尝试用 plpgsql 探测 + 逐个安装
# 用法:
#   SRC_DB=monitor DST_DB=monitor_test bash verify-functions.sh
#   SRC_DB=monitor DST_DB=monitor_test bash verify-functions.sh --install
set -euo pipefail

CONTAINER="${CONTAINER:-monitordb}"
SRC_DB="${SRC_DB:-monitor}"
DST_DB="${DST_DB:-monitor_test}"
GAUSSHOME="${GAUSSHOME:-/usr/local/opengauss}"
GS="${GAUSSHOME}/bin/gsql"
DO_INSTALL=false
[[ "${1:-}" == "--install" ]] && DO_INSTALL=true

run() {
  local db="$1"; shift
  docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
    "${GS}" -p 5432 -d "${db}" "$@"
}

echo "==== 函数对比 ${SRC_DB} vs ${DST_DB} ===="

echo "---- 源库函数 ----"
run "${SRC_DB}" -c "SELECT p.oid, p.proname, l.lanname, length(p.prosrc) AS src_len FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='public' AND l.lanname NOT IN ('internal','c') ORDER BY 1;" || true

echo "---- 目标库函数 ----"
run "${DST_DB}" -c "SELECT p.oid, p.proname, l.lanname, length(p.prosrc) AS src_len FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='public' AND l.lanname NOT IN ('internal','c') ORDER BY 1;" 2>&1 || true

echo "---- plpgsql CREATE 探测（与真实函数同语言）----"
set +e
PL_PROBE=$(run "${DST_DB}" -c "CREATE OR REPLACE FUNCTION public.__plpgsql_probe() RETURNS integer LANGUAGE plpgsql AS \$\$ BEGIN RETURN 1; END; \$\$;" 2>&1)
PL_RC=$?
set -e
echo "${PL_PROBE}"
if echo "${PL_PROBE}" | grep -qiE 'OID 3483|ERROR'; then
  echo
  echo "结论: ${DST_DB} 无法 CREATE plpgsql 函数（OID 3483）"
  echo "restore-objects.sh 里的 SQL 探测可能误报「可用」，但 plpgsql 函数实际装不进去。"
  echo
  echo "可行替代:"
  echo "  1) 测试直接连源库 ${SRC_DB}（函数已在源库）"
  echo "  2) 文件系统级克隆: bash clone-db-fs.sh --drop-dst"
  echo "  3) 维护窗口: VACUUM FULL; REINDEX DATABASE ${DST_DB};"
  CAN_INSTALL=false
else
  run "${DST_DB}" -c "DROP FUNCTION IF EXISTS public.__plpgsql_probe();" >/dev/null 2>&1 || true
  echo "结论: plpgsql CREATE 可用，可尝试 install-functions.sh"
  CAN_INSTALL=true
fi

if [[ "${DO_INSTALL}" == "true" && "${CAN_INSTALL}" == "true" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SRC_DB="${SRC_DB}" DST_DB="${DST_DB}" bash "${SCRIPT_DIR}/install-functions.sh"
elif [[ "${DO_INSTALL}" == "true" ]]; then
  echo "跳过 --install（plpgsql 不可用）"
  exit 2
fi

SRC_N=$(run "${SRC_DB}" -tAc "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='public' AND l.lanname NOT IN ('internal','c');" | tr -d '[:space:]')
DST_N=$(run "${DST_DB}" -tAc "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='public' AND l.lanname NOT IN ('internal','c');" 2>/dev/null | tr -d '[:space:]' || echo 0)
echo
echo "函数数量: 源=${SRC_N} 目标=${DST_N}"
[[ "${SRC_N}" == "${DST_N}" ]] && echo "状态: OK" || echo "状态: 不一致"
