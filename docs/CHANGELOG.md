# 版本变更记录

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

## v1.28 关键改进（db.sh 高危操作二次确认）
- **`omf db create` 升级为 `confirm_danger`（防 -y 误删库）**：原 `db create` 仅用普通 `confirm`，在 `-y` 下会直接通过并执行 `SHUTDOWN ABORT` + 删除现有 SID 的数据文件/FRA/admin 后重建——**数据不可逆丢失**。现改为 `confirm_danger`：即使 `-y` 也强制交互输入 `YES`，非交互环境默认中止；`omf deploy` 编排中以 `OMF_ALLOW_DANGEROUS=1` 显式放行（部署即重建语义，脚本化预期）。
- **`omf db dg failover` 升级为 `confirm_danger`（防自动化误触发灾难切换）**：failover 是脑裂/数据差异风险极高的灾难操作，原普通 `confirm` 在 `-y`/自动化下可能被静默触发。现强制二次确认，即便主库确认宕机也需显式 `YES`；确需脚本化时 `OMF_ALLOW_DANGEROUS=1` 放行。
- **`omf db stop` / `restart` 增加停机确认**：原 `db stop`/`restart` **无任何确认**即执行 `SHUTDOWN IMMEDIATE` 停机，误调用即停生产库。现加普通 `confirm` + 停机警告（停机属可用性影响、可逆，故用普通 `confirm` 以兼容 cron 维护窗口；与 `archivelog enable` 风格统一）。

## v1.27 关键改进（监听器日志安全轮换）
- **监听器日志清空改用 `lsnrctl` 安全轮换（修复文件空洞）**：原 `clean all`/`clean all --all` 直接用 `> listener.log` 截断。长生命周期 listener 仍持有旧 fd，会按原 offset 续写，导致文件中间出现 0 字节"空洞"且内容错位，难以排查。现优先 `lsnrctl set log_status off` 暂停日志写入 → 安全清空 → `set log_status on` 恢复（listener 重新打开日志 fd，从源头写、无空洞）；当 `lsnrctl` 不可用（如 listener 未启动）时降级为直接截断并告警，仍释放磁盘。

## v1.26 关键改进（clean all 回收站剥离 / 部署端到端冒烟示例）
- **回收站清理从 `clean all` 中剥离（高危操作脱敏）**：原 `omf clean all` 在常规按天清理（cron 用 `-y` 静默跑）中**无条件执行 `PURGE DBA_RECYCLEBIN`**——这是影响可恢复性的不可逆高危操作（会永久删除误删、待 `flashback` 恢复的对象），随 cron 静默执行是隐患。现改为：①常规 `omf clean all`（按天）**不再触碰回收站**；②仅 `omf clean all --all`（全量）经 `confirm_danger` 二次确认后才 purge；③新增独立子命令 **`omf clean recyclebin`** 供运维显式调用（名称本身警示危险），cron 模板同步改为可选注释行，不再隐式清空回收站。
- **监听器日志清空保留于 `clean all`（低危）**：仅清空、不影响可恢复性，维持常规执行；实现已改用 `lsnrctl` 安全轮换避免 `>` 截断造成的 fd 空洞（详见 v1.27）；预览提示已区分 `--all`/常规差异。
- **新增 `.github/workflows/deploy-selfhosted.yml`（自托管 Runner 端到端冒烟示例）**：在已备好 Oracle 介质的自托管 runner（`self-hosted,oracle` 标签）上，对 `omf deploy` 编排做端到端冒烟：默认仅校验（status / check / `SELECT 1 FROM dual` / 监听状态），`workflow_dispatch` 输入 `run_deploy=true` 才真正执行完整部署。手动触发，避免误跑重操作；与既有 `ci.yml`（纯静态自检）互补。

