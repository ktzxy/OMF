# 备份与恢复

## 1. 范围参数（scope）

可加在任意备份/恢复子命令后：

| 参数 | 含义 |
|------|------|
| _(缺省)_ | 物理=整 CDB（root+所有 PDB）；逻辑=配置项 `PDB_NAME` 单个 PDB |
| `--all` | 所有库：物理=整 CDB；逻辑=遍历所有 PDB 各导一份 |
| `--root` | 仅系统库（CDB$ROOT）|
| `--pdb a,b` | 指定一个或多个 PDB（逗号分隔）|
| `--schema <模式名>` | **仅逻辑备份**指定模式（多库场景，其余模式不受影响）|

## 2. 命令一览

| 命令 | 说明 |
|------|------|
| `omf backup full [--all\|--root\|--pdb a,b]` | 逻辑备份 (expdp)，按范围导出 |
| `omf backup logical [--schema <名>\|--all\|--root\|--pdb a,b]` | 逻辑备份；`--schema` 仅导出该模式（多库按库单独备份）|
| `omf backup incr [--all\|--root\|--pdb a,b]` | RMAN 增量备份（范围同物理）|
| `omf backup archive [--pdb a,b]` | 归档日志备份（`--pdb` 时仅该 PDB）|
| `omf backup physical [--all\|--root\|--pdb a,b]` | RMAN 物理全量备份 |
| `omf backup schedule setup` | 配置定时备份 |
| `omf backup auto` | 按 `BACKUP_MODE` 配置自动执行（logical/physical/both）|
| `omf backup cleanup [--logical\|--physical] [-d N \| --all] [-p\|list] [-y]` | 清理备份 |
| `omf backup list [all\|expdp\|rman]` | 查看备份列表 + 过期高亮 |
| `omf backup validate [--all\|--root\|--pdb a,b]` | 校验备份可恢复性（RESTORE VALIDATE）|
| `omf backup restore <file> [--pdb <PDB>] [--schema <模式名>]` | 逻辑恢复（impdp）|
| `omf backup restore --rman [--all\|--root\|--pdb a,b] [--scn N] [--time '...']` | 物理恢复（支持 SCN/时间点不完全恢复）|
| `omf backup restore --rman [...] --validate` | 物理备份校验 |

## 3. 配置驱动备份

`BACKUP_MODE=logical|physical|both`，`omf backup auto` 按配置执行。`omf backup schedule setup` 生成 cron（每天 2:00 全量 / 每周日 3:00 物理 / 每天 3 次增量 / 每 4h 归档）。

## 4. 按模式（多库）逻辑备份

多库场景下，常需**单独备份某个 ERP 库（模式）**：

```bash
# 仅导出 lsdherp 模式 (复用 LSDHERP_PASSWORD / LSDHERP_TABLESPACE 等配置)
omf backup logical --schema lsdherp
# → 落盘 schema_lsdherp_<时间戳>_%U.dmp, 用 SCHEMAS= 限定
```

- 框架用 `omf_schema_user` 解析模式名到实际 Oracle 用户，expdp 以 `SCHEMAS=<用户>` 导出。
- 固定导出 `PDB_NAME` 中的该模式，忽略 scope 参数。
- 恢复对应用 `omf backup restore <file> --schema lsdherp`（见下）。

## 5. 逻辑恢复（impdp）

```bash
omf backup restore <file.dmp>                 # 整库 FULL 恢复
omf backup restore <file.dmp> --schema lsdherp   # 仅恢复该模式, 其余模式不受影响
omf backup restore <file.dmp> --pdb <PDB>     # 恢复到指定 PDB
```

- 并行分片自动改写 `%U` 形式读入完整备份集。
- `ORA-31684`（对象已存在）属非致命，不影响数据导入。

## 6. 物理恢复（RMAN）

```bash
omf backup restore --rman                 # 完全恢复到最新归档 (不 OPEN RESETLOGS)
omf backup restore --rman --scn 12345
omf backup restore --rman --time '2026-07-28 14:00:00'   # 不完全恢复
omf backup restore --rman --validate     # 仅校验可恢复性
```

- PDB 级恢复会先将目标 PDB 置于 MOUNT 再 RESTORE+RECOVER。
- 不完全恢复完成后需 `ALTER DATABASE OPEN RESETLOGS;`；完全恢复可直接 `ALTER DATABASE OPEN;`。

## 7. Data Guard 环境下的备份/恢复

> 完整规则见 [DATAGUARD.md §4](DATAGUARD.md)（与 DG 的备份/恢复/状态/启停交互）。三条核心约定：
>
> 1. **逻辑备份（expdp）必须在【主库】**：物理备库是只读/MOUNT 无法 expdp，框架已加守卫（备库上执行会报错提示到主库）。
> 2. **物理备份（RMAN）建议卸到备库**：标准实践，框架不限制节点。
> 3. **主库物理恢复会破坏 DG**：`omf backup restore --rman` 在主库+DG 会告警，恢复后须重建备库。

