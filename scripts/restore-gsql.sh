#!/usr/bin/env bash
# 还原 backup-gsql.sh 产物（.tar.gz 或解压目录）
# 用法:
#   ./scripts/restore-gsql.sh backups/monitor_public_gsql_YYYYmmdd_HHMMSS.tar.gz
#   ./scripts/restore-gsql.sh --no-schema backups/xxx.tar.gz   # 只还原数据
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

RESTORE_SCHEMA=true
BACKUP_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-schema) RESTORE_SCHEMA=false; shift ;;
    -h|--help)
      echo "用法: restore-gsql.sh [--no-schema] <备份.tar.gz|目录>"
      exit 0
      ;;
    *) BACKUP_PATH="$1"; shift ;;
  esac
done

[[ -n "${BACKUP_PATH}" ]] || die "请指定备份路径"
[[ -e "${BACKUP_PATH}" ]] || die "不存在: ${BACKUP_PATH}"

load_config
require_docker
require_container
detect_tools

CONN_ARGS=()
while IFS= read -r _line; do
  [[ -n "${_line}" ]] && CONN_ARGS+=("${_line}")
done < <(db_conn_args)

WORK="$(mktemp -d /tmp/restore_gsql_XXXX)"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

if [[ -f "${BACKUP_PATH}" && "${BACKUP_PATH}" == *.tar.gz ]]; then
  tar -xzf "${BACKUP_PATH}" -C "${WORK}"
  SRC="$(find "${WORK}" -maxdepth 1 -type d -name '*_gsql_*' | head -1)"
  [[ -n "${SRC}" ]] || die "压缩包内未找到 gsql 备份目录"
elif [[ -d "${BACKUP_PATH}" ]]; then
  SRC="${BACKUP_PATH}"
else
  die "无法识别备份: ${BACKUP_PATH}"
fi

[[ -f "${SRC}/002_data.sql" ]] || die "缺少 002_data.sql"

log "还原 gsql 备份: ${SRC} -> db=${DB_NAME}"
CONTAINER_SQL="/tmp/restore_gsql_$$"

if [[ "${RESTORE_SCHEMA}" == "true" && -f "${SRC}/001_schema.sql" ]]; then
  docker cp "${SRC}/001_schema.sql" "${CONTAINER_NAME}:${CONTAINER_SQL}_schema.sql"
  set +e
  docker_db_exec "${SQL_BIN}" "${CONN_ARGS[@]}" -d "${DB_NAME}" --no-password -f "${CONTAINER_SQL}_schema.sql"
  RC=$?
  set -e
  [[ ${RC} -eq 0 ]] || log "WARN: schema 还原有错误（exit=${RC}），继续尝试数据还原"
fi

docker cp "${SRC}/002_data.sql" "${CONTAINER_NAME}:${CONTAINER_SQL}_data.sql"
docker_db_exec "${SQL_BIN}" "${CONN_ARGS[@]}" -d "${DB_NAME}" --no-password -f "${CONTAINER_SQL}_data.sql"
docker_db_exec rm -f "${CONTAINER_SQL}_schema.sql" "${CONTAINER_SQL}_data.sql" >/dev/null 2>&1 || true

TABLE_COUNT="$(
  docker_db_exec "${SQL_BIN}" "${CONN_ARGS[@]}" -d "${DB_NAME}" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='${SCHEMA:-public}' AND table_type='BASE TABLE';" \
    2>/dev/null | tr -d '[:space:]' || echo "?"
)"
log "还原完成: public/目标 schema 表数量=${TABLE_COUNT}"
