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

## 7. ⚠️ Data Guard 环境下的备份/恢复（全盘考虑）

详见 [DATAGUARD.md](DATAGUARD.md)。要点：

- **逻辑备份（expdp）必须在【主库】执行**：物理备库（PHYSICAL STANDBY）是只读/MOUNT 状态，无法运行 expdp。框架已加守卫——在 PHYSICAL STANDBY 上执行 `omf backup logical` 会直接报错并提示到主库跑。
- **物理备份（RMAN）建议【卸载到备库】**：在物理备库上做 RMAN 备份是标准实践（不占用主库资源），框架对物理备份不作节点限制（备库可正常备份）。
- **主库上做物理恢复会破坏 DG**：若 `ENABLE_DG=true` 且当前为 PRIMARY，`omf backup restore --rman` 会显式告警——恢复后的主库与备库 redo 流不一致，恢复完成后必须重新在主库 `dgmgrl` 重建备库（或重新 RMAN duplicate）。
- **逻辑恢复（impdp）无此问题**：impdp 的 DML/DDL 会经 redo 自动同步到备库，DG 环境可安全执行。

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
