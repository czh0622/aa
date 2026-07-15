#!/usr/bin/env bash
# 公共工具：加载配置、校验容器、统一日志
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "ERROR: $*" >&2; exit 1; }

load_config() {
  local conf="${CONFIG_FILE:-${ROOT_DIR}/config.env}"
  if [[ ! -f "${conf}" ]]; then
    if [[ -f "${ROOT_DIR}/config.env.example" ]]; then
      die "缺少配置文件 ${conf}，请先执行: cp config.env.example config.env"
    fi
    die "缺少配置文件: ${conf}"
  fi
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1091
  source "${conf}"
  set +a

  CONTAINER_NAME="${CONTAINER_NAME:-monitordb}"
  DB_PORT="${DB_PORT:-5432}"
  DB_NAME="${DB_NAME:-monitor}"
  DB_USER="${DB_USER:-omm}"
  DB_PASSWORD="${DB_PASSWORD:-}"
  BACKUP_DIR="${BACKUP_DIR:-${ROOT_DIR}/backups}"
  KEEP_DAYS="${KEEP_DAYS:-7}"
  BACKUP_FORMAT="${BACKUP_FORMAT:-custom}"
  SCHEMA="${SCHEMA:-public}"
  COMPRESS_PLAIN="${COMPRESS_PLAIN:-true}"

  [[ -n "${DB_PASSWORD}" ]] || die "DB_PASSWORD 未配置"
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "未找到 docker 命令"
  docker info >/dev/null 2>&1 || die "无法访问 Docker 守护进程"
}

require_container() {
  local status
  status="$(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
  [[ "${status}" == "running" ]] || die "容器 ${CONTAINER_NAME} 未运行（当前状态: ${status:-不存在}）"
}

# 在容器内执行命令，自动注入密码环境变量
docker_db_exec() {
  docker exec \
    -e PGPASSWORD="${DB_PASSWORD}" \
    -e GS_PASSWORD="${DB_PASSWORD}" \
    "${CONTAINER_NAME}" \
    "$@"
}

# 检测容器内可用的客户端工具（openGauss 优先 gs_*，兼容 pg_*）
# 使用 login shell 解析绝对路径，避免 docker exec 非交互 PATH 找不到命令
detect_tools() {
  local dump restore sql
  dump="$(docker_db_exec bash -lc 'command -v gs_dump' 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "${dump}" ]]; then
    DUMP_BIN="${dump}"
    RESTORE_BIN="$(docker_db_exec bash -lc 'command -v gs_restore' 2>/dev/null | tr -d '\r' || true)"
    SQL_BIN="$(docker_db_exec bash -lc 'command -v gsql' 2>/dev/null | tr -d '\r' || true)"
  else
    dump="$(docker_db_exec bash -lc 'command -v pg_dump' 2>/dev/null | tr -d '\r' || true)"
    [[ -n "${dump}" ]] || die "容器内未找到 gs_dump/pg_dump"
    DUMP_BIN="${dump}"
    RESTORE_BIN="$(docker_db_exec bash -lc 'command -v pg_restore' 2>/dev/null | tr -d '\r' || true)"
    SQL_BIN="$(docker_db_exec bash -lc 'command -v psql' 2>/dev/null | tr -d '\r' || true)"
  fi
  [[ -n "${RESTORE_BIN}" && -n "${SQL_BIN}" ]] || die "容器内还原/SQL 客户端不完整（需要 gs_restore+gsql 或 pg_restore+psql）"
  log "检测到工具: dump=${DUMP_BIN} restore=${RESTORE_BIN} sql=${SQL_BIN}"
}

ensure_backup_dir() {
  mkdir -p "${BACKUP_DIR}"
  BACKUP_DIR="$(cd "${BACKUP_DIR}" && pwd)"
}

timestamp() {
  date '+%Y%m%d_%H%M%S'
}
