#!/usr/bin/env bash
# 仅补充导出：序列 / 视图 / 函数 / 过程
# 函数导出避开 pg_get_functiondef（OID 3483 会导致失败），改为读 pg_proc.prosrc 拼 DDL
set -euo pipefail

CONTAINER="${CONTAINER:-monitordb}"
DB="${DB:-monitor}"
SCHEMA="${SCHEMA:-public}"
GAUSSHOME="${GAUSSHOME:-/usr/local/opengauss}"
GS="${GAUSSHOME}/bin/gsql"
OUT="${OUT:-./backups/objects_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "${OUT}"
run() {
  docker exec -u omm -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" "${CONTAINER}" "${GS}" -p 5432 -d "${DB}" "$@"
}

echo "导出目录: ${OUT}"

echo "==== 1) 例程清单（不调用 pg_get_functiondef）===="
run -c "SELECT p.oid, p.proname, l.lanname, length(p.prosrc) AS src_len FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='${SCHEMA}' AND l.lanname NOT IN ('internal','c') ORDER BY p.oid;" \
  | tee "${OUT}/routines_diag.txt" || true

echo "==== 2) OID 3483 ===="
run -c "SELECT oid, relname, relkind FROM pg_class WHERE oid=3483;" | tee "${OUT}/oid3483.txt" || true

# ---------- 序列 ----------
run -tAc "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='${SCHEMA}' AND c.relkind='S' ORDER BY 1;" \
  | tr -d '\r' | sed '/^$/d' > "${OUT}/sequences.list"
echo "SET search_path TO ${SCHEMA}, public;" > "${OUT}/001_sequences.sql"
: > "${OUT}/006_sequence_values.sql"
while read -r seq; do
  [ -z "${seq}" ] && continue
  echo "sequence: ${seq}"
  META=$(run -tAc "SELECT increment_by||'|'||min_value||'|'||max_value||'|'||start_value||'|'||cache_value||'|'||CASE WHEN is_cycled THEN 'CYCLE' ELSE 'NO CYCLE' END||'|'||last_value||'|'||CASE WHEN is_called THEN 'true' ELSE 'false' END FROM ${SCHEMA}.\"${seq}\";" | tr -d '\r' || true)
  [ -z "${META}" ] && { echo "CREATE SEQUENCE IF NOT EXISTS ${SCHEMA}.\"${seq}\";" >> "${OUT}/001_sequences.sql"; continue; }
  IFS='|' read -r INC MINV MAXV START CACHE CYCLE LAST CALLED <<< "${META}"
  cat >> "${OUT}/001_sequences.sql" <<EOF
CREATE SEQUENCE IF NOT EXISTS ${SCHEMA}."${seq}"
  INCREMENT BY ${INC} MINVALUE ${MINV} MAXVALUE ${MAXV}
  START WITH ${START} CACHE ${CACHE} ${CYCLE};
EOF
  echo "SELECT setval('${SCHEMA}.\"${seq}\"', ${LAST}, ${CALLED});" >> "${OUT}/006_sequence_values.sql"
done < "${OUT}/sequences.list"

# ---------- 视图 ----------
run -tAc "SELECT viewname FROM pg_views WHERE schemaname='${SCHEMA}' ORDER BY 1;" \
  | tr -d '\r' | sed '/^$/d' > "${OUT}/views.list"
echo "SET search_path TO ${SCHEMA}, public;" > "${OUT}/003_views.sql"
while read -r v; do
  [ -z "${v}" ] && continue
  echo "view: ${v}"
  DEF=$(run -tAc "SELECT definition FROM pg_views WHERE schemaname='${SCHEMA}' AND viewname='${v}';" | tr -d '\r' || true)
  if [ -n "${DEF}" ]; then
    cat >> "${OUT}/003_views.sql" <<EOF
CREATE OR REPLACE VIEW ${SCHEMA}."${v}" AS
${DEF};

EOF
  else
    echo "-- WARN: empty view def: ${v}" >> "${OUT}/003_views.sql"
  fi
done < "${OUT}/views.list"

# ---------- 函数/过程：逐条读目录拼 DDL ----------
echo "SET search_path TO ${SCHEMA}, public;" > "${OUT}/004_routines.sql"
echo "-- workaround: built from pg_proc.prosrc (no pg_get_functiondef)" >> "${OUT}/004_routines.sql"

run -tAc "SELECT p.oid::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='${SCHEMA}' AND l.lanname NOT IN ('internal','c') ORDER BY p.oid;" \
  | tr -d '\r' | sed '/^$/d' > "${OUT}/routines.oids"

ROUT_OK=0
ROUT_FAIL=0
ROUT_TOTAL=0
[[ -s "${OUT}/routines.oids" ]] && ROUT_TOTAL=$(grep -c . "${OUT}/routines.oids" || true)
echo "待导出例程数: ${ROUT_TOTAL}"

