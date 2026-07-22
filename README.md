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
- **AWR 自动报告**：`omf tune awr [days]` 非交互取最近快照首尾 ID 及 `dbid`/`inst_num`，调用 `DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_HTML` 直接生成 HTML 报告到 `logs/awr/`（`awrrpt.sql`/`awrrpti.sql` 内部会交互式询问报告名，非交互会卡死，故不用）。报告先写到 `/tmp` 再移入 `logs/awr/`，规避 oracle 用户对 `/root` 无遍历权限的问题。
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

## 内存参数调优说明

OMF 对 Oracle 内存采用**集中规划、为 OS 预留余量**的策略，避免把物理内存 100% 分给数据库导致 OS 无内存、实例起不来或 OOM。规划逻辑由 `lib/common.sh` 的 `omf_oracle_mem_mb()` / `omf_sga_mb()` / `omf_hugepages_count()` 实现，`omf tune memory` 与 `omf tune apply` 共用同一套口径。

### 规划原理

```
物理内存 (MemTotal)
  └─ Oracle 可用内存 = 物理内存 × ORACLE_MEM_RATIO%   (默认 80%, 下限 2048MB)
       ├─ SGA 目标   = Oracle 可用 × SGA_RATIO%       (默认 75%)
       └─ PGA 目标   = Oracle 可用 − SGA 目标         (下限 512MB)
  └─ OS 预留        = 物理内存 − Oracle 可用          (即 物理内存 × (100%−ORACLE_MEM_RATIO%))
```

- SGA 还会被**钳制**为不超过 `物理内存 − HUGEPAGES_RESERVE_FREE_MB`（默认 2048MB），保证即使 SGA 拉满，常规内存也至少留 2GB 给 OS / PGA / 安装器，小内存机器不会被大页吃光。
- HugePages 数量（2MB/页）= `(SGA_MB + 256) / 2 + 2`，仅覆盖 SGA 并留约 256MB 余量，**不过度预留**（旧版 +1GB 余量会在小内存机器上挤占常规内存导致 OOM）。

### 相关配置项（`conf/omf.conf`）

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `ORACLE_MEM_RATIO` | `80` | Oracle 可用内存占物理内存百分比 |
| `SGA_RATIO` | `75` | SGA 占 Oracle 可用内存百分比 |
| `HUGEPAGES_RESERVE_FREE_MB` | `2048` | SGA 钳制上限预留（给 OS 的常规内存下限）|

> 改这些值用 `omf config set ORACLE_MEM_RATIO 70` 等，写入的是正式 `conf/omf.conf`。

### 常用命令

```bash
omf tune memory                       # 查看当前内存使用 + 建议配置 (含 OS 预留说明)
omf tune apply --scope memory        # 同时调 SGA+PGA (写 SPFILE, 需重启实例生效)
omf tune apply --scope sga           # 仅调 SGA
omf tune apply --scope pga           # 仅调 PGA
omf tune apply -y                   # 非交互自动确认 (危险操作, 仍会 SHUTDOWN/STARTUP)
omf check preflight                  # 安装前预检: 内存下限 / HugePages 建议
omf check all                       # 健康检查含内存项 (可用内存过低会 ✗)
```

### 注意事项

