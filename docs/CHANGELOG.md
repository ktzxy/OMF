# 版本变更记录

## v1.60 关键改进（新增部署走查清单 DEPLOY_WALKTHROUGH.md）
基于"Ubuntu 单机全备 + CentOS 主备"两个真实部署场景的模拟推演，沉淀为可落地核对的走查清单：
- **新增 `docs/DEPLOY_WALKTHROUGH.md`**：两个场景从配置到备份/日志的完整命令序列，含 deploy 7 步拆解、backup auto 实际行为、DG 主备构建与 Broker 流程、备库 DG 守卫（禁 expdp）、`db_unique_name` 自动推导说明、落地核对清单。
- **核实并修正推演臆测**：确认 `DB_UNIQUE_NAME_PRIMARY/STANDBY` 在 `lib/config.sh` 有出厂默认（`<SID>_PRIMARY/_STANDBY`，随 SID 自动对齐，无需手配）；确认 Ubuntu 依赖包/`libnsl.so.1`/`/usr/lib64`/ufw/pam 等跨发行版适配已在 `cmd/env.sh` 系统落地（非待实测项）；标注 TEST_REPORT 中 `db_unique_name` 未生效为历史快照（当前代码已改为 SPFILE 先设后重启）。

## v1.59 关键改进（文档体系打磨：去重 + 补齐缺失 + 结构统一）
对全部 md 文档做系统打磨（消除重复、补齐缺失、统一结构）：
- **去重**：README 安装节压缩为指向 INSTALL.md；BACKUP.md §7 的 DG 规则压缩为交叉引用 DATAGUARD.md；SQL.md/DATAGUARD.md 坑点改为交叉引用 TROUBLESHOOT.md（统一排错入口）；CONFIG.md §3 多模式改为配置键表格并指向 SQL.md。
- **补齐缺失**：新建 **docs/INFO.md**（`omf info` 用途/输出/场景）与 **docs/DEPLOY.md**（deploy 步骤/参数/断点续跑/破坏性警告）；CONFIG.md 补全 `tune` 的 storage/session/analyze/awr 四子命令；CHECK.md 补 `log errors` 与 status 健康风险段；README 功能表补 info/deploy/selftest/self-update 链接。
- **结构统一**：TROUBLESHOOT.md 的 `#` 顶级标题降为 `##`；**CHANGELOG.md 精简**（保留 v1.58-v1.29 近期版本，v1.28 及更早归档到 `docs/CHANGELOG_archive.md`，篇幅 327→179 行）；TEST_REPORT.md 标注为历史快照。

## v1.58 关键改进（DBA 视角：调优前后 AWR 基线对比）
基于资深 DBA 建议，为 `tune apply` 补"调优前后对比"闭环：
- **调优前自动生成基线 AWR 报告**：`tune_apply` 在调优重启前调用 `tune_awr` 生成基线报告到 `logs/awr/awr_before_*.html`（快照不足时仅提示不阻断）。
- **重启后补对比指引**：健康验证通过后提示"等运行稳定（建议 1-2 天积累快照）后执行 `omf tune awr` 生成新报告，与基线对比 DB Time / 等待事件"，形成"调优前基线 + 调优后报告"的完整对比闭环。

## v1.57 关键改进（DBA 视角：表空间数据文件个数/大小可配）
基于资深 DBA 建议，解决"每模式 11×1G 起步对数据量小的组织过重"：
- **`_create_schema.sql` 数据文件动态生成**：由 PL/SQL 循环按 `&APP_DATAFILES`（默认 4 个）/`&APP_DATAFILE_SIZE_MB`（默认 1024M）拼接 `DATAFILE` 子句，替代原先硬编码 11×1G；文件个数钳制 1~16。
- **`omf_schema_datafiles`/`omf_schema_datafile_size` 辅助函数**：按 `<大写模式名>_DATAFILES`/`_DATAFILE_SIZE_MB` 逐模式覆盖，缺省用全局 `APP_DATAFILES`/`APP_DATAFILE_SIZE_MB`。
- **`_sql_run_file` 注入新 DEFINE**：增加模式名参数（`$6`），sql_init/`_ensure_schema_exists` 传入模式名以解析每模式配置；`load_config` 补默认值；`conf/omf.conf.example` 补配置说明。
- 验证数据文件循环生成正确（4 个 data00-03、大小/AUTOEXTEND 无误）。

