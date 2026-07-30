# 版本变更记录

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
