#!/usr/bin/env bash
# 一键下载本仓库全部运维脚本到当前目录
set -euo pipefail
BRANCH="${BRANCH:-cursor/opengauss-backup-restore-9282}"
BASE="https://raw.githubusercontent.com/czh0622/aa/${BRANCH}/scripts"
FILES=(
  backup-objects.sh restore-objects.sh
  clone-db.sh clone-db-fs.sh finish-clone.sh
  install-functions.sh verify-functions.sh diagnose-oid3483.sh
  restore-table-data.sh backup-gsql.sh restore-gsql.sh
  backup-physical.sh common.sh
)
for f in "${FILES[@]}"; do
  echo "下载 ${f}"
  curl -fsSL -o "${f}" "${BASE}/${f}"
done
chmod +x ./*.sh
echo "OK: 已下载到 $(pwd)"
echo "下一步:"
echo "  bash diagnose-oid3483.sh"
echo "  bash clone-db.sh --drop-dst          # 整库克隆"
echo "  bash finish-clone.sh                 # 仅补对象（表已存在时）"
