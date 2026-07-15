#!/usr/bin/env bash
# openGauss Docker：导出 public 下 序列 + 视图 + 函数/过程
# （避开 gs_dump / pg_get_functiondef 的 OID 3483 问题）
#
# 用法:
#   bash backup-objects.sh
#   CONTAINER=monitordb DB=monitor SCHEMA=public bash backup-objects.sh
#
# 产物:
#   ./backups/objects_YYYYmmdd_HHMMSS/
#     001_sequences.sql
#     003_views.sql
#     004_routines.sql
#     006_sequence_values.sql
#     *.list / routines_diag.txt
set -euo pipefail

CONTAINER="${CONTAINER:-monitordb}"
DB="${DB:-monitor}"
SCHEMA="${SCHEMA:-public}"
GAUSSHOME="${GAUSSHOME:-/usr/local/opengauss}"
GS_BIN="${GAUSSHOME}/bin/gsql"
OUT="${OUT:-./backups/objects_$(date +%Y%m%d_%H%M%S)}"

mkdir -p "${OUT}"

run() {
  docker exec -u omm \
    -e LD_LIBRARY_PATH="${GAUSSHOME}/lib" \
    "${CONTAINER}" \
    "${GS_BIN}" -p 5432 -d "${DB}" "$@"
}

echo "==== 备份对象: container=${CONTAINER} db=${DB} schema=${SCHEMA} ===="
echo "输出目录: ${OUT}"

# ---------- 诊断 ----------
run -c "SELECT p.oid, p.proname, l.lanname, length(p.prosrc) AS src_len
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid=p.pronamespace
        JOIN pg_language l ON l.oid=p.prolang
        WHERE n.nspname='${SCHEMA}' AND l.lanname NOT IN ('internal','c')
        ORDER BY p.oid;" | tee "${OUT}/routines_diag.txt" || true

# ---------- 序列 ----------
run -tAc "SELECT c.relname
          FROM pg_class c
          JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname='${SCHEMA}' AND c.relkind='S'
          ORDER BY 1;" | tr -d '\r' | sed '/^$/d' > "${OUT}/sequences.list"

echo "SET search_path TO ${SCHEMA}, public;" > "${OUT}/001_sequences.sql"
: > "${OUT}/006_sequence_values.sql"

SEQ_N=0
while read -r seq; do
  [[ -z "${seq}" ]] && continue
  echo "seq ${seq}"
  META="$(run -tAc "SELECT increment_by||'|'||min_value||'|'||max_value||'|'||start_value||'|'||cache_value||'|'||CASE WHEN is_cycled THEN 'CYCLE' ELSE 'NO CYCLE' END||'|'||last_value||'|'||CASE WHEN is_called THEN 'true' ELSE 'false' END FROM ${SCHEMA}.\"${seq}\";" | tr -d '\r' || true)"
  if [[ -z "${META}" ]]; then
    echo "CREATE SEQUENCE IF NOT EXISTS ${SCHEMA}.\"${seq}\";" >> "${OUT}/001_sequences.sql"
    continue
  fi
  IFS='|' read -r INC MINV MAXV START CACHE CYCLE LAST CALLED <<< "${META}"
  cat >> "${OUT}/001_sequences.sql" <<EOF
CREATE SEQUENCE IF NOT EXISTS ${SCHEMA}."${seq}"
  INCREMENT BY ${INC}
  MINVALUE ${MINV}
  MAXVALUE ${MAXV}
  START WITH ${START}
  CACHE ${CACHE}
  ${CYCLE};
EOF
  echo "SELECT setval('${SCHEMA}.\"${seq}\"', ${LAST}, ${CALLED});" >> "${OUT}/006_sequence_values.sql"
  SEQ_N=$((SEQ_N + 1))
done < "${OUT}/sequences.list"

# ---------- 视图（优先 pg_views.definition）----------
run -tAc "SELECT viewname FROM pg_views WHERE schemaname='${SCHEMA}' ORDER BY 1;" \
  | tr -d '\r' | sed '/^$/d' > "${OUT}/views.list"