## v1.25 关键改进（高危操作 / 二次确认防护）
- **新增 `confirm_danger()`（高风险操作防护）**：普通 `confirm()` 在全局 `-y`（`OMF_ASSUME_YES=true`）下会直接放行，导致 `omf -y clean archive --all` 等"全量删除"操作**跳过确认直接执行**，对自动化/cron 是隐患。新增 `confirm_danger()`：即使 `-y` 也强制交互输入 `YES` 才放行；非交互环境（管道/cron）**默认中止并返回非0**，避免静默误删；确需脚本化时显式 `export OMF_ALLOW_DANGEROUS=1` 才跳过。已应用于：`clean logs/trace/audit/archive --all`（全量清理）、`db archivelog disable`（关闭归档，影响可恢复性）。
- **移除 `clean --force` 别名**：原 `--force` 实际是"全量删除"的别名（与 `CLEAN_ALL` 等价），语义极易误导（用户以为"强制确认"实则"全量删除"），已移除，统一用 `--all`/`-a` 表达全量。

## v1.24 关键改进（调优 / 避免无谓重启）
- **`omf tune apply` 短路判断**：原实现在 SGA/PGA 目标值与当前 SPFILE/运行值**已一致**时仍会 `SHUTDOWN IMMEDIATE; STARTUP` 重启库（无谓停机）。现应用前先查询 `v$spparameter`(SPFILE) 与 `v$parameter`(运行值)，若目标值已生效则**直接跳过重启**并提示"无需调整"，仅在确需变更时才重启；确认提示也附带了"当前值→目标值"的差异明细。

## v1.23 关键改进（状态总览 / 健康风险段落）
- **`omf status` 新增"健康风险"段落**：补充生产最关心的三项一手信号——**无效对象数**（>0 时提示排查/重编译）、**表空间使用率 >85% 清单**（提前预警写满）、**上次逻辑备份时间**（多久没备份）。与既有"备份概览/磁盘"呼应，使 `omf status` 真正成为一眼掌握库健康度的总览。

## v1.22 关键改进（日志错误汇总 / 天数过滤 + Top N）
- **`omf log errors [days]` 修复并增强**：原实现 `days` 参数被完全忽略（实际 grep 整个日志），且只罗列末尾若干行。现改为**真正按天数过滤**（兼容 19c XML `time='...'` 与文本 `Day Mon DD HH:MM:SS YYYY` 两种 alert 日志格式；取不到时间戳时回退全量，不丢数据），并**按错误码聚合 Top 10**（出现次数降序），更利于定位高频故障。已用样本日志验证：07-29 条目被正确排除、07-30 条目保留。

## v1.21 关键改进（健康检查 / 退出码透传）
- **`omf check` 退出码透传**（自动化致命修复）：`cmd_check` 在 `case` 列表内调用子检查，bash `set -e` 对 `case` 命令列表失效，原实现导致 `omf check all`/`monitor --alert` 即使出错/告警也**始终退出 0**，cron 无法据此告警。现改为 `cmd || rc=$?` 捕获并显式 `exit $rc`：`all`/`db`/`preflight` 等有错返回 2，`monitor --alert` 超阈值返回 1，正常返回 0。可直接接入 cron：如 `omf -y check all || 告警`。

## v1.20 关键改进（CI / 静态门禁）
- **新增 GitHub Actions CI**（`.github/workflows/ci.yml`）：对每次 `push`/`pull_request` 到 `main` 运行 `omf selftest` 作为**门禁**（纯静态检查，无需 Oracle，任意装 bash 的 runner 即可），并在独立 job 跑 `shellcheck`（`-S error` 仅 error 级失败，避免风格噪声阻断构建）。CI 范围刻意**不含 `omf deploy`**——部署 Oracle 需授权介质/root/大资源，需自托管 runner，属集成测试而非 CI 守卫。
- **`omf selftest` 退出码修复**：因 `omf.sh` 分发在 `case` 列表内，bash 的 `set -e` 对其失效，原函数 `return 1` 会被吞掉导致 CI 误判通过；改为失败时显式 `exit 1`（走 EXIT trap 清理），确保 CI 门禁能正确感知失败。本地实跑：35 项全过、0 失败。

