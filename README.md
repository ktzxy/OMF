# OMF - Oracle Management Framework

Oracle 数据库（CDB 系列：18c / 19c / 21c / 23ai）生命周期管理框架，类似 Helm 风格的命令行工具。

## 框架结构

```
omf/
├── omf.sh                    # 主入口
├── conf/
│   ├── omf.conf.example      # 配置模板 (脱敏, 入库)
│   └── omf.conf              # 真实配置 (本地生成, 已被 .gitignore 忽略)
├── lib/
│   ├── common.sh             # 公共函数库
│   └── config.sh             # 配置加载
├── cmd/
│   ├── env.sh                # 环境准备
│   ├── install.sh            # 软件安装
│   ├── db.sh                 # 数据库管理
│   ├── backup.sh             # 备份管理
│   ├── sql.sh                # SQL 脚本管理
│   ├── tune.sh               # 性能调优
│   ├── check.sh              # 健康检查
│   ├── log.sh                # 日志管理
│   ├── clean.sh              # 定时清理
│   ├── self_update.sh        # 框架自更新
│   └── config.sh             # 配置管理
├── sql/
│   ├── init/                 # 初始化脚本
│   ├── upgrade/              # 升级脚本
│   ├── patch/                # 补丁脚本
│   └── custom/               # 自定义脚本
└── logs/                     # 运行日志
```

## 快速开始

### 前置：生成正式配置文件 `conf/omf.conf`（必做）

> ⚠️ **框架只读取 `conf/omf.conf`，绝不读取 `conf/omf.conf.example`**（那是入库的脱敏模板，改它无效）。
> 之前有人把 `HUGEPAGES_DEFER`、`ORACLE_MEM_RATIO` 等项改到了 `omf.conf.example`，
> 结果一直用默认值、配置"不生效"。请务必确认改动落在 `conf/omf.conf`：
> `grep -n HUGEPAGES_DEFER conf/omf.conf`

二选一生成正式文件（生成后编辑的是 `conf/omf.conf`，不是 example）：

```bash
# 方式 A（推荐）：内置命令生成, 含全部配置项(含内存规划 HUGEPAGES_* 等)
omf config init
#   若 conf/omf.conf 已存在会询问是否覆盖; 生成后按需修改

# 方式 B：从模板复制
cp conf/omf.conf.example conf/omf.conf

vi conf/omf.conf                   # 按需修改密码/路径/IP (密码也建议用环境变量注入)
```

### 方式一：Git 克隆（推荐，便于更新）

```bash
git clone git@github.com:ktzxy/OMF.git /opt/omf
cd /opt/omf
./setup.sh                         # 自动 chmod +x 所有脚本、建 omf 软链、校验配置、可选预检

# 生成并修改正式配置 (见上方"前置"步骤, 注意改的是 conf/omf.conf 而非 example)
omf config init && vi conf/omf.conf

# 把 Oracle 安装包放到默认位置 (任意路径亦可, 安装时显式传入即可)
# 支持 CDB 系列: 18c/19c/21c/23ai, 由 conf 中 ORACLE_VERSION 决定默认包名
# 注意: 无需手动 chown, omf install software 会自动接管归属
mv LINUX.X64_193000_db_home.zip /home/oracle/   # 19c 示例, 其他版本包名见 ORACLE_VERSION

# 一键安装: 自动检测全新环境 → 自动 env prepare (建用户/装依赖/补 libnsl 软链)
#           → 自动 chown 安装包 → 解压安装
omf install software
# 等价于: omf install software /home/oracle/LINUX.X64_193000_db_home.zip
```

> 如需安装前先确认磁盘/依赖, 可先跑 `omf check preflight` 查看告警。

### 方式二：wget 解压即用

```bash
wget http://your-host/omf.tar.gz && tar xzf omf.tar.gz && cd omf
./setup.sh
# 生成并修改正式配置 (见上方"前置"步骤, 注意改的是 conf/omf.conf 而非 example)
omf config init && vi conf/omf.conf
omf install software /home/oracle/LINUX.X64_193000_db_home.zip
```

### 后续步骤

```bash
omf db create              # 创建数据库 (含内存优化前置)
omf sql run --all          # 导入并执行准备好的 SQL (失败即停, 支持断点续跑)
omf backup schedule setup  # 配置定时备份
omf clean schedule setup   # 配置定时清理
omf status                 # 一键总览
```

## 支持的 Oracle 版本

