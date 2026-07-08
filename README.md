# OMF - Oracle Management Framework

Oracle 19c 生命周期管理框架，类似 Helm 风格的命令行工具。

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
│   └── config.sh             # 配置管理
├── sql/
│   ├── init/                 # 初始化脚本
│   ├── upgrade/              # 升级脚本
│   ├── patch/                # 补丁脚本
│   └── custom/               # 自定义脚本
└── logs/                     # 运行日志
```

## 快速开始

### 方式一：Git 克隆（推荐，便于更新）

```bash
git clone <your-repo-url> /opt/omf
cd /opt/omf
./setup.sh                         # 自动 chmod +x 所有脚本、建 omf 软链、校验配置、可选预检

# 用脱敏模板生成真实配置 (conf/omf.conf 已被 .gitignore 忽略, 不会上传到仓库)
cp conf/omf.conf.example conf/omf.conf
vi conf/omf.conf                   # 按需修改密码/路径/IP (密码也建议用环境变量注入)

# 把 Oracle 19c 安装包放到默认位置 (任意路径亦可, 安装时显式传入即可)
# 注意: 无需手动 chown, omf install software 会自动接管归属
mv LINUX.X64_193000_db_home.zip /home/oracle/

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
cp conf/omf.conf.example conf/omf.conf && vi conf/omf.conf
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

## 排错提示

- **`Permission denied` / `lib/common.sh: No such file or directory`**：旧版经 `/usr/local/bin/omf` 软链调用时 `OMF_HOME` 解析错误。已修复（`readlink -f`），拉取最新代码即可；若仍报错，重跑 `./setup.sh`。
- **`chown: invalid user: 'oracle:oinstall'`**：在 `omf env prepare` 之前手动 `chown` 了安装包。无需手动 `chown`，直接 `omf install software` 会自动建用户并接管归属。
- **`/tmp` 空间不足导致安装失败**：Oracle 安装器需在 `/tmp` 暂存。扩容，或后续版本支持 `TMPDIR` 自动处理（见 issue）。
- **`/backup` 剩余不足**：把 `conf/omf.conf` 的 `ORACLE_BACKUP` 改到空间充足的盘，再 `omf config validate`。
- **脚本 CRLF 报错 `bad interpreter`**：Windows 检出后脚本被转成 CRLF。仓库已用 `.gitattributes` 锁定 `*.sh` 为 LF；若手动改过，用 `dos2unix cmd/*.sh lib/*.sh omf.sh setup.sh` 修复。

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

### 备份管理 (`omf backup`)
| 命令 | 说明 |
|------|------|
| `omf backup full` | 全量备份 (expdp) |
| `omf backup incr` | RMAN 增量备份 |
| `omf backup archive` | 归档日志备份 |
| `omf backup physical` | RMAN 物理全量备份 |
| `omf backup schedule setup` | 配置定时备份 |
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

### 一键总览 / 自更新
| 命令 | 说明 |
|------|------|
| `omf status` | 一键总览 (库/监听/磁盘/备份/日志) |
| `omf self-update [version]` | 框架自更新 (需配置 `OMF_UPDATE_URL`) |

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