while read -r oid; do
  [ -z "${oid}" ] && continue
  NAME=$(run -tAc "SELECT proname FROM pg_proc WHERE oid=${oid};" | tr -d '\r')
  LANG=$(run -tAc "SELECT l.lanname FROM pg_proc p JOIN pg_language l ON l.oid=p.prolang WHERE p.oid=${oid};" | tr -d '\r')
  RET=$(run -tAc "SELECT COALESCE(quote_ident(n.nspname)||'.'||quote_ident(t.typname), quote_ident(t.typname)) FROM pg_proc p JOIN pg_type t ON t.oid=p.prorettype LEFT JOIN pg_namespace n ON n.oid=t.typnamespace WHERE p.oid=${oid};" | tr -d '\r')
  VOL=$(run -tAc "SELECT CASE provolatile WHEN 'i' THEN 'IMMUTABLE' WHEN 's' THEN 'STABLE' ELSE 'VOLATILE' END FROM pg_proc WHERE oid=${oid};" | tr -d '\r')
  STRICT=$(run -tAc "SELECT CASE WHEN proisstrict THEN 'STRICT' ELSE '' END FROM pg_proc WHERE oid=${oid};" | tr -d '\r')
  SEC=$(run -tAc "SELECT CASE WHEN prosecdef THEN 'SECURITY DEFINER' ELSE '' END FROM pg_proc WHERE oid=${oid};" | tr -d '\r')
  RETSET=$(run -tAc "SELECT CASE WHEN proretset THEN 't' ELSE 'f' END FROM pg_proc WHERE oid=${oid};" | tr -d '\r')
  ARGTYPES=$(run -tAc "SELECT trim(both FROM proargtypes::text) FROM pg_proc WHERE oid=${oid};" | tr -d '\r')
  ARGNAMES=$(run -tAc "SELECT COALESCE(array_to_string(proargnames, ','), '') FROM pg_proc WHERE oid=${oid};" | tr -d '\r')

  # 参数类型名
  ARG_SQL=""
  if [ -n "${ARGTYPES}" ]; then
    i=0
    parts=()
    IFS=',' read -r -a ANAMES <<< "${ARGNAMES}"
    for tyoid in ${ARGTYPES}; do
      tname=$(run -tAc "SELECT COALESCE(quote_ident(n.nspname)||'.'||quote_ident(t.typname), quote_ident(t.typname)) FROM pg_type t LEFT JOIN pg_namespace n ON n.oid=t.typnamespace WHERE t.oid=${tyoid};" | tr -d '\r')
      n="${ANAMES[$i]:-arg${i}}"
      parts+=("\"${n}\" ${tname}")
      i=$((i+1))
    done
    ARG_SQL=$(IFS=', '; echo "${parts[*]}")
  fi

  # 函数体：base64，避免 COPY 文本转义/换行问题
  SRC_B64=$(run -tAc "SELECT encode(convert_to(prosrc,'UTF8'),'base64') FROM pg_proc WHERE oid=${oid};" | tr -d '\r\n' || true)
  if [ -z "${SRC_B64}" ]; then
    echo "-- SKIP ${NAME} (${oid}): empty prosrc" >> "${OUT}/004_routines.sql"
    echo "fail routine ${oid} ${NAME} (empty prosrc)"
    ROUT_FAIL=$((ROUT_FAIL+1))
    continue
  fi
  BODY_FILE="${OUT}/prosrc_${oid}.txt"
  if ! echo "${SRC_B64}" | base64 -d > "${BODY_FILE}" 2>/dev/null; then
    echo "${SRC_B64}" | base64 -D > "${BODY_FILE}" 2>/dev/null || {
      echo "-- SKIP ${NAME} (${oid}): base64 decode failed" >> "${OUT}/004_routines.sql"
      ROUT_FAIL=$((ROUT_FAIL+1))
      continue
    }
  fi

  {
    echo "-- OID ${oid} ${NAME} LANGUAGE ${LANG}"
    echo "CREATE OR REPLACE FUNCTION ${SCHEMA}.\"${NAME}\"(${ARG_SQL})"
    if [ "${RETSET}" = "t" ]; then
      echo "RETURNS SETOF ${RET}"
    else
      echo "RETURNS ${RET}"
    fi
    echo "LANGUAGE ${LANG}"
    echo "${VOL}"
    [ -n "${STRICT}" ] && echo "${STRICT}"
    [ -n "${SEC}" ] && echo "${SEC}"
    echo "AS \$body\$"
    cat "${BODY_FILE}"
    echo
    echo "\$body\$;"
    echo
  } >> "${OUT}/004_routines.sql"
  rm -f "${BODY_FILE}"

  echo "ok routine ${oid} ${NAME}"
  ROUT_OK=$((ROUT_OK+1))
done < "${OUT}/routines.oids"

echo "OK: ${OUT}"
echo "例程: 成功=${ROUT_OK} 失败=${ROUT_FAIL} 总计=${ROUT_TOTAL}"
echo "若总计=0：库里 public 下确实没有用户函数/过程（不是导出失败）"
echo "若总计>0 且成功>0：函数已写入 004_routines.sql"
ls -l "${OUT}"