OMF 面向 **CDB 架构** 的 Oracle 数据库，当前支持：

| 版本 | 默认安装包名 (ORACLE_VERSION) | 说明 |
|------|-------------------------------|------|
| 18c  | `LINUX.X64_180000_db_home.zip` | CDB |
| 19c  | `LINUX.X64_193000_db_home.zip` | CDB（默认）|
| 21c  | `LINUX.X64_213000_db_home.zip` | CDB |
| 23ai | `LINUX.X64_2340000_db_home.zip` | CDB |

- 通过 `conf/omf.conf` 的 `ORACLE_VERSION`（取值 `18`/`19`/`21`/`23`）切换，框架据此推导默认安装包名与 CVU 兼容假名（`CV_ASSUME_DISTID`）。
- `ORACLE_HOME` 留空时按 `ORACLE_VERSION` 自动推导（如 `19` → `/u01/app/oracle/product/19.3.0/dbhome_1`），在 conf 中显式指定则覆盖（兼容自定义路径）。**装其他版本只需改 `ORACLE_VERSION` 一处**。
- 若安装包路径非默认，可设 `ORACLE_ZIP="/path/to/xxx_db_home.zip"`，或安装时显式传入 `omf install software <zip>`。
- 非 CDB 版本（如 11g、12c non-CDB）暂不官方支持（建库默认走 CDB/PDB）。

## 支持的 Linux 发行版

`omf env prepare` 按发行版自动选择包管理器与包名:

| 发行版 | 包管理器 | 备注 |
|--------|----------|------|
| CentOS / RHEL / Oracle Linux / Rocky / Alma / Fedora | `dnf` / `yum` / `microdnf` | 官方支持 |
| Ubuntu / Debian / Mint 等 | `apt` | 自动补 `libnsl.so.1` 软链 (Oracle 19c 需要) |

> 防火墙: RHEL 系用 `firewalld`, Debian 系用 `ufw`, 均未启用则跳过。
> 依赖/预检统一用 `ldconfig` 探测, 不再依赖 `rpm`。

## v1.1 关键改进

- **定时任务不再静默失败**：backup/clean 去掉 `require_root`，cron 以 `oracle` 用户正常运行。
- **逻辑备份落盘修正**：expdp 统一写入 `${ORACLE_BACKUP}/dump`，恢复路径一致。
- **密码安全**：expdp/impdp 改用 parfile，避免密码出现在 `ps`。
- **备份失败保护**：RMAN 备份失败时不执行 `DELETE OBSOLETE`，并发送失败通知。
- **配置驱动备份**：`BACKUP_MODE=logical|physical|both`，`omf backup auto` 按配置执行。
- **集中日志**：所有运行日志写入 `logs/omf_<cmd>_<时间戳>.log`（失败邮件/Webhook 通知为规划中功能，暂未实现）。
- **SQL 严格错误检测**：退出码 + `ORA-/SP2-/PLS-/TNS-` 正则三重检测；失败即停，重跑 `omf sql run --all` 自动跳过已成功脚本（断点续跑）。
- **安装前预检**：`omf check preflight` 校验内存下限、HugePages 建议、磁盘空间、依赖包、用户与数据库连通性。
- **内存前置**：`env prepare` / `db create` 前可先看 `omf check preflight` 的内存与 HugePages 建议。
- **配置持久化**：`omf config set KEY VALUE` 现在会写入 `conf/omf.conf`。
- **全局选项**：`-y/--yes` 非交互自动确认，`-d/--debug` 调试，`-c/--config` 指定配置。
- **并发锁**：每次执行按命令加文件锁，防止重叠运行。
- **env_profile 配置化**：`.bash_profile` 由配置变量生成，不再写死 SID/路径。

## v1.2 关键改进