echo "SET search_path TO ${SCHEMA}, public;" > "${OUT}/003_views.sql"
VIEW_N=0
while read -r v; do
  [[ -z "${v}" ]] && continue
  echo "view ${v}"
  DEF="$(run -tAc "SELECT definition FROM pg_views WHERE schemaname='${SCHEMA}' AND viewname='${v}';" | tr -d '\r' || true)"
  if [[ -z "${DEF}" ]]; then
    DEF="$(run -tAc "SELECT pg_get_viewdef('${SCHEMA}.${v}'::regclass, true);" 2>/dev/null | tr -d '\r' || true)"
  fi
  if [[ -n "${DEF}" ]]; then
    cat >> "${OUT}/003_views.sql" <<EOF
CREATE OR REPLACE VIEW ${SCHEMA}."${v}" AS
${DEF};

EOF
    VIEW_N=$((VIEW_N + 1))
  else
    echo "-- WARN: empty view def: ${v}" >> "${OUT}/003_views.sql"
  fi
done < "${OUT}/views.list"

# ---------- 函数/过程：读 prosrc，避开 pg_get_functiondef ----------
# 生成两份：004_routines.sql（完整）与 004_routines_simple.sql（类型名简化，兼容性更好）
echo "SET search_path TO public;" > "${OUT}/004_routines.sql"
echo "-- built from pg_proc.prosrc (avoid pg_get_functiondef / OID 3483)" >> "${OUT}/004_routines.sql"
mkdir -p "${OUT}/routines.d"

# 类型名简化：去掉 pg_catalog 前缀，常用别名归一
simp_type() {
  local t="$1"
  t="${t#pg_catalog.}"
  t="${t//\"/}"
  case "${t}" in
    character\ varying|varchar) echo "varchar" ;;
    character|bpchar|char) echo "varchar" ;;
    int4|integer) echo "integer" ;;
    int8|bigint) echo "bigint" ;;
    int2|smallint) echo "smallint" ;;
    float8|double\ precision) echo "float8" ;;
    float4|real) echo "float4" ;;
    bool|boolean) echo "boolean" ;;
    timestamptz|timestamp\ with\ time\ zone) echo "timestamptz" ;;
    timestamp|timestamp\ without\ time\ zone) echo "timestamp" ;;
    *) echo "${t}" ;;
  esac
}

run -tAc "SELECT p.oid::text
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid=p.pronamespace
          JOIN pg_language l ON l.oid=p.prolang
          WHERE n.nspname='${SCHEMA}'
            AND l.lanname NOT IN ('internal','c')
          ORDER BY p.oid;" | tr -d '\r' | sed '/^$/d' > "${OUT}/routines.oids"

