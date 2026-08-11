# OMF 部署走查清单（场景推演与落地核对）

> 本文档是**部署流程走查与落地核对清单**，非框架使用指南。
> 完整命令语义见 `DEPLOY.md`（一键部署）、`DATAGUARD.md`（主备）、`BACKUP.md`（备份）。
> 每个场景均为「推演结论 → 已核实事实 → 落地命令」三层结构，落地时逐项打勾核对。

---

## 通用：框架硬性前置

任何场景（单机 / 主备）都满足以下前置，否则第一步即拒：

| 检查项 | 要求 | 依据 |
|---|---|---|
| 运行身份 | `root`（`require_root`） | `cmd/deploy.sh` 首行 |
| 数据库可连 | 已建库并 OPEN | `sql init` 的 `sql_preflight` |
| 内存下限 | 满足 `check_memory_prereq` 强校验 | `cmd/db.sh` |
| 磁盘 | 数据/备份目录空间足够，触发 `backup_spatial_check` | `cmd/backup.sh` |
| 发行版 | Ubuntu/Debian 与 CentOS/RHEL 系均支持 | `cmd/env.sh` |

### 发行版适配（已核实的框架能力，非待实测项）

框架在多轮迭代中已系统落地跨发行版适配（`cmd/env.sh`）：

- **依赖包按发行版/版本选择**：Ubuntu 分支区分 `libcrypt1`(22.04+)/`libxcrypt1`(18.04/20.04)、`libaio1t64`(24.04,time_t 64 位改造)/`libaio1`、`libnsl2`/`libtirpc3`；且**逐个安装、单包缺失不阻断整条**。
- **`libnsl.so.1` 自动软链**：Ubuntu 装完从 `libnsl.so.2` 软链出 `.so.1`，并补链接器名 `libnsl.so`（Oracle 19c 安装/运行必需）。
- **`/usr/lib64` 软链**：Oracle 链接脚本写死 RHEL 路径，Ubuntu 下自动指向 `/usr/lib/x86_64-linux-gnu/`。
- **防火墙**：RHEL 系 `firewalld`，Debian 系 `ufw`，改端口自动同步放行。
- **PAM**：Ubuntu 默认 `pam_deny`，`env all` 补最小可用配置。
- **RHEL7 libxcrypt 剔除**：老系统仓库无此包，按版本精确剔除避免整条安装失败。

> 结论：Ubuntu 与 CentOS 均可直接走 `deploy` / `env all`，无需手工补包。若某库仍缺，框架会给出明确的包名错误提示。

---

## 场景 1：Ubuntu 新环境部署 Oracle + 全备

**目标**：全新 Ubuntu 主机 → 装 Oracle 19c → 建库 → 全量备份（逻辑+物理）。

### 步骤（可整段走 `omf deploy`，也可逐条）

```bash
# 0. 准备安装包（默认名推导：LINUX.X64_193000_db_home.zip，19c EE）
#    put /opt/LINUX.X64_193000_db_home.zip

# 1. 初始化配置（复制模板，按需改 SID/PDB/内存/备份保留天数）
cp conf/omf.conf.example conf/omf.conf

# 2. 一键部署（7 步串联，失败即停，可 --from 续跑）
omf -y deploy --zip /opt/LINUX.X64_193000_db_home.zip --edition EE
```

### deploy 实际执行的 7 步（`cmd/deploy.sh` 步定义）

| # | 步骤 | 子命令 | 关键行为 |
|---|---|---|---|
| 1 | 预检 | `check preflight` | root/内存/磁盘/依赖，不满足即拒 |
| 2 | 环境准备 | `env all` | 建 oracle 用户、内核参数、目录、依赖、ufw 放行 |
| 3 | 安装软件 | `install software` | 解压→CVU→runInstaller→root.sh，Lib 兼容已内置 |
| 4 | 建库 | `db create` | 有 `confirm_danger`（删旧 SID 重建），deploy 以 `OMF_ALLOW_DANGEROUS=1` 显式放行 |
| 5 | 开归档 | `db archivelog enable` | 物理备份前置 |
| 6 | 初始化 | `sql init` | 按 `APP_SCHEMAS` 建模式/表空间 + 执行 init SQL |
| 7 | 首次备份 | `backup auto` | 按 `BACKUP_MODE`（默认 both=逻辑+物理） |