## v1.19 关键改进（监控告警 / 外部 webhook 对接）
- **`send_notification` 新增通用 webhook 渠道**（命中你点名的**监控**维度 — `monitor --alert` 可直接对外告警）：配置 `OMF_NOTIFY_WEBHOOK` 即启用，`OMF_NOTIFY_WEBHOOK_FMT` 指定 `raw`（默认，推送 `{"title","content"}`）/ `dingtalk`（text）/ `wechat`（markdown），**兼容 Prometheus Alertmanager、钉钉、企业微信**的入站 webhook。三个渠道（自定义钩子 `conf/notify.sh` → webhook → 邮件兜底）可叠加。
- 配套：新增 `conf/notify.sh.example`（演示对接钉钉/企微/Alertmanager 的 curl 写法，含 Alertmanager 的 `severity` 判定），`omf.conf.example` 增补告警通知配置段。

## v1.18 关键改进（多模式可见性 / 表空间维度）
- **`omf sql usage` 增加表空间维度明细**：每个模式除原有"段空间(MB)/无效对象/对象类型分布"外，新增**按表空间的段占用拆分**（`tablespace_name, mb`），便于定位某模式的大头落在哪个表空间（如数据 vs 索引表空间）；末尾附**全库表空间容量概览**（总量/已用/空闲/使用率，按使用率降序），一眼看出哪个表空间快满。

## v1.17 关键改进（部署 / 断点续跑）
- **`omf deploy` 断点续跑**：新增 `--from <序号|步骤>`（从指定步骤开始，跳过其前所有）、`--skip <序号|步骤>[,...]`（重复可多次，跳过指定步骤）、`--list`（仅打印步骤清单）。步骤可用**序号**（如 `3`）或**命令**（如 `db create`）定位。任一步失败立即中止（返回非0），配合 `--from` 可在修复后从断点继续，无需重跑已完成的步骤。

## v1.16 关键改进（部署 / 一键编排）
- **新增 `omf deploy` 一键部署编排**（命中你点名的 **部署** 维度）：串联 `check preflight`（预检）→ `env all`（系统环境）→ `install software`（Oracle 软件，支持 `--zip`/`--edition` 透传）→ `db create`（建库）→ `db archivelog enable`（开归档，物理备份前置）→ `sql init`（初始化）→ `backup auto`（首次备份）。每一步通过调用 `omf.sh` 子进程复用既有子命令，独立进程与日志、错误隔离；全局 `-y` 自动跳过各步骤确认。任一步失败即中止并提示可单独重跑该步（如 `omf -y db create`）。

## v1.15 关键改进（多模式可见性 / 空间与无效对象）
- **新增 `omf sql usage` 多模式空间使用一览**（命中你点名的 **多模式** 维度）：遍历 `APP_SCHEMAS`，逐个模式输出段空间占用（MB）、无效对象数、以及按对象类型的分布（表/视图/过程/函数/序列等），便于多库场景下快速掌握各模式体量与健康度，定位无效对象（INVALID）聚集的模式。

## v1.14 关键改进（内存调优 / 当前对比 + 大页建议）
- **`omf tune memory` 增强**（命中你点名的 **内存优化** 维度）：
  - 新增 **当前 vs 建议对比**：查询当前生效的 `SGA_TARGET`/`PGA_AGGREGATE_TARGET`，与框架建议值并排展示差值，一眼看出需要调大/调小多少。
  - 新增 **大页(HugePages)配置建议**：读取系统当前 `HugePages_Total/Free` 与页大小，结合 `omf_hugepages_count()` 给出建议的 `vm.nr_hugepages` 值，并在不足时提示写入 `/etc/sysctl.conf` 的修复命令。

## v1.13 关键改进（监控增强 / 持续采样 + 阈值告警）
- **`omf check monitor` 增强**（命中你点名的 **监控** 维度）：
  - 新增 **`--watch N` 持续采样**：每 N 秒输出一次快照（json/prom 格式可指定），便于人工盯屏或外部轮询。
  - 新增 **`--alert` 阈值告警模式**：按阈值（磁盘使用率 `MONITOR_DISK_WARN_PCT`/`MONITOR_DISK_ERR_PCT`、可用内存率 `MONITOR_MEM_WARN_PCT`/`MONITOR_MEM_ERR_PCT`，conf 可覆盖）判定，超阈值返回非 0 并调用 `send_notification`，便于直接接入 cron：如 `omf -y check monitor --alert || 告警`。采集逻辑抽为 `_monitor_collect`，供输出与告警复用，避免重复连库。

