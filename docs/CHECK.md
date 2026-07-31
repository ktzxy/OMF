# 健康检查与总览

## 1. 健康检查 (`omf check`)

| 命令 | 说明 |
|------|------|
| `omf check all` | 全面健康检查（实例/监听/归档/磁盘/内存/CPU/Alert/**模式存在性**）|
| `omf check db` | 数据库检查（实例/PDB/无效对象/表空间/最近备份）|
| `omf check disk` | 磁盘空间检查 |
| `omf check perf` | 性能检查（Top 等待/Buffer 命中/活跃会话/Redo 速率）|
| `omf check alert` | Alert 日志检查（最后 N 行 + ORA- 错误）|
| `omf check listener` | 监听器检查（`lsnrctl status`/`services`）|
| `omf check preflight` | 安装前预检（内存下限/HugePages/磁盘阈值/依赖/用户/连通性）|
| `omf check schemas` | **校验已配置模式（多库）是否真实存在于数据库** |
| `omf check dg` | **Data Guard 健康检查**（传输/MRP/延迟/间隙，需 `ENABLE_DG=true`，已并入 `check all`）|
| `omf check monitor [json\|prom]` | 机器可读监控输出（JSON/Prometheus，自动持久化快照）|

退出码：`0`=成功，`1`=执行错误（真正失败），`2`=检查/健康检查发现问题（预期内，非崩溃）。

### 模式（多库）存在性校验

`omf check schemas` 遍历 `APP_SCHEMAS`（含自动纳入的主模式），逐个查 `dba_users` 确认其 Oracle 用户是否真实存在：

```bash
omf check schemas
# ✓ 模式[dherp] (用户 DHERP) 已存在
# ✗ 模式[lsdherp] (用户 LSDHERP) 不存在于数据库! 请 omf sql init
```

缺失的模式用 `omf sql init`（全量）或 `omf sql init --schema <名>`（单模式重建）补齐。该检查也已并入 `omf check all`。

## 2. 一键总览 (`omf status`)

```bash
omf status              # 版本/主机/库/监听/Data Guard 角色/磁盘/备份概览/最近日志
omf status history [N] # 监控历史趋势 (默认 10 次, 读 check monitor 快照)
```

`omf status` 现含 **Data Guard 区块**：显示 `ENABLE_DG` 配置与实际数据库角色（PRIMARY / PHYSICAL STANDBY / …）。

## 3. 监控输出 (`omf check monitor`)

机器可读，对接 Prometheus / 外部监控，不做人类排版：

```bash
omf check monitor            # 默认 JSON
omf check monitor prom     # Prometheus 格式
```

输出指标：`db_up`（实例存活）、`disk_usage_pct`（各挂载点）、`mem_free_pct`（可用内存%，空闲大页计入避免误报）、`alert_ora_errors`（本次启动以来 ORA- 数）、`status`（ok/warn/err）。

每次运行自动持久化快照到 `logs/monitor_history.jsonl`，供 `omf status history` 展示趋势。状态判定：库 down 或内存可用率 <10% → `err`；内存 <20% 或存在 ORA- 错误 → `warn`。

## 4. 日志管理 (`omf log`)

| 命令 | 说明 |
|------|------|
| `omf log view alert` | 查看 Alert 日志 |
| `omf log tail alert` | 实时跟踪 Alert |
| `omf log rotate` | 日志轮转 |
| `omf log clean` | 清理旧日志 |

## 5. 定时清理 (`omf clean`)

| 命令 | 说明 |
|------|------|
| `omf clean all` | 全面清理（各分类按保留天数）|
| `omf clean logs [-d N \| --all] [-p]` | 清理日志 |
| `omf clean trace [-d N \| --all] [-p]` | 清理 trace |
| `omf clean audit [-d N \| --all] [-p]` | 清理审计 |
| `omf clean archive [-d N \| --all] [-p]` | 清理归档日志 |
| `omf clean backup [-d N \| --all] [--logical\|--physical] [-p] [-y]` | 清理备份（同 `omf backup cleanup`）|
| `omf clean recyclebin` | 清空数据库回收站 (`PURGE DBA_RECYCLEBIN`, 不可逆, 需显式调用) |
| `omf clean schedule setup` | 配置定时清理 |

`-p/--preview` 仅预览并按保留天数高亮"即将过期/将清理"，不删除；`-y` 免确认。

## 6. 生产操作标准步骤（按场景）

> 风险等级：🟢 低风险（只读/预览）｜🟡 需确认｜🔴 高风险（停机/写库/改配置，需维护窗口）。

### 场景一：日常巡检（🟢 全部只读）
```bash
omf status; omf check all; omf listener status; omf backup list
omf clean logs -p; omf sql status; omf sql scan
omf sql run "SELECT ..."          # 只读查询（自动切 PDB）
```

### 场景二：变更/维护前备份（🟢→🟡）
```bash
omf backup full                   # 或 omf backup logical
omf check all
```

### 场景三：重启监听器（🟡）
```bash
omf listener restart
lsnrctl status                   # 确认 Services Summary 含 ARTERYPDB 且 READY
# 若空: sqlplus / as sysdba -> ALTER SYSTEM REGISTER;
```

### 场景四：重启数据库（🔴）
```bash
omf db restart; omf db status; omf listener status
```

### 场景五：日志与清理（🟡）
```bash
omf log clean; omf clean logs -p
omf sql rollback --all          # 仅删执行标记, 不碰库内数据
```

### 场景六：紧急恢复（🔴）
```bash
omf backup restore <file> [--pdb <PDB>]          # 逻辑恢复
omf backup restore --rman [--scn N|--time ...]   # 物理 / 不完全恢复
omf db start / omf db stop
```

### 场景七：高风险操作（🔴）
- `omf listener port <新端口>`：改 `listener.ora`/`tnsnames.ora`+防火墙+`local_listener`+重启，配错可能连不上库。改前先备份这两个文件。
- `omf sql init` / `omf sql run --all`：真正写库建对象，执行前务必 `omf sql scan` 确认脚本并确认幂等。
- `omf tune apply`：会重启数据库做内存调整，维护窗口执行。
- `omf db dg config`：改库参数 + 重启，维护窗口执行（详见 [DATAGUARD.md](DATAGUARD.md)）。
- `omf db dg switchover`：主备角色互换，应用需改连新主库，维护窗口执行。
- `omf db dg failover [--immediate]`：仅主库不可恢复时执行；`--immediate` 可能丢数据（详见 [DATAGUARD.md](DATAGUARD.md)）。