## v1.56 关键改进（DBA 视角：SQL 事务边界澄清 + 跨主机恢复指引）
基于资深 DBA 建议的文档级补全：
- **SQL.md 补「rollback 语义澄清」**：明确 `omf sql rollback` 只清执行标记、**非回滚**（不能撤销已执行的 DDL/DML，需靠 flashback/备份恢复）；并警示 `sql_execute_all` 的"失败即停"是脚本级非事务级——含多条 DDL 的脚本中途失败后前面已持久化、重跑会因对象已存在失败，**SQL 脚本须自身幂等**。
- **BACKUP.md 新增「跨主机恢复（DR 到异机）」**：说明 `omf backup restore` 只作用于本机；给出逻辑（scp dump + `sql_import`，推荐）与物理（RMAN 控制文件重建 + RESTORE/RECOVER + RESETLOGS，需路径一致）两种跨机恢复流程，并提醒物理恢复路径一致性是 DR 演练最易踩坑点。

## v1.55 关键改进（DBA 视角：check monitor 补生产关键指标）
基于资深 DBA 建议，补齐 monitor 生产瓶颈/容量指标：
- **`_monitor_collect` 新增 4 个指标**：
  - `_MC_CPU` 主机 CPU 使用率（`/proc/stat` 两次采样差值，非瞬时值）
  - `_MC_ACTIVE_SESS` 活动会话数（`v$session` ACTIVE 非后台）
  - `_MC_REDO_MBPS` Redo 平均生成速率（MB/s，`redo size`/实例启动秒数，供容量评估）
  - `_MC_TOP_WAIT` Top 等待事件名（非 Idle，生产瓶颈首要信号）
- **json/prom/历史快照输出**均补 `cpu_pct`/`active_sessions`/`redo_mbps`（prom 附 HELP/TYPE），json 另含 `top_wait`。
- **`--alert` 新增 CPU 阈值告警**：`MONITOR_CPU_WARN_PCT=90`/`ERR_PCT=98`（conf 可覆盖），高 CPU 告警附 Top 等待事件提示。
- `conf/omf.conf.example` 补 CPU 阈值注释。

## v1.54 关键改进（DBA 视角：RMAN 增量累积策略 + 归档自动清理防 FRA 满）
基于资深 DBA 视角建议，优先落地备份可靠性与效率两项：
- **RMAN 增量累积策略**：`omf backup incremental` 新增 `--level N`（默认 1）、`--cumulative`（默认，累积增量，恢复只需 0 级+最新 1 级累积）/`--differential`（差异增量）参数；RMAN 脚本 `BACKUP INCREMENTAL LEVEL ${level} ${accum}` 明确累积/差异类型。
- **归档自动清理防 FRA 满**：新增 `rman_purge_archivelog` 辅助函数，物理全量/增量备份【成功】后调用 `DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-N'`（N=保留期），删除已备份的过期归档。**仅在备份成功后清理**（与"失败不删旧备"一致），防止 FRA 被归档撑满这一生产最常见事故。
- `omf.sh` backup help 补充 incremental 新选项与归档自动清理说明。

## v1.53 关键改进（新手安全预警 + deploy 交互优化）
基于"小白上手"审查发现的语义预警缺失与交互细节：
- **README 顶部补默认口令警告**：明确"上线前必须用 `omf config password` 或环境变量改掉出厂默认弱口令（`Qiyuan!960#123`/`dherp_skzy`）"，否则 validate 持续报弱口令风险、带默认口令上线等于裸奔。
- **README 补 `omf deploy` 破坏性警告**：明确 deploy 第 7 步 `db create` 会 `SHUTDOWN ABORT` + **删除现有 SID 数据重建（不可逆）**，仅限全新机器/可重建环境；并说明 deploy 强依赖 conf 路径、`ORACLE_ZIP` 安装包，首次使用前须 `config init` + `validate`。
- **README 补多模式三配置关系**：解释 `APP_USER`/`APP_TABLESPACE`/`APP_SCHEMAS` 三者关系，强调"无论单/多组织都会建 `APP_USER` 模式"，防新手漏改导致 `sql init` 结果与预期不符。
- **`omf deploy` 补总耗时预估**：步骤清单前提示"预计 40-70 分钟（安装+建库各 15-30 分钟），期间勿中断"，避免新手跑一半以为卡死；并修正步骤串 `omf ${s%%*}` 为 `${s%%:*}` 的笔误。