> 耗时：框架输出预估 **40-70 分钟**（软件安装+建库各 15-30 分钟）。期间勿 Ctrl-C。

### 首次备份（步骤 7，`backup auto`）实际行为

按 `BACKUP_MODE=both` 顺序执行：

1. **逻辑备份** `backup_logical`：expdp `FULL=Y` 连 PDB 服务，parfile 避免密码进 ps，落 `/backup/oracle/dump/`。
2. **空间预检** `backup_spatial_check`：`df` 可用空间 vs `SUM(bytes) FROM v$datafile)/3 ×(1+20%)`，不足即中止并告警（防盘满损坏备份集）。
3. **物理备份** `backup_physical`：RMAN `BACKUP AS COMPRESSED BACKUPSET DATABASE PLUS ARCHIVELOG` + controlfile + spfile，成功后 `DELETE NOPROMPT OBSOLETE` + `rman_purge_archivelog`（防 FRA 满）+ 清理过期 dump。

### 建库/备份的参数自适应

- **FRA 大小**：`FRA_SIZE_MB=40960` 若超磁盘可用空间，自动下调到「可用-15GB」并告警，避免 DBCA `DBT-06604` 失败。
- **表空间数据文件**：`sql init` 内 PL/SQL 循环按 `APP_DATAFILES`(默认4)/`APP_DATAFILE_SIZE_MB`(默认1024M) 生成，钳制 1-16 个，按 `<SID>/<模式>` 子目录隔离避免 `ORA-01537`。

### 部署后建议

```bash
omf status                   # 一手总览
omf backup schedule setup    # cron：每天02:00 backup auto + 每4h备份归档
omf check monitor --alert    # 监控告警
```

---

## 场景 2：CentOS 新环境部署主备 Oracle + 备份 + 日志

**目标**：两台 CentOS，主备 Data Guard，端口 1522(主)/1523(备)，IP 192.168.4.100(主)/192.168.4.101(备)，含备份与日志。

### 端口 1522/1523 的语义约定

框架是**单端口模型**（`LISTENER_PORT`）。本走查按最常见的生产拓扑解释：**主库监听 1522、备库监听 1523**，各服务器独立配置，DG 传输、钱包别名均自动带各自端口。

> 若你想的是"同一台跑 1522+1523 双监听"，框架不直接支持（多监听需手动补 listener），会偏离 OMF 编排，不建议。

### db_unique_name 的自动推导（已核实，无需手工配置）

`lib/config.sh` 有出厂默认，由 `ORACLE_SID` 自动推导：

```bash
DB_UNIQUE_NAME_PRIMARY  = ${ORACLE_SID}_PRIMARY   # SID=ARTERY → ARTERY_PRIMARY
DB_UNIQUE_NAME_STANDBY  = ${ORACLE_SID}_STANDBY   # SID=ARTERY → ARTERY_STANDBY
```

**主备两侧只要 `ORACLE_SID` 一致，唯一名就自动一致**，无需手工对齐。这两个键不在 `conf/omf.conf` 模板里，但 config.sh 有默认值，故不要也不需要在 conf 里配。

> 历史提示：早期版本 `db dg config` 存在"`db_unique_name` 未生效"的坑（先连库设置时库未 OPEN，且不重跑）。**当前代码已修正**为「先 `ALTER SYSTEM SET ... SCOPE=SPFILE` → 再 `SHUTDOWN IMMEDIATE`/`STARTUP`」，重启后即生效。见 `TEST_REPORT.md`（历史快照）。

### 主库（192.168.4.100，监听 1522）

**1. 配置 `conf/omf.conf`**：

