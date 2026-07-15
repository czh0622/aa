# OpenGauss (Docker) 备份与还原方案

面向容器 `monitordb`（`enmotech/opengauss:6.0.0`，宿主机 `5435 -> 5432`）。

| 项 | 值 |
|---|---|
| 容器名 | `monitordb` |
| 源库 | `monitor` |
| 测试库 | `monitor_test` |
| Schema | `public` |
| 业务用户 | `monitor` / `monitor_2012` |
| 超管 | `omm` / `GU1chuideng@2025` |

> **已知实例限制：** `gs_dump` / `pg_get_functiondef` / `CREATE FUNCTION` 可能触发 **OID 3483**。  
> 表数据用 COPY；对象用 `backup-objects.sh`；函数能否迁入测试库取决于诊断结果。

---

## 〇、当前推荐流程（克隆到 monitor_test）

```bash
mkdir -p /tmp/og-clone && cd /tmp/og-clone
curl -fsSL -o fetch-all.sh https://raw.githubusercontent.com/czh0622/aa/cursor/opengauss-backup-restore-9282/scripts/fetch-all.sh
bash fetch-all.sh

# A. 诊断（必做）
DB=monitor_test bash diagnose-oid3483.sh

# B. 整库克隆（建库+表结构+数据+对象）
bash clone-db.sh --drop-dst

# C. 若表已在、只需补对象
bash finish-clone.sh
```

| 能力 | 状态 |
|---|---|
| 表结构 + 表数据 | 可用（COPY / clone-db） |
| 序列 | 可用 |
| 函数迁入 monitor_test | 取决于 CREATE FUNCTION 是否触发 OID 3483 |
| 依赖函数的视图 | 取决于函数先成功 |
| `gs_dump` | 本实例不可用，勿用 |

若诊断显示 CREATE FUNCTION 报 OID 3483：表数据仍可用；函数留在源库 `monitor`；测试可连源库或目录修复后再跑 `install-functions.sh`。

---

## 一、脚本一览

| 脚本 | 作用 |
|---|---|
| `fetch-all.sh` | 一键下载全部脚本 |
| `diagnose-oid3483.sh` | 诊断 OID 3483 / CREATE FUNCTION |
| `clone-db.sh` | monitor → monitor_test 整库克隆 |
| `finish-clone.sh` | 表已存在时补齐对象 |
| `backup-objects.sh` | 导出序列/视图/函数 |
| `restore-objects.sh` | 还原对象（序列→函数→视图→setval） |
| `install-functions.sh` | 逐个安装函数到目标库 |
| `backup-physical.sh` | 停库物理备份整实例 |
| `restore-table-data.sh` | 还原方案 A 的 `.copy` 数据 |

---

## 二、日常备份（表数据，不停库）

```bash
TS=$(date +%Y%m%d_%H%M%S); mkdir -p ./backups/gsql_$TS
docker exec -u omm -e LD_LIBRARY_PATH=/usr/local/opengauss/lib monitordb \
  /usr/local/opengauss/bin/gsql -p 5432 -d monitor -tAc \
  "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' ORDER BY 1;" \
  > ./backups/gsql_$TS/tables.list
while read -r t; do [ -z "$t" ] && continue; echo "dump $t"
  docker exec -u omm -e LD_LIBRARY_PATH=/usr/local/opengauss/lib monitordb \
    /usr/local/opengauss/bin/gsql -p 5432 -d monitor -c \
    "COPY public.\"$t\" TO '/tmp/${t}_${TS}.copy' WITH (FORMAT text, ENCODING 'UTF8');"
  docker cp monitordb:/tmp/${t}_${TS}.copy ./backups/gsql_$TS/${t}.copy
  docker exec monitordb rm -f /tmp/${t}_${TS}.copy
done < ./backups/gsql_$TS/tables.list
echo OK: ./backups/gsql_$TS
```

对象：`bash backup-objects.sh`

---

## 三、还原到 monitor_test

```bash
DB=monitor_test bash restore-objects.sh --create-db ./backups/objects_时间戳
DB=monitor_test bash restore-table-data.sh ./backups/gsql_时间戳
# 或
bash clone-db.sh --drop-dst
```

openGauss 禁止 `TEMPLATE monitor`，只能 `TEMPLATE template0`。

---

## 四、OID 3483

```bash
DB=monitor_test bash diagnose-oid3483.sh
SRC_DB=monitor DST_DB=monitor_test bash install-functions.sh
```

维护窗口可试（先备份）：`VACUUM FULL; REINDEX DATABASE monitor_test;`  
整实例备份：`bash backup-physical.sh`

---

## 五、注意

1. 工具在容器内，路径 `/usr/local/opengauss/bin/`
2. `gsql -f` 不支持 `-`；SQL 需 cp 到 `/home/omm` 并 chown omm
3. 还原顺序：序列 → 函数 → 视图 → 序列值
4. `config.env` 含密码勿提交

```bash
docker exec -u omm -e LD_LIBRARY_PATH=/usr/local/opengauss/lib monitordb \
  /usr/local/opengauss/bin/gsql -p 5432 -d monitor -c 'SELECT version();'
```