ROUT_OK=0
ROUT_FAIL=0
while read -r oid; do
  [[ -z "${oid}" ]] && continue
  NAME="$(run -tAc "SELECT proname FROM pg_proc WHERE oid=${oid};" | tr -d '\r')"
  LANG="$(run -tAc "SELECT l.lanname FROM pg_proc p JOIN pg_language l ON l.oid=p.prolang WHERE p.oid=${oid};" | tr -d '\r')"
  RET_RAW="$(run -tAc "SELECT CASE WHEN n.nspname IN ('pg_catalog','public') OR n.nspname IS NULL THEN t.typname ELSE n.nspname||'.'||t.typname END FROM pg_proc p JOIN pg_type t ON t.oid=p.prorettype LEFT JOIN pg_namespace n ON n.oid=t.typnamespace WHERE p.oid=${oid};" | tr -d '\r')"
  RET="$(simp_type "${RET_RAW}")"
  VOL="$(run -tAc "SELECT CASE provolatile WHEN 'i' THEN 'IMMUTABLE' WHEN 's' THEN 'STABLE' ELSE 'VOLATILE' END FROM pg_proc WHERE oid=${oid};" | tr -d '\r')"
  STRICT="$(run -tAc "SELECT CASE WHEN proisstrict THEN 'STRICT' ELSE '' END FROM pg_proc WHERE oid=${oid};" | tr -d '\r')"
  SEC="$(run -tAc "SELECT CASE WHEN prosecdef THEN 'SECURITY DEFINER' ELSE '' END FROM pg_proc WHERE oid=${oid};" | tr -d '\r')"
  RETSET="$(run -tAc "SELECT CASE WHEN proretset THEN 't' ELSE 'f' END FROM pg_proc WHERE oid=${oid};" | tr -d '\r')"
  ARGTYPES="$(run -tAc "SELECT trim(both FROM proargtypes::text) FROM pg_proc WHERE oid=${oid};" | tr -d '\r')"
  ARGNAMES="$(run -tAc "SELECT COALESCE(array_to_string(proargnames, ','), '') FROM pg_proc WHERE oid=${oid};" | tr -d '\r')"
  SRC_B64="$(run -tAc "SELECT encode(convert_to(prosrc,'UTF8'),'base64') FROM pg_proc WHERE oid=${oid};" | tr -d '\r\n')"

  echo "routine ${oid} ${NAME}"

  ARG_SQL=""
  ARG_TYPES_ONLY=""
  if [[ -n "${ARGTYPES}" ]]; then
    i=0
    parts=()
    type_parts=()
    IFS=',' read -r -a ANAMES <<< "${ARGNAMES}"
    for tyoid in ${ARGTYPES}; do
      traw="$(run -tAc "SELECT CASE WHEN n.nspname IN ('pg_catalog','public') OR n.nspname IS NULL THEN t.typname ELSE n.nspname||'.'||t.typname END FROM pg_type t LEFT JOIN pg_namespace n ON n.oid=t.typnamespace WHERE t.oid=${tyoid};" | tr -d '\r')"
      tname="$(simp_type "${traw}")"
      n="${ANAMES[$i]:-p${i}}"
      parts+=("${n} ${tname}")
      type_parts+=("${tname}")
      i=$((i + 1))
    done
    ARG_SQL="$(IFS=', '; echo "${parts[*]}")"
    ARG_TYPES_ONLY="$(IFS=', '; echo "${type_parts[*]}")"
  fi

  if [[ -z "${SRC_B64}" ]]; then
    echo "-- SKIP ${NAME} (${oid}): empty prosrc" >> "${OUT}/004_routines.sql"
    ROUT_FAIL=$((ROUT_FAIL + 1))
    continue
  fi

  BODY_FILE="${OUT}/.body_${oid}.txt"
  if ! echo "${SRC_B64}" | base64 -d > "${BODY_FILE}" 2>/dev/null; then
    if ! echo "${SRC_B64}" | base64 -D > "${BODY_FILE}" 2>/dev/null; then
      echo "-- SKIP ${NAME} (${oid}): base64 decode failed" >> "${OUT}/004_routines.sql"
      ROUT_FAIL=$((ROUT_FAIL + 1))
      continue
    fi
  fi

  {
    echo "-- OID ${oid} ${NAME}"
    echo "DROP FUNCTION IF EXISTS ${SCHEMA}.${NAME}(${ARG_TYPES_ONLY});"
    echo "CREATE FUNCTION ${SCHEMA}.${NAME}(${ARG_SQL})"
    if [[ "${RETSET}" == "t" ]]; then
      echo "RETURNS SETOF ${RET}"
    else
      echo "RETURNS ${RET}"
    fi
    echo "AS \$function\$"
    cat "${BODY_FILE}"
    echo
    echo "\$function\$ LANGUAGE ${LANG};"
    echo
  } >> "${OUT}/004_routines.sql"

  {
    echo "-- OID ${oid} ${NAME} (per-function file also in routines.d/)"
    echo "DROP FUNCTION IF EXISTS ${SCHEMA}.${NAME}(${ARG_TYPES_ONLY});"
    echo "CREATE FUNCTION ${SCHEMA}.${NAME}(${ARG_SQL})"
    if [[ "${RETSET}" == "t" ]]; then
      echo "RETURNS SETOF ${RET}"
    else
      echo "RETURNS ${RET}"
    fi
    echo "AS \$function\$"
    cat "${BODY_FILE}"
    echo
    echo "\$function\$ LANGUAGE ${LANG};"
    echo
  } > "${OUT}/routines.d/${oid}_${NAME}.sql"

  rm -f "${BODY_FILE}"
  ROUT_OK=$((ROUT_OK + 1))
done < "${OUT}/routines.oids"

cat > "${OUT}/meta.txt" <<EOF
backup_time=$(date -Iseconds)
container=${CONTAINER}
db=${DB}
schema=${SCHEMA}
sequences=${SEQ_N}
views=${VIEW_N}
routines_ok=${ROUT_OK}
routines_fail=${ROUT_FAIL}
restore=bash restore-objects.sh ${OUT}
EOF

echo
echo "==== 备份完成 ===="
echo "目录: ${OUT}"
echo "序列=${SEQ_N} 视图=${VIEW_N} 函数成功=${ROUT_OK} 函数失败=${ROUT_FAIL}"
ls -l "${OUT}"
echo
echo "还原: bash restore-objects.sh ${OUT}"
