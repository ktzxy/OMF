# OMF 分组测试报告

> 目的：记录各分组命令在本环境的实测结论、风险分级与关键坑点，作为生产操作依据。
> 测试框架版本：OMF v1.4.0

## 测试环境

| 项 | 值 |
|----|----|
| 主机 | localhost（CentOS/RHEL 系，Oracle 19c） |
| CDB | `ARTERY`（OPEN / ARCHIVELOG / PRIMARY） |
| PDB | `ARTERYPDB`（READ WRITE） |
| 监听端口 | `1522` |
| `local_listener` | `LISTENER_ARTERY`（tnsnames 别名，解析到 1522） |

---

## 分组与结论

本轮重点验证 **B 组**（env/install/db/backup/sql/log/clean/listener/check 等运维命令）。**A 组**已于上一轮验证通过（命令可用性确认）。

### B 组：按风险分级验证

#### 🟢 零风险（只读 / 预览）— 可随时跑

| 命令 | 结果 | 验证点 |
|------|------|--------|
| `omf backup list` | ✅ | RMAN 段无备份不报错，正常列出 dump / 备份集 / 目录占用 |
| `omf clean logs -p` | ✅ | 仅预览，列出待删文件 + 汇总（总数/将清理/即将过期），**不删除** |
| `omf clean trace -p` | ✅ | 同上 |
| `omf clean audit -p` | ✅ | 同上 |
| `omf clean archive -p` | ✅ | 基于 `V$ARCHIVED_LOG` 预览，同上 |
| `omf log rotate` | ✅ | alert 正常时仅清 7 天前 trace，几乎空转 |
| `omf sql status` | ✅ | 显示执行记录（成功/失败计数） |
| `omf sql scan` | ✅ | 列出待执行脚本 |
| `omf sql run "SELECT ..."` | ✅ | 切 PDB 执行，返回结果并打印「执行成功」 |

#### 🟡 需确认（轻微动作，命令自带 confirm 保护）

| 命令 | 结果 | 说明 |
|------|------|------|
| `omf log clean` | ✅ | 删 N 天前旧日志/alert 备份，输入 `yes` 后执行 |
| `omf sql rollback --all` | ✅ | **只删 `sql/.executed` 标记文件，不碰库内数据**，可让 init 脚本重跑 |

#### 🔴 高风险（停机 / 写库 / 改配置）

| 命令 | 结果 | 说明 |
|------|------|------|
| `omf listener restart` | ✅ | 监听重启到 `1522`；**坑点**：`restart` 子命令**不刷新 `local_listener`**，重启瞬间 `Services Summary` 为空（`The listener supports no services`），库 OPEN 后 PMON 才自动注册 |
| `omf db restart` | ✅ | 停机约 **1 分 13 秒**（18:12:41 → 18:13:54），重新 OPEN / ARCHIVELOG / PRIMARY，PDB READ WRITE |

### 关键验证点（必做收尾，否则业务可能连不上）

1. **监听重启后必须确认服务注册**：
   ```bash
   lsnrctl status
   # Services Summary 应含 ARTERY / ARTERY_PRIMARY / ARTERYXDB / arterypdb 且 status READY
   ```
   若 services 为空，手动触发注册：
   ```bash
   sqlplus -s / as sysdba <<'SQL'
   ALTER SYSTEM REGISTER;
   SQL
   ```

2. **`local_listener=LISTENER_ARTERY` 是 tnsnames 别名**（非直接 `ADDRESS=(...)`），服务在 1522 上全部 READY 即证明其解析正确，**当前配置无需改动**。

3. **端到端连通性（可选但推荐）**：
   ```bash
   sqlplus dherp/<密码>@//localhost:1522/ARTERYPDB
   # 能进入 SQL> 提示符即证明 监听+服务名+端口+账号 全链路通
   ```

### 本轮未执行（非必要不测）

