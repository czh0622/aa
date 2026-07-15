#!/usr/bin/env bash
# openGauss / GaussDB Docker 逻辑备份
# 用法:
#   ./scripts/backup.sh
#   ./scripts/backup.sh --format plain
#   ./scripts/backup.sh --no-schema          # 备份整个库（忽略 SCHEMA）
#   ./scripts/backup.sh --cleanup            # 备份后清理过期文件
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

USE_SCHEMA=true
DO_CLEANUP=false
FORMAT_OVERRIDE=""

usage() {
  cat <<'EOF'
用法: backup.sh [选项]

选项:
  --format <custom|plain|directory>  覆盖配置中的备份格式
  --no-schema                        备份整个数据库，不限定 SCHEMA
  --cleanup                          备份成功后按 KEEP_DAYS 清理旧备份
  -h, --help                         显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      FORMAT_OVERRIDE="${2:-}"
      shift 2
      ;;
    --no-schema)
      USE_SCHEMA=false
      shift
      ;;
    --cleanup)
      DO_CLEANUP=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数: $1"
      ;;
  esac
done

load_config
require_docker
require_container
detect_tools
ensure_backup_dir

FORMAT="${FORMAT_OVERRIDE:-${BACKUP_FORMAT}}"
TS="$(timestamp)"
HOST_TMP_DIR="${BACKUP_DIR}/.tmp_${TS}"
CONTAINER_TMP="/tmp/monitor_backup_${TS}"
mkdir -p "${HOST_TMP_DIR}"

SCHEMA_ARGS=()
if [[ "${USE_SCHEMA}" == "true" && -n "${SCHEMA}" ]]; then
  SCHEMA_ARGS=(-n "${SCHEMA}")
  NAME_SUFFIX="_${SCHEMA}"
else
  NAME_SUFFIX="_full"
fi

BASE_NAME="${DB_NAME}${NAME_SUFFIX}_${TS}"

case "${FORMAT}" in
  custom)
    CONTAINER_FILE="${CONTAINER_TMP}/${BASE_NAME}.dump"
    HOST_FILE="${BACKUP_DIR}/${BASE_NAME}.dump"
    DUMP_ARGS=(-F c -f "${CONTAINER_FILE}")
    ;;
  plain)
    CONTAINER_FILE="${CONTAINER_TMP}/${BASE_NAME}.sql"
    HOST_FILE="${BACKUP_DIR}/${BASE_NAME}.sql"
    DUMP_ARGS=(-F p -f "${CONTAINER_FILE}")
    ;;
  directory)
    CONTAINER_FILE="${CONTAINER_TMP}/${BASE_NAME}.dir"
    HOST_FILE="${BACKUP_DIR}/${BASE_NAME}.dir"
    DUMP_ARGS=(-F d -f "${CONTAINER_FILE}")
    ;;
  *)
    die "不支持的 BACKUP_FORMAT: ${FORMAT}（支持 custom|plain|directory）"
    ;;
esac

log "开始备份: container=${CONTAINER_NAME} db=${DB_NAME} user=${DB_USER} format=${FORMAT}"
[[ ${#SCHEMA_ARGS[@]} -gt 0 ]] && log "限定 schema: ${SCHEMA}"

# 在容器内创建临时目录并执行 dump
docker_db_exec bash -lc "mkdir -p '${CONTAINER_TMP}'"

DUMP_CMD=(
  "${DUMP_BIN}"
  -h 127.0.0.1
  -p "${DB_PORT}"
  -U "${DB_USER}"
  -d "${DB_NAME}"
  --no-password
)
if [[ ${#SCHEMA_ARGS[@]} -gt 0 ]]; then
  DUMP_CMD+=("${SCHEMA_ARGS[@]}")
fi
DUMP_CMD+=("${DUMP_ARGS[@]}")

set +e
docker_db_exec "${DUMP_CMD[@]}"
DUMP_RC=$?
set -e

if [[ ${DUMP_RC} -ne 0 ]]; then
  docker_db_exec bash -lc "rm -rf '${CONTAINER_TMP}'" >/dev/null 2>&1 || true
  rm -rf "${HOST_TMP_DIR}"
  die "备份失败，${DUMP_BIN} 退出码=${DUMP_RC}"
fi

# 将备份拷到宿主机
if [[ "${FORMAT}" == "directory" ]]; then
  docker cp "${CONTAINER_NAME}:${CONTAINER_FILE}" "${HOST_FILE}"
else
  docker cp "${CONTAINER_NAME}:${CONTAINER_FILE}" "${HOST_TMP_DIR}/"
  mv "${HOST_TMP_DIR}/$(basename "${CONTAINER_FILE}")" "${HOST_FILE}"
fi

# plain 可选 gzip
if [[ "${FORMAT}" == "plain" && "${COMPRESS_PLAIN}" == "true" ]]; then
  gzip -f "${HOST_FILE}"
  HOST_FILE="${HOST_FILE}.gz"
  log "已 gzip 压缩"
fi

# 清理容器临时文件
docker_db_exec bash -lc "rm -rf '${CONTAINER_TMP}'" >/dev/null 2>&1 || true
rm -rf "${HOST_TMP_DIR}"

# 写一份 sidecar 元数据，方便还原时核对
META_FILE="${HOST_FILE}.meta"
if [[ "${FORMAT}" == "directory" ]]; then
  META_FILE="${HOST_FILE}.meta"
fi
cat > "${META_FILE}" <<EOF
backup_time=$(date -Iseconds)
container=${CONTAINER_NAME}
db_name=${DB_NAME}
db_user=${DB_USER}
schema=${USE_SCHEMA:+${SCHEMA}}
format=${FORMAT}
tool=${DUMP_BIN}
file=$(basename "${HOST_FILE}")
EOF

SIZE="$(du -sh "${HOST_FILE}" | awk '{print $1}')"
log "备份成功: ${HOST_FILE} (${SIZE})"

if [[ "${DO_CLEANUP}" == "true" ]]; then
  log "清理 ${KEEP_DAYS} 天前的备份..."
  find "${BACKUP_DIR}" -maxdepth 1 \( \
      -name "${DB_NAME}_*.dump" -o \
      -name "${DB_NAME}_*.sql" -o \
      -name "${DB_NAME}_*.sql.gz" -o \
      -name "${DB_NAME}_*.dir" -o \
      -name "${DB_NAME}_*.meta" \
    \) -type f -mtime +"${KEEP_DAYS}" -print -delete 2>/dev/null || true
  # directory 备份是目录
  find "${BACKUP_DIR}" -maxdepth 1 -type d -name "${DB_NAME}_*.dir" -mtime +"${KEEP_DAYS}" -print -exec rm -rf {} + 2>/dev/null || true
fi

echo "${HOST_FILE}"