## v1.52 关键改进（密码特殊字符统一转义）
- **新增统一转义函数**（`lib/common.sh`）：`omf_quote_sql`（SQL 字符串单引号翻倍包裹）与 `omf_quote_sh`（shell 单引号 `'`→`'"'"'` 转义），供密码/字符串传参统一使用。
- **SQL DEFINE 密码转义**：`sql.sh` 的 `_sql_run_file`/`sql_execute_inline` 中 `DEFINE APP_PASSWORD` 改用 `omf_quote_sql`，并加 `SET DEFINE OFF`（防密码含 `&` 触发 SQL*Plus 变量替换）。
- **expdp/impdp parfile 密码内双引号转义**：`backup.sh` 的 expdp `USERID` 与 `sql_import.sh` 的 impdp `userid` 中密码含 `"` 时转义为 `\"`（此前会破坏 parfile 语法）。
- **harness 回归 16→17 项**：新增"特殊字符转义函数正确"（验证单引号翻倍、shell 转义 eval 可还原）。
- 背景：审查发现密码特殊字符传递四处路径各自为政（DBCA 命令行/impdp parfile/SQL DEFINE/备份 connect 串），默认弱口令 `Qiyuan!960#123` 恰好能跑通掩盖了问题；用户一旦改含 `'`/`"`/`&` 的密码就会随机失败。本轮收敛 SQL 与 parfile 两处高风险路径，DBCA 命令行受 shell 二次展开影响较大，建议通过 `.omf.secret`/环境变量传递弱化该风险。

## v1.51 关键改进（跨发行版/资源适配：RHEL7 libxcrypt / ufw 端口同步 / 建库内存校验）
基于"使用者视角"审查发现的代码级问题修复：
- **RHEL7/CentOS7 依赖包修复**：`env_packages` 的 rpm 分支按 OS 版本精确剔除仓库不存在的 `libxcrypt`/`libxcrypt-devel`（RHEL7 由 glibc 提供 libcrypt.so.1），避免单包缺失导致整条 `dnf/yum install` 失败。
- **Ubuntu/Debian 改监听端口同步 ufw**：`listener_fw_update` 补 ufw 分支（`ufw allow/delete allow`），此前只处理 firewalld，Debian 系改端口后外网连不上。
- **`db create` 补内存下限强校验**：建库前调用 `check_memory_prereq "" true`，<4GB 直接中止（即使绕过 `omf check preflight` 直接建库也能拦截，避免 Oracle 在小内存上 OOM）。
- 复核确认 `check_memory_prereq` 非 fatal 模式已正确 `return 1`、preflight 已正确标 err（子代理误报，无需改动）。

## v1.50 关键改进（排障文档补全：常见 ORA- 速查表 + DG 排查指引 + DR 演练）
- **TROUBLESHOOT.md 新增「常见 ORA- 速查表」**：汇总散落各文档的错误码（ORA-01034/01109/01119/01537/01920/12514/16532/27037/31631/31684/39082/39149 等），每项对应**根因 + OMF 处理命令**，作为排障快速对照入口（配合 `omf log errors` 高频错误聚合）。
- **TROUBLESHOOT.md 新增「DG 故障排查指引」**：按"先传输→再应用→后间隙/磁盘"的顺序，覆盖 MRP 不启动、传输延迟大、FRA 满、角色误判、脑裂/failover 后旧主库等 6 类常见场景的排查步骤。
- **BACKUP.md 新增「备份恢复演练（DR 演练）」**：明确 `backup validate` 只做 `RESTORE VALIDATE` 不落数据、无法证明可恢复；给出逻辑/物理两种真实恢复演练流程与验证方法、演练后回滚/收尾、以及演练记录要点（RTO 内/保留期调整）。

## v1.49 关键改进（CONFIG.md 补全 + 口令说明统一 + wallet 幂等 mock 测试）
- **CONFIG.md 补全配置项表格**：新增 `BACKUP_SPACE_SAFETY`（此前连 example 都没有）、`RMAN_RETRY`/`RMAN_RETRY_INTERVAL`、`OMF_LOG_STRUCTURED`、`OMF_UPDATE_URL`，以及路径类（`ORACLE_USER/GROUP`、`ORACLE_DATA_BASE/ARCH/FRA`、`FRA_SIZE_MB`、`ORACLE_ZIP`）和实例参数类（`PROCESSES`/`OPEN_CURSORS`/`REDO_SIZE_MB`/`CHARSET`/`NLS_LANG`）。
- **CONFIG.md 新增口令管理说明（§2.1）**：`omf config password` 写入独立 `conf/.omf.secret`（600），并明确加载优先级（环境变量 > `.omf.secret` > `omf.conf` > 出厂默认），替换过时的"仅靠环境变量"表述。
- **`omf.conf.example` 口令注释统一**：明确 `ChangeMe_123` 为脱敏占位符（代码出厂默认与之不同，且均会被 `config validate` 判为弱口令），推荐用 `.omf.secret` 或环境变量注入，消除照模板生成后"validate 报弱口令"的困惑。
- **harness 回归 14→16 项**：新增"DG 钱包 tnsnames 别名幂等"（mock `oracle_su`，连续两次 `dg_wallet_setup` 验证 OMF_DG_WALLET 段只追加一次）与"backup incremental 别名可解析"（回归 v1.46 别名修复）。

