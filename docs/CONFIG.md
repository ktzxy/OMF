# 配置管理

> 框架只读取 `conf/omf.conf`。先生成正式文件：`omf config init`（含全部配置项）或 `cp conf/omf.conf.example conf/omf.conf`，再编辑。

## 1. 查看与校验

```bash
omf config show          # 当前全部配置 (密码掩码)
omf config list          # 同 show
omf config get ORACLE_BACKUP   # 读取单项
omf config set KEY VALUE        # 设置并持久化到 conf/omf.conf
omf config validate      # 校验 (必要项/路径/路径存在/磁盘空间/模式列表合法性)
omf config init         # 生成正式配置 (交互确认是否覆盖)
omf config password     # 交互式设置口令到 conf/.omf.secret (权限 600, 不落 shell 历史)
```

`omf config validate` 还会校验 `APP_SCHEMAS` 列表的完整性：非空、合法 Oracle 标识符（含 `#$`）、不重复。

配置加载优先级：**命令行参数 > 环境变量 > `conf/omf.conf` > 默认值**。

## 2. 关键配置项

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `ORACLE_SID` | `ARTERY` | 实例 SID |
| `PDB_NAME` | `ARTERYPDB` | PDB 名 |
| `ORACLE_VERSION` | `19` | `18`/`19`/`21`/`23`，推导安装包名与 Home |
| `ORACLE_HOME` | 按版本推导 | 显式指定可覆盖 |
| `ORACLE_BASE` | `/u01/app/oracle` | |
| `ORACLE_DATA` | `/data/oracle/oradata` | 数据文件根 |
| `ORACLE_BACKUP` | `/backup/oracle` | 备份根 |
| `ORACLE_DUMP_DIR` | `/data/oracle/oracle_dumps` | 数据泵导入目录（OS 路径）|
| `LISTENER_PORT` | `1521` | 监听端口 |
| `APP_USER` | `dherp` | 主模式（主库）用户名 |
| `APP_PASSWORD` | `dherp_skzy` | 主模式密码 |
| `APP_TABLESPACE` | `dherp` | 主模式表空间 |
| `APP_SCHEMAS` | 空 | 多模式列表（空格分隔），空=仅 `APP_USER` |
| `ENABLE_DG` | `false` | 是否启用 Data Guard |
| `PRIMARY_IP` / `STANDBY_IP` | `192.168.0.108` / `110` | DG 主/备 IP |
| `BACKUP_MODE` | `both` | `logical`/`physical`/`both` |
| `BACKUP_RETENTION_DAYS` | `30` | 备份保留天数 |
| `BACKUP_WARN_DAYS` | 空 | 即将过期阈值（默认保留期 1/5，钳制 2~7 天）|
| `BACKUP_COMPRESSION` | `ALL` | expdp 压缩 |
| `BACKUP_PARALLEL` | `4` | 并行度 |
| `BACKUP_SPACE_SAFETY` | `20` | 备份前空间预检安全余量（%，估算备份集之外额外要求）|
| `RMAN_RETRY` / `RMAN_RETRY_INTERVAL` | `1` / `5` | RMAN 备份失败重试次数 / 重试间隔秒 |
| `LOG_RETENTION_DAYS` / `AUDIT_*` / `TRACE_*` | `7`/`30`/`7` | 清理保留期 |
| `OMF_LOG_STRUCTURED` | `false` | true 时 `omf_*.log` 以 JSON Lines 输出（接监控）|
| `OMF_UPDATE_URL` | 空 | `omf self-update` 的 tar.gz 地址（空则不可用）|

**路径类补充**：`ORACLE_USER`/`ORACLE_GROUP`（默认 `oracle`/`oinstall`）、`ORACLE_DATA_BASE`（`/data/oracle`，数据盘根）、`ORACLE_ARCH`（`/data/oracle/archivelog`）、`ORACLE_FRA`（`/data/oracle/fast_recovery`）、`FRA_SIZE_MB`（`40960`，FRA 容量）、`ORACLE_ZIP`（安装包路径，空则按版本推导）。

**实例参数类**：`PROCESSES`（`1500`）、`OPEN_CURSORS`（`1000`）、`REDO_SIZE_MB`（`2048`）、`CHARSET`（`AL32UTF8`）、`NLS_LANG`（`AMERICAN_AMERICA.AL32UTF8`）。

> 以上除路径类外均可在 `conf/omf.conf` 覆盖；`BACKUP_SPACE_SAFETY`/`RMAN_RETRY`/`OMF_LOG_STRUCTURED` 等若未写进 conf，用代码内置默认值。

## 2.1 口令管理

