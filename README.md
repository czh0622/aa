# OpenGauss (Docker) 备份与还原方案

面向容器 `monitordb`（`enmotech/opengauss:6.0.0`，宿主机 `5435 -> 5432`）的可落地逻辑备份/还原方案。

| 项 | 值 |
|---|---|
| 容器名 | `monitordb` |
| 数据库 | `monitor` |
| Schema | `public` |
| 业务用户/密码 | `monitor` / `monitor_2012` |
| 超管 omm 密码 | `GU1chuideng@2025` |

推荐使用 **omm** 做备份/还原（权限完整）。脚本默认已按此配置。

---

## 一、快速上手（三步）

```bash
# 1. 准备配置
cp config.env.example config.env
# 按需编辑 config.env（密码、备份目录等）

# 2. 备份
chmod +x scripts/*.sh
./scripts/backup.sh --cleanup

# 3. 还原（会覆盖同名对象，务必确认文件）
./scripts/restore.sh --clean ./backups/monitor_public_YYYYMMDD_HHMMSS.dump
```

连通性检查：

```bash
./scripts/list-backups.sh --ping
```

---

## 二、脚本说明

| 脚本 | 作用 |
|---|---|
| `scripts/backup.sh` | 逻辑备份（默认 custom 格式，仅 `public` schema） |
| `scripts/restore.sh` | 从 `.dump` / `.sql` / `.sql.gz` / 目录备份还原 |
| `scripts/list-backups.sh` | 列出备份；`--ping` 探测库连通 |
| `scripts/common.sh` | 公共配置加载与容器工具探测 |

备份产物默认落在 `./backups/`，并附带 `.meta` 元数据文件。

---

## 三、常用命令

### 备份

```bash
# 默认：custom 格式，仅 public schema
./scripts/backup.sh

# 纯 SQL（便于人工查看；默认会 gzip）
./scripts/backup.sh --format plain

# 整库（不限 schema）
./scripts/backup.sh --no-schema

# 备份并清理 KEEP_DAYS 天前的旧文件
./scripts/backup.sh --cleanup
```

### 还原

```bash
# 标准还原（custom）
./scripts/restore.sh ./backups/monitor_public_20260715_080000.dump

# 还原前清理已存在对象（推荐覆盖场景）
./scripts/restore.sh --clean ./backups/monitor_public_20260715_080000.dump

# 目标库不存在时自动创建
./scripts/restore.sh --create-db --clean ./backups/monitor_public_20260715_080000.dump

# 还原 SQL 文本备份
./scripts/restore.sh ./backups/monitor_public_20260715_080000.sql.gz
```

---

## 四、不依赖脚本的 Docker 原生命令

适合临时操作或排障。在**宿主机**执行：

### 备份（custom，推荐）

```bash
TS=$(date +%Y%m%d_%H%M%S)
mkdir -p ./backups

docker exec -e PGPASSWORD='GU1chuideng@2025' monitordb \
  bash -lc "gs_dump -h 127.0.0.1 -p 5432 -U omm -d monitor -n public -F c -f /tmp/monitor_${TS}.dump"

docker cp "monitordb:/tmp/monitor_${TS}.dump" "./backups/monitor_public_${TS}.dump"
docker exec monitordb rm -f "/tmp/monitor_${TS}.dump"
echo "OK: ./backups/monitor_public_${TS}.dump"
```

### 备份（纯 SQL）

```bash
TS=$(date +%Y%m%d_%H%M%S)
mkdir -p ./backups

docker exec -e PGPASSWORD='GU1chuideng@2025' monitordb \
  bash -lc "gs_dump -h 127.0.0.1 -p 5432 -U omm -d monitor -n public -F p -f /tmp/monitor_${TS}.sql"

docker cp "monitordb:/tmp/monitor_${TS}.sql" "./backups/monitor_public_${TS}.sql"
docker exec monitordb rm -f "/tmp/monitor_${TS}.sql"
gzip -f "./backups/monitor_public_${TS}.sql"
```

### 还原（custom）

```bash
FILE=./backups/monitor_public_YYYYMMDD_HHMMSS.dump   # 改成真实文件名
NAME=$(basename "$FILE")

docker cp "$FILE" "monitordb:/tmp/${NAME}"
docker exec -e PGPASSWORD='GU1chuideng@2025' monitordb \
  bash -lc "gs_restore -h 127.0.0.1 -p 5432 -U omm -d monitor -c /tmp/${NAME}"
docker exec monitordb rm -f "/tmp/${NAME}"
```

### 还原（SQL）

```bash
FILE=./backups/monitor_public_YYYYMMDD_HHMMSS.sql.gz
NAME=$(basename "${FILE%.gz}")

gunzip -c "$FILE" | docker exec -i -e PGPASSWORD='GU1chuideng@2025' monitordb \
  bash -lc "gsql -h 127.0.0.1 -p 5432 -U omm -d monitor --no-password -f -"
```

> 若容器内没有 `gs_dump`/`gsql`，脚本会自动回退到 `pg_dump`/`psql`（部分镜像兼容层如此命名）。

---

## 五、定时备份（cron）

```bash
# 每天 02:30 备份并清理 7 天前文件
# 把 /path/to/repo 换成实际路径
crontab -e
```

加入：

```cron
30 2 * * * cd /path/to/repo && ./scripts/backup.sh --cleanup >> /var/log/opengauss-backup.log 2>&1
```

也可参考 `scripts/crontab.example`。

---

## 六、操作建议与注意点

1. **还原前先再做一份备份**，避免误覆盖后无法回退。
2. **优先 custom（`.dump`）**：体积小，支持 `--clean`，比 plain SQL 更适合例行恢复。
3. 默认只备份 **`public` schema**；若库内还有其他 schema，用 `--no-schema` 做整库备份。
4. 这是**逻辑备份**，不能替代物理备份/WAL 归档；适合中小库、迁移与日常容灾。
5. `config.env` 含明文密码，已加入 `.gitignore`，不要提交到仓库。
6. 还原报权限/`already exists` 时，优先用 omm + `--clean` 重试。
7. 跨大版本还原（如 5.x → 6.x）可能不兼容，尽量同版本镜像还原。

---

## 七、故障排查

```bash
# 容器是否在跑
docker ps --filter name=monitordb

# 容器内工具是否存在
docker exec monitordb bash -lc 'command -v gs_dump; command -v gsql; command -v pg_dump'

# 用 omm 登录测试
docker exec -e PGPASSWORD='GU1chuideng@2025' -it monitordb \
  gsql -h 127.0.0.1 -p 5432 -U omm -d monitor

# 看最近备份
./scripts/list-backups.sh
```

若 `gsql`/`gs_dump` 报认证失败：核对 `config.env` 密码；确认用的是 `omm` 而非业务用户（业务用户可能缺 dump 权限）。