- `omf listener port <新端口>`：改 `listener.ora`/`tnsnames.ora` + 防火墙 + 改 `local_listener` + 重启，配错可能连不上库。
- `omf sql init` / `omf sql run --all`：真正写库建表空间/用户/对象，执行前务必 `omf sql scan` 确认脚本并确认幂等。
- `omf tune apply`：会重启数据库做内存调整，须维护窗口执行。

---

## D 组：定时备份与清理验证（omf backup / clean schedule）

> 目的：验证定时备份/清理任务能否真实执行，并暴露 cron 环境下的坑点。

### 1) backup auto 实测（BACKUP_MODE=both）

手动以 root 执行 `/root/OMF/omf.sh -y backup auto`，完整成功：
- **逻辑全量**：expdp 导出 `PDB=ARTERYPDB` → `/backup/oracle/dump/full_ARTERYPDB_20260724_172956_0{1..4}.dmp`，`Job successfully completed`（耗时 5:10）。数据库已有真实业务数据（DHERP 多张百万级表，如 `GOODSDOCEXPTEST` 1259712 行）。
- **RMAN 物理全量**：datafile 全备 + 归档 + controlfile + spfile + autobackup 全部 `Finished backup` / `Recovery Manager complete`。

### 2) clean all 实测（-y 生效）

手动 + cron 等价环境（`/bin/bash -c '... >> /root/OMF/logs/omf_clean_cron.log'`）均成功：
- 日志清理 / 审计清理 / 归档清理（`no obsolete backups found`，正常）/ 回收站 `DBA Recyclebin purged` 全部执行。
- **关键**：`clean all` 内部含多道 `confirm`，实测 `-y` 让全部通过，未出现"非交互环境, 已取消" → 坑点2 修复确认有效。

### 3) schedule setup 生成的 cron 文件（修复后）

`/etc/cron.d/omf_backup`：
```
# OMF 备份定时任务 (BACKUP_MODE=both)
0 2 * * * root /root/OMF/omf.sh -y backup auto >> /root/OMF/logs/omf_backup.log 2>&1
0 */4 * * * root /root/OMF/omf.sh -y backup archive >> /root/OMF/logs/omf_backup.log 2>&1
```
`/etc/cron.d/omf_clean`：
```
# OMF 定时清理任务
0 4 * * * root /root/OMF/omf.sh -y clean all >> /root/OMF/logs/omf_clean_cron.log 2>&1
0 5 * * 0 root /root/OMF/omf.sh -y clean archive >> /root/OMF/logs/omf_clean_cron.log 2>&1
```
> 注：cron 运行用户为 **root**（非默认 oracle），原因见坑点0。

### 4) 三个坑点（定时任务专项）

| # | 坑 | 根因 | 修复 | 验证 |
|---|----|------|------|------|
| **坑点0** | OMF 装在 `/root/OMF`（权限 700），cron 默认 `oracle` 用户无法进入 → 定时任务整体失败 | 部署路径问题 | **未改代码**，cron 用户改 `root`（omf 内部 `oracle_su` 切 oracle 设计支持，`require_db_user` 允许 root） | `su - oracle -c "/root/OMF/omf.sh ..."` 实测 `Permission denied`；改 root 后 cron 等价执行成功写入日志 |
| **坑点1** | 定时备份日志写死 `/var/log/omf_backup.log`，oracle 无写权限 → cron 静默失败 | `backup.sh` 硬编码路径 | 改 `${OMF_HOME}/logs/omf_backup.log`（与 clean 一致） | cron 文件现用 `/root/OMF/logs/...` |
| **坑点2** | cron 无 TTY 时 `confirm()` 默认 `exit 0` 取消任务 → `backup auto`/`clean all` 静默跳过 | `lib/common.sh` 第 91 行 `[ -t 0 ] \|\| { ... 已取消; exit 0; }` | 生成的 cron 命令自带 `-y`（源码 `backup_schedule`/`clean_schedule`） | `clean all` 在 `-y` 下真正执行清理，未再取消 |

### 5) 坑点0 根治建议（可选）

