# OMF 命令钩子（Hooks）

OMF 提供轻量命令钩子机制，允许在不改 OMF 核心代码的情况下，在关键生命周期时点插入自定义动作（对接 CMDB / 审批流 / 监控平台 / 自定义归档等）。

## 使用方式

1. 在对应阶段目录放一个**可执行脚本**（`chmod +x`）。
2. 脚本参数：`$1 = 阶段名`，`$2.. = 附加参数`（见下方各阶段说明）。
3. 钩子脚本**失败不阻断主流程**（OMF 记录 warn 并继续），符合"仅编排、可审计"原则。钩子内部应自行限制耗时。

## 目录结构

```
conf/hooks/
├── backup_before.d/     # 每次备份前
├── backup_after.d/      # 每次备份成功后 (auto 全模式)
├── db_create_after.d/   # 建库成功后
├── dg_switchover_after.d/  # DG 计划内切换成功后 (主库执行)
├── dg_failover_after.d/    # DG 灾难切换成功后 (备库执行)
└── deploy_after.d/      # omf deploy 编排全部完成后
```

## 各阶段钩子参数

| 阶段 | 触发点 | 附加参数 $2.. |
|---|---|---|
| `backup_before` | `omf backup auto` 执行前 | `mode=<logical\|physical\|both>` |
| `backup_after` | `omf backup auto` 执行成功后 | `mode=<...>` |
| `db_create_after` | `omf db create` 建库成功后 | `sid=<SID>` `pdb=<PDB>` |
| `dg_switchover_after` | switchover 成功后 | `new_primary=<新主库唯一名>` `old_primary=<旧主库SID>` |
| `dg_failover_after` | failover 成功后 | `new_primary=<新主库唯一名>` |
| `deploy_after` | deploy 编排完成后 | `sid=<SID>` `pdb=<PDB>` |

## 示例

在 `backup_after.d/` 放一个归档备份报告的钩子：

```bash
#!/bin/bash
# 备份后: 把最新备份报告归档到 /backup/omf_reports/
stage="$1"   # = backup_after
mode="$2"    # = mode=both
latest=$(ls -1t /root/omf/logs/backup_reports/ 2>/dev/null | head -1)
[ -n "$latest" ] && cp "/root/omf/logs/backup_reports/$latest" /backup/omf_reports/
exit 0
```

> 提示：`$OMF_HOME` 环境变量在钩子内可用（OMF 已 export），可用它定位 logs/ 等路径，勿写死 `/root/omf`。
