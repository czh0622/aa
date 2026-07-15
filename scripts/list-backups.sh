#!/usr/bin/env bash
# 列出备份目录中的备份，并可选做连通性检查
# 用法:
#   ./scripts/list-backups.sh
#   ./scripts/list-backups.sh --ping
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

DO_PING=false
[[ "${1:-}" == "--ping" ]] && DO_PING=true

load_config
ensure_backup_dir

echo "备份目录: ${BACKUP_DIR}"
echo "----------------------------------------"
if compgen -G "${BACKUP_DIR}/${DB_NAME}_*" > /dev/null; then
  ls -lhtr "${BACKUP_DIR}/${DB_NAME}_"* 2>/dev/null | grep -v '\.meta$' || true
else
  echo "(暂无备份)"
fi
echo "----------------------------------------"

if [[ "${DO_PING}" == "true" ]]; then
  require_docker
  require_container
  detect_tools
  log "探测数据库连通性..."
  docker_db_exec bash -lc "
    ${SQL_BIN} -h 127.0.0.1 -p ${DB_PORT} -U '${DB_USER}' -d '${DB_NAME}' --no-password \
      -c 'SELECT version(); SELECT current_database(), current_user;'
  "
fi
