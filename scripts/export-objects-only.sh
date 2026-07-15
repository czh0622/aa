#!/usr/bin/env bash
# 仅补充导出：序列 / 视图 / 函数 / 过程（给已经用方案A拷过表数据的场景）
# 在仓库根目录执行，或把本脚本拷到服务器后改 CONTAINER 变量。
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

# 序列
run -tAc "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='${SCHEMA}' AND c.relkind='S' ORDER BY 1;" \
  | tr -d '\r' | sed '/^$/d' > "${OUT}/sequences.list"
: > "${OUT}/001_sequences.sql"
: > "${OUT}/006_sequence_values.sql"
echo "SET search_path TO ${SCHEMA}, public;" >> "${OUT}/001_sequences.sql"
while read -r seq; do
  [ -z "${seq}" ] && continue
  echo "sequence: ${seq}"
  META=$(run -tAc "SELECT increment_by||'|'||min_value||'|'||max_value||'|'||start_value||'|'||cache_value||'|'||CASE WHEN is_cycled THEN 'CYCLE' ELSE 'NO CYCLE' END||'|'||last_value||'|'||CASE WHEN is_called THEN 'true' ELSE 'false' END FROM ${SCHEMA}.\"${seq}\";" | tr -d '\r')
  IFS='|' read -r INC MINV MAXV START CACHE CYCLE LAST CALLED <<< "${META}"
  cat >> "${OUT}/001_sequences.sql" <<EOF
CREATE SEQUENCE IF NOT EXISTS ${SCHEMA}."${seq}"
  INCREMENT BY ${INC} MINVALUE ${MINV} MAXVALUE ${MAXV}
  START WITH ${START} CACHE ${CACHE} ${CYCLE};
EOF
  echo "SELECT setval('${SCHEMA}.\"${seq}\"', ${LAST}, ${CALLED});" >> "${OUT}/006_sequence_values.sql"
done < "${OUT}/sequences.list"

# 视图
run -tAc "SELECT viewname FROM pg_views WHERE schemaname='${SCHEMA}' ORDER BY 1;" \
  | tr -d '\r' | sed '/^$/d' > "${OUT}/views.list"
{
  echo "SET search_path TO ${SCHEMA}, public;"
} > "${OUT}/003_views.sql"
while read -r v; do
  [ -z "${v}" ] && continue
  echo "view: ${v}"
  DEF=$(run -tAc "SELECT pg_get_viewdef('${SCHEMA}.${v}'::regclass, true);" | tr -d '\r')
  if [ -z "${DEF}" ]; then
    DEF=$(run -tAc "SELECT definition FROM pg_views WHERE schemaname='${SCHEMA}' AND viewname='${v}';" | tr -d '\r')
  fi
  cat >> "${OUT}/003_views.sql" <<EOF
CREATE OR REPLACE VIEW ${SCHEMA}."${v}" AS
${DEF};

EOF
done < "${OUT}/views.list"

# 函数/过程
{
  echo "SET search_path TO ${SCHEMA}, public;"
} > "${OUT}/004_routines.sql"
if run -tAc "SELECT 1 FROM information_schema.columns WHERE table_name='pg_proc' AND column_name='prokind' LIMIT 1;" | grep -q 1; then
  run -tAc "SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='${SCHEMA}' AND p.prokind IN ('f','p') ORDER BY p.proname, p.oid;" \
    | tr -d '\r' | sed '/^$/d' > "${OUT}/routines.oids"
else
  run -tAc "SELECT p.oid FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='${SCHEMA}' AND NOT p.proisagg ORDER BY p.proname, p.oid;" \
    | tr -d '\r' | sed '/^$/d' > "${OUT}/routines.oids"
fi
while read -r oid; do
  [ -z "${oid}" ] && continue
  echo "routine oid: ${oid}"
  DEF=$(run -tAc "SELECT pg_get_functiondef(${oid});" | tr -d '\r')
  if [ -n "${DEF}" ]; then
    echo "${DEF};" >> "${OUT}/004_routines.sql"
    echo >> "${OUT}/004_routines.sql"
  fi
done < "${OUT}/routines.oids"

echo "OK: ${OUT}"
echo "文件: 001_sequences.sql 003_views.sql 004_routines.sql 006_sequence_values.sql"
echo "还原示例:"
echo "  docker cp ${OUT}/001_sequences.sql ${CONTAINER}:/tmp/o.sql && docker exec -u omm -e LD_LIBRARY_PATH=${GAUSSHOME}/lib ${CONTAINER} ${GS} -p 5432 -d ${DB} -f /tmp/o.sql"
