# OMF SQL 初始化目录

## 脚本命名与执行规则
- 普通初始化脚本: `{序号}_{描述}.sql`, 自动按文件名排序执行 (如 `02_roles.sql`)。
- **模板脚本**: 以 `_` 开头的文件 (如 `_create_schema.sql`) 被 `omf sql run --all` / `omf sql scan` **自动跳过**,
  它由 `omf sql init` 显式、按 `APP_SCHEMAS` 列表逐个调用, 每次注入不同的
  `&APP_USER` / `&APP_PASSWORD` / `&APP_TABLESPACE` / `&APP_DATA_DIR`。
- 已执行的脚本记录在 `sql/.executed/` 下, 支持断点续跑。

## 多模式(多库)支持
`omf sql init` 会遍历 `conf/omf.conf` 的 `APP_SCHEMAS`(空格分隔的模式名列表),
对每个模式调用 `_create_schema.sql` 模板, 用该模式的派生配置建好:
- Oracle 用户 (= 模式名, 可用 `<大写名>_USER` 覆盖)
- 表空间 (默认=模式名, 可用 `<大写名>_TABLESPACE` 覆盖)
- 数据文件目录 (默认 `${ORACLE_DATA}/${ORACLE_SID}/<模式名>/`, 各模式独立子目录,
  彻底避免多个表空间同名数据文件冲突 ORA-01537; 可用 `<大写名>_DATA_DIR` 覆盖)
- 数据泵目录对象 `oracle_dumps` 并授权给该用户

仅配置单模式时 `APP_SCHEMAS` 留空, 框架回退到 `APP_USER` 单模式行为。