## v1.48 关键改进（文档/帮助与实现同步）
基于深度排查的"文档与实现漂移"问题，逐项同步：
- **`omf log errors` 补进 help**：`omf.sh` 的 log help 由 `{view|tail|rotate|clean}` 补为含 `errors`（并说明聚合 Top10），与代码实现一致（此前按 help 不知道有此排障入口）。
- **TEST_REPORT.md 过时同步**：版本号 v1.4.0→v1.5.0；cron 用户说明更新为"v1.5.0 起改回 oracle 用户（原临时 root 处置已撤销）"；坑点0 根治建议明确为"装 `/opt/omf` 勿装 `/root`"；DG broker 部分更新为"v1.5.0 起 `omf db dg broker` 自动创建配置"（取代早期手动 dgmgrl）。
- **INSTALL.md 加部署路径硬性要求**：明确"必须装到 oracle 可读写路径（推荐 `/opt/omf`），切勿装 `/root/OMF`"，并解释原因（cron 以 oracle 运行），根治坑点0。

## v1.47 关键改进（通知可靠性：send_notification 失败可感知）
- **修复"备份失败但告警没发出"隐患**：`send_notification` 原先三渠道全部 `&>/dev/null &`（后台+丢输出），webhook 失败完全静默。现 webhook 改为**前台同步执行**（`curl -m 10` 有超时保护），失败即检测；配置了渠道但全部失败时 `log_warn "通知发送失败..."`，让日志能感知告警未送达。
- **不返回非0**：避免 `set -e` 下备份成功/监控告警等调用点因通知失败被误中断（失败经 `log_warn` 暴露，调用方如需编程式判断可自行扩展）。

## v1.46 关键改进（深度排查修复：status 中断 bug / backup 别名 / RMAN mock 测试）
基于框架深度检测发现的可靠性问题，落地：
- **修复 `omf status` 在无逻辑备份时中断**：`status.sh`/`backup.sh` 中 `ls -t dump/*.dmp | head -1` 无 `|| true`，在 `set -e` + `pipefail` 下，dump 目录无文件时 `ls` 失败会触发命令替换中断整个 status/backup_list。补 `|| true`（含 status 的最新日志行、backup_list 的 RPO 统计）。
- **`omf backup incremental` 兼容**：`cmd_backup` 增加 `incr|incremental` 别名，使用户按 `omf.sh` help（`incremental`）输入也能执行（此前只认 `incr`，按 help 输入会报错）。
- **harness 回归 12→14 项**：新增"RMAN 物理备份脚本生成正确"（mock `rman_run` 捕获生成的 RMAN 脚本，断言 FORMAT 含 `full/%d_%T_%s_%p`、`BACKUP AS COMPRESSED BACKUPSET`、`BACKUP CURRENT CONTROLFILE`——无库验证高危脚本拼写）与"无 dump 文件时 ls|head 不触发 set -e 中断"（回归 pipefail 防护）。

## v1.45 关键改进（多组织 DG：切换后连接串指引 + monitor PDB 级 redo 应用）
基于"多组织 DG 部署与生命周期"检测验证发现的痛点，落地两项改进：
- **switchover/failover 后多组织应用重连指引**：新增 `dg_app_conn_guide`，遍历 `APP_SCHEMAS`（多组织模式），输出每个组织的 EZConnect 连接串（`用户@新主库IP:端口/PDB`）与管理连接串，替代原先"应用改连新主库"一行笼统提示。明确提示 OMF 不自动翻转 tnsnames/钱包别名 IP，需确保各组织应用实际连到新主库。调用点：switchover/failover 成功分支。
- **`omf check monitor` 补 PDB 级 redo 应用（DG 场景）**：`_monitor_collect` 新增采集 `v$pdbs` 各 PDB 的 `con_id:name:open_mode` 到 `_MC_DG_PDB`，json 输出补 `dg_pdbs` 字段。辅助定位多组织下某个组织所在 PDB 是否单独异常（此前仅实例级 apply lag，无法定位具体 PDB）。

> 说明：钱包别名 IP 自动翻转（原计划第 2 项）因风险较高（修改 tnsnames 可能影响运行中连接）暂缓，当前以连接串指引覆盖应用改连核心需求。

