#!/usr/bin/env bash
# 还原 backup-gsql.sh 产物（支持完整对象：序列/表/视图/函数/过程/数据）
# 用法:
#   ./scripts/restore-gsql.sh backups/monitor_public_gsql_YYYYmmdd_HHMMSS.tar.gz
#   ./scripts/restore-gsql.sh --data-only backups/xxx.tar.gz
#   ./scripts/restore-gsql.sh --objects-only backups/xxx.tar.gz
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

MODE=all   # all | data-only | objects-only
BACKUP_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-only) MODE=data-only; shift ;;
    --objects-only|--no-data) MODE=objects-only; shift ;;
    --no-schema) MODE=data-only; shift ;; # 兼容旧参数
    -h|--help)
      echo "用法: restore-gsql.sh [--data-only|--objects-only] <备份.tar.gz|目录>"
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
  SRC="$(find "${WORK}" -maxdepth 1 -type d \( -name '*_gsql_*' -o -name 'gsql_*' \) | head -1)"
  [[ -n "${SRC}" ]] || SRC="$(find "${WORK}" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -n "${SRC}" ]] || die "压缩包内未找到备份目录"
elif [[ -d "${BACKUP_PATH}" ]]; then
  SRC="${BACKUP_PATH}"
else
  die "无法识别备份: ${BACKUP_PATH}"
fi

log "还原 gsql 备份: ${SRC} mode=${MODE} -> db=${DB_NAME}"
CONTAINER_SQL="/tmp/restore_gsql_$$"

apply_file() {
  local host_file="$1"
  local label="$2"
  [[ -f "${host_file}" ]] || { log "跳过 ${label}（文件不存在）"; return 0; }
  local base
  base="$(basename "${host_file}")"
  docker cp "${host_file}" "${CONTAINER_NAME}:${CONTAINER_SQL}_${base}"
  set +e
  docker_db_exec "${SQL_BIN}" "${CONN_ARGS[@]}" -d "${DB_NAME}" --no-password -f "${CONTAINER_SQL}_${base}"
  local rc=$?
  set -e
  docker_db_exec rm -f "${CONTAINER_SQL}_${base}" >/dev/null 2>&1 || true
  if [[ ${rc} -ne 0 ]]; then
    log "WARN: ${label} 还原有错误 exit=${rc}"
  else
    log "完成: ${label}"
  fi
}

# 兼容旧版单文件 001_schema.sql / 002_data.sql
if [[ -f "${SRC}/001_schema.sql" && ! -f "${SRC}/001_sequences.sql" ]]; then
  [[ "${MODE}" != "data-only" ]] && apply_file "${SRC}/001_schema.sql" "旧版 schema"
  if [[ "${MODE}" != "objects-only" ]]; then
    apply_file "${SRC}/002_data.sql" "旧版 data"
  fi
else
  if [[ "${MODE}" != "data-only" ]]; then
    apply_file "${SRC}/001_sequences.sql" "sequences"
    apply_file "${SRC}/002_tables.sql" "tables"
    apply_file "${SRC}/003_views.sql" "views"
    apply_file "${SRC}/004_routines.sql" "routines"
  fi
  if [[ "${MODE}" != "objects-only" ]]; then
    if [[ -f "${SRC}/005_data.sql" ]]; then
      apply_file "${SRC}/005_data.sql" "data"
    elif [[ -f "${SRC}/002_data.sql" ]]; then
      apply_file "${SRC}/002_data.sql" "legacy data"
    else
      log "跳过 data（无 005_data.sql / 002_data.sql）"
    fi
  fi
  if [[ "${MODE}" != "data-only" ]]; then
    apply_file "${SRC}/006_sequence_values.sql" "sequence values"
  fi
fi

# 清理可能误跑的 legacy 空跳过：若 005 存在则不应重复强调
TABLE_COUNT="$(
  docker_db_exec "${SQL_BIN}" "${CONN_ARGS[@]}" -d "${DB_NAME}" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='${SCHEMA:-public}' AND table_type='BASE TABLE';" \
    2>/dev/null | tr -d '[:space:]' || echo "?"
)"
VIEW_COUNT="$(
  docker_db_exec "${SQL_BIN}" "${CONN_ARGS[@]}" -d "${DB_NAME}" -tAc \
    "SELECT count(*) FROM information_schema.views WHERE table_schema='${SCHEMA:-public}';" \
    2>/dev/null | tr -d '[:space:]' || echo "?"
)"
log "还原完成: tables=${TABLE_COUNT} views=${VIEW_COUNT}"
