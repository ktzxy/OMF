# Data Guard 全盘指南

OMF 对 Data Guard 提供主库配置、钱包免密、备库构建、校验与状态查看。本页覆盖**完整搭建流程**与**与其它模块的交互（全盘考虑）**。

## 1. 角色与配置

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `ENABLE_DG` | `false` | 是否启用 DG（影响备份/恢复守卫与 `omf status` 显示）|
| `DB_UNIQUE_NAME_PRIMARY` | `<SID>_PRIMARY` | 主库唯一名 |
| `DB_UNIQUE_NAME_STANDBY` | `<SID>_STANDBY` | 备库唯一名 |
| `STANDBY_SID` | `<SID>` | 备库 SID（可不同）|
| `PRIMARY_IP` / `STANDBY_IP` | `192.168.0.108` / `110` | 主/备 IP |

## 2. 搭建流程

```bash
# 1) 主库侧 DG 准备（开归档/Force Logging/配参数/建 SRL, dest_state_2=DEFER）
omf db dg config
#   关键: 执行前确认 db_unique_name 已统一为 <SID>_PRIMARY, 否则 config 首条语句
#         在库未 OPEN 时会失败且不重跑, 导致名字与 log_archive_config 不一致
sqlplus -S / as sysdba <<'SQL'
SELECT db_unique_name, log_mode, force_logging FROM v$database;
SQL
#   若 db_unique_name 非 <SID>_PRIMARY, 修正并重启:
sqlplus -S / as sysdba <<'SQL'
ALTER SYSTEM SET db_unique_name='<SID>_PRIMARY' SCOPE=SPFILE;
SHUTDOWN IMMEDIATE; STARTUP;
SQL

# 2) 校验（broker 配置未建前, validate 比 status 更准）
omf db dg validate      # DEST_1 VALID / DEST_2 DEFERRED 即预期; ORA-16532 属正常
omf db dg status        # broker 未配置会报 ORA-16532 (工具判失败), 属预期

# 3) 主备各执行钱包免密 (消除 ps 中 sys/密码 残留, 根因修复)
omf db dg wallet

# 4) 在【备库服务器】构建物理备库 (RMAN duplicate from active database)
omf db dg standby

# 5) 主库开启日志传输 + 校验
omf db dg enable
omf db dg validate

# 6) 创建 Broker 配置 (switchover/failover 前置, 主库执行)
omf db dg broker
omf db dg status        # 等 1-2 分钟后应显示 SUCCESS
```

`omf db dg` 子命令：

| 命令 | 说明 |
|------|------|
| `omf db dg config` | 配置主库（归档/Force Logging/SRL/参数，dest_state_2=DEFER）|
| `omf db dg enable` | 开启日志传输（dest_state_2=ENABLE）|
| `omf db dg standby` | 备库服务器自动建备（RMAN duplicate）|
| `omf db dg wallet` | 创建 DG 钱包（主备各执行一次，消除 ps 密码残留）|
| `omf db dg broker` | 创建/重建 Broker 配置（switchover/failover 前置）|
| `omf db dg switchover [--to X]` | 计划内主备切换（主库执行，无数据丢失）|
| `omf db dg failover [--to X] [--immediate]` | 灾难切换（备库执行）|
| `omf db dg reinstate [X]` | failover 后回收旧主库为新备库（需 Flashback）|
| `omf db dg apply {start\|stop\|status}` | 备库 MRP 应用管理 |
| `omf db dg gap` | 传输/应用延迟与归档间隙 |
| `omf db dg validate` | 校验 DG 配置/传输状态 |
| `omf db dg status` | 查看 Broker 配置（`dgmgrl`）|

> `dg enable` 只改 `log_archive_dest_state_2=ENABLE`，**不自动建 broker 配置**；备库建好后执行 `omf db dg broker` 创建 Broker 配置（switchover/failover 的前置），在此之前 `status` 报 `ORA-16532` 属预期而非故障。

## 2.1 角色切换（Switchover / Failover）

### 计划内切换（Switchover，无数据丢失）

适用: 主库计划内停机维护（打补丁/换硬件）。**在主库执行**：

```bash
# 前置(一次性): 创建 Broker 配置
omf db dg broker

# 切换 (自动预检: Broker=SUCCESS + Ready for Switchover: Yes)
omf db dg switchover                 # 切到配置的 DB_UNIQUE_NAME_STANDBY
omf db dg switchover --to <备库唯一名>  # 或显式指定

# 切换后
omf db dg status                     # 确认配置 SUCCESS
omf db dg apply status               # 本机(新备库)确认 MRP 应用
# 应用连接串改指新主库
```

### 灾难切换（Failover，主库故障）

适用: 主库彻底不可恢复。**在存活的备库执行**：

```bash
omf db dg failover                   # 完全 failover, 应用完剩余 redo (尽量零丢失)
omf db dg failover --immediate       # 立即切换, 不等剩余 redo (可能丢数据!)

# 旧主库修复后 (在新主库执行):
omf db dg reinstate                  # 回收旧主库为新备库 (需其 Flashback 在 failover 前已开)
# 若 Flashback 未开, 只能在旧主库服务器重建: omf db dg standby
```

> **建议**: DG 环境主库提前开启 Flashback（`ALTER DATABASE FLASHBACK ON`，需 FRA），否则 failover 后旧主库无法 reinstate 只能重建。