## v1.44 关键改进（install 卸载清理 + clean 删除量回报）
- **`install --force` 清理系统注册残留**：强制重装路径在清理 ORACLE_HOME/inventory 之外，补充清理 `/etc/oratab` 中本 SID 行与 `/etc/oracle` 目录，避免重装后旧系统引用干扰。
- **`clean` 删除量回报**：新增 `_clean_del` 删除执行器（`find -delete -print` 一次统计实际删除数，累计到 `CLEAN_DELETED`），替换 `clean_logs`/`clean_trace`/`clean_audit` 的 `-delete`（此前 `|| true` 静默吞错，无法感知清理结果）；`clean all` 末尾回报本次删除文件总数。验证删除计数正确（2+1=3）。

## v1.43 关键改进（env 加固：内核参数备份 + 依赖包失败检测）
- **`env_kernel` 覆盖前备份原 sysctl 文件**：此前直接 `cat >` 覆盖 `/etc/sysctl.d/99-oracle.conf`，系统原有自定义内核参数会永久丢失且无回滚途径。现覆盖前若文件非空，先 `cp -a` 备份为 `99-oracle.conf.bak.<时间戳>` 并提示。
- **`env_packages` 依赖包安装失败不再"假成功"**：rpm 分支一次性安装后捕获退出码，非零即 `log_warn` + `return 1`；apt 分支末尾 `failed` 非空（有关键包缺失）时 `return 1`。此前两分支均无返回非零，部署/预检无法感知关键依赖缺失。

## v1.42 关键改进（体验类修补：备份成功通知 + 监听器端口冲突预检）
- **备份成功通知**（此前仅失败有通知）：`backup_physical`/`backup_incremental`/`backup_logical` 成功分支补 `send_notification`，与既有失败通知成对；逻辑备份部分失败也补通知。
- **监听器端口冲突预检**：新增 `listener_port_check`（用 `ss`/`netstat` 探测 TCP 监听），`omf listener start`/`restart` 启动前预检目标端口，被占用时提前提示/中止（`restart` 直接 `log_error`），避免"启动失败后翻日志排查"。

## v1.41 关键改进（生产痛点修补：env all / 解压校验 / 备份清理边界 / 锁分析修正 / 调优闭环）
基于全面排查（见对话记录）优先修复影响可用性与可靠性的问题：
- **修复 `omf deploy` 必失败 bug：`cmd_env` 新增 `all` 子命令**（等价 `prepare`）。此前 `deploy.sh` 第 2 步调用 `omf env all`，但 `cmd_env` 无 `all` 分支落入 `*)` 报错，导致一键部署第 2 步必然失败。现 `all|prepare` 均映射 `env_prepare`。
- **安装包解压前完整性校验 + 解压失败中止**：解压前 `unzip -l` 快速校验 zip 可读（能发现截断/损坏），解压后捕获退出码失败即 `log_error` 中止，避免带病生成响应文件继续安装。校验 `log_error` 自带 `exit 1`，安装失败会正确中止（不继续跑 root/监听器）。
- **逻辑备份失败不再清旧 dump**：`backup_logical` 仅当本次**所有分片**都成功才 `backup_cleanup_disks "dump"`；任一分片失败则保留旧 dump 维持可恢复窗口（与物理备份"失败不删旧备"语义一致）。
- **修正 `tune_session` 锁等待查询**：原 `JOIN v$session s2 ON l.id1 = s2.sid` 语义错误（`v$lock.id1` 是被锁对象 ID 非 sid），改用 `v$session.BLOCKING_SESSION` 官方推荐阻塞链查询 + 被阻塞对象查询。
- **`tune_apply` 补调优闭环**：调优前保存 SGA/PGA 参数快照到 `logs/tune_*_before_*.snap`（600 权限，供回滚参考）；重启后健康验证实例是否重新 OPEN，未 OPEN 则 `log_error` 提示用快照回滚。

## v1.40 关键改进（巨型文件拆分：sql.sh 776 → 414 行）
- **`cmd/sql.sh` 拆分出数据泵导入模块**：`sql_import` 及 impdp 系列（`sql_import_parfile_dir`/`ensure_dump_dir_object`/`_grant_import_privs`/`_ensure_schema_exists`/`sql_import_gen_parfile`/`do_impdp`/`_omf_dump_schema`/`_omf_dump_tablespace`）移至独立的 `cmd/sql_import.sh`（368 行）。
- **依赖处理**：import 组的 `_ensure_schema_exists` 依赖主文件的 `_sql_run_file`。`omf.sh` sql 分支改为**先 source 主文件、再 source sql_import.sh**（与 v1.39 的 backup_restore 依赖主文件工具函数同模式）。
- 至此 4 个巨型文件全部拆分完成（db/check/backup/sql）。拆分后所有 sql 函数可加载（ALL_LOADED），selftest 41/0。