- **安装兼容性修复**：`install software` 不再写死 `LD_PRELOAD=/usr/lib64/libnsl.so.1`，改为探测 `libnsl.so.1` 实际路径，OL8/9 不再失效；并以 `PIPESTATUS` 正确捕获安装器退出码。
- **Data Guard 备库自动构建**：`omf db dg standby` 在备库服务器通过 `RMAN duplicate from active database` 自动建备（自动生成备库参数文件、启动 nomount、执行 duplicate）；新增 `omf db dg enable`（开启日志传输）与 `omf db dg validate`（校验配置/传输）。
- **DG 钱包免密（消除 ps 密码残留）**：新增 `omf db dg wallet`，在主备各自创建自动登录钱包并将 `sys` 凭据入库，配合 `sqlnet.ora`/`tnsnames.ora`；之后 `omf db dg standby` 自动改用 `/@<别名>` 免密连接，数据库密码不再出现在命令行与 `ps` 输出中（根因修复，原 `sys/密码@host` 在长时 duplicate 期间全程可见）。
- **时间点/SCN 物理恢复**：`omf backup restore --rman [--scn N] [--time 'YYYY-MM-DD HH24:MI:SS']` 支持不完全恢复；未指定则完全恢复到最新归档。
- **备份可恢复性校验（演练）**：`omf backup validate` 与 `omf backup restore --rman --validate` 执行 `RESTORE ... VALIDATE`，恢复演练前必做。
- **tune apply 防护与分域**：`omf tune apply [--scope memory|sga|pga]` 可单独调 SGA 或 PGA；危险重启操作受 `--yes`/交互确认保护。
- **一键总览**：`omf status` 汇总版本、数据库、监听、磁盘、备份概览与最近运行日志。
- **框架自更新**：`omf self-update` 从 `OMF_UPDATE_URL` 下载 tar.gz 并覆盖更新（保留用户配置 `conf/sql/logs`）。

## v1.3 关键改进（开箱即用 / 多发行版）

- **多发行版支持**：`omf env prepare` 按发行版自动选择 `apt`（Ubuntu/Debian）或 `dnf/yum/microdnf`（RHEL 系），并映射对应包名；依赖/预检统一用 `ldconfig` 探测，不再依赖 `rpm`。
- **Ubuntu libnsl 自动修复**：Debian 系装完依赖后，自动从 `libnsl.so.2` 软链出 `libnsl.so.1`（Oracle 19c 运行/安装必需），使 `install software` 的 `LD_PRELOAD` 探测生效。
- **setup 自动授权**：`./setup.sh` 自动 `chmod +x` 所有 `.sh` 脚本并建 `omf` 软链，全新环境无需手动 `chmod`。
- **安装全自动接管**：`omf install software` 检测到 `oracle` 用户或核心依赖缺失时，**自动执行 `env prepare`**；并自动把安装包 `chown` 给 `oracle`，免去手动 `chown`。
- **用户家目录归属修正**：`omf env user` 建完用户后，若家目录已被 root 预先创建，自动将其归属改回 `oracle`，避免 `su - oracle` 写不进 `.bash_profile`。
- **preflight 阈值告警**：`omf check preflight` 新增 `/tmp（≥5G，不足直接报错）` 与 `ORACLE_BACKUP（≥20G）` 剩余空间阈值；依赖检查改用 `ldconfig`。
- **配置模板入库**：新增 `conf/omf.conf.example`（脱敏），真实 `conf/omf.conf` 由 `.gitignore` 忽略，避免明文密码上传。

## v1.4 关键改进（运维增强 / 安全加固）

- **日志统一（消除两套分离）**：所有业务日志（install / netca / dbca / backup）与 clean cron 日志统一汇入 `logs/omf_<cmd>_<时间戳>.log`（`OMF_RUN_LOG`），不再散落 `/tmp`、`/var/log` 与 `ORACLE_BACKUP`；仅保留 `/tmp` 下一次性响应文件与 `sql` 每脚本独立 `.logs`（断点续跑回看）。
- **self-update 完整性加固（Bug13）**：新增版本比较（相同版本跳过，`force` 强制）、可选 `OMF_UPDATE_SHA256` 完整性校验、覆盖失败/校验失败自动回滚、完成后报告真实新版本号；配置模板补充 `OMF_UPDATE_SHA256` 可选项。
- **监控机器可读输出**：`omf check monitor [json|prom]` 输出 JSON（默认）或 Prometheus 格式，采集 `db_up` / 磁盘使用率 / 内存可用率 / Alert ORA- 错误数及 `status`，对接外部监控无需解析人类排版；每次运行自动持久化快照。
- **AWR 自动报告**：`omf tune awr [days]` 非交互取最近快照首尾 ID，调用 `awrrpt.sql` 生成 HTML 报告到 `logs/awr/`。
- **每命令 `-h` 帮助**：`omf <cmd> -h`、`omf help <cmd>`、`omf -h` 全局总览均可用，并退出 0。
- **DG 钱包免密**：见 v1.2（根因修复 `ps` 密码残留）。
- **状态历史趋势**：`omf status history [N]` 读取 `check monitor` 持久化的 JSONL 快照，打印最近 N 次趋势（库存活 / 内存 / ORA 错误 / 状态 / 磁盘）。
- **稳定性与安装健壮性（历史批次）**：密码掩码（expdp/impdp parfile、DG 连接）、`sed` 特殊字符转义、`clean_archive` 空值保护、退出码 1/2 区分、锁不阻塞只读命令且消除 trap 覆盖；安装 `TMPDIR` 重定向、HugePages 落地、安装幂等、建库前磁盘预检、备份失败判定正则修正。

