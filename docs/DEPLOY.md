# 一键部署（`omf deploy`）

> **生产一键编排**：预检 → 环境 → 安装 → 建库 → 开归档 → 初始化 → 首次备份，7 步串联，任一步失败即中止。

> ⚠️ **破坏性警告**：`omf deploy` 第 4 步 `omf db create` 会 `SHUTDOWN ABORT` 并**删除现有 SID 的全部数据文件后重建（数据不可逆）**。**仅限在全新机器/可重建环境执行**；若机器上已有需要保留的库，请勿直接 deploy，先用 `omf backup full` 备份。

## 前置条件

deploy 依赖 `conf/omf.conf` 正确配置，首次使用前务必：
1. `omf config init` 生成并编辑正式配置（路径、口令、SID/PDB/模式名、`BACKUP_MODE`）。
2. `omf config validate` 校验通过（尤其**改掉默认弱口令**，见 [CONFIG.md](CONFIG.md) §2.1）。
3. 准备好 Oracle 安装包 zip（显式 `--zip` 传入，或依赖 `ORACLE_VERSION` 推导默认包名）。

## 用法

```bash
omf deploy                              # 执行全部 7 步
omf deploy --list                       # 仅打印步骤清单 (看序号)
omf deploy --zip <db_home.zip> --edition EE   # 指定安装包与版本
omf deploy --from 3                     # 从第 3 步开始 (断点续跑, 跳过前 2 步)
omf deploy --skip "env all,db create"   # 跳过指定步骤 (序号或命令名, 逗号分隔/可多次)
omf deploy -y                           # 全局非交互 (自动确认各步; 危险操作仍受 confirm_danger 保护)
```

## 步骤清单（`omf deploy --list`）

| 序号 | 命令 | 说明 |
|------|------|------|
| 1 | `check preflight` | 预检环境（用户/OS/内存/磁盘/依赖）|
| 2 | `env all` | 准备系统环境（用户/内核/依赖/目录/防火墙）|
| 3 | `install software` | 安装 Oracle 软件（15-30 分钟）|
| 4 | `db create` | 创建数据库（CDB + PDB，15-30 分钟）|
| 5 | `db archivelog enable` | 开启归档模式（物理备份前置）|
| 6 | `sql init` | 初始化（按 `APP_SCHEMAS` 建模式/表空间 + 执行初始化 SQL）|
| 7 | `backup auto` | 首次备份（按 `BACKUP_MODE`：逻辑/物理）|

## 断点续跑（`--from` / `--skip`）

- **`--from N`**：从第 N 步开始，跳过其前所有步骤（修复某步失败后续跑用）。
- **`--skip <序号|命令|描述>[,...]`**：跳过指定步骤（可重复 `--skip`）。
- 任一步失败立即中止并提示"可单独重跑：`omf -y <该步命令>`"，修复后配合 `--from` 续跑，无需重跑已完成步骤。

> **耗时预估**：软件安装 + 建库各 15-30 分钟，**全程约 40-70 分钟**。期间请勿中断终端或 Ctrl-C（`--skip` 掉 install/db 会显著缩短）。
> Oracle 安装器原始输出会直刷终端，属正常；最终以"成功/失败 + 日志路径"为准，日志在 `${OMF_HOME}/logs/`。

## 适用建议

- 适合**全新机器从零部署**（环境准备→安装→建库→首次备份全自动）。
- 已有库/数据的环境**不要直接 deploy**（会重建丢数据）；用各子命令按需操作。
- 首次部署完成后，用 `omf status` / `omf check all` 验证整体健康，并配置 `omf backup schedule setup` / `omf clean schedule setup` 定时任务。