## v1.39 关键改进（巨型文件拆分：backup.sh 846 → 624 行）
- **`cmd/backup.sh` 拆分出恢复模块**：`backup_restore`/`restore_logical`/`restore_rman` 移至独立的 `cmd/backup_restore.sh`（228 行）。
- **依赖处理**：restore 组依赖主文件的 `parse_scope`/`scope_clause`/`ensure_dump_dir`（这三个工具被所有 RMAN/恢复类函数共用，宜留在主文件）。`omf.sh` backup 分支改为**先 source 主文件、再 source backup_restore.sh**（保证工具函数先定义，与 v1.37 的 db_pdb 依赖 db_status 同模式）。
- `omf.sh` backup 分支一次 source 2 个文件。拆分后所有 backup 函数可加载（ALL_LOADED），selftest 40/0。

## v1.38 关键改进（巨型文件拆分：check.sh 871 → 596 行）
- **`cmd/check.sh` 拆分出监控模块**：`check_monitor` + `_monitor_collect`/`_monitor_run_once`/`_monitor_alert` 移至独立的 `cmd/check_monitor.sh`（281 行）。monitor 组内部自洽，仅依赖 lib/common.sh，与 check.sh 其余检查函数无调用耦合。
- `omf.sh` 的 check 分支改为一次 source 2 个文件。拆分后 16 个 check 函数全部可加载（ALL_LOADED），selftest 39/0。

## v1.37 关键改进（巨型文件拆分：db.sh 1142 → 385 行）
- **`cmd/db.sh` 按功能拆分为 4 个文件（消除巨型文件，职责单一化）**：
  - `cmd/db.sh`（385 行）：分发器 `cmd_db` + 基础生命周期 `db_create`/`db_optimize`/`db_status`/`db_start`/`db_stop`（`db_status` 留在主文件，被 create/start/pdb 共享）。
  - `cmd/db_dg.sh`（632 行）：Data Guard 全套 `db_dg` + 各 `db_dg_*` + `dg_wallet_*` + `dg_conn_*`（内部完全自洽，高度内聚）。
  - `cmd/db_archivelog.sh`（94 行）：`db_archivelog`（完全独立）。
  - `cmd/db_pdb.sh`（47 行）：`db_pdb`（依赖主文件的 `db_status`）。
  - 纯函数移动，不改任何逻辑；`omf.sh` 的 db 分支改为一次 source 4 个文件。
- **`selftest` 分发一致性检查适配多 source 行**：`omf.sh` 的 db 分支一行含多个 `source`，原检查用 `grep -oE` 取全部匹配导致 `sf`/`fn` 变多行而误判"分发引用 cmd/db.sh 但文件不存在"。现改为各取**首个**匹配，拆分文件（不定义 `cmd_*`）由反向存在性检查兜底。
- **验证**：拆分后 21 个函数全部可加载（ALL_FUNCTIONS_LOADED），selftest 38/0。

## v1.36 关键改进（运行日志结构化：cmd/subcmd 维度 + JSON Lines 模式）
- **运行日志新增结构化字段（cmd/sub 维度）**：`omf.sh` 记录命令名 `OMF_CMD`，各 `cmd_*` 入口经 `log_set_subcmd` 记录子命令名；`_log`/`log_error` 写日志文件时行首附加 `[cmd=X][sub=Y]`（终端仍人类可读，不破坏现有 grep/解析）。
- **新增 JSON Lines 日志模式**：conf 设 `OMF_LOG_STRUCTURED=true` 时，日志文件以 `{"ts","level","cmd","sub","msg"}` JSON Lines 输出，便于接入 ELK/日志监控。
- **`tests/harness.sh` 回归断言 10→12 项**：新增"文本模式含 cmd/sub 字段"与"JSON 模式输出合法 JSON"两项，固化结构化日志语义。

## v1.35 关键改进（load_config 的 set -e 保护：配置文件加载失败明确报错）
- **`omf.conf` 加载加 `set -e` 保护（防静默中断）**：配置文件是用户可控文本，语法错误/未定义变量在 `set -e` 下会静默中断整个 OMF 且难定位。现用 `set +e` 包裹 source 并捕获返回码，失败时给出明确错误 `配置文件加载失败(语法或执行错误): <路径>` 并退出非0。注意**必须在当前 shell source**（子 shell 会丢失配置里的变量赋值）。
- **`tests/harness.sh` 回归断言 9→10 项**：新增 `load_config 语法错误配置被明确拒绝`，固化"语法错误配置不得静默通过"语义。