- **务必为 OS 留余量**：旧版曾硬编码 `SGA=75% 物理 + PGA=25% 物理 = 100%`，不留 OS 空间，`omf tune apply` 会直接 OOM。现版本已修复，建议配置已含 OS 预留。
- **不要贸然 `nr_hugepages=0`**：SGA 跑在大页上时，取消大页会让 SGA 无法分配、实例起不来。要调整请改 `ORACLE_MEM_RATIO`/`SGA_RATIO` 后让框架重新计算并 `omf tune apply`。
- **`omf tune apply` 会重启数据库**（SHUTDOWN IMMEDIATE → STARTUP），生产环境务必在维护窗口执行，或加 `-y` 走自动化。
- **AWR 报告需快照**：`omf tune awr` 依赖 `dba_hist_snapshot` 至少 2 个快照；库刚建或 `STATISTICS_LEVEL` 非 `TYPICAL/ALL` 时会报"快照不足"，可手动建快照后再生成：
  ```sql
  sqlplus / as sysdba -e "EXEC DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT;"
  # 间隔数分钟再建一个, 然后:
  omf tune awr
  ```

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
| `omf db archivelog status` | 查看归档模式 |
| `omf db archivelog enable` | 开启归档模式 (RMAN 备份前置条件, 会重启数据库切到 ARCHIVELOG) |
| `omf db archivelog disable` | 关闭归档模式 |
| `omf db dg config` | 配置主库 Data Guard (归档/Force Logging/SRL/参数) |
| `omf db dg enable` | 开启日志传输 (dest_state_2=ENABLE) |
| `omf db dg standby` | 备库服务器自动建备 (RMAN duplicate) |
| `omf db dg validate` | 校验 DG 配置/传输状态 |
| `omf db dg status` | 查看 DG 配置 (dgmgrl) |
| `omf db dg wallet` | 创建 DG 钱包 (主备各执行一次, 消除 ps 密码残留) |

### 备份管理 (`omf backup`)

**范围参数（scope，可加在任意备份/恢复子命令后）**

| 参数 | 含义 |
|------|------|
| _(缺省)_ | 物理=整 CDB（root+所有 PDB）；逻辑=配置项 `PDB_NAME` 单个 PDB |
| `--all` | 所有库：物理=整 CDB；逻辑=遍历所有 PDB 各导一份 |
| `--root` | 仅系统库（CDB$ROOT） |
| `--pdb a,b` | 指定一个或多个 PDB（逗号分隔） |

| 命令 | 说明 |
|------|------|
| `omf backup full [--all\|--root\|--pdb a,b]` | 逻辑备份 (expdp)，按范围导出 |
| `omf backup incr [--all\|--root\|--pdb a,b]` | RMAN 增量备份（范围同物理） |
| `omf backup archive [--pdb a,b]` | 归档日志备份（`--pdb` 时仅该 PDB 归档） |
| `omf backup physical [--all\|--root\|--pdb a,b]` | RMAN 物理全量备份 |
| `omf backup schedule setup` | 配置定时备份 |
| `omf backup auto` | 按 `BACKUP_MODE` 配置自动执行 (logical/physical/both) |
| `omf backup cleanup [-d N | --all]` | 清理备份：`-d N` 删 N 天前的 RMAN 备份集 + dump 文件；`--all` 删全部（需确认） |
| `omf backup list [all\|expdp\|rman]` | 查看备份列表，并按 `BACKUP_RETENTION_DAYS` 高亮"即将过期"(剩余≤阈值标黄)/"已过期(将清理)"(标红)；阈值 `BACKUP_WARN_DAYS`(默认保留期1/5，钳制2~7天) |
| `omf backup validate [--all\|--root\|--pdb a,b]` | 校验备份可恢复性 (RESTORE VALIDATE) |
| `omf backup restore <file> [--pdb <PDB>]` | 逻辑恢复 (impdp)，默认恢复到 `PDB_NAME`，可指定目标 PDB |
| `omf backup restore --rman [--all\|--root\|--pdb a,b] [--scn N] [--time '...']` | 物理恢复（整库/PDB/root），支持 SCN/时间点不完全恢复 |
| `omf backup restore --rman [--all\|--root\|--pdb a,b] --validate` | 物理备份校验（按范围） |

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