```bash
ORACLE_SID="ARTERY"           # 主备必须一致
PDB_NAME="ARTERYPDB"          # 主备必须一致
LISTENER_PORT="1522"
ENABLE_DG="true"
PRIMARY_IP="192.168.4.100"
STANDBY_IP="192.168.4.101"
# 密码：ORACLE_PASSWORD / SYSTEM_PASSWORD / PDB_PASSWORD 主备必须一致（密码文件靠它）
# 建议用 omf config password 写入 conf/.omf.secret（权限600），或环境变量注入
```

**2. 部署主库**：

```bash
omf -y deploy --zip /opt/LINUX.X64_193000_db_home.zip --edition EE
```

> deploy 步骤5开归档、步骤7做首次全备——全备是建备前的合理基准备备（虽建备用 `DUPLICATE FROM ACTIVE DATABASE` 在线复制，不依赖备份集）。

**3. 配置 DG 主库**：

```bash
omf -y db dg config
```

实际执行（`cmd/db_dg.sh`）：设 `db_unique_name`(SPFILE) → `SHUTDOWN IMMEDIATE`/`STARTUP MOUNT` → `ALTER DATABASE ARCHIVELOG` → OPEN → `FORCE LOGGING` → 设 `standby_file_management=AUTO`/`fal_server`/`dg_broker_start=TRUE`/`log_archive_config`/`log_archive_dest_2='SERVICE=<STANDBY> ASYNC ...'` → **`log_archive_dest_state_2=DEFER`**（先不发日志，等备库就绪）→ 自动加 Standby Redo Log → 生成 PFILE → 重启。

**4. 建 DG 钱包（主库）**：

```bash
omf -y db dg wallet
```

`orapki wallet create` + `mkstore -createCredential` 写 sys 凭据，写 `sqlnet.ora`/`tnsnames.ora`（含 `PRIMARY_IP:1522` 与 `STANDBY_IP:1523`）。密码经文件管道传入，不进 ps。

### 备库（192.168.4.101，监听 1523）

**1. 配置 `conf/omf.conf`**（关键项与主库一致，仅端口/IP 不同）：

```bash
ORACLE_SID="ARTERY"
PDB_NAME="ARTERYPDB"
LISTENER_PORT="1523"
ORACLE_PASSWORD="<同主库>"
SYSTEM_PASSWORD="<同主库>"
PDB_PASSWORD="<同主库>"
ENABLE_DG="true"
PRIMARY_IP="192.168.4.100"
STANDBY_IP="192.168.4.101"
```

**2. 备库只装软件、不建库**（备库靠 RMAN duplicate 建，不是 db create）：

```bash
omf -y env all
omf -y install software --zip /opt/LINUX.X64_193000_db_home.zip --edition EE
omf -y listener port 1523    # 改监听端口（同步写回 conf + ufw 放行）
```

**3. 建 DG 钱包（备库也执行一次）**：

```bash
omf -y db dg wallet
```

**4. 复制密码文件到备库**（框架前提条件）：

```bash
# 主库执行：scp 密码文件到备库
scp $ORACLE_HOME/dbs/orapwARTERY 192.168.4.101:$ORACLE_HOME/dbs/orapwARTERY
```

### 回主库：开启日志传输 + 建 Broker

**5. 主库开启日志传输**：

```bash
omf -y db dg enable      # log_archive_dest_state_2=ENABLE
```

**6. 备库构建物理备库**（在 192.168.4.101 上执行）：

```bash
omf -y db dg standby
```

实际行为：确认前提 → 建目录 → 生成最小 PFILE（含 `db_file_name_convert`/`log_file_name_convert`/`log_archive_dest_2='SERVICE=<PRIMARY>'`/FRA）→ `STARTUP NOMOUNT PFILE=...` → RMAN：

```
DUPLICATE TARGET DATABASE FOR STANDBY FROM ACTIVE DATABASE DORECOVER SPFILE
SET db_unique_name='<STANDBY>' NOFILENAMECHECK
```

**7. 备库启动 MRP 实时应用**：

```bash
omf -y db dg apply start   # ALTER DATABASE RECOVER MANAGED STANDBY USING CURRENT LOGFILE
```

**8. 建 Broker（主库，switchover/failover 前置）**：

