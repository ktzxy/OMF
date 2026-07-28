# 安装与环境准备

> 所有改动落在 `conf/omf.conf`（不是 `conf/omf.conf.example`）。详见 [CONFIG.md](CONFIG.md)。

## 1. 安装方式

```bash
# 方式一：Git 克隆（推荐）
git clone git@github.com:ktzxy/OMF.git /opt/omf
cd /opt/omf
./setup.sh                         # 自动 chmod +x、建 omf 软链、校验配置、可选预检
omf config init && vi conf/omf.conf

# 方式二：wget 解压
wget http://your-host/omf.tar.gz && tar xzf omf.tar.gz && cd omf
./setup.sh
omf config init && vi conf/omf.conf
```

`setup.sh` 会：自检 → 可选交互配置 → 建立 `/usr/local/bin/omf` 软链并写入 `/etc/profile.d/omf.sh` → 校验配置 → 可选预检。

## 2. 支持的 Oracle 版本

| 版本 | 默认安装包名 (`ORACLE_VERSION`) | 说明 |
|------|-------------------------------|------|
| 18c  | `LINUX.X64_180000_db_home.zip` | CDB |
| 19c  | `LINUX.X64_193000_db_home.zip` | CDB（默认）|
| 21c  | `LINUX.X64_213000_db_home.zip` | CDB |
| 23ai | `LINUX.X64_2340000_db_home.zip` | CDB |

- 通过 `ORACLE_VERSION`（`18`/`19`/`21`/`23`）切换，框架据此推导默认包名与 CVU 兼容假名。
- `ORACLE_HOME` 留空时按版本推导（如 `19` → `/u01/app/oracle/product/19.3.0/dbhome_1`），显式指定则覆盖。
- 安装包路径非默认时，设 `ORACLE_ZIP` 或安装时显式传入 `omf install software <zip>`。
- 非 CDB 版本（11g、12c non-CDB）暂不官方支持。

## 3. 支持的 Linux 发行版

`omf env prepare` 按发行版自动选择包管理器与包名：

| 发行版 | 包管理器 | 备注 |
|--------|----------|------|
| CentOS / RHEL / Oracle Linux / Rocky / Alma / Fedora | `dnf` / `yum` / `microdnf` | 官方支持 |
| Ubuntu / Debian / Mint 等 | `apt` | 自动补 `libnsl.so.1` 软链 |

- 防火墙：RHEL 系用 `firewalld`，Debian 系用 `ufw`，均未启用则跳过。
- 依赖/预检统一用 `ldconfig` 探测，不再依赖 `rpm`。

## 4. 环境准备 (`omf env`)

| 命令 | 说明 |
|------|------|
| `omf env prepare` | 完整环境准备（用户/内核/依赖/目录/变量/防火墙）|
| `omf env check` | 环境检查 |
| `omf env user` | 创建用户和组 |
| `omf env kernel` | 配置内核参数 |
| `omf env packages` | 安装依赖包 |

`omf install software` 检测到 `oracle` 用户或核心依赖缺失时**自动执行 `env prepare`**，并自动把安装包 `chown` 给 `oracle`。

## 5. 软件安装 (`omf install`)

| 命令 | 说明 |
|------|------|
| `omf install software [<zip>]` | 安装 Oracle 软件（自动接管用户/依赖/归属）|
| `omf install listener` | 配置监听器 |
| `omf install check` | 检查安装状态 |

```bash
omf install software /home/oracle/LINUX.X64_193000_db_home.zip
```

安装兼容性说明：`install software` 不再写死 `LD_PRELOAD`，改为探测 `libnsl.so.1` 实际路径（OL8/9 不再失效）；并以 `PIPESTATUS` 正确捕获安装器退出码。Ubuntu/Debian 装完依赖后自动从 `libnsl.so.2` 软链出 `libnsl.so.1`。

## 6. 创建数据库 (`omf db`)

| 命令 | 说明 |
|------|------|
| `omf db create` | 创建数据库（含内存优化前置、磁盘预检）|
| `omf db status` | 查看状态 |
| `omf db start` / `stop` / `restart` | 启停 / 重启 |
| `omf db pdb open/close [<PDB>]` | PDB 管理 |
| `omf db archivelog status/enable/disable` | 归档模式（enable 会重启切到 ARCHIVELOG，是 RMAN 备份前置）|

`omf db create` 会：按需预留 HugePages（延迟模式）→ 计算 SGA/PGA/FRA → 建库前磁盘预检（`ORACLE_DATA_BASE`/`ORACLE_FRA`/`ORACLE_BACKUP` ≥ 20G）→ DBCA 静默建库 → 优化参数（密码策略、PDB SAVE STATE）。

Data Guard 相关命令见 [DATAGUARD.md](DATAGUARD.md)。

## 7. 监听器 (`omf listener`)

| 命令 | 说明 |
|------|------|
| `omf listener status` | 运行状态与端口 |
| `omf listener start` / `stop` / `restart` | 启停 / 重启 |
| `omf listener port <新端口>` | 改端口（同步 `listener.ora`/`tnsnames.ora`/防火墙/配置并重启）|

> 重启监听器后 `restart` 不会刷新 `local_listener`，需等库 OPEN 后 PMON 注册；若 `lsnrctl status` 的 Services Summary 为空，到库里 `ALTER SYSTEM REGISTER;`。