## v1.12 关键改进（备份可见性 / RPO）
- **`omf backup list` 增强**（命中你点名的 **备份** 维度）：
  - 新增 **RPO（恢复点目标）概览**：分别给出逻辑备份 RPO（最新 dump 文件的 mtime）与物理备份 RPO（基于 `V$BACKUP_SET` 最大完成时间），并给出**综合 RPO（最坏情况，取两者较旧者）**。运维一眼可见"当前若崩溃最多丢失多少数据时长"。
  - 逻辑备份列表新增 **大小列**（字节经 `human_size` 转 B/K/M/G），便于评估备份体积与磁盘占用。

## v1.11 关键改进（生产可见性 / 排障增强）

- **新增 `omf info` 实例信息总览**（`cmd/info.sh`）：集中展示生产排障、部署验证与交接最关心的信息——主机名/IP、OS、Oracle 关键路径（ORACLE_HOME/BASE、数据/备份目录、Alert/监听器日志、SPFILE）、监听器状态与端口/HOST、实例与库基本信息（版本/状态/角色/归档/服务名/归档目标）、**各 PDB 的 EZCONNECT 连接串**（`//host:port/pdb`）、内存概要（SGA/PGA target 与系统大页）。已加入只读命令白名单。
- **新增 `omf log errors [天数]`**（`cmd/log.sh`）：汇总最近 N 天（默认 1 天）Alert 与监听器日志中的 `ORA-/TNS-/ASM-` 错误，作为生产排障快速入口；`omf log` 用法提示同步更新为 `{view|tail|rotate|clean|errors}`。

## v1.10 关键改进（体验增量 / 自动补全增强）

- **`conf/omf.completion` 补全能力增强**：由"仅一级命令+已知子命令"升级为支持多级子命令（如 `omf db dg broker`、`omf sql import` 后接文件/选项）与全局选项（`-y/-d/-c/-h` 等）补全；`-c/--config` 之后补全文件路径；已输入以 `-` 开头时直接列出全局选项。启用方式不变（`source conf/omf.completion` 或 `cp` 到 `/etc/bash_completion.d/omf`）。

## v1.9 关键改进（可维护性 / 文档完善）

- **`omf selftest` 增加命令分发一致性校验**（`cmd/selftest.sh`）：在原有语法/shebang 检查基础上，新增正向校验（`omf.sh` 分发的每个命令，其引用的 `cmd/<x>.sh` 必须存在且定义了被调用的 `cmd_<x>` 函数）与反向校验（`cmd/` 下每个脚本都应被分发，否则提示疑似死代码），可在开发期快速发现框架内部「分发了但没实现 / 实现了没接入」的不一致。
- **README 完善**：功能大纲表补充 `omf selftest`；新增「进阶用法」小节，说明 `omf selftest` 与 bash 自动补全（`conf/omf.completion`）的启用方式。

## v1.8 关键改进（可维护性 / 体验增量）

- **新增 `omf selftest` 自检命令**（`cmd/selftest.sh`）：纯静态检查，不依赖 Oracle 环境，遍历 `omf.sh`/`lib/*.sh`/`cmd/*.sh` 执行 `bash -n` 语法检查与 shebang 检查，便于 CI 与批量部署前快速发现框架自身问题；已加入只读/静态命令白名单（跳过并发锁）。
- **新增 bash 自动补全脚本**（`conf/omf.completion`）：补全一级命令与已知子命令（选项如 `-y/-d` 不在补全范围）。启用方式：`source conf/omf.completion` 临时启用，或 `cp conf/omf.completion /etc/bash_completion.d/omf` 全局安装。