```bash
omf -y db dg broker
# dgmgrl: REMOVE/CREATE CONFIGURATION 'omf_dg' AS PRIMARY ... ADD <STANDBY> ... ENABLE
omf -y db dg status        # 等 1-2 分钟确认 SUCCESS
omf -y db dg validate      # 校验
```

### 备份 + 日志

**主库**：

```bash
omf -y backup auto                # 逻辑+物理全备
omf -y backup schedule setup      # cron：02:00 auto + 每4h archive
omf -y check monitor --alert      # 监控
```

**备库（DG 守卫会拦截 expdp！）**：

```bash
omf -y backup archive             # 归档日志备份
omf -y backup physical            # RMAN 物理备份（不跑 backup auto 的 logical 部分）
```

> **关键**：`backup_logical` 有 DG 守卫——检测到 `PHYSICAL STANDBY` 直接 `log_error` 拒绝 expdp（备库只读）。所以备库只做归档/物理备份，勿在主备都跑 `backup auto`（若 `BACKUP_MODE=both`，备库 logical 段会报错）。

**"日志"的两层含义**：

1. **数据库告警/归档**：`omf status` / `omf check monitor` 覆盖，归档由 RMAN 自动管理防 FRA 满。
2. **框架运行日志**：deploy/backup 全程写 `$OMF_HOME/logs/omf_*.log`；可开 `OMF_LOG_STRUCTURED=true`（JSON Lines）接日志平台；`LOG_RETENTION_DAYS=7` 自动清理。

### 主备日常与切换

```bash
omf db dg gap              # 传输/应用延迟与归档间隙（主备均可）
omf db dg status           # Broker 状态
omf db dg switchover       # 计划内切换（主库发起，零丢失，需 Broker SUCCESS + 备 Ready）
omf db dg failover         # 灾难切换（备库发起，旧主需 reinstate 或重建）
```

> 切换后 `switchover/failover` 会自动调用 `dg_app_conn_guide` 输出各模式（APP_SCHEMAS）的重连指引。OMF 不自动翻转 tnsnames/钱包 IP，应用需手动改连新主库。

---

## 两场景差异对照

| 维度 | 场景1 Ubuntu 单机全备 | 场景2 CentOS 主备+备份+日志 |
|---|---|---|
| 环境准备 | `deploy` 一步全包 | 主备各自 `env all`，备库**不建库** |
| 建库 | deploy 步骤4 `db create` | 主库 `db create`；备库靠 `db dg standby` duplicate |
| 归档 | deploy 步骤5 | 主库 `db dg config` 内建；备库由 duplicate 继承 |
| 端口 | 单端口 1521 | 主 1522 / 备 1523 |
| 备份 | `backup auto`（both） | 主库 both；备库**不能 expdp**（DG守卫）只做 archive/physical |
| 日志 | 框架 logs + 归档 | 同上 + DG 延迟监控 `MONITOR_DG_LAG_WARN_SEC` |
| 高可用 | 无 | DG broker + switchover/failover + wallet 免密 |
| db_unique_name | 不涉及 | 自动推导 `<SID>_PRIMARY/_STANDBY`，主备 SID 一致即对齐 |

---

## 落地核对清单（逐项打勾）

### 场景 1（Ubuntu）
- [ ] 安装包 `LINUX.X64_193000_db_home.zip` 已就位
- [ ] `conf/omf.conf` 已配置（SID/PDB/内存/备份保留天数）
- [ ] `omf deploy --zip ... --edition EE` 7 步全部 ✓
- [ ] `omf status` 确认库 OPEN、归档已开
- [ ] `omf backup list` 确认逻辑+物理备份成功、RPO 正常
- [ ] `omf backup schedule setup` 定时备份已配
- [ ] 记录密码（建议已入 `.omf.secret`，权限 600）

