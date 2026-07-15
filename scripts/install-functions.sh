#!/usr/bin/env bash
# 从源库逐个安装函数到目标库（每函数单独 SQL，失败不阻断其余）
#
# 用法:
#   SRC_DB=monitor DST_DB=monitor_test bash install-functions.sh
#   SRC_DB=monitor DST_DB=monitor_test bash install-functions.sh --dry-run
set -euo pipefail

CONTAINER="${CONTAINER:-monitordb}"
SRC_DB="${SRC_DB:-monitor}"
DST_DB="${DST_DB:-monitor_test}"
SCHEMA="${SCHEMA:-public}"
GAUSSHOME="${GAUSSHOME:-/usr/local/opengauss}"
GS="${GAUSSHOME}/bin/gsql"
DRY_RUN=false

[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

run_src() {
  docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
    "${GS}" -p 5432 -d "${SRC_DB}" "$@"
}
run_dst() {
  docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
    "${GS}" -p 5432 -d "${DST_DB}" "$@"
}

apply_sql_dst() {
  local f="$1"
  local remote="/home/omm/_fn_$(basename "$f").$$"
  docker cp "$f" "${CONTAINER}:${remote}"
  docker exec -u 0 "${CONTAINER}" chown omm:omm "${remote}" && docker exec -u 0 "${CONTAINER}" chmod 644 "${remote}"
  set +e
  docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" \
    "${GS}" -p 5432 -d "${DST_DB}" -f "${remote}"
  local rc=$?
  set -e
  docker exec -u 0 "${CONTAINER}" rm -f "${remote}" >/dev/null 2>&1 || true
  return $rc
}

simp_type() {
  local t="${1#pg_catalog.}"
  case "$t" in
    varchar|character\ varying) echo varchar ;;
    bpchar|character) echo varchar ;;
    int4|integer) echo integer ;;
    int8|bigint) echo bigint ;;
    int2|smallint) echo smallint ;;
    bool|boolean) echo boolean ;;
    text) echo text ;;
    *) echo "$t" ;;
  esac
}

WORK="./backups/install_fn_${SRC_DB}_to_${DST_DB}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${WORK}"

echo "==== 安装函数 ${SRC_DB} -> ${DST_DB} ===="

# 探测目标库能否 CREATE plpgsql 函数（与真实函数同语言）
set +e
PROBE="$(run_dst -c "CREATE OR REPLACE FUNCTION public.__fn_probe() RETURNS int LANGUAGE plpgsql AS \$\$ BEGIN RETURN 1; END; \$\$;" 2>&1)"
set -e
if echo "${PROBE}" | grep -qiE 'OID 3483|ERROR'; then
  echo "ERROR: ${DST_DB} 无法 CREATE plpgsql 函数"
  echo "${PROBE}"
  echo "请运行: bash verify-functions.sh"
  echo "或文件系统克隆: bash clone-db-fs.sh --drop-dst"
  exit 2
fi
run_dst -c "DROP FUNCTION IF EXISTS public.__fn_probe();" >/dev/null 2>&1 || true

OIDS="$(run_src -tAc "SELECT p.oid::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='${SCHEMA}' AND l.lanname NOT IN ('internal','c') ORDER BY p.oid;" | tr -d '\r' | sed '/^$/d')"

OK=0
FAIL=0
while read -r oid; do
  [[ -z "${oid}" ]] && continue
  NAME="$(run_src -tAc "SELECT proname FROM pg_proc WHERE oid=${oid};" | tr -d '\r')"
  LANG="$(run_src -tAc "SELECT l.lanname FROM pg_proc p JOIN pg_language l ON l.oid=p.prolang WHERE p.oid=${oid};" | tr -d '\r')"
  RET_RAW="$(run_src -tAc "SELECT t.typname FROM pg_proc p JOIN pg_type t ON t.oid=p.prorettype WHERE p.oid=${oid};" | tr -d '\r')"
  RET="$(simp_type "${RET_RAW}")"
  RETSET="$(run_src -tAc "SELECT CASE WHEN proretset THEN 't' ELSE 'f' END FROM pg_proc WHERE oid=${oid};" | tr -d '\r')"
  ARGTYPES="$(run_src -tAc "SELECT trim(both FROM proargtypes::text) FROM pg_proc WHERE oid=${oid};" | tr -d '\r')"
  ARGNAMES="$(run_src -tAc "SELECT COALESCE(array_to_string(proargnames,','), '') FROM pg_proc WHERE oid=${oid};" | tr -d '\r')"
  SRC_B64="$(run_src -tAc "SELECT encode(convert_to(prosrc,'UTF8'),'base64') FROM pg_proc WHERE oid=${oid};" | tr -d '\r\n')"

  ARG_SQL=""
  ARG_TYPES=""
  if [[ -n "${ARGTYPES}" ]]; then
    i=0; parts=(); tps=()
    IFS=',' read -r -a ANAMES <<< "${ARGNAMES}"
    for tyoid in ${ARGTYPES}; do
      traw="$(run_src -tAc "SELECT t.typname FROM pg_type t WHERE t.oid=${tyoid};" | tr -d '\r')"
      tn="$(simp_type "${traw}")"
      n="${ANAMES[$i]:-p${i}}"
      parts+=("${n} ${tn}")
      tps+=("${tn}")
      i=$((i+1))
    done
    ARG_SQL="$(IFS=', '; echo "${parts[*]}")"
    ARG_TYPES="$(IFS=', '; echo "${tps[*]}")"
  fi

  SQL_FILE="${WORK}/${oid}_${NAME}.sql"
  BODY_FILE="${WORK}/${oid}.body"
  echo "${SRC_B64}" | base64 -d > "${BODY_FILE}" 2>/dev/null || echo "${SRC_B64}" | base64 -D > "${BODY_FILE}"

  {
    echo "SET search_path TO public;"
    echo "DROP FUNCTION IF EXISTS public.${NAME}(${ARG_TYPES});"
    echo "CREATE FUNCTION public.${NAME}(${ARG_SQL})"
    if [[ "${RETSET}" == "t" ]]; then echo "RETURNS SETOF ${RET}"; else echo "RETURNS ${RET}"; fi
    echo "AS \$function\$"
    cat "${BODY_FILE}"
    echo
    echo "\$function\$ LANGUAGE ${LANG};"
  } > "${SQL_FILE}"

  echo "安装: ${NAME} (${oid})"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  -> ${SQL_FILE}"
    continue
  fi

  set +e
  apply_sql_dst "${SQL_FILE}" 2>&1 | tee "${WORK}/${oid}.log"
  rc=${PIPESTATUS[0]}
  set -e
  if [[ ${rc} -eq 0 ]]; then
    echo "  OK"
    OK=$((OK+1))
  else
    echo "  FAIL rc=${rc}"
    FAIL=$((FAIL+1))
  fi
done <<< "${OIDS}"

echo
echo "结果: 成功=${OK} 失败=${FAIL} 目录=${WORK}"
run_dst -c "SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' ORDER BY 1;" || true

if [[ ${FAIL} -gt 0 ]]; then
  echo "部分函数安装失败。若日志含 OID 3483，请运行: bash diagnose-oid3483.sh"
  exit 1
fi