## v1.7 关键改进（健壮性 / 可读性与可维护性）

- **DG 日志传输状态解析重构**（`cmd/check.sh` `check_dg_inner`）：原代码用 `case "VALID\|*"` 这类转义 `\|` 匹配（数据格式为 `STATUS|ERROR`，`\|` 是字面管道符）。该写法可读性差、易误改坏（一旦错改成 `VALID|*`，`|` 会变成 case 模式分隔符导致匹配失效）。现改为先 `dest_status="${dest2%%|*}"` 截取状态字段，再用纯 `case VALID)`/`DEFERRED)` 匹配，语义更清晰、更健壮。

## v1.6 关键改进（缺陷修复 / 安全加固 / 运维健壮性）

- **修复全局 `--help` 误执行**：`omf -h <cmd>` / `omf --help <cmd>` 此前会先真正执行该命令再打印帮助（如 `omf -h db` 会连接数据库跑 `db status`）。现在在 dispatch 前拦截，仅打印帮助并退出，避免危险/只读命令被误触发。
- **OMF 运行日志自动清理**：`lib/common.sh` 的 `log_init` 每次运行顺手清理 `${OMF_HOME}/logs/omf_*.log` 中超过 `LOG_RETENTION_DAYS`（默认 30 天）的旧日志，防止长期运行的服务器被运行日志撑满磁盘；仅清理一级日志、不影响 `awr` 等子目录，本次新建日志为当天不会被误删。
- **配置校验增强密码安全**：`omf config validate` 新增「密码安全」段，检测 `ORACLE_PASSWORD`/`SYSTEM_PASSWORD`/`PDB_PASSWORD`/`APP_PASSWORD` 是否仍为出厂弱口令（`Qiyuan!960#123`、`dherp_skzy`、`ChangeMe_123` 等）或过短（<8 位），部署前即暴露风险。

## v1.5 关键改进（DG 切换自动化 / DG 感知启停 / DG 健康检查）

- **DG Broker 自动化**：`omf db dg broker` 一键创建/重建 Broker 配置（幂等，switchover/failover 的前置）。
- **计划内切换**：`omf db dg switchover [--to X]` 自动预检（角色=PRIMARY、Broker=SUCCESS、`Ready for Switchover: Yes`）后执行 `dgmgrl switchover`，附切换后行动指引与通知。
- **灾难切换**：`omf db dg failover [--to X] [--immediate]`，角色守卫（主库存活时拒绝）、`--immediate` 丢数风险强告警；`omf db dg reinstate [X]` 回收旧主库为新备库。
- **备库应用管理**：`omf db dg apply {start|stop|status}`（MRP 实时应用/停止/进程状态）。
- **延迟与间隙**：`omf db dg gap` 查看 `v$dataguard_stats` 传输/应用延迟、`v$archive_gap` 归档间隙、目的地错误。
- **DG 感知启停**：`ENABLE_DG=true` 时 `omf db start` 对物理备库保持 MOUNT+自动开 MRP（不再误 OPEN PDB）；`omf db stop` 先 CANCEL MRP 再关库。
- **DG 健康检查**：`omf check dg`（并入 `omf check all`，仅 `ENABLE_DG=true` 时执行）——主库查 dest_2 传输状态/归档间隙，备库查 MRP 进程/应用延迟，异常直接提示修复命令。

## v1.4 关键改进（运维增强 / 安全加固 / 多模式 / DG / 文档拆分）