### 场景 2（CentOS 主备）
- [ ] 主备 `ORACLE_SID` / `PDB_NAME` / 三类密码 已对齐
- [ ] 主 `LISTENER_PORT=1522` / 备 `LISTENER_PORT=1523` 已配
- [ ] 主库 `deploy` 完成（含首次全备）
- [ ] 主库 `db dg config` ✓（归档/Force Logging/SRL）
- [ ] 主备各执行 `db dg wallet` ✓
- [ ] 密码文件已 scp 到备库
- [ ] 备库 `env all` + `install software` + `listener port 1523`（**不建库**）
- [ ] 主库 `db dg enable` 开启日志传输
- [ ] 备库 `db dg standby` duplicate 成功
- [ ] 备库 `db dg apply start` MRP 已应用
- [ ] 主库 `db dg broker` + `status` SUCCESS
- [ ] 主库 `backup auto`；备库 `backup archive` + `backup physical`
- [ ] 主备 `backup schedule setup`（备库注意避开 expdp 段）
- [ ] `omf db dg gap` 延迟正常、无归档间隙
- [ ] 日志：框架 logs 已接（可选 JSON Lines）+ 归档由 RMAN 管理

---

## 部署+日常运维速查（走查未覆盖的常用功能）

部署完成不代表结束。下表是框架已具备、但上述两个场景未展开的常用能力，按"部署期 / 日常 / 故障"三个运维场景归类。**部署期建议全程做完，日常期用 cron 固化。**

### A. 部署期（建议一次性做完）

| 功能 | 命令 | 作用 / 何时用 |
|---|---|---|
| 强口令 | `omf config password` | 把 ORACLE/SYSTEM/PDB/APP 四口令写入 `conf/.omf.secret`（600），替代弱口令兜底 |
| 配置校验 | `omf config validate` | 部署前校验配置 + 弱口令检测，必跑 |
| 业务数据导入 | `omf sql import <dump>.dmp --apply` | **部署后把历史数据搬进去**（impdp）。多模式加 `--schema <模式>`；`--check` 先探测源模式不导入 |
| 恢复演练 | `omf backup restore --rman --validate` | RESTORE VALIDATE，**不真恢复**，验证备份可恢复 |
| 全量体检 | `omf check all` | 库/磁盘/性能/alert/listener/模式 一次看全 |

### B. 日常运维（建议 cron 固化）

| 功能 | 命令 | 作用 / 何时用 |
|---|---|---|
| 定时备份 | `omf backup schedule setup` | 每天 02:00 `backup auto` + 每 4h `backup archive` |
| **定时清理** | `omf clean schedule setup` | **防日志/归档/回收站撑满**（deploy 完成也会提示）。清 logs/trace/audit/archive/backup |
| 定时体检 | `omf check monitor`（配合 `--alert`）+ cron | 生产指标：CPU/活动会话/redo速率/等待事件/FRA/DG延迟，超阈值告警 |
| 一键总览 | `omf status` | 库/监听/DG/磁盘/备份/健康风险/最近日志 |
| 实例信息 | `omf info` | 路径/端口/IP/连接串/内存/版本（交接给新手友好）|
| 历史趋势 | `omf status history [N]` | 读 `monitor_history.jsonl`，看最近 N 次监控快照趋势 |
| 启停维护 | `omf db {start\|stop\|restart\|status}` | 补丁/改参数后的常规重启 |
| 监听管理 | `omf listener {status\|start\|stop\|restart\|port <N>}` | 监听维护 |

### C. 故障 / 排错

| 功能 | 命令 | 作用 / 何时用 |
|---|---|---|
| 错误汇总 | `omf log errors [N]` | 汇总最近 N 天 Alert/监听器日志的 ORA-/TNS-/ASM- 错误 Top10 |
| 日志查看 | `omf log {view\|tail\|rotate\|clean}` | 运行日志查看/跟踪/轮转/清理 |
| 逻辑恢复 | `omf backup restore <dump>.dmp [--schema x]` | impdp 覆盖恢复（对象已存在 ORA-31684 属非致命）|
| 物理恢复 | `omf backup restore --rman [--scn N \| --time '...']` | RMAN 时间点/SCN 恢复；**主库+DG 时会告警需重建备库** |
| DG 健康 | `omf check dg` | 传输/MRP/延迟/间隙 专门体检（比 `db dg gap` 更全）|
| 性能 | `omf tune awr` | 生成 AWR 报告到 `logs/awr/`（调优前基线对比）|
| 框架自检 | `omf selftest` | 41 项静态自检（不依赖 Oracle，升级/排错后跑）|
| 多模式体检 | `omf sql usage` / `omf check schemas` | 各模式段空间/无效对象/表空间容量；校验配置模式真实存在 |