## 8. 清理

`omf backup cleanup` / `omf clean backup` 共用：
`--logical` 仅逻辑备份(dump)、`--physical` 仅物理备份(RMAN)，默认两者；`-d N` 删 N 天前（默认 `BACKUP_RETENTION_DAYS`）、`--all` 删全部、`-p|list` 仅预览、`-y` 免确认。

## 9. 备份恢复演练（DR 演练）

> 定期演练证明备份**可恢复**，而不只是"已生成"。`omf backup validate` 只做 `RESTORE VALIDATE`（校验块/文件可读，**不落数据**），无法证明能真实恢复。建议按 DR 周期（如每季度）做一次真实恢复演练。

### 9.1 逻辑备份（dump）恢复演练

```bash
# 1. 选一份较新的 dump 做演练 (避免用最新的, 模拟"落后一点"的灾备)
omf backup list expdp              # 找一份 N 天前的 dump

# 2. 在【演练目标】恢复 (建议恢复到临时 PDB 或临时 schema, 不影响生产)
omf backup restore <dumpfile.dmp> --pdb <临时PDB>    # 整库到临时 PDB
omf backup restore <dumpfile.dmp> --schema <临时schema>  # 单模式到临时 schema

# 3. 验证恢复结果 (对象数/数据量/无效对象)
omf sql usage --schema <临时schema>    # 看对象统计 + INVALID 检查
# 关键行数抽验: 与应用侧约定 1-2 张表, 对比 dump 时的行数
```

### 9.2 物理备份（RMAN）恢复演练

```bash
# 1. 校验备份可恢复性 (可随时做, 不落数据)
omf backup restore --rman --validate

# 2. 真实恢复演练 (建议在【独立演练库】上做, 避免破坏生产; 或在维护窗口对目标库)
omf backup restore --rman --time 'YYYY-MM-DD HH24:MI:SS'   # 恢复到演练时间点
# 不完全恢复完成后: ALTER DATABASE OPEN RESETLOGS; 再确认数据

# 3. 验证: 对比该时间点的关键表数据/SCN, 确认恢复正确
```

### 9.3 演练后回滚/收尾

- **临时 PDB/schema 演练**：验证通过后直接 `DROP` 临时对象即可，不影响生产。
- **对目标库的真实恢复**：演练即真实恢复，后续按需重建 DG（若启用）并恢复应用。
- 每次演练后记录：恢复耗时、失败点、耗时是否在 RTO 内、是否需要调整 `BACKUP_RETENTION_DAYS`。

> ⚠️ 物理恢复演练若在 `ENABLE_DG=true` 的主库执行会破坏 DG（见 §7），务必在独立演练库或备库重建前进行。

## 10. 跨主机恢复（DR 到异机）

> **当前 `omf backup restore` 只作用于【当前连接的本机】数据库**，不能直接跨网络恢复到另一台机器。若生产在 A 机、灾备要恢复到 B 机，按以下两种方式之一做（本质是"把 A 机的备份在 B 机用 Oracle 原生命令恢复"）：

### 10.1 逻辑备份跨主机恢复（推荐，简单）

```bash
# 1. A 机(生产)导 dump; B 机(灾备)需已装好 Oracle 软件 + 建好目标库/PDB
#    把 dump 拷到 B 机的数据泵目录
scp /backup/oracle/dump/full_*.dmp oracle@B:/data/oracle/oracle_dumps/

# 2. B 机上用 omf sql import 导入 (dump 可跨机, 无节点绑定)
omf sql import <dumpfile.dmp> [--schema <模式名>] [--remap 源:目标]
# 或用 omf backup restore <dumpfile.dmp> (逻辑恢复)
```

### 10.2 物理备份跨主机恢复（RMAN，较复杂）

物理备份集是 A 机控制文件登记的，恢复到 B 机需要：
1. B 机装好同版本 Oracle 软件，`ORACLE_SID`/路径与 A 机尽量一致（或准备 `db_file_name_convert`）。
2. **把 A 机的备份集传到 B 机可访问的位置**（NFS 共享 / `scp` 到 B 机对应目录），并保持 A 机 RMAN 记录的相对路径一致。
3. B 机建**新控制文件**（基于 A 机的备份，用 `RESTORE CONTROLFILE`），然后 `RESTORE DATABASE` + `RECOVER DATABASE`（可用 `SET NEWNAME`/`db_file_name_convert` 适配路径），最后 `ALTER DATABASE OPEN RESETLOGS`。
4. 恢复后需重建监听器、密码文件、`omf config init`（B 机独立配置）。

> 跨主机物理恢复对路径一致性要求高，是 DR 演练中最容易踩坑的环节，**强烈建议先在 B 机做一次演练验证路径转换**。OMF 当前提供的是本机恢复的封装，跨主机需用 Oracle 原生 `rman` 命令配合本指引手工执行。