### 日常运维

```bash
omf db dg gap            # 传输/应用延迟、归档间隙、目的地错误
omf db dg apply start    # 备库开启 MRP 实时应用 (USING CURRENT LOGFILE)
omf db dg apply stop     # 备库停止应用 (如备库维护前)
omf check dg             # DG 健康检查 (传输/MRP/延迟/间隙, 已并入 omf check all)
```

`omf db start`/`omf db stop` 已 DG 感知（`ENABLE_DG=true` 时）：物理备库启动到 `MOUNT` 并自动开 MRP，停止先 `CANCEL` MRP 再关库——无需手工区分主备操作。

## 3. 钱包免密（消除 ps 密码残留）

`omf db dg wallet` 在主备各自：
1. 创建自动登录钱包（`orapki`，钱包密码随机一次性值，运行时免输入）；
2. 将 `sys` 凭据存入钱包（密码经文件管道传入，不进命令行/ps）；
3. 写入 `sqlnet.ora`/`tnsnames.ora`（主备别名）。

之后 DG 连接改用 `/@<别名>` 免密，数据库密码不再出现在命令行与 `ps`。`omf db dg standby` 在钱包就绪时自动改用免密连接（`dg_conn_primary`/`dg_conn_standby`）。

## 4. ⚠️ 与其它模块的交互（全盘考虑）

### 4.1 备份

- **逻辑备份（expdp）必须在【主库】**：物理备库（PHYSICAL STANDBY）是只读/MOUNT 状态，无法运行 expdp。OMF 已加守卫——在 `PHYSICAL STANDBY` 上执行 `omf backup logical` 会直接报错并提示到主库跑。
- **物理备份（RMAN）建议卸载到【备库】**：在物理备库做 RMAN 备份是标准实践（不占主库资源），OMF 对物理备份**不作节点限制**，备库可正常备份（备份的是备库数据，与主库一致）。
- **按模式逻辑备份**：`omf backup logical --schema <名>` 同样只在主库有效（同 4.1 守卫）。

### 4.2 恢复

- **逻辑恢复（impdp）无 DG 问题**：impdp 的 DML/DDL 会经 redo 自动同步到备库，DG 环境可安全执行。
- **物理恢复（RMAN）在主库会破坏 DG**：若 `ENABLE_DG=true` 且当前为 `PRIMARY`，`omf backup restore --rman` 会显式告警——恢复后的主库与备库 redo 流不一致，**恢复完成后必须重新在主库 `dgmgrl` 重建备库配置（或重新 RMAN duplicate 备库）**，否则备库永久失效。
- 维护窗口做主库物理恢复时，标准做法是先 `dgmgrl` 移除备库，恢复+前滚完成后重建。

### 4.3 状态与检查

- `omf status` 现含 **Data Guard 区块**：显示 `ENABLE_DG` 配置与实际数据库角色（PRIMARY / PHYSICAL STANDBY / …）。
- `omf check db` 的 SQL 输出已含 `database_role`，可直接看到当前角色。
- `omf check dg`（`ENABLE_DG=true` 时自动并入 `omf check all`）：主库查 `dest_2` 传输状态与归档间隙，备库查 MRP 进程与应用延迟，异常直接给出修复命令提示。
- 详情排查用 `omf db dg gap`（`v$dataguard_stats` / `v$archive_gap` / `v$archive_dest_status`）。

### 4.4 启停

- `omf db start`：`ENABLE_DG=true` 时先 `STARTUP MOUNT` 探测角色，物理备库保持 MOUNT 并开 MRP，主库正常 OPEN + 打开 PDB。
- `omf db stop`：物理备库先 `RECOVER ... CANCEL` 停 MRP 再 `SHUTDOWN IMMEDIATE`（避免关库卡在 MRP）。

### 4.5 其它注意事项

- **主备 Oracle 版本须一致**（建备用 `duplicate from active database`，要求相同版本/补丁）。
- **主备 TNS / 静态监听**：备库需静态监听注册 `<STANDBY_SID>`，否则 duplicate 连不上。
- **密码文件**：主库 `orapw<SID>` 须复制到备库 `$ORACLE_HOME/dbs/orapw<STANDBY_SID>`。
- **Force Logging / 归档**：主库 `omf db dg config` 会自动开启，但务必在 `dg enable` 前确认 `log_mode=ARCHIVELOG` 且 `force_logging=YES`。
- **网络**：主备 `PRIMARY_IP`/`STANDBY_IP` 与 `LISTENER_PORT` 须互访，防火墙放行。

## 5. 排错

> **系统化的 DG 故障排查指引**（MRP 不启动 / 传输延迟 / FRA 满 / 角色误判 / 脑裂等 6 类场景的排查顺序）已收进 **[TROUBLESHOOT.md 的「DG 故障排查指引」](TROUBLESHOOT.md)**，此处不重复。

本条保留 DG 特有的两个关键点：
- **duplicate 失败**：检查主备网络/静态监听/密码文件/目录权限；钱包就绪时 `dg standby` 自动用 `/@别名` 免密（否则回退 `sys/密码@host:port/sid`，密码会出现在 ps，建议先建钱包）。
- **`ORA-16532`（`dg status`）**：broker 配置尚未建立，属预期，用 `dg validate` 校验；`omf db dg broker` 创建后即正常。
