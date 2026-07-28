# 排错提示

- **`Permission denied` / `lib/common.sh: No such file or directory`**：旧版经 `/usr/local/bin/omf` 软链调用时 `OMF_HOME` 解析错误。已修复（`readlink -f`），拉取最新代码即可；若仍报错，重跑 `./setup.sh`。
- **`chown: invalid user: 'oracle:oinstall'`**：在 `omf env prepare` 之前手动 `chown` 了安装包。无需手动 `chown`，直接 `omf install software` 会自动建用户并接管归属。
- **`/tmp` 空间不足导致安装失败**：Oracle 安装器需在 `/tmp` 暂存。`install software` 已自动将安装器临时目录重定向到配置的数据盘，若仍不足请扩容数据盘或手动设 `TMPDIR` 后重试。
- **`/backup` 剩余不足**：把 `conf/omf.conf` 的 `ORACLE_BACKUP` 改到空间充足的盘，再 `omf config validate`。
- **脚本 CRLF 报错 `bad interpreter`**：Windows 检出后脚本被转成 CRLF。仓库已用 `.gitattributes` 锁定 `*.sh` 为 LF；若手动改过，用 `dos2unix cmd/*.sh lib/*.sh omf.sh setup.sh` 修复。
- **配置改了不生效**（如 `HUGEPAGES_DEFER` 无效、内存仍被大页占满）：框架只读取 `conf/omf.conf`，**不读 `conf/omf.conf.example`**（脱敏模板）。确认改动落在正式文件：`grep -n HUGEPAGES_DEFER conf/omf.conf`；若文件不存在先用 `omf config init` 生成。用 `omf config set KEY VALUE` 也会自动写入正式文件。
- **`omf sql import` 跨模式权限不足（ORA-31631/ORA-39149）**：`--remap` 目标模式 ≠ 连接用户、或显式 `--schema` 时，连接用户需 `IMP_FULL_DATABASE`。框架已统一按条件自动授权，无需手动补。
- **PDB 须 OPEN**：`omf sql init`/查询前确保 `omf db pdb open` 已使 PDB 处于 READ WRITE，否则报 `no rows` 或对象建到 CDB$ROOT。
- **目录 OS 权限（impdp ORA-27037 / permission denied）**：`oracle_dumps` 指向的 `ORACLE_DUMP_DIR` 须为 `oracle:oinstall` 可读写（权限 `750`）。`omf sql init` 已自动建好并归属，手动改动后确认：`ls -ld /data/oracle/oracle_dumps`。
- **逻辑备份在物理备库上报错**：物理备库（PHYSICAL STANDBY）无法运行 expdp（需读写库），必须到**主库**执行 `omf backup logical`。这是 DG 环境预期行为，非故障。
- **主库物理恢复后备库失效**：`ENABLE_DG=true` 且当前为 PRIMARY 时 `omf backup restore --rman` 会告警。恢复后必须重新 `dgmgrl` 重建备库（或重新 RMAN duplicate），否则备库永久失效。
- **DG `dg status` 报 ORA-16532**：broker 配置尚未建立，属预期（用 `omf db dg validate` 校验），非故障。
- **多模式漏建主库**：若 `APP_SCHEMAS="lsdherp"` 但 `APP_USER=dherp`，框架已自动把主模式纳入列表，不会静默丢弃主库。
- **模式（多库）不存在**：`omf check schemas` 校验；缺失用 `omf sql init`（全量）或 `omf sql init --schema <名>`（单模式重建）补齐。
