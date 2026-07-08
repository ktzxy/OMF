# OMF - Oracle Management Framework

Oracle 19c 生命周期管理框架，类似 Helm 风格的命令行工具。

## 框架结构

```
omf/
├── omf.sh                    # 主入口
├── conf/
│   └── omf.conf              # 配置文件
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

## 快速开始 (wget 解压即用)

```bash
# 0. 下载解压后引导 (自检/可选配置/建软链/校验/预检)
wget http://your-host/omf.tar.gz && tar xzf omf.tar.gz && cd omf
./setup.sh

# 1. 配置 (密码建议用环境变量注入, 避免明文)
vi conf/omf.conf
omf config validate

# 2. 安装前预检 (内存前置/HugePages/磁盘/依赖/用户)
omf check preflight

# 3. 环境准备
omf env prepare

# 4. 安装 Oracle 软件
omf install software /home/oracle/LINUX.X64_193000_db_home.zip

# 5. 创建数据库 (含内存优化前置)
omf db create

# 6. 导入并执行准备好的 SQL (失败即停, 支持断点续跑)
omf sql run --all

# 7. 配置定时备份 (按 BACKUP_MODE 配置驱动)
omf backup schedule setup

# 8. 配置定时清理
omf clean schedule setup
```

## v1.1 关键改进

- **定时任务不再静默失败**：backup/clean 去掉 `require_root`，cron 以 `oracle` 用户正常运行。
- **逻辑备份落盘修正**：expdp 统一写入 `${ORACLE_BACKUP}/dump`，恢复路径一致。
- **密码安全**：expdp/impdp 改用 parfile，避免密码出现在 `ps`。
- **备份失败保护**：RMAN 备份失败时不执行 `DELETE OBSOLETE`，并发送失败通知。
- **配置驱动备份**：`BACKUP_MODE=logical|physical|both`，`omf backup auto` 按配置执行。
- **集中日志**：所有运行日志写入 `logs/omf_<cmd>_<时间戳>.log`，并支持失败邮件/Webhook 通知（见 `conf/notify.sh`）。
- **SQL 严格错误检测**：退出码 + `ORA-/SP2-/PLS-/TNS-` 正则三重检测；失败即停，重跑 `omf sql run --all` 自动跳过已成功脚本（断点续跑）。
- **安装前预检**：`omf check preflight` 校验内存下限、HugePages 建议、磁盘空间、依赖包、用户与数据库连通性。
- **内存前置**：`env prepare` / `db create` 前可先看 `omf check preflight` 的内存与 HugePages 建议。
- **配置持久化**：`omf config set KEY VALUE` 现在会写入 `conf/omf.conf`。
- **全局选项**：`-y/--yes` 非交互自动确认，`-d/--debug` 调试，`-c/--config` 指定配置。
- **并发锁**：每次执行按命令加文件锁，防止重叠运行。
- **env_profile 配置化**：`.bash_profile` 由配置变量生成，不再写死 SID/路径。

## v1.2 关键改进（后续完善）

- **安装兼容性修复**：`install software` 不再写死 `LD_PRELOAD=/usr/lib64/libnsl.so.1`，改为探测 `libnsl.so.1` 实际路径，OL8/9 不再失效；并以 `PIPESTATUS` 正确捕获安装器退出码。
- **Data Guard 备库自动构建**：`omf db dg standby` 在备库服务器通过 `RMAN duplicate from active database` 自动建备（自动生成备库参数文件、启动 nomount、执行 duplicate）；新增 `omf db dg enable`（开启日志传输）与 `omf db dg validate`（校验配置/传输）。
- **时间点/SCN 物理恢复**：`omf backup restore --rman [--scn N] [--time 'YYYY-MM-DD HH24:MI:SS']` 支持不完全恢复；未指定则完全恢复到最新归档。
- **备份可恢复性校验（演练）**：`omf backup validate` 与 `omf backup restore --rman --validate` 执行 `RESTORE ... VALIDATE`，恢复演练前必做。
- **tune apply 防护与分域**：`omf tune apply [--scope memory|sga|pga]` 可单独调 SGA 或 PGA；危险重启操作受 `--yes`/交互确认保护。
- **一键总览**：`omf status` 汇总版本、数据库、监听、磁盘、备份概览与最近运行日志。
- **框架自更新**：`omf self-update` 从 `OMF_UPDATE_URL` 下载 tar.gz 并覆盖更新（保留用户配置 `conf/sql/logs`）。

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
