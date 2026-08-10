# 排错提示

- **`Permission denied` / `lib/common.sh: No such file or directory`**：旧版经 `/usr/local/bin/omf` 软链调用时 `OMF_HOME` 解析错误。已修复（`readlink -f`），拉取最新代码即可；若仍报错，重跑 `./setup.sh`。
- **`chown: invalid user: 'oracle:oinstall'`**：在 `omf env prepare` 之前手动 `chown` 了安装包。无需手动 `chown`，直接 `omf install software` 会自动建用户并接管归属。
- **`/tmp` 空间不足导致安装失败**：Oracle 安装器需在 `/tmp` 暂存。`install software` 已自动将安装器临时目录重定向到配置的数据盘，若仍不足请扩容数据盘或手动设 `TMPDIR` 后重试。
- **`/backup` 剩余不足**：把 `conf/omf.conf` 的 `ORACLE_BACKUP` 改到空间充足的盘，再 `omf config validate`。
- **脚本 CRLF 报错 `bad interpreter`**：Windows 检出后脚本被转成 CRLF。仓库已用 `.gitattributes` 锁定 `*.sh` 为 LF；若手动改过，用 `dos2unix cmd/*.sh lib/*.sh omf.sh setup.sh` 修复。
- **配置改了不生效**（如 `HUGEPAGES_DEFER` 无效、内存仍被大页占满）：框架只读取 `conf/omf.conf`，**不读 `conf/omf.conf.example`**（脱敏模板）。确认改动落在正式文件：`grep -n HUGEPAGES_DEFER conf/omf.conf`；若文件不存在先用 `omf config init` 生成。用 `omf config set KEY VALUE` 也会自动写入正式文件。
- **`omf sql import` 跨模式权限不足（ORA-31631/ORA-39149）**：`--remap` 目标模式 ≠ 连接用户、或显式 `--schema` 时，连接用户需 `IMP_FULL_DATABASE`。框架已统一按条件自动授权，无需手动补。
- **PDB 须 OPEN**：`omf sql init`/查询前确保 `omf db pdb open` 已使 PDB 处于 READ WRITE，否则报 `no rows` 或对象建到 CDB$ROOT。
- **目录 OS 权限（impdp ORA-27037 / permission denied）**：`oracle_dumps` 指向的 `ORACLE_DUMP_DIR` 须为 `oracle:oinstall` 可读写（权限 `750`）。`omf sql init` 已自动建好并归属，手动改动后确认：`ls -ld /data/oracle/oracle_dumps`。
- **逻辑备份在物理备库上报错**：物理备库（PHYSICAL STANDBY）无法运行 expdp（需读写库），必须到**主库**执行 `omf backup logical`。这是 DG 环境预期行为，非故障。
- **主库物理恢复后备库失效**：`ENABLE_DG=true` 且当前为 PRIMARY 时 `omf backup restore --rman` 会告警。恢复后必须重新 `dgmgrl` 重建备库（或重新 RMAN duplicate），否则备库永久失效。
- **DG `dg status` 报 ORA-16532**：broker 配置尚未建立，属预期（用 `omf db dg validate` 校验），非故障。
- **多模式漏建主库**：若 `APP_SCHEMAS="lsdherp"` 但 `APP_USER=dherp`，框架已自动把主模式纳入列表，不会静默丢弃主库。
- **模式（多库）不存在**：`omf check schemas` 校验；缺失用 `omf sql init`（全量）或 `omf sql init --schema <名>`（单模式重建）补齐。

---

# 常见 ORA- 速查表

> 汇总各文档散落的错误码，对应 OMF 处理命令。**先在 `omf log errors`（最近 N 天错误聚合）看高频错误，再对照下表定位。**