## 排错提示

- **`Permission denied` / `lib/common.sh: No such file or directory`**：旧版经 `/usr/local/bin/omf` 软链调用时 `OMF_HOME` 解析错误。已修复（`readlink -f`），拉取最新代码即可；若仍报错，重跑 `./setup.sh`。
- **`chown: invalid user: 'oracle:oinstall'`**：在 `omf env prepare` 之前手动 `chown` 了安装包。无需手动 `chown`，直接 `omf install software` 会自动建用户并接管归属。
- **`/tmp` 空间不足导致安装失败**：Oracle 安装器需在 `/tmp` 暂存。`install software` 已自动将安装器临时目录重定向到配置的数据盘（不再写死 `/tmp`），若仍不足请扩容数据盘或手动设 `TMPDIR` 后重试。
- **`/backup` 剩余不足**：把 `conf/omf.conf` 的 `ORACLE_BACKUP` 改到空间充足的盘，再 `omf config validate`。
- **脚本 CRLF 报错 `bad interpreter`**：Windows 检出后脚本被转成 CRLF。仓库已用 `.gitattributes` 锁定 `*.sh` 为 LF；若手动改过，用 `dos2unix cmd/*.sh lib/*.sh omf.sh setup.sh` 修复。
- **配置改了不生效（如 `HUGEPAGES_DEFER` 无效、内存仍被大页占满）**：框架只读取 `conf/omf.conf`，**不读 `conf/omf.conf.example`**（那是入库的脱敏模板）。确认改动落在正式文件：`grep -n HUGEPAGES_DEFER conf/omf.conf`；若文件不存在先用 `omf config init` 生成（含全部配置项）。用 `omf config set KEY VALUE` 也会自动写入正式文件。

## 命令速查

### 环境管理 (`omf env`)
| 命令 | 说明 |
|------|------|
| `omf env prepare` | 完整环境准备 |
| `omf env check` | 环境检查 |
| `omf env user` | 创建用户和组 |
| `omf env kernel` | 配置内核参数 |
| `omf env packages` | 安装依赖包 |

### 软件安装 (`omf install`)
| 命令 | 说明 |
|------|------|
| `omf install software` | 安装 Oracle 软件 |
| `omf install listener` | 配置监听器 |
| `omf install check` | 检查安装状态 |

### 数据库管理 (`omf db`)
| 命令 | 说明 |
|------|------|
| `omf db create` | 创建数据库 |
| `omf db status` | 查看状态 |
| `omf db start` | 启动数据库 |
| `omf db stop` | 停止数据库 |
| `omf db restart` | 重启数据库 |
| `omf db pdb open/close` | PDB 管理 |
| `omf db dg config` | 配置主库 Data Guard (归档/Force Logging/SRL/参数) |
| `omf db dg enable` | 开启日志传输 (dest_state_2=ENABLE) |
| `omf db dg standby` | 备库服务器自动建备 (RMAN duplicate) |
| `omf db dg validate` | 校验 DG 配置/传输状态 |
| `omf db dg status` | 查看 DG 配置 (dgmgrl) |
| `omf db dg wallet` | 创建 DG 钱包 (主备各执行一次, 消除 ps 密码残留) |

### 备份管理 (`omf backup`)
| 命令 | 说明 |
|------|------|
| `omf backup full` | 全量备份 (expdp) |
| `omf backup incr` | RMAN 增量备份 |
| `omf backup archive` | 归档日志备份 |
| `omf backup physical` | RMAN 物理全量备份 |
| `omf backup schedule setup` | 配置定时备份 |
| `omf backup auto` | 按 `BACKUP_MODE` 配置自动执行 (logical/physical/both) |
| `omf backup cleanup` | 清理过期备份 (按 `BACKUP_RETENTION_DAYS`) |
| `omf backup list` | 查看备份列表 |
| `omf backup validate` | 校验备份可恢复性 (RESTORE VALIDATE) |
| `omf backup restore <file>` | 逻辑恢复 (impdp) |
| `omf backup restore --rman [--scn N] [--time '...']` | 物理时间点/SCN 恢复 |
| `omf backup restore --rman --validate` | 物理备份校验 |

