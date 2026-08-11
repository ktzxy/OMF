# SQL 脚本管理（初始化 / 导入 / 多模式 / 回滚）

## 1. 脚本目录

| 目录 | 触发命令 | 说明 |
|------|----------|------|
| `sql/init/` | `omf sql init` | 初始化（建模式 + 执行本目录脚本）|
| `sql/upgrade/` | `omf sql run --all` | 升级 |
| `sql/patch/` | `omf sql run --all` | 补丁 |
| `sql/custom/` | `omf sql run --all` | 自定义 |

`omf sql init` 会**遍历全部 4 个目录**执行（模板 `_*.sql` 除外），故日常直接 `omf sql init` 即可；仅想重跑 upgrade/patch/custom 而不重跑 init 脚本时，用 `omf sql run --all`（已成功的脚本因 `.executed` 记录不会重复执行）。已执行记录在 `sql/.executed/`。

> `sql/init/_create_schema.sql` 是参数化模板（文件名以 `_` 开头，被 `run --all`/`scan` 自动跳过），由 `omf sql init` 按 `APP_SCHEMAS` 逐个调用，注入不同 `&APP_USER`/`&APP_PASSWORD`/`&APP_TABLESPACE`/`&APP_DATA_DIR`。

## 2. 多模式（多库）配置

```bash
# conf/omf.conf
APP_SCHEMAS="dherp lsdherp miserp"   # 空格分隔
LSDHERP_PASSWORD="ls_pwd"            # <大写名>_PASSWORD 覆盖
LSDHERP_TABLESPACE="ls_ts"
MISERP_DATA_DIR="/data/oracle/oradata/ARTERY/miserp"
```

每个模式用 `<大写名>_USER` / `_PASSWORD` / `_TABLESPACE` / `_DATA_DIR` 个别覆盖；缺省用户名=表空间名=模式名，密码回退全局 `APP_PASSWORD`，**数据文件按 `<SID>/<模式名>/` 子目录隔离**。

## 3. 初始化 (`omf sql init`)

`omf sql init` 按 `APP_SCHEMAS` 逐个建模式（用户+表空间+目录授权，模板幂等），再执行其余 init 脚本。

```bash
omf sql init                 # 扫描 init 并执行 (交互确认)
omf sql init --schema lsdherp   # 仅重建单个模式 (用户/表空间), 不重跑全局脚本
omf sql status               # 查看执行记录
```

- 多模式时 `omf sql init` 逐个重建/补齐所有模式；只想补建某一个模式，用 `omf sql init --schema <名>`（仅重建该模式的用户/表空间，不重跑全局 init 脚本）。
- 导入命令 `omf sql import --schema <名>` 也会**自动按模板建好**该模式（含表空间/目录授权），无需先 `init`。

### 初始化做了什么（模板步骤，均幂等）

| 步骤 | 动作 | 幂等 |
|------|------|------|
| 1 | `ALTER SESSION SET CONTAINER = &PDB_NAME` | — |
| 2 | 建表空间（11 个 1G 数据文件，路径 `&APP_DATA_DIR/dataNN.dbf`）| 吞 `ORA-01543` |
| 3 | 建用户（默认表空间、配额 UNLIMITED）| 吞 `ORA-01920` |
| 4 | 授权 `CONNECT/RESOURCE` + 建表/视图/序列/过程/触发器/同义词/`UNLIMITED TABLESPACE` | 可重复 |
| 5 | 建目录对象 `oracle_dumps` 并授权目标用户 | `CREATE OR REPLACE` |

### 初始化验证清单（先切到 PDB 再查，否则在 CDB$ROOT 查不到对象）

```bash
omf sql run 'ALTER SESSION SET CONTAINER = ARTERYPDB;
SELECT tablespace_name, status FROM dba_tablespaces WHERE tablespace_name='\''DHERP'\'';'
# → DHERP  ONLINE

omf sql run 'ALTER SESSION SET CONTAINER = ARTERYPDB;
SELECT username, default_tablespace FROM dba_users WHERE username='\''DHERP'\'';'
# → DHERP  DHERP

omf sql run 'ALTER SESSION SET CONTAINER = ARTERYPDB;
SELECT privilege FROM dba_sys_privs WHERE grantee='\''DHERP'\'' ORDER BY 1;'
# → CREATE PROCEDURE/SEQUENCE/SESSION/SYNONYM/TABLE/TRIGGER/VIEW + UNLIMITED TABLESPACE

omf sql run 'ALTER SESSION SET CONTAINER = ARTERYPDB;
SELECT granted_role FROM dba_role_privs WHERE grantee='\''DHERP'\'';'
# → RESOURCE  CONNECT

# 连通性 + 建表冒烟测试
omf sql run 'CONNECT dherp/"dherp_skzy"@//localhost:1522/ARTERYPDB;
CREATE TABLE smoke_t(id NUMBER);
DROP TABLE smoke_t;'
# 连接串端口取 LISTENER_PORT (默认 1521)
```