- **推荐**：`omf config password` 交互式设置口令（`read -s` 不回显、不落 shell 历史），写入独立的 **`conf/.omf.secret`**（权限 `600`，已被 `.gitignore` 忽略）。支持显式传键名（`omf config password LSDHERP_PASSWORD`）与 `--remove <KEY>`。
- 也可用环境变量注入：`export ORACLE_PASSWORD=xxx`。
- 加载优先级：**环境变量 > `.omf.secret` > `conf/omf.conf` > 出厂默认**。
- 涉及键：`ORACLE_PASSWORD`/`SYSTEM_PASSWORD`/`PDB_PASSWORD`/`APP_PASSWORD` 及各模式 `<大写名>_PASSWORD`。

## 3. 多模式（多库）配置

一个 PDB 内运行多个 ERP 库（模式 = Oracle 用户）。在 `APP_SCHEMAS` 给模式名列表，每个模式可用 `<大写名>_USER` / `_PASSWORD` / `_TABLESPACE` / `_DATA_DIR` 个别覆盖：

```bash
APP_SCHEMAS="dherp lsdherp miserp"   # 空格分隔, 想加第 N 个直接追加
LSDHERP_PASSWORD="ls_pwd"            # 个别覆盖 (键名 = 大写模式名 + 后缀)
LSDHERP_TABLESPACE="ls_ts"           #   缺省: 用户名/表空间=模式名, 密码=全局 APP_PASSWORD
MISERP_DATA_DIR="/data/oracle/oradata/ARTERY/miserp"
```

要点：
- 框架自动把主模式 `APP_USER` 纳入列表（防漏建主库被静默丢弃）。
- 数据文件按 `<SID>/<模式名>/` 子目录隔离，避免多表空间同名文件冲突（`ORA-01537`）。
- `omf sql init` 按列表逐个建用户/表空间/目录授权。
- `omf sql import --schema <模式名>` 可指定导入到某模式（自动自举建模式）。

详见 [SQL.md](SQL.md) 与 [BACKUP.md](BACKUP.md)。

## 4. 内存参数调优

OMF 采用**集中规划、为 OS 预留余量**策略，避免把物理内存 100% 分给数据库导致 OOM：

```
物理内存 (MemTotal)
  └─ Oracle 可用内存 = 物理内存 × ORACLE_MEM_RATIO%   (默认 80%, 下限 2048MB)
       ├─ SGA 目标   = Oracle 可用 × SGA_RATIO%       (默认 75%)
       └─ PGA 目标   = Oracle 可用 − SGA 目标         (下限 512MB)
  └─ OS 预留        = 物理内存 − Oracle 可用
```

- SGA 还会被钳制为不超过 `物理内存 − HUGEPAGES_RESERVE_FREE_MB`（默认 2048MB），保证 OS / PGA / 安装器至少留 2GB。
- HugePages 数量（2MB/页）= `(SGA_MB + 256) / 2 + 2`，仅覆盖 SGA 并留约 256MB 余量，**不过度预留**。

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `ORACLE_MEM_RATIO` | `80` | Oracle 可用内存占物理内存百分比 |
| `SGA_RATIO` | `75` | SGA 占 Oracle 可用内存百分比 |
| `HUGEPAGES_RESERVE_FREE_MB` | `2048` | SGA 钳制上限预留（给 OS 的常规内存下限）|
| `HUGEPAGES_DEFER` | `false` | true 时大页推迟到 `omf db create` 前再预留（避免安装器内存不足）|

```bash
omf tune memory                       # 查看当前内存使用 + 建议配置
omf tune apply --scope memory        # 同时调 SGA+PGA (写 SPFILE, 需重启实例生效)
omf tune apply --scope sga           # 仅调 SGA
omf tune apply --scope pga           # 仅调 PGA
omf tune apply -y                   # 非交互自动确认 (危险操作, 仍会 SHUTDOWN/STARTUP)
omf check preflight                  # 安装前预检: 内存下限 / HugePages 建议
omf check all                       # 健康检查含内存项
```

- **务必为 OS 留余量**：旧版曾硬编码 `SGA=75% + PGA=25% = 100%` 不留 OS 空间会 OOM。
- **不要贸然 `nr_hugepages=0`**：SGA 跑在大页上时取消大页会无法分配、实例起不来。
- `omf tune apply` 会重启数据库（SHUTDOWN IMMEDIATE → STARTUP），生产环境务必在维护窗口执行。
- AWR 报告需快照：`omf tune awr [days]` 依赖 `dba_hist_snapshot` 至少 2 个快照；不足时先 `EXEC DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT;`（间隔数分钟再建一个）。
