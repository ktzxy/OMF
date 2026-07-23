# OMF 分组测试报告

> 目的：记录各分组命令在本环境的实测结论、风险分级与关键坑点，作为生产操作依据。
> 测试框架版本：OMF v1.4.0

## 测试环境

| 项 | 值 |
|----|----|
| 主机 | localhost（CentOS/RHEL 系，Oracle 19c） |
| CDB | `ARTERY`（OPEN / ARCHIVELOG / PRIMARY） |
| PDB | `ARTERYPDB`（READ WRITE） |
| 监听端口 | `1522` |
| `local_listener` | `LISTENER_ARTERY`（tnsnames 别名，解析到 1522） |

---

## 分组与结论

本轮重点验证 **B 组**（env/install/db/backup/sql/log/clean/listener/check 等运维命令）。**A 组**已于上一轮验证通过（命令可用性确认）。

### B 组：按风险分级验证

#### 🟢 零风险（只读 / 预览）— 可随时跑

| 命令 | 结果 | 验证点 |
|------|------|--------|
| `omf backup list` | ✅ | RMAN 段无备份不报错，正常列出 dump / 备份集 / 目录占用 |
| `omf clean logs -p` | ✅ | 仅预览，列出待删文件 + 汇总（总数/将清理/即将过期），**不删除** |
| `omf clean trace -p` | ✅ | 同上 |
| `omf clean audit -p` | ✅ | 同上 |
| `omf clean archive -p` | ✅ | 基于 `V$ARCHIVED_LOG` 预览，同上 |
| `omf log rotate` | ✅ | alert 正常时仅清 7 天前 trace，几乎空转 |
| `omf sql status` | ✅ | 显示执行记录（成功/失败计数） |
| `omf sql scan` | ✅ | 列出待执行脚本 |
| `omf sql run "SELECT ..."` | ✅ | 切 PDB 执行，返回结果并打印「执行成功」 |

#### 🟡 需确认（轻微动作，命令自带 confirm 保护）

| 命令 | 结果 | 说明 |
|------|------|------|
| `omf log clean` | ✅ | 删 N 天前旧日志/alert 备份，输入 `yes` 后执行 |
| `omf sql rollback --all` | ✅ | **只删 `sql/.executed` 标记文件，不碰库内数据**，可让 init 脚本重跑 |

#### 🔴 高风险（停机 / 写库 / 改配置）

| 命令 | 结果 | 说明 |
|------|------|------|
| `omf listener restart` | ✅ | 监听重启到 `1522`；**坑点**：`restart` 子命令**不刷新 `local_listener`**，重启瞬间 `Services Summary` 为空（`The listener supports no services`），库 OPEN 后 PMON 才自动注册 |
| `omf db restart` | ✅ | 停机约 **1 分 13 秒**（18:12:41 → 18:13:54），重新 OPEN / ARCHIVELOG / PRIMARY，PDB READ WRITE |

### 关键验证点（必做收尾，否则业务可能连不上）

1. **监听重启后必须确认服务注册**：
   ```bash
   lsnrctl status
   # Services Summary 应含 ARTERY / ARTERYXDB / arterypdb 且 status READY
   ```
   若 services 为空，手动触发注册：
   ```bash
   sqlplus -s / as sysdba <<'SQL'
   ALTER SYSTEM REGISTER;
   SQL
   ```

2. **`local_listener=LISTENER_ARTERY` 是 tnsnames 别名**（非直接 `ADDRESS=(...)`），服务在 1522 上全部 READY 即证明其解析正确，**当前配置无需改动**。

3. **端到端连通性（可选但推荐）**：
   ```bash
   sqlplus dherp/<密码>@//localhost:1522/ARTERYPDB
   # 能进入 SQL> 提示符即证明 监听+服务名+端口+账号 全链路通
   ```

### 本轮未执行（非必要不测）

- `omf listener port <新端口>`：改 `listener.ora`/`tnsnames.ora` + 防火墙 + 改 `local_listener` + 重启，配错可能连不上库。
- `omf sql init` / `omf sql run --all`：真正写库建表空间/用户/对象，执行前务必 `omf sql scan` 确认脚本并确认幂等。
- `omf tune apply`：会重启数据库做内存调整，须维护窗口执行。

---

## 结论

B 组全部命令在 19c 单实例（CDB/PDB）环境验证通过：监听重启后服务注册正常、`local_listener` 别名解析正常、停库起库停机时长在可接受窗口内。结合 A 组，OMF 运维命令可用性已确认。