将 OMF 迁到 `/opt/omf`（与 README 快速开始一致），oracle 可访问，cron 即可恢复 `oracle` 用户：
```bash
systemctl stop crond
mv /root/OMF /opt/omf
ln -sfn /opt/omf/omf.sh /usr/local/bin/omf
cd /opt/omf && omf backup schedule setup && omf clean schedule setup
systemctl start crond
```

### 6) 小瑕疵（非阻断，留作优化）

`clean all` 曾报 `[WARN] Trace 目录不存在: /u01/app/oracle/diag/rdbms/ARTERY/ARTERY/trace` —— 原 `clean.sh`/`log.sh` 将 trace 目录路径硬编码拼接，未兼容 db_name/db_unique_name 差异；**已修复**为用 `find` 在 `${ORACLE_BASE}/diag/rdbms` 下定位真实 trace 目录（回退原拼接），见 `clean_trace()` 与 `log.sh:get_trace_dir()`。

---

## DG 专项测试（omf db dg）

> 目的：验证主库侧 Data Guard 准备命令 `omf db dg config` 的真实行为，记录坑点与修正。

### 执行后关键状态（已闭环）
| 项 | 值 |
|----|----|
| `db_unique_name` | `ARTERY_PRIMARY`（执行后统一，见坑点） |
| `LOG_MODE` | `ARCHIVELOG` |
| `FORCE_LOGGING` | `YES` |
| `DATABASE_ROLE` | `PRIMARY` |
| `dg_broker_start` | `TRUE` |
| `log_archive_config` | `DG_CONFIG=(ARTERY_PRIMARY,ARTERY_STANDBY)` |
| `log_archive_dest_2` | `SERVICE=ARTERY_STANDBY ASYNC ... DB_UNIQUE_NAME=ARTERY_STANDBY` |
| `fal_server` | `ARTERY_STANDBY` |
| `standby_file_management` | `AUTO` |
| Standby Redo Log | 4 组（4/5/6/7 各 2048M，主库上 UNASSIGNED 属预期） |

### 执行：`omf db dg config`
- 作用：主库侧 DG 准备——开归档、开 Force Logging、配 DG 参数、建 Standby Redo Log、`log_archive_dest_state_2=DEFER`（暂不传，备库就绪后再 enable）。
- 结果：除 `db_unique_name` 外全部参数设置成功。

#### ⚠ 坑点（重要）：`db_unique_name` 未生效
- 现象：脚本第一条 `ALTER SYSTEM SET db_unique_name='ARTERY_PRIMARY' SCOPE=SPFILE` 在执行时库未处于 OPEN（连接报 `ORA-01034 ORACLE not available`），且该语句在库起来后**不会被重跑** → `db_unique_name` 仍为默认值 `ARTERY`。
- 影响：与 `log_archive_config` 中登记的 `DG_CONFIG=(ARTERY_PRIMARY,ARTERY_STANDBY)` 第一个成员不一致，后续建 broker 配置 / 启用传输时 DG 按 `ARTERY_PRIMARY` 找不到主库，**同步起不来**。
- 处置（用户决策：统一命名，无论是否真建主备都固定为 `ARTERY_PRIMARY`，便于辨识、避免再改）：
  ```bash
  sqlplus -S / as sysdba <<'SQL'
  ALTER SYSTEM SET db_unique_name='ARTERY_PRIMARY' SCOPE=SPFILE;
  SHUTDOWN IMMEDIATE;
  STARTUP;
  SQL
  ```
- 复验：`db_unique_name=ARTERY_PRIMARY`；`lsnrctl status` 新增 `ARTERY_PRIMARY` 服务且 `status READY`；整组 DG 参数自洽。

### 验证命令结果与预期
- `omf db dg validate`：
  - DGMGRL 报 `ORA-16532: broker configuration does not exist` —— **预期**（尚未建备库、未建 broker 配置）。
  - 退化视图正常：`DEST_ID 1 VALID`、`DEST_ID 2 DEFERRED`（主动设的，符合预期）、`ARCH CONNECTED` / `DGRD ALLOCATED` 正常。