## v1.34 关键改进（敏感口令独立管理 conf/.omf.secret / 回归测试补口令断言）
- **新增 `omf config password` 子命令（明文口令与 omf.conf 分离）**：原所有口令（`ORACLE_PASSWORD`/`SYSTEM_PASSWORD`/`PDB_PASSWORD`/`APP_PASSWORD` 及各模式密码）均明文写于 `omf.conf`，且默认带出厂弱口令兜底。现新增交互式口令管理：`read -s` 不回显、不写入 shell 历史，写入独立的 `conf/.omf.secret`（`chmod 600`）；支持显式传键名（如 `omf config password LSDHERP_PASSWORD`）与 `--remove <KEY>`。非交互（无 tty）下禁止设置，防密码经脚本/管道明文注入（自动化请用环境变量注入）。
- **`load_config` 支持加载 `.omf.secret`（口令优先级分离）**：加载顺序为 **环境变量 > `.omf.secret` > `omf.conf` > 出厂默认**。secret 文件仅提取 `*_PASSWORD` 键（防任意注入），且权限非 600 时告警提示收紧。修复了一个优先级 bug：secret 原先会**覆盖环境变量**，现改为仅当变量未在环境中时用 secret 覆盖 omf.conf，保证显式 `export` 优先。
- **`tests/harness.sh` 回归断言 7→9 项**：新增 `secret 文件口令覆盖 omf.conf` 与 `环境变量口令优先于 secret` 两项，固化口令优先级语义，防未来改动破坏。

## v1.33 关键改进（confirm 非交互语义修正 / set_config 防注入 / monitor 补 FRA 指标 / 危险路径回归测试）
- **`confirm` 非交互拒绝改为返回非0（修正 cron 误判"已执行"）**：原实现非交互未指定 `-y` 时 `exit 0`，cron 调用方无法区分"执行了"与"被拒绝"；现改为返回非0（与 `confirm_danger` 一致），使 `set -e` + `pipefail` 下调用链正确中断，cron 能感知"操作未执行"。交互下用户主动取消仍为 `exit 0`（正常结束，语义不变）。
- **`omf config set` 防注入加固**：`set_config` 新增键名白名单校验（仅允许 `[A-Za-z0-9_]`，防止经键名注入 `OMF_CONFIG["..."]` 数组语法）与换行值拒绝（防止 sed 追加时注入多条配置行）。非法输入直接 `log_error` 报错，不落盘。
- **`omf check monitor` 补 FRA(快速恢复区)使用率指标（DG/备份高危维度）**：满仓会阻塞归档与备份，是 DG 场景常见事故。`_monitor_collect` 新增查 `v$recovery_area_usage` 的 `PERCENT_SPACE_USED`；json/prom/历史快照均补 `arch_used_pct`；`--alert` 新增阈值 `MONITOR_ARCH_WARN_PCT=80`/`ERR_PCT=90`，超限发 ALERT/WARN（未配置 FRA 时为 -1，不误报）。
- **新增 `tests/harness.sh` 危险路径行为回归测试**：不依赖 Oracle、不改动真实 conf，固化了 7 项防护语义断言——`confirm` 非交互拒绝/`--yes` 通过、`confirm_danger` 非交互中止/显式放行、`set_config` 非法键名/换行值拒绝、合法键值持久化。运行 `bash tests/harness.sh` 即可回归，防未来改动破坏"执行前拦截"语义。

## v1.32 关键改进（sql.sh 危险路径加固 / rman_run 可配置化 / monitor 输出补指标）
- **`omf sql init --schema` 单模式重建补确认（执行前拦截）**：原实现无确认即重跑 `_create_schema.sql` 重建该模式用户/表空间，会短暂 DROP 会话、中断该模式现有连接；且确认提示被放在重建**落库之后**，confirm 形同虚设。现把普通 `confirm` + 连接中断警告**提前到重建循环之前**，确保真正在执行（CREATE USER/TABLESPACE 落库、中断连接）前拦截；仅普通确认即可，与 `db stop` 风格一致。
- **`omf sql rollback --all` 升级为 `confirm_danger`（防 -y 静默清记录）**：原 `--all` / `--all --schema` 仅用普通 `confirm`，在 `-y`/cron 下会被静默执行、不可逆地清除全部 SQL 执行记录（重跑将从头重建所有模式）。现改为 `confirm_danger`：即便 `-y` 也强制输入 `YES`，非交互环境默认中止；确需脚本化时 `OMF_ALLOW_DANGEROUS=1` 放行。
- **`rman_run` 重试次数/间隔抽为配置项（不再硬编码 1 次/5s）**：新增 `RMAN_RETRY`（默认 1）与 `RMAN_RETRY_INTERVAL`（默认 5s），`omf backup {auto|physical|incr}` 自动读取；`conf/omf.conf.example` 已补注释。网络存储抖动场景下可按需调高重试，消除误报失败；重试耗尽前才 `sleep`，最后一次失败不再空等。
- **`omf check monitor` 的 json/prom 输出补 4 个新指标（供 Prometheus 采集）**：原输出仅含 db_up/disk/mem/ora_errors/status。现 `json` 与 `prom` 均新增 `invalid_objects`（无效对象数）、`tbs_max_pct`（表空间最大使用率）、`backup_age_days`（最近全量备份天数，-1 表示无）、`dg_lag_sec`（DG 应用延迟秒）；历史快照 `monitor_history.jsonl` 同步补这 4 字段，便于趋势回溯。