> **核心提醒**：部署后务必做两件事——①`omf sql import` 导入业务数据；②`omf clean schedule setup` 配定时清理（deploy 完成只提示了备份定时，清理定时易被忽略）。

---

## 运维提效拓展建议（框架可进一步自动化）

以下从"减少运维人员手工操作量"角度列出可拓展点，按价值排序。标注 `[已有]` 的是框架已具备、只需用起来；`[可拓展]` 是当前缺失、值得考虑实现。

### 高价值（强烈建议）

1. **[已有] 备份 + 清理 + 监控 三件套 cron 固化**：`backup schedule setup` + `clean schedule setup` + `check monitor --alert` 定时执行。这是最省人工的一件事，deploy 后 3 分钟配好，长期自动跑。

2. **[已有] 恢复演练自动化（DR 演练）**：备份验证 `backup restore --rman --validate` 应**纳入定期 schedule**（如每月一次），否则"备份每天都在做、但没人验证能不能恢复"是生产最隐性风险。当前 validate 是手工命令，建议拓展为可定时（见可拓展 #1）。

3. **[可拓展] 恢复/校验纳入定时**：把 `RESTORE VALIDATE` 做成 `backup schedule` 里的一个周期任务（如每周日 04:00 `backup restore --rman --validate`），失败告警。这样"可恢复性"从一次性变成持续监控。

4. **[可拓展] 备份报告生成**：`backup list` 已有 RPO/保留期分析，但只输出到终端。拓展为每次备份后**生成一份快照报告**（备份集清单/大小/RPO/下次预期），落盘 `logs/backup_reports/` 或随 webhook 推送，运维早上扫一眼即可，不用逐个 `list`。

### 中价值

5. **[已有] 多组织统一体检入口**：多模式场景用 `check schemas` + `sql usage` 一次查完所有 dherp/lsdherp 的空间、无效对象，已省去逐库手工 SQL。建议纳入日常 `check monitor` 一并轮询。

6. **[可拓展] 实例元数据一键导出**：`info` 已给出连接串/IP/端口，但未落盘。拓展为 `omf info --export <file>` 导出实例台账（SID/PDB/端口/IP/模式/备份策略/定时任务），交接、合规审计、故障应急时直接取，避免每次现查。

7. **[可拓展] 变更操作留痕（审计日志）**：`clean recyclebin`、`backup restore`、`sql rollback`、`db stop` 等**高危操作**当前只进运行日志。拓展为独立的**变更审计记录**（时间/操作者/命令/参数），便于回溯"谁在什么时候干了什么"。

### 低价值 / 需权衡

8. **[可拓展] PDB 级定时备份**：多 PDB 场景可对重点 PDB 单独配 `backup physical --pdb x` 定时，粒度更细（当前定时是全库）。适合"大库只保某个业务 PDB"。

9. **[可拓展] 备库自动归档清理守卫**：备库的归档由主库 RMAN 管理，但备库侧 `FRA_SIZE` 也需监控。建议 `check monitor` 对备库 FRA 单独阈值（已有 `MONITOR_ARCH_*`，确认覆盖备库即可）。

---

## 建议优先级小结

| 优先级 | 动作 | 工作量 |
|---|---|---|
| 立即做 | 部署后配齐 `config password` + `sql import` + `clean schedule` + `backup schedule` | 无（用起来）|
| 本周做 | 把 `backup restore --rman --validate` 纳入月/周定时，验证可恢复性 | 无（用起来）|
| 建议评估 | 备份报告落盘推送、实例台账导出、高危操作审计留痕 | 需开发（3 项各半天~1天）|
| 按需 | PDB 级定时备份、备库 FRA 阈值确认 | 按实际拓扑 |