- `omf db dg status`：
  - DGMGRL `ORA-16532` —— **预期**，但工具判为 `✗ 执行失败`（瑕疵：broker 未配置时应判"未配置"而非失败）。
  - **broker 配置建立前，用 `omf db dg validate` 看状态更准。**

### OMF DG 流程缺口（重要）
- `omf db dg enable` 仅把 `log_archive_dest_state_2` 改 `ENABLE`，**不会自动 `CREATE CONFIGURATION`**。
- 即使用 `enable`，`omf db dg status` 仍报 `ORA-16532`，除非主备就绪后**手动 `dgmgrl` 建 broker 配置**。
- 真要建备的完整路径：`omf db dg wallet`（主备各一次）→ 备库 `omf db dg standby` → `omf db dg enable` → 手动 `dgmgrl CREATE CONFIGURATION` → `omf db dg validate`。

### DG 完整测试路径
| 步骤 | 命令 | 在哪台 | 前置 / 副作用 |
|------|------|--------|--------------|
| 1. 主库准备 | `omf db dg config` | 主库 | 已做；开归档+Force Logging+建 SRL（注意 `db_unique_name` 需已统一） |
| 2. 钱包免密 | `omf db dg wallet` | 主库**和**备库各一次 | 建 wallet + 写 tns 别名，消除连接密码暴露 |
| 3. 建备库 | `omf db dg standby` | **备库服务器** | RMAN duplicate，需同版本 Oracle、主备网络/静态监听/密码文件就绪 |
| 4. 开传输 | `omf db dg enable` | 主库 | `log_archive_dest_state_2=ENABLE` |
| 5. 建 broker 配置 | `dgmgrl` 手动 `CREATE CONFIGURATION` | 主库 | OMF 当前未自动建，需手动 |
| 6. 校验 | `omf db dg validate` | 主库 | `dgmgrl validate` 或退化查 `v$archive_dest_status` |
| 7. 看状态 | `omf db dg status` | 主库 | `dgmgrl show configuration`（需先有 broker 配置） |

> 单台机器无法真正测"双机同步"；但步骤 1 的参数正确性、步骤 6 的 validate 逻辑、钱包免密均可在主库侧验证。

### DG 作用
1. **灾难恢复**：主库机房故障，可切到备库继续营业（RTO 分钟级）。
2. **高可用**：配合 DG Broker 可自动/手动 failover。
3. **数据保护**：最大保护模式可做到主库提交前备库已收到 redo（零丢失）。
4. **只读分流（ADG）**：备库可开只读扛报表/查询，减轻主库压力。

### 本轮未执行
- `omf db dg wallet` / `standby` / `enable`：需第二台备库服务器，单台无法真正测双机同步（参数正确性与 validate 逻辑已在主库侧验证）。

---

## 结论

B 组运维命令 + D 组定时备份清理 + DG 主库准备均在 19c 单实例（CDB/PDB）环境验证：监听重启后服务注册正常、`local_listener` 别名解析正常、停库起库停机约 1 分 13 秒在可接受窗口内；`backup auto`（逻辑+RMAN 物理全量）与 `clean all` 在 `-y` 下真实执行成功，定时 cron 文件已带 `-y` 并写日志到 `${OMF_HOME}/logs`；DG `config` 主库侧参数全部落位，并修正了 `db_unique_name` 未生效的坑、统一为 `ARTERY_PRIMARY`，整组参数现已自洽。结合 A 组，OMF 运维、定时备份清理与 DG 主库准备可用性已确认。

**本轮修复的定时任务三坑**（已 commit & push）：坑点1（backup cron 日志路径 `/var/log`→`${OMF_HOME}/logs`）、坑点2（cron 命令加 `-y` 绕过 confirm 取消）、以及 `clean schedule {setup|show|remove}` 参数解析 bug；坑点0（`/root/OMF` 权限 700 致 oracle 跑不了 cron）以 cron 用户改 `root` 绕过验证，根治建议迁 `/opt/omf`。真双机同步（standby/enable/broker 配置）需备库服务器，待环境就绪再补测。
