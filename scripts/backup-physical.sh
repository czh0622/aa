#!/usr/bin/env bash
# 物理备份：停库拷贝数据目录（不依赖 gs_dump，适合工具链异常时的保底方案）
# 用法:
#   ./scripts/backup-physical.sh
# 还原见 README「物理还原」章节。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

load_config
require_docker
require_container
ensure_backup_dir

TS="$(timestamp)"
OUT_TGZ="${BACKUP_DIR}/${DB_NAME}_physical_${TS}.tar.gz"
# enmotech 镜像默认数据目录
PGDATA_IN_CONTAINER="${PGDATA_PATH:-/var/lib/opengauss/data}"

log "物理备份将短暂停止容器 ${CONTAINER_NAME} 以保证一致性"
log "数据目录: ${PGDATA_IN_CONTAINER}"

docker stop "${CONTAINER_NAME}" >/dev/null
set +e
docker cp "${CONTAINER_NAME}:${PGDATA_IN_CONTAINER}" "${BACKUP_DIR}/.pgdata_${TS}"
CP_RC=$?
set -e
docker start "${CONTAINER_NAME}" >/dev/null

# 等库起来
for i in $(seq 1 30); do
  if docker exec -u "${DOCKER_USER:-omm}" \
      -e "LD_LIBRARY_PATH=${GAUSSHOME}/lib" \
      -e "PATH=${GAUSSHOME}/bin:/usr/bin:/bin" \
      "${CONTAINER_NAME}" \
      bash -lc "gsql -p ${DB_PORT} -d postgres -c 'SELECT 1;' >/dev/null 2>&1"; then
    break
  fi
  sleep 2
done

[[ ${CP_RC} -eq 0 ]] || die "docker cp 数据目录失败"

tar -czf "${OUT_TGZ}" -C "${BACKUP_DIR}" ".pgdata_${TS}"
rm -rf "${BACKUP_DIR}/.pgdata_${TS}"
SIZE="$(du -sh "${OUT_TGZ}" | awk '{print $1}')"
log "物理备份成功: ${OUT_TGZ} (${SIZE})"
echo "${OUT_TGZ}"
