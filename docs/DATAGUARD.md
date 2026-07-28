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
#   真正建备需第二台服务器; 备库建好后手动 dgmgrl CREATE CONFIGURATION
```

`omf db dg` 子命令：

| 命令 | 说明 |
|------|------|
| `omf db dg config` | 配置主库（归档/Force Logging/SRL/参数，dest_state_2=DEFER）|
| `omf db dg enable` | 开启日志传输（dest_state_2=ENABLE）|
| `omf db dg standby` | 备库服务器自动建备（RMAN duplicate）|
| `omf db dg wallet` | 创建 DG 钱包（主备各执行一次，消除 ps 密码残留）|
| `omf db dg validate` | 校验 DG 配置/传输状态 |
| `omf db dg status` | 查看 DG 配置（`dgmgrl`）|

> `dg enable` 只改 `log_archive_dest_state_2=ENABLE`，**不自动建 broker 配置**；`status` 在 broker 配置建立前必然报 `ORA-16532`，属预期而非故障。

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
- `omf check all` 含实例/归档/磁盘/内存等，DG 环境下建议额外关注：备库 `v$managed_standby` 的 MRP（Managed Recovery Process）是否 APPLYING LOG，以及 `v$archive_dest_status` 的传输错误。

### 4.4 其它注意事项

- **主备 Oracle 版本须一致**（建备用 `duplicate from active database`，要求相同版本/补丁）。
- **主备 TNS / 静态监听**：备库需静态监听注册 `<STANDBY_SID>`，否则 duplicate 连不上。
- **密码文件**：主库 `orapw<SID>` 须复制到备库 `$ORACLE_HOME/dbs/orapw<STANDBY_SID>`。
- **Force Logging / 归档**：主库 `omf db dg config` 会自动开启，但务必在 `dg enable` 前确认 `log_mode=ARCHIVELOG` 且 `force_logging=YES`。
- **网络**：主备 `PRIMARY_IP`/`STANDBY_IP` 与 `LISTENER_PORT` 须互访，防火墙放行。

## 5. 排错

- `ORA-16532`（`dg status`）：broker 配置尚未建立，属预期，用 `dg validate` 校验即可。
- duplicate 失败：检查主备网络/静态监听/密码文件/目录权限；钱包就绪时 `dg standby` 自动用 `/@别名` 免密（否则回退 `sys/密码@host:port/sid`，密码会出现在 ps）。
- 备库长期未应用：查 `v$managed_standby` 的 MRP 状态与 `v$archive_dest_status` 错误，确认主库 `dest_state_2=ENABLE`（`omf db dg enable`）。
