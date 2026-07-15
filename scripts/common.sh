#!/usr/bin/env bash
# 公共工具：加载配置、校验容器、统一日志
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# enmotech/opengauss 镜像默认安装路径
DEFAULT_GAUSSHOME="/usr/local/opengauss"

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
  DB_HOST="${DB_HOST-}"
  DB_NAME="${DB_NAME:-monitor}"
  DB_USER="${DB_USER:-omm}"
  DB_PASSWORD="${DB_PASSWORD:-}"
  DOCKER_USER="${DOCKER_USER:-omm}"
  BACKUP_DIR="${BACKUP_DIR:-${ROOT_DIR}/backups}"
  KEEP_DAYS="${KEEP_DAYS:-7}"
  BACKUP_FORMAT="${BACKUP_FORMAT:-custom}"
  SCHEMA="${SCHEMA:-public}"
  COMPRESS_PLAIN="${COMPRESS_PLAIN:-true}"
  GAUSSHOME="${GAUSSHOME:-${DEFAULT_GAUSSHOME}}"

  # 本地 socket + omm 时密码可为空；TCP 连接则必须有密码
  if [[ -n "${DB_HOST}" && -z "${DB_PASSWORD}" ]]; then
    die "DB_HOST=${DB_HOST} 时需要配置 DB_PASSWORD"
  fi
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "未找到 docker 命令。请在安装了 Docker 的宿主机执行，不要在容器外直接跑 gs_dump"
  docker info >/dev/null 2>&1 || die "无法访问 Docker 守护进程"
}

require_container() {
  local status
  status="$(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
  [[ "${status}" == "running" ]] || die "容器 ${CONTAINER_NAME} 未运行（当前状态: ${status:-不存在}）。请先: docker ps | grep ${CONTAINER_NAME}"
}

# 在容器内执行命令；注入密码与 openGauss 环境（PATH 对非交互 shell 常未加载）
docker_db_exec() {
  local -a exec_args=(exec)
  if [[ -n "${DOCKER_USER}" ]]; then
    exec_args+=(-u "${DOCKER_USER}")
  fi
  exec_args+=(
    -e "PGPASSWORD=${DB_PASSWORD}"
    -e "GS_PASSWORD=${DB_PASSWORD}"
    -e "GAUSSHOME=${GAUSSHOME}"
    -e "PATH=${GAUSSHOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    -e "LD_LIBRARY_PATH=${GAUSSHOME}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    "${CONTAINER_NAME}"
  )
  docker "${exec_args[@]}" "$@"
}

# 组装客户端连接参数（空 DB_HOST = Unix socket，避免错误密码导致 TCP 认证失败）
db_conn_args() {
  local -a args=(-p "${DB_PORT}" -U "${DB_USER}")
  if [[ -n "${DB_HOST}" ]]; then
    args+=(-h "${DB_HOST}")
  fi
  printf '%s\n' "${args[@]}"
}

# 在容器内解析可执行文件绝对路径
_resolve_bin() {
  local name="$1"
  local found=""
  found="$(docker_db_exec bash -lc "
    if [ -x '${GAUSSHOME}/bin/${name}' ]; then
      echo '${GAUSSHOME}/bin/${name}'
    elif command -v '${name}' >/dev/null 2>&1; then
      command -v '${name}'
    else
      # 兜底扫描常见目录
      for d in /usr/local/opengauss/bin /opt/opengauss/bin /home/omm/opengauss/bin; do
        if [ -x \"\$d/${name}\" ]; then echo \"\$d/${name}\"; exit 0; fi
      done
      exit 1
    fi
  " 2>/dev/null | tr -d '\r' || true)"
  echo "${found}"
}

# 检测容器内可用的客户端工具（openGauss 优先 gs_*，兼容 pg_*）
detect_tools() {
  local dump restore sql
  dump="$(_resolve_bin gs_dump)"
  if [[ -n "${dump}" ]]; then
    DUMP_BIN="${dump}"
    RESTORE_BIN="$(_resolve_bin gs_restore)"
    SQL_BIN="$(_resolve_bin gsql)"
  else
    dump="$(_resolve_bin pg_dump)"
    [[ -n "${dump}" ]] || die "容器 ${CONTAINER_NAME} 内未找到 gs_dump/pg_dump。请执行: docker exec ${CONTAINER_NAME} ls -l ${GAUSSHOME}/bin/gs_dump"
    DUMP_BIN="${dump}"
    RESTORE_BIN="$(_resolve_bin pg_restore)"
    SQL_BIN="$(_resolve_bin psql)"
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