### SQL 脚本管理 (`omf sql`)
| 命令 | 说明 |
|------|------|
| `omf sql scan` | 扫描待执行脚本 |
| `omf sql scan --auto` | 扫描并自动执行 |
| `omf sql run <script>` | 执行指定脚本 |
| `omf sql run --all` | 执行所有待处理 |
| `omf sql init` | 初始化基线数据 |
| `omf sql status` | 查看执行状态 |
| `omf sql rollback <name>` | 重置执行记录 |

### 性能调优 (`omf tune`)
| 命令 | 说明 |
|------|------|
| `omf tune memory` | 内存参数调优 |
| `omf tune storage` | 存储参数检查 |
| `omf tune session` | 会话参数检查 |
| `omf tune analyze` | AWR/ADDM 分析 |
| `omf tune awr [days]` | 非交互生成 AWR 报告 (默认最近1天, 输出 logs/awr/) |
| `omf tune apply [--scope memory|sga|pga]` | 应用建议配置 (需重启, 受 --yes 保护) |

### 健康检查 (`omf check`)
| 命令 | 说明 |
|------|------|
| `omf check all` | 全面健康检查 |
| `omf check db` | 数据库检查 |
| `omf check disk` | 磁盘空间检查 |
| `omf check perf` | 性能检查 |
| `omf check alert` | Alert 日志检查 |
| `omf check listener` | 监听器检查 |
| `omf check preflight` | 安装前预检 |
| `omf check monitor [json|prom]` | 机器可读监控输出 (JSON/Prometheus, 自动持久化快照) |

### 一键总览 / 自更新
| 命令 | 说明 |
|------|------|
| `omf status` | 一键总览 (库/监听/磁盘/备份/日志) |
| `omf status history [N]` | 监控历史趋势 (默认最近10次, 读取 check monitor 快照) |
| `omf self-update [version]` | 框架自更新 (需配置 `OMF_UPDATE_URL`) |
| `omf self-update force` | 强制更新 (忽略版本相同) |
| `omf help <cmd>` | 查看子命令用法 (等价 `<cmd> -h`) |

### 全局选项
| 选项 | 说明 |
|------|------|
| `-h / --help` | 显示总览或子命令用法 |
| `-y / --yes` | 非交互自动确认危险操作 |
| `-d / --debug` | 调试模式 (显示 DEBUG 日志) |
| `-c / --config <file>` | 指定配置文件 |

### 日志管理 (`omf log`)
| 命令 | 说明 |
|------|------|
| `omf log view alert` | 查看 Alert 日志 |
| `omf log tail alert` | 实时跟踪 Alert |
| `omf log rotate` | 日志轮转 |
| `omf log clean` | 清理旧日志 |

### 定时清理 (`omf clean`)
| 命令 | 说明 |
|------|------|
| `omf clean all` | 全面清理 |
| `omf clean logs` | 清理日志 |
| `omf clean trace` | 清理 trace |
| `omf clean audit` | 清理审计 |
| `omf clean archive` | 清理过期归档 |
| `omf clean schedule setup` | 配置定时清理 |

## 定时任务

配置完成后会自动创建以下 cron 任务:

```cron
# 备份
0 2 * * *    oracle omf backup full         # 每天 2:00 全量备份
0 3 * * 0    oracle omf backup physical     # 每周日 3:00 物理备份
0 6,12,18 * * * oracle omf backup incr     # 每天 3 次增量备份
0 */4 * * *  oracle omf backup archive      # 每 4 小时归档备份

# 清理
0 4 * * *    oracle omf clean all           # 每天 4:00 全面清理
0 5 * * 0    oracle omf clean archive       # 每周日 5:00 清理归档
```

## SQL 脚本自动执行

将 `.sql` 文件放入对应目录，执行 `omf sql scan --auto` 即可自动按序执行:

```
sql/init/       → omf sql init        # 初始化
sql/upgrade/    → omf sql run --all   # 升级
sql/patch/      → omf sql run --all   # 补丁
sql/custom/     → omf sql run --all   # 自定义
```

已执行的脚本记录在 `sql/.executed/` 下，不会重复执行。