### 监听器管理 (`omf listener`)
| 命令 | 说明 |
|------|------|
| `omf listener status` | 查看监听器运行状态与端口 |
| `omf listener start` | 启动监听器 |
| `omf listener stop` | 停止监听器 |
| `omf listener restart` | 重启监听器 |
| `omf listener port <新端口>` | 修改监听端口 (同步 listener.ora / tnsnames.ora / 防火墙 / 配置, 并重启) |

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
| `omf clean all` | 全面清理（各分类按保留天数） |
| `omf clean logs [-d N \| --all] [-p]` | 清理日志（默认按 `LOG_RETENTION_DAYS`；`-d N` 删 N 天前；`--all` 删全部需确认；`-p/--preview` 仅预览并按保留天数高亮"即将过期/将清理"） |
| `omf clean trace [-d N \| --all] [-p]` | 清理 trace 文件（同上，含 `-p` 预览高亮） |
| `omf clean audit [-d N \| --all] [-p]` | 清理审计文件（同上，含 `-p` 预览高亮） |
| `omf clean archive [-d N \| --all] [-p]` | 清理归档日志（`-d N` 删 N 天前；`--all` 删全部需确认；`-p` 基于 `V$ARCHIVED_LOG` 预览高亮） |
| `omf clean backup [-d N \| --all]` | 清理备份（同 `omf backup cleanup`） |
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

## SQL 初始化与数据导入指南

`omf sql init` 通过 `sql/init/01_create_app_schema.sql` 为后续数据导入准备**目标模式**。
在 Oracle 中「模式 = 用户」，创建用户即创建其模式，因此只需配置 `APP_USER` 一处。

### 1. 初始化脚本做了什么

| 步骤 | 动作 | 幂等 |
|------|------|------|
| 1 | `ALTER SESSION SET CONTAINER = &PDB_NAME` 切到目标 PDB（PDB 须 OPEN） | — |
| 2 | 建表空间 `&APP_TABLESPACE`（11 个 1G 数据文件，路径 `&ORACLE_DATA/&ORACLE_SID/dataNN.dbf`，自动扩展） | 吞 `ORA-01543` |
| 3 | 建用户 `&APP_USER`（默认表空间 `&APP_TABLESPACE`，配额 UNLIMITED） | 吞 `ORA-01920` |
| 4 | 授权 `CONNECT/RESOURCE` + `CREATE SESSION/TABLE/VIEW/SEQUENCE/PROCEDURE/TRIGGER/SYNONYM/UNLIMITED TABLESPACE` | 可重复 |
| 5 | 建目录对象 `oracle_dumps`（路径 `/data/oracle/oracle_dumps`，硬编码）并 `GRANT READ, WRITE` 给 `&APP_USER` | `CREATE OR REPLACE` |

**可配置项**（在 `conf/omf.conf` 修改，无需改脚本）：`APP_USER` / `APP_PASSWORD` / `APP_TABLESPACE`（默认 `dherp` / `dherp_skzy` / `dherp`），数据文件路径由 `ORACLE_DATA` + `ORACLE_SID` 推导。

### 2. 执行初始化

```bash
omf sql init                 # 扫描 init 并执行 (交互确认)
omf sql status               # 查看执行记录 (成功 1 失败 0)
```

如需重跑：`omf sql rollback 01_create_app_schema.sql` 清记录后再次 `omf sql init`（脚本幂等，重跑安全）。

### 3. 初始化验证清单（已验证通过）

以下命令先切到 PDB 再查，否则在 `CDB$ROOT` 查不到 PDB 对象会 `no rows`。
`omf sql run` 支持一行内用 `;` 分隔多条语句（框架已按行尾分号自动换行）。

