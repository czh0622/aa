#!/usr/bin/env bash
# openGauss / GaussDB Docker 逻辑还原
# 用法:
#   ./scripts/restore.sh backups/monitor_public_20260101_120000.dump
#   ./scripts/restore.sh backups/monitor_public_20260101_120000.sql.gz
#   ./scripts/restore.sh --clean backups/xxx.dump     # 还原前清理目标对象
#   ./scripts/restore.sh --create-db backups/xxx.dump # 目标库不存在时先创建
#
# 警告: 还原会覆盖同名对象数据，请先确认备份文件正确，建议在业务低峰操作。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

DO_CLEAN=false
CREATE_DB=false
TARGET_DB=""
BACKUP_PATH=""

usage() {
  cat <<'EOF'
用法: restore.sh [选项] <备份文件路径>

选项:
  --clean              还原前清理已存在对象（gs_restore -c / SQL 中依赖备份内容）
  --create-db          若目标库不存在则用模板创建
  --db <name>          还原到指定库名（默认用 config 中的 DB_NAME）
  -h, --help           显示帮助

示例:
  ./scripts/restore.sh ./backups/monitor_public_20260715_080000.dump
  ./scripts/restore.sh --clean --db monitor ./backups/monitor_public_20260715_080000.dump
  ./scripts/restore.sh ./backups/monitor_public_20260715_080000.sql.gz
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      DO_CLEAN=true
      shift
      ;;
    --create-db)
      CREATE_DB=true
      shift
      ;;
    --db)
      TARGET_DB="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "未知参数: $1"
      ;;
    *)
      BACKUP_PATH="$1"
      shift
      ;;
  esac
done

[[ -n "${BACKUP_PATH}" ]] || { usage; die "请指定备份文件路径"; }
[[ -e "${BACKUP_PATH}" ]] || die "备份不存在: ${BACKUP_PATH}"

load_config
require_docker
require_container
detect_tools

TARGET_DB="${TARGET_DB:-${DB_NAME}}"
BACKUP_PATH="$(cd "$(dirname "${BACKUP_PATH}")" && pwd)/$(basename "${BACKUP_PATH}")"
BASENAME="$(basename "${BACKUP_PATH}")"
TS="$(timestamp)"
CONTAINER_TMP="/tmp/monitor_restore_${TS}"
CONTAINER_FILE="${CONTAINER_TMP}/${BASENAME}"

# 识别格式
detect_format() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    echo "directory"
  elif [[ "${path}" == *.sql.gz || "${path}" == *.sql ]]; then
    echo "plain"
  elif [[ "${path}" == *.dump || "${path}" == *.backup || "${path}" == *.dmp ]]; then
    echo "custom"
  else
    # 尝试用 file 命令
    if file "${path}" 2>/dev/null | grep -qiE 'PostgreSQL|custom database dump|gzip'; then
      if file "${path}" 2>/dev/null | grep -qi gzip; then
        # 可能是压缩的 plain，也可能是 gzip 自定义；默认按扩展名已处理
        echo "custom"
      else
        echo "custom"
      fi
    else
      die "无法识别备份格式，请使用 .dump / .sql / .sql.gz / 目录备份"
    fi
  fi
}

FORMAT="$(detect_format "${BACKUP_PATH}")"
log "准备还原: file=${BACKUP_PATH} format=${FORMAT} target_db=${TARGET_DB}"
log "警告: 还原可能覆盖现有数据，请确认已做好二次备份"

# 可选：创建数据库
db_exists() {
  docker_db_exec bash -lc "
    ${SQL_BIN} -h 127.0.0.1 -p ${DB_PORT} -U '${DB_USER}' -d postgres -tAc \
      \"SELECT 1 FROM pg_database WHERE datname='${TARGET_DB}'\" 2>/dev/null | tr -d '[:space:]'
  "
}

if [[ "$(db_exists || true)" != "1" ]]; then
  if [[ "${CREATE_DB}" == "true" ]]; then
    log "目标库 ${TARGET_DB} 不存在，正在创建..."
    docker_db_exec bash -lc "
      ${SQL_BIN} -h 127.0.0.1 -p ${DB_PORT} -U '${DB_USER}' -d postgres --no-password \
        -c \"CREATE DATABASE ${TARGET_DB} ENCODING 'UTF8';\"
    "
  else
    die "目标库 ${TARGET_DB} 不存在。可加 --create-db 自动创建"
  fi
fi

# 上传备份到容器
docker_db_exec bash -lc "mkdir -p '${CONTAINER_TMP}'"
if [[ "${FORMAT}" == "directory" ]]; then
  docker cp "${BACKUP_PATH}" "${CONTAINER_NAME}:${CONTAINER_FILE}"
else
  # .sql.gz 需要在容器内解压
  docker cp "${BACKUP_PATH}" "${CONTAINER_NAME}:${CONTAINER_FILE}"
fi

cleanup_container() {
  docker_db_exec bash -lc "rm -rf '${CONTAINER_TMP}'" >/dev/null 2>&1 || true
}
trap cleanup_container EXIT

restore_custom_or_dir() {
  local clean_args=()
  [[ "${DO_CLEAN}" == "true" ]] && clean_args+=(-c)

  docker_db_exec bash -lc "
    ${RESTORE_BIN} \
      -h 127.0.0.1 \
      -p ${DB_PORT} \
      -U '${DB_USER}' \
      -d '${TARGET_DB}' \
      --no-password \
      ${clean_args[*]+"${clean_args[@]}"} \
      '${CONTAINER_FILE}'
  "
}

restore_plain() {
  local sql_file="${CONTAINER_FILE}"
  if [[ "${BASENAME}" == *.gz ]]; then
    sql_file="${CONTAINER_TMP}/${BASENAME%.gz}"
    docker_db_exec bash -lc "gunzip -c '${CONTAINER_FILE}' > '${sql_file}'"
  fi

  # plain SQL：若要求 clean，先尝试 truncate/drop schema 中对象风险高，
  # 这里仅提示；推荐用 custom 格式 + --clean
  if [[ "${DO_CLEAN}" == "true" ]]; then
    log "plain 格式不自动执行 --clean（避免误删）。如需干净还原，建议先备份后手动 DROP SCHEMA 或改用 custom 备份。"
  fi

  docker_db_exec bash -lc "
    ${SQL_BIN} -h 127.0.0.1 -p ${DB_PORT} -U '${DB_USER}' -d '${TARGET_DB}' --no-password \
      -f '${sql_file}'
  "
}

set +e
case "${FORMAT}" in
  custom|directory)
    restore_custom_or_dir
    RC=$?
    ;;
  plain)
    restore_plain
    RC=$?
    ;;
  *)
    die "内部错误: 未知格式 ${FORMAT}"
    ;;
esac
set -e

if [[ ${RC} -ne 0 ]]; then
  die "还原失败，退出码=${RC}（部分对象报错时请检查日志；权限/已存在对象可用 --clean）"
fi

# 简单校验：连接并统计 public schema 表数量
TABLE_COUNT="$(
  docker_db_exec bash -lc "
    ${SQL_BIN} -h 127.0.0.1 -p ${DB_PORT} -U '${DB_USER}' -d '${TARGET_DB}' -tAc \
      \"SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';\" \
      2>/dev/null | tr -d '[:space:]'
  " || echo "?"
)"

log "还原完成: db=${TARGET_DB} public 表数量=${TABLE_COUNT}"
log "建议执行应用侧冒烟检查，并核对关键表行数"