## 4. 数据导入 (`omf sql import`)

**一键导入**（推荐）：把 dump 放到任意位置，框架自动拷入数据泵目录、从配置生成**持久化 parfile**、以 oracle 执行 impdp，并在导入后按对象类型统计校验。

parfile 生成后保存在 `sql/.import/<dump名>.par`，方便编辑端口/用户/密码/remap/表空间后再导入。

```bash
# 场景 A: 已知 dump 模式名 == APP_USER, 直接导入
omf sql import /root/dherp_202606290300.dmp

# 场景 B: 先检查模式 (生成 parfile + 抽取源模式, 不真正导入)
omf sql import /root/dherp_202606290300.dmp --check

# 场景 C: 源模式名与主库不同, 改名导入
omf sql import /root/dherp_202606290300.dmp --remap 源模式[:目标模式]

# 场景 D: 用检查生成的 parfile 真正导入
vi sql/.import/dherp_202606290300.dmp.par
omf sql import /root/dherp_202606290300.dmp --apply

# 场景 E: 导入到【另一个模式】(多库, 如连锁库 lsdherp)
omf sql import /root/lsdherp_202606290300.dmp --schema lsdherp
```

- 导入前框架会自动确保 `oracle_dumps` 目录对象在目标 PDB 存在并授权目标模式用户；`--schema` 时还会自动建好该模式并授予跨模式 `remap` 所需的 `IMP_FULL_DATABASE`，**不必先跑 `omf sql init`**。
- 跨模式 `--remap`（不带 `--schema`）仍以 `APP_USER` 连接却建对象到目标模式，框架已统一授予 `IMP_FULL_DATABASE`，修复了此前权限不足的问题。
- 未指定 `--remap` 时假定 dump 中模式名 == `APP_USER`。
- 连接串端口取 `LISTENER_PORT`（默认 `1521`）。
- 手动高级：`sql/imp.par.example` 是参考模板；完全手动：
  ```bash
  cp sql/imp.par.example /tmp/imp.par && vi /tmp/imp.par
  runuser -u oracle -- impdp parfile=/tmp/imp.par
  ```

## 5. 回滚 (`omf sql rollback`)

| 命令 | 说明 |
|------|------|
| `omf sql rollback <name>` | 清除单个脚本执行记录（全局命名空间）|
| `omf sql rollback --all` | 清除全部执行记录 |
| `omf sql rollback --all --schema <名>` | **仅清除某模式的执行记录**（定点重置单库）|
| `omf sql rollback <name> --schema <名>` | 清除某模式下该脚本的记录 |

- 模式命名空间：`sql/.executed/<模式名>/`，由 `omf sql init`/`init --schema` 写入 `.schema_created` 标记。
- 重置后可重新 `omf sql init`（全量）或 `omf sql init --schema <名>`（仅重建该模式）重跑。
- `rollback` 仅删执行标记文件，**不碰库内数据**。

> ⚠️ **重要语义澄清**：
> 1. **`rollback` 不是回滚**：它只清除执行标记（允许重跑），**不能撤销已执行的 DDL/DML**（Oracle 无 DDL 事务）。若想回滚数据库变更，需依赖 flashback/备份恢复（`omf backup restore`），而非 `omf sql rollback`。
> 2. **脚本须幂等**：`sql_execute_all` 的"失败即停"是**脚本级**非事务级。一个脚本含多条 `CREATE TABLE`（DDL 隐式提交）时，若中途失败，前面的 DDL 已持久化（但 `.executed` 标记不写），重跑会因"对象已存在"失败。**因此 SQL 脚本必须写成幂等**（用 `CREATE OR REPLACE`、先 `DROP` 判断、或 `_create_schema.sql` 那样的"存在则跳过"模板），框架不保证脚本级原子性。

## 6. 其它

| 命令 | 说明 |
|------|------|
| `omf sql scan` | 扫描待执行脚本 |
| `omf sql scan --auto` | 扫描并自动执行 |
| `omf sql run <script>` | 执行指定脚本（也支持内联 SQL，自动切 PDB）|
| `omf sql run --all` | 执行所有待处理（断点续跑）|
| `omf sql status` | 查看执行状态与日志 |

> **已移除 `ANY` 权限**：标准化时去掉了 `CREATE ANY PROCEDURE`/`EXECUTE ANY PROCEDURE` 等过宽权限。若导入 dump 含跨模式建对象或需这类权限，导入会报权限不足，届时按需单独补授。
>
> **常见坑点**（目录权限 `ORA-27037`、跨模式权限 `ORA-31631/39149`、PDB 须 OPEN 等）已统一收进 [TROUBLESHOOT.md](TROUBLESHOOT.md) 的 ORA- 速查表，此处不重复展开。
