# OMF - Oracle Management Framework

Oracle 数据库（CDB 系列：18c / 19c / 21c / 23ai）全生命周期管理框架，命令行风格类似 Helm。

> ⚠️ 框架只读取 `conf/omf.conf`，绝不读取 `conf/omf.conf.example`（脱敏模板，改它无效）。改动务必落在 `conf/omf.conf`：`omf config set KEY VALUE` 或 `omf config init` 后编辑。

> 🔐 **上线前必须改掉出厂默认口令**：`ORACLE_PASSWORD`/`SYSTEM_PASSWORD`/`PDB_PASSWORD`/`APP_PASSWORD` 出厂默认是公开弱口令（如 `Qiyuan!960#123`/`dherp_skzy`）。部署前务必用 `omf config password`（写入权限 600 的 `conf/.omf.secret`）或环境变量注入改掉，否则 `omf config validate` 会持续报弱口令风险，且带着默认口令上线等于裸奔。

## 功能大纲

| 模块 | 命令 | 说明 | 详情文档 |
|------|------|------|----------|
| 环境准备 | `omf env` | 用户/内核/依赖/目录/变量/防火墙 | [docs/INSTALL.md](docs/INSTALL.md) |
| 软件安装 | `omf install` | Oracle 软件 + 监听器 | [docs/INSTALL.md](docs/INSTALL.md) |
| 数据库管理 | `omf db` | 建库/启停/PDB/归档/**Data Guard** | [docs/INSTALL.md](docs/INSTALL.md) · [docs/DATAGUARD.md](docs/DATAGUARD.md) |
| 备份恢复 | `omf backup` | 逻辑/物理/增量/归档/定时/**恢复校验**/恢复/清理 | [docs/BACKUP.md](docs/BACKUP.md) |
| SQL 管理 | `omf sql` | 初始化/导入/**多模式(多库)**/回滚 | [docs/SQL.md](docs/SQL.md) |
| 性能调优 | `omf tune` | 内存/存储/会话/AWR | [docs/CONFIG.md](docs/CONFIG.md) |
| 健康检查 | `omf check` | 库/磁盘/性能/Alert/**模式存在性**/监控 | [docs/CHECK.md](docs/CHECK.md) |
| 总览 | `omf status` | 库/监听/**DG 角色**/磁盘/备份一键总览 | [docs/CHECK.md](docs/CHECK.md) |
| 监听器 | `omf listener` | status/start/stop/restart/port | [docs/INSTALL.md](docs/INSTALL.md) |
| 日志/清理 | `omf log` `omf clean` | 日志查看/错误汇总/**高危操作审计**与定时清理 | [docs/CHECK.md](docs/CHECK.md) |
| 配置 | `omf config` | 查看/校验/设置 | [docs/CONFIG.md](docs/CONFIG.md) |
| 自更新 | `omf self-update` | 框架升级（需 `OMF_UPDATE_URL`） | [docs/INSTALL.md](docs/INSTALL.md) |
| 自检 | `omf selftest` | 语法/分发一致性静态自检（不依赖 Oracle） | [docs/CHECK.md](docs/CHECK.md) |
| 信息总览 | `omf info` | 路径/端口/IP/连接串/内存一键总览（排障/交接），`--export` 导出实例台账 | [docs/INFO.md](docs/INFO.md) |
| 一键部署 | `omf deploy` | 预检→环境→安装→建库→开归档→初始化→首次备份（生产一键） | [docs/DEPLOY.md](docs/DEPLOY.md) |

> ⚠️ **`omf deploy` 会重建数据库**：其第 7 步 `omf db create` 会 `SHUTDOWN ABORT` 并**删除现有 SID 的全部数据文件后重建（数据不可逆）**。仅限在**全新机器/可重建环境**执行；若机器上已有需要保留的库，请勿直接 `omf deploy`，先用 `omf backup full` 备份。
> 另外，`deploy` 强依赖 `conf/omf.conf` 中正确的路径、`ORACLE_ZIP` 安装包路径（或已把 db_home zip 放到预期位置）。首次使用前务必先 `omf config init` 编辑好配置并 `omf config validate`，再运行。

## 安装

```bash
# 必须装到 oracle 用户可读写路径 (推荐 /opt/omf, 切勿装 /root, 见 INSTALL.md)
git clone git@github.com:ktzxy/OMF.git /opt/omf
cd /opt/omf
./setup.sh                        # 自动 chmod +x、建 omf 软链、校验配置、可选预检
omf config init && vi conf/omf.conf   # 生成并编辑正式配置
```

> 📄 完整安装（含 wget 方式、支持的 Oracle 版本/发行版、环境准备/安装/建库/监听器命令表）详见 **[docs/INSTALL.md](docs/INSTALL.md)**。
> 把 Oracle 安装包放到任意路径（如 `/home/oracle/LINUX.X64_193000_db_home.zip`），安装时显式传入或依赖 `ORACLE_VERSION` 推导默认包名。

## 快速开始

```bash
omf config validate            # 校验配置
omf check preflight            # 安装前预检
omf env prepare                # 准备系统环境 (需 root)
omf install software <zip>     # 安装 Oracle 软件
omf db create                  # 创建数据库 (含内存优化前置)
omf sql init                  # 初始化: 按 APP_SCHEMAS 建模式/表空间 + 逐目录执行 SQL
omf backup schedule setup      # 配置定时备份 (含每周恢复校验 --validate-day)
omf clean schedule setup       # 配置定时清理
omf status                     # 一键总览
```

> 💡 **运维提效三件套**（部署后建议固化）：
> - `omf backup schedule setup` 定时备份（每天 auto + 每4h归档 + **每周 `backup validate` 恢复校验**，可用 `--pdb <名>` 加重点 PDB 单独备份）
> - `omf clean schedule setup` 定时清理（防日志/归档/回收站撑满）
> - `omf check monitor --alert` + cron 定时体检告警（CPU/会话/redo/FRA/DG延迟等，超阈值 webhook/邮件推送）
> - 查看安全审计：`omf log audit`（高危操作留痕）

## 多模式（多库）一句话

`conf/omf.conf` 的 `APP_SCHEMAS="dherp lsdherp miserp"` 即可在一个 PDB 内建立多个 ERP 库（模式）。`omf sql init` 逐个建模式；`omf sql import --schema lsdherp` 导入到指定库；`omf backup logical --schema lsdherp` 单独备份某个库；`omf check schemas` 校验配置的模式是否都已存在。详见 [docs/SQL.md](docs/SQL.md) 与 [docs/BACKUP.md](docs/BACKUP.md)。

**三个关键配置的关系**（新手必读）：
- `APP_USER`：主模式名（**默认会建这个模式**，默认 `dherp`）。
- `APP_TABLESPACE`：主模式对应的表空间名（默认同 `APP_USER`）。
- `APP_SCHEMAS`：附加的其它模式列表（空格分隔）。若留空 = 仅 `APP_USER` 单模式；若填写则自动把 `APP_USER` 纳入列表。
- 即：**无论单/多组织，都会建 `APP_USER` 那个模式**。若你把 `APP_USER` 改成业务名而漏改 `APP_SCHEMAS`/`APP_TABLESPACE`，`omf sql init` 建的表空间/用户会和预期不一致——建议改 `APP_USER` 时同步确认三者一致。

## Data Guard 一句话

`omf db dg config` 配置主库 → 备库 `omf db dg wallet` + `omf db dg standby` 建备 → 主库 `omf db dg enable` + `omf db dg broker` 建 Broker → `omf db dg switchover` 计划切换 / `omf db dg failover` 灾难切换 / `omf check dg` 健康检查。详见 [docs/DATAGUARD.md](docs/DATAGUARD.md)。

## 进阶用法

- **框架自检**：`omf selftest` 对 `omf.sh`/`lib/*.sh`/`cmd/*.sh` 做 `bash -n` 语法检查、shebang 检查与「命令分发一致性」校验（可发现「分发了但没实现」或「实现了但未分发」的死代码），不依赖 Oracle 环境，适合 CI 与批量部署前快速体检。
- **Bash 自动补全**：复制或 source `conf/omf.completion` 即可补全一级命令与子命令（选项如 `-y/-d` 不在补全范围）。
  ```bash
  source conf/omf.completion                         # 当前会话临时启用
  # 或全局安装 (需 root):
  cp conf/omf.completion /etc/bash_completion.d/omf
  ```

## 版本与变更

支持的 Oracle 版本、发行版及各版本改进记录见 [docs/CHANGELOG.md](docs/CHANGELOG.md)。排错见 [docs/TROUBLESHOOT.md](docs/TROUBLESHOOT.md)。测试报告见 [docs/TEST_REPORT.md](docs/TEST_REPORT.md)。

## 版权与许可

- **项目**：OMF（Oracle Management Framework），由 **ktzxy** 维护。
- **协议**：[Apache License 2.0](LICENSE)。可自由使用、修改、再分发，但**必须保留版权署名与 `NOTICE` 文件**，且不得移除各脚本中的 OMF 归属头。
- **设计原则**：本框架**全部以 Shell 脚本实现**，仅编排 Oracle 自带命令（`sqlplus` / `rman` / `lsnrctl` / `srvctl` / `dgmgrl`）。DBA 与运维可逐行审计每个操作，无任何黑盒二进制——这是运维工具应有的透明性。
- **署名即护城河**：fork、二次开发、内部分发均可，但请保留出处。如需闭源商用或去掉署名，请先联系作者授权。
- 项目主页：https://github.com/ktzxy/OMF