```bash
# 表空间
omf sql run 'ALTER SESSION SET CONTAINER = ARTERYPDB;
SELECT tablespace_name, status FROM dba_tablespaces WHERE tablespace_name='\''DHERP'\'';'
# → DHERP  ONLINE

# 用户与默认表空间
omf sql run 'ALTER SESSION SET CONTAINER = ARTERYPDB;
SELECT username, default_tablespace FROM dba_users WHERE username='\''DHERP'\'';'
# → DHERP  DHERP

# 系统权限 (应 8 项)
omf sql run 'ALTER SESSION SET CONTAINER = ARTERYPDB;
SELECT privilege FROM dba_sys_privs WHERE grantee='\''DHERP'\'' ORDER BY 1;'
# → CREATE PROCEDURE/SEQUENCE/SESSION/SYNONYM/TABLE/TRIGGER/VIEW + UNLIMITED TABLESPACE

# 角色
omf sql run 'ALTER SESSION SET CONTAINER = ARTERYPDB;
SELECT granted_role FROM dba_role_privs WHERE grantee='\''DHERP'\'';'
# → RESOURCE  CONNECT

# 表空间配额 (MAX_BYTES=-1 表示无限制)
omf sql run 'ALTER SESSION SET CONTAINER = ARTERYPDB;
SELECT tablespace_name, max_bytes FROM dba_ts_quotas WHERE username='\''DHERP'\'';'
# → DHERP  -1

# 目录对象与授权
omf sql run 'ALTER SESSION SET CONTAINER = ARTERYPDB;
SELECT directory_name, directory_path FROM all_directories WHERE directory_name='\''ORACLE_DUMPS'\'';'
# → ORACLE_DUMPS  /data/oracle/oracle_dumps
omf sql run 'ALTER SESSION SET CONTAINER = ARTERYPDB;
SELECT privilege FROM dba_tab_privs WHERE grantee='\''DHERP'\'' AND table_name='\''ORACLE_DUMPS'\'';'
# → READ  WRITE

# 连通性 + 建表冒烟测试 (用实际端口; 本环境监听 1522, 默认 1521)
omf sql run 'CONNECT dherp/"dherp_skzy"@//localhost:1522/ARTERYPDB;
CREATE TABLE smoke_t(id NUMBER);
DROP TABLE smoke_t;'
# → Table created.  Table dropped.
```

> 冒烟测试同时验证了：密码正确、EZCONNECT 到 PDB 连通、建表/删表权限齐备。
> 连接串端口取 `conf/omf.conf` 的 `LISTENER_PORT`（默认 `1521`）。

### 4. 数据导入（impdp 到 DHERP 模式）

```bash
# 1. 把 dump 放到目录对象对应的 OS 路径, 并确保属主为 oracle
cp your_dump.dmp /data/oracle/oracle_dumps/
chown oracle:oinstall /data/oracle/oracle_dumps/your_dump.dmp

# 2. 用 parfile 避免密码出现在 ps
cat > /tmp/imp.par <<'EOF'
userid=dherp/dherp_skzy@//localhost:1522/ARTERYPDB
directory=oracle_dumps
dumpfile=your_dump.dmp
logfile=imp_yourdump.log
remap_schema=SOURCE_SCHEMA:dherp     # 源模式名与目标 dherp 不同时才需要
transform=oid:n
EOF

# 3. 以 oracle 用户执行
runuser -u oracle -- impdp parfile=/tmp/imp.par
```

- 目录路径 `/data/oracle/oracle_dumps` 在脚本中**硬编码**，修改需编辑 `sql/init/01_create_app_schema.sql` 的第 87 行。
- 若用 `sqlldr` / 普通 SQL 入库，连接串同样用 `dherp/dherp_skzy@//localhost:1522/ARTERYPDB`。

### 5. 注意事项

- **已移除 `ANY` 权限**：标准化时去掉了 `CREATE ANY PROCEDURE` / `EXECUTE ANY PROCEDURE` 等过宽权限。若导入 dump 含**跨模式建对象**或需这类权限，导入会报权限不足，届时按需单独补授。
- **目录 OS 权限**：`oracle_dumps` 指向的 `/data/oracle/oracle_dumps` 须 `oracle:oinstall` 可读写，否则 impdp 报 `ORA-27037` / ` permission denied`。确认：`ls -ld /data/oracle/oracle_dumps`。
- **PDB 须 OPEN**：初始化与查询前确保 `omf db pdb open` 已使 `ARTERYPDB` 处于 READ WRITE。