- **文档拆分**：`README.md` 精简为首页（安装/快速开始/功能大纲+跳转），专题文档移入 `docs/`：`INSTALL.md`(环境/安装/建库/版本发行版)、`CONFIG.md`(配置/多模式/内存调优)、`SQL.md`(初始化/导入/多库/回滚)、`BACKUP.md`(备份/恢复/范围/按模式/DG)、`CHECK.md`(检查/总览/监控/场景)、`DATAGUARD.md`(DG 全盘指南)、`TROUBLESHOOT.md`(排错)、`CHANGELOG.md`(本文件)。
- **按模式逻辑备份**：`omf backup logical --schema <模式名>` 用 `SCHEMAS=` 仅导出指定模式（多库按库单独备份），固定导出 `PDB_NAME` 中的该模式。
- **模式存在性校验**：`omf check schemas`(及并入 `omf check all`) 遍历 `APP_SCHEMAS` 逐个查 `dba_users`，缺失即告警并提示 `omf sql init`。
- **回滚按模式定点重置**：`omf sql rollback --all --schema <名>` / `omf sql rollback <name> --schema <名>` 仅清该模式的执行记录（命名空间 `sql/.executed/<模式名>/`）；配套 `omf sql init --schema <名>` 仅重建单模式的用户/表空间，形成"重建+重置"闭环。
- **DG 全盘感知**：
  - `lib/common.sh` 新增 `omf_db_role` / `omf_dg_enabled` 助手。
  - `omf backup logical` 在 `PHYSICAL STANDBY` 上禁止（expdp 需读写库，应在主库跑）。
  - `omf backup restore --rman` 在主库+`ENABLE_DG=true` 时告警（物理恢复会破坏备库，恢复后须重建 DG）。
  - `omf status` 新增 **Data Guard 区块**，显示 `ENABLE_DG` 配置与实际数据库角色。
  - 详见 `docs/DATAGUARD.md`。
- **校验增强（前序）**：`validate_config` 校验模式名非空/合法标识符/重复；`omf_schema_list` 自动纳入主模式；`omf sql import` 跨模式 remap 统一授予 `IMP_FULL_DATABASE`；`omf backup restore` 新增 `--schema` 单模式恢复；文档引导统一为 `omf sql init`。

## v1.3 关键改进（开箱即用 / 多发行版）

- 多发行版支持：`omf env prepare` 按发行版选择 `apt`（Ubuntu/Debian）或 `dnf/yum/microdnf`（RHEL 系），依赖/预检统一用 `ldconfig`。
- Ubuntu libnsl 自动修复：装完依赖后自动从 `libnsl.so.2` 软链出 `libnsl.so.1`。
- setup 自动授权：自动 `chmod +x` 所有 `.sh` 并建 `omf` 软链。
- 安装全自动接管：`omf install software` 缺依赖时自动 `env prepare` 并 `chown` 安装包。
- preflight 阈值告警：`/tmp` ≥5G、`ORACLE_BACKUP` ≥20G。
- 配置模板入库：`conf/omf.conf.example`（脱敏），真实配置由 `.gitignore` 忽略。

## v1.2 关键改进

- 安装兼容性修复：`install software` 改为探测 `libnsl.so.1` 实际路径，并以 `PIPESTATUS` 正确捕获退出码。
- **Data Guard 备库自动构建**：`omf db dg standby`（RMAN duplicate）、`omf db dg enable`、`omf db dg validate`。
- **DG 钱包免密**：`omf db dg wallet` 创建自动登录钱包并入库 `sys` 凭据，消除 ps 密码残留（根因修复）。
- 时间点/SCN 物理恢复：`omf backup restore --rman [--scn|--time]`。
- 备份可恢复性校验：`omf backup validate` / `omf backup restore --rman --validate`。
- `omf tune apply [--scope memory|sga|pga]` 分域调优。
- 一键总览 `omf status`；框架自更新 `omf self-update`。

## v1.1 关键改进

- 定时任务不再静默失败（cron 以 `oracle` 运行，去 `require_root`）。
- 逻辑备份落盘修正：expdp 统一写入 `${ORACLE_BACKUP}/dump`。
- 密码安全：expdp/impdp 改用 parfile。
- 备份失败保护：RMAN 失败不删旧备 + 失败通知。
- 配置驱动备份：`BACKUP_MODE`。
- 集中日志：`logs/omf_<cmd>_<时间戳>.log`。
- SQL 严格错误检测 + 失败即停 + 断点续跑。
- 安装前预检 `omf check preflight`。
- 配置持久化 `omf config set`。
- 全局选项 `-y/-d/-c`、并发锁、`env_profile` 配置化。