## v1.31 关键改进（check monitor 阈值告警扩展）
- **`omf check monitor --alert` 新增 4 类告警维度（主动推送，不再仅展示）**：原 `--alert` 仅覆盖磁盘/内存/ORA-错误，`check_db` 虽已采集无效对象、表空间、备份时效却只展示不告警。本轮 `_monitor_collect` 新增采集并在 `_monitor_alert` 加阈值判定：
  - **无效对象数**（`dba_objects status='INVALID'`，阈值 `MONITOR_INVALID_WARN=20`/`ERR=100`）；
  - **表空间最大使用率**（所有表空间最高水位，阈值 `MONITOR_TBS_WARN_PCT=85`/`ERR_PCT=92`）；
  - **备份时效/RPO 风险**（最近成功全量备份距今天数 `MONITOR_BACKUP_MAX_DAYS`，默认 1 天；无备份则直接 ALERT）；
  - **DG 应用延迟**（仅 `ENABLE_DG=true` 采集，`v$dataguard_stats` 的 `+DD HH:MM:SS` 解析为秒，`MONITOR_DG_LAG_WARN_SEC=600` 即 10 分钟，超限 WARN）。
  - 全部阈值 conf 可覆盖（见 `omf.conf.example`），超阈值仍沿用 `send_notification`（webhook/邮件/自定义钩子），cron 接 `omf -y check monitor --alert || 告警` 即可主动通知。
- **`omf.conf.example` 补全告警阈值注释**：新增上述 4 类扩展阈值与说明。

## v1.30 关键改进（backup 健壮性：空间预检 + 失败重试）
- **`omf backup auto` 新增备份前空间预检（防盘满损坏备份集）**：物理/增量备份若目录剩余空间不足以容纳估算备份集（数据文件体量 ÷3 再叠加 `BACKUP_SPACE_SAFETY` 默认 20% 安全余量），会**直接中止并发送告警**，避免在"盘满"下写出损坏备份集——这是生产上最常见的"备份中途失败"事故。逻辑备份（expdp 增量追加、体量较小）不强制预检。`BACKUP_SPACE_SAFETY` 可在配置中调高阈值。
- **物理/增量备份新增失败重试（缓解偶发瞬断误报）**：封装 `rman_run` 辅助函数，RMAN 因网络存储抖动等偶发瞬断失败时**自动重试 1 次（共最多 2 次）**，消除误报失败；成功判定仍为 `rc=0 且无 RMAN-/ORA- 错误`。重试仍保留"成功后才清 obsolete / 失败才通知"的既有语义，且**失败绝不删旧备**。
- 预检失败会在 `backup auto` 的物理/`both` 分支前短路返回，避免浪费一次注定失败的备份。

## v1.29 关键改进（pdb close / dg apply stop 补确认）
- **`omf db pdb close` 增加确认**：原实现**无任何确认**即执行 `ALTER PLUGGABLE DATABASE <pdb> CLOSE IMMEDIATE`，会回滚未提交事务并断开该 PDB 上所有会话，误调用即中断业务。现加普通 `confirm` + 业务中断警告（关闭属可用性影响、可逆——`omf db pdb open` 即恢复，故用普通 `confirm`，与 `db stop` 风格一致）。
- **`omf db dg apply stop` 增加确认与后果提示**：原实现无确认即 `RECOVER MANAGED STANDBY DATABASE CANCEL`。停止 MRP 后备库不再追平主库，**长期停止会累积应用延迟与归档间隙，主库归档可能因备库未确认而堆积撑满 FRA**（是运维中常见的"停了忘记开"事故）。现加 `confirm` 并醒目提示"维护完成后请及时 `omf db dg apply start`"。