| 错误码 | 含义 | 根因 | OMF 处理命令 |
|--------|------|------|-------------|
| ORA-01034 / ORA-27101 | ORACLE not available / 实例未起 | 数据库未启动或崩溃 | `omf db start`；看 `omf log view alert` |
| ORA-01109 | 数据库未打开 | 库处于 MOUNT/NOMOUNT，或备库 MOUNT 无 PDB | 主库 `omf db start`；备库保持 MOUNT 属预期 |
| ORA-01119 | 创建数据文件失败 | 数据目录不存在或不可写 | 确认 `<SID>/<模式名>/` 子目录存在，`omf sql init` 会自动建 |
| ORA-01537 | 数据文件同名冲突 | 多表空间同名文件 | OMF 已按 `<SID>/<模式名>/` 隔离目录，避免；手工建的库需自查 |
| ORA-01920 | 用户已存在 | 重复建同一 Oracle 用户 | `omf sql init` 幂等吞掉（跳过），非故障 |
| ORA-12514 | 服务未注册到监听 | PDB 未打开或监听未注册服务 | `omf db pdb open` + `omf listener status` |
| ORA-16532 | Broker 配置不存在 | DG broker 尚未建立 | `omf db dg broker`；此前属预期用 `dg validate` |
| ORA-27037 | 文件不可读/不可写 | 数据泵目录 OS 权限不对 | 确认 `ORACLE_DUMP_DIR` 属主 `oracle:oinstall` 权限 750 |
| ORA-31631 / ORA-39149 | 导入权限不足 | 跨模式 remap 时连接用户缺 `IMP_FULL_DATABASE` | `omf sql import --schema/--remap` 已自动授权，无需手动 |
| ORA-31684 | 对象已存在 | Data Pump 覆盖时非表对象已存在 | 属非致命，`omf sql import` 会跳过并计入良性；不影响数据 |
| ORA-39082 | 对象创建后编译失败 | 依赖缺失导致 INVALID | `omf sql usage` 看无效对象，检查依赖 |
| ORA-39111 / ORA-39151 | 依赖对象/表已存在跳过 | Data Pump 正常行为 | 属良性，`omf sql import` 跳过，结构一致无需覆盖 |

# DG 故障排查指引

> 顺序排查：**先看传输，再看应用，最后看间隙/磁盘**。核心命令：`omf db dg gap`（延迟/间隙）、`omf db dg validate`（传输/角色）、`omf check dg`（健康）、`omf log errors`（错误聚合）。

**1. `dg status` 报 ORA-16532**：broker 未建立 → `omf db dg broker` 创建；之前属预期。

**2. 应用延迟大 / MRP 不启动**（备库 `v$managed_standby` 无 MRP0）：
- `omf db dg apply start` 开启 MRP（实时应用）。
- 若仍不启动，查备库 alert 日志（`omf log view alert`）有无 ORA- 应用错误；常见为备库空间不足、数据文件路径问题（duplicate 时的 `db_file_name_convert`）。

**3. 传输延迟大 / 主备序列差距大**（`omf db dg gap` 看 transport lag）：
- 主库 `omf db dg gap` 看 `v$archive_dest_status` dest_2 状态：VALID 正常；DEFERRED 未启用 → `omf db dg enable`；ERROR 看 error 列。
- 检查主备网络、`log_archive_dest_2` 服务名可达（`omf db dg validate`）。

**4. FRA 满（归档堆积）**：
- `omf check monitor`（含 `arch_used_pct`）看 FRA 水位；`omf db dg gap` 确认备库未确认导致主库归档堆积。
- 备库恢复应用后自动追平；必要时 `omf clean archive` 清理过期归档（先确认备库已应用）。

**5. 主备角色误判 / 连接混乱**（切换后）：
- 切换后 tnsnames/钱包别名指向 IP 不自动翻转（见 DATAGUARD.md），多组织应用须按 `dg_app_conn_guide` 输出改连新主库 IP；否则连到已变备库（不可写）。
- 用 `omf db dg status`/`validate` 确认角色，避免基于 IP 判断。

**6. 脑裂 / failover 后旧主库**：
- failover 后旧主库须 `omf db dg reinstate`（需其 Flashback 已开）或重建 `omf db dg standby`。
- 切勿让旧主库同时以 PRIMARY 存活（脑裂风险），先确认旧主库已 SHUTDOWN 再 reinstate。
