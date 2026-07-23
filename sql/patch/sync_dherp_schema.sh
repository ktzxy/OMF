#!/bin/bash
#===============================================================================
# 通过"完整 schema 比对"补齐 DHERP (ARTERYPDB) 中缺失的表/列
#
# 思路 (一次性、幂等、安全):
#   1) 建一个临时用户 DHERP_DIFF, 把 patch dump 里的全部
#      TABLE/SEQUENCE/TYPE/TYPE BODY DDL 载入 (owner 改写到 DHERP_DIFF)。
#      (dump 里只取 DDL, 不含 INSERT 数据; 失败的对象用 WHENEVER SQLERROR
#        CONTINUE 跳过, 不影响整体)
#   2) 用 MINUS 比较 DHERP_DIFF 与正式库 DHERP:
#        a. 缺失的表 -> 从 dump 提取该表 CREATE 建到 DHERP
#        b. 缺失的列 -> 生成 ALTER TABLE ... ADD (..., NULL) 建到 DHERP
#      (列一律以 NULL 加入, 保证对已存在数据表安全且能通过编译)
#   3) 重编译 DHERP。
#   4) 报告仍 INVALID 的对象及其编译错误 -> 这些就是 dump 也给不了的,
#      需另找正确的 Oracle 源码/建表源。
#
# 说明:
#   - 本脚本只动 DDL 结构, 不插数据, 不删任何对象。
#   - 临时用户 DHERP_DIFF 每次运行先 DROP CASCADE 再重建, 仅作比对基线。
#   - 须以 root 运行; root 下读取 /root/OMF(700) 的 .dump, 经 runuser -l oracle
#     以 oracle 用户执行 sqlplus。
#
# 用法:
#   cd <OMF>/sql/patch
#   bash sync_dherp_schema.sh
#===============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DUMP="$SCRIPT_DIR/01_fix_dherp_deps.sql.dump"
[ -f "$DUMP" ] || { echo "找不到 $DUMP"; exit 1; }

PDB="${PDB_NAME:-ARTERYPDB}"
DIFF_USER="DHERP_DIFF"
DIFF_PWD="dherp_diff"

# ---------------------------------------------------------------------------
# 从 .dump 提取 DHERP 的 TABLE/SEQUENCE/TYPE/TYPE BODY DDL
# ---------------------------------------------------------------------------
extract_ddl() {
  awk '
    /^CREATE (OR REPLACE )?(FORCE )?(GLOBAL TEMPORARY )?(EDITIONABLE )?(TABLE|SEQUENCE|TYPE|TYPE BODY) "DHERP"\./ {
      f=1; seen=0
    }
    f && seen>0 && $0 ~ /^(CREATE|ALTER|COMMENT|GRANT|BEGIN|DECLARE|INSERT|PROMPT|CONNECT|ANALYZE|ALTER SESSION) / {
      f=0
    }
    f { print; seen++ }
  ' "$DUMP"
}

# 提取单张表的完整 CREATE (owner 保持 DHERP, 用于补建到正式库)
extract_single_table() {
  local name="$1"
  awk -v name="$name" '
    $0 ~ ("^CREATE (OR REPLACE )?(FORCE )?(GLOBAL TEMPORARY )?(EDITIONABLE )?TABLE \"DHERP\"\." name "\"") {
      f=1; seen=0
    }
    f && seen>0 && $0 ~ /^(CREATE|ALTER|COMMENT|GRANT|BEGIN|DECLARE|INSERT|PROMPT|CONNECT|ANALYZE|ALTER SESSION) / {
      f=0
    }
    f { print; seen++ }
  ' "$DUMP"
}

# 以 oracle 用户执行 sqlplus @file
run_sqlfile() {
  local sqlfile="$1"
  chown oracle:oinstall "$sqlfile" 2>/dev/null || true
  chmod 644 "$sqlfile"
  local inner="sqlplus -s / as sysdba @${sqlfile}"
  if [ "$(id -u)" -eq 0 ]; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -l oracle -c "$inner"
    else
      su - oracle -c "$inner"
    fi
  else
    eval "$inner"
  fi
}

# ---------------------------------------------------------------------------
# 步骤 0: 重建临时比对用户 DHERP_DIFF
# ---------------------------------------------------------------------------
echo "=== 步骤0: 重建临时比对用户 $DIFF_USER ==="
tmp="$(mktemp /tmp/dherp_diff_user_XXXXXX.sql)"
cat > "$tmp" <<SQL
WHENEVER SQLERROR CONTINUE
ALTER SESSION SET CONTAINER = ${PDB};
DROP USER ${DIFF_USER} CASCADE;
CREATE USER ${DIFF_USER} IDENTIFIED BY ${DIFF_PWD} DEFAULT TABLESPACE USERS TEMPORARY TABLESPACE TEMP;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE TYPE, CREATE VIEW, CREATE PROCEDURE, UNLIMITED TABLESPACE TO ${DIFF_USER};
EXIT
SQL
run_sqlfile "$tmp"
rm -f "$tmp"
echo ""

# ---------------------------------------------------------------------------
# 步骤 1: 把 dump 的 DDL 载入 DHERP_DIFF (owner 改写到 DHERP_DIFF)
# ---------------------------------------------------------------------------
echo "=== 步骤1: 将 dump DDL 载入 $DIFF_USER (用作比对基线) ==="
tmp="$(mktemp /tmp/dherp_load_diff_XXXXXX.sql)"
{
  echo "WHENEVER SQLERROR CONTINUE"
  echo "ALTER SESSION SET CONTAINER = ${PDB};"
  extract_ddl | sed 's/"DHERP"\./"DHERP_DIFF"./g'
  echo "EXIT"
} > "$tmp"
run_sqlfile "$tmp"
rm -f "$tmp"
echo ""

# ---------------------------------------------------------------------------
# 步骤 2a: 缺失的表 -> 从 dump 提取并建到 DHERP
# ---------------------------------------------------------------------------
echo "=== 步骤2a: 找出缺失的表并建到 DHERP ==="
tmp="$(mktemp /tmp/dherp_get_mt_XXXXXX.sql)"
cat > "$tmp" <<SQL
SET PAGES 0 LINES 200 FEED OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = ${PDB};
spool /tmp/dherp_missing_tables.txt
SELECT table_name FROM dba_tables WHERE owner='${DIFF_USER}'
MINUS
SELECT table_name FROM dba_tables WHERE owner='DHERP';
spool off
EXIT
SQL
run_sqlfile "$tmp"
rm -f "$tmp"

if [ -f /tmp/dherp_missing_tables.txt ]; then
  tmp2="$(mktemp /tmp/dherp_add_tables_XXXXXX.sql)"
  {
    echo "WHENEVER SQLERROR CONTINUE"
    echo "ALTER SESSION SET CONTAINER = ${PDB};"
    while read -r t; do
      [ -z "${t// }" ] && continue
      extract_single_table "$t"
    done < /tmp/dherp_missing_tables.txt
    echo "EXIT"
  } > "$tmp2"
  run_sqlfile "$tmp2"
  rm -f "$tmp2"
fi
echo ""

# ---------------------------------------------------------------------------
# 步骤 2b: 缺失的列 -> 生成 ALTER TABLE ... ADD 建到 DHERP (一律 NULL, 安全)
# ---------------------------------------------------------------------------
echo "=== 步骤2b: 找出缺失的列并 ALTER ADD 到 DHERP ==="
tmp="$(mktemp /tmp/dherp_get_mc_XXXXXX.sql)"
cat > "$tmp" <<SQL
SET PAGES 0 LINES 200 FEED OFF TRIMSPOOL ON
ALTER SESSION SET CONTAINER = ${PDB};
spool /tmp/dherp_add_cols.sql
SELECT 'ALTER TABLE DHERP."'||dt.table_name||'" ADD ("'||dt.column_name||'" '||
  CASE dt.data_type
    WHEN 'VARCHAR2' THEN 'VARCHAR2('||dt.data_length||')'
    WHEN 'NVARCHAR2' THEN 'NVARCHAR2('||dt.data_length||')'
    WHEN 'CHAR'      THEN 'CHAR('||dt.data_length||')'
    WHEN 'NUMBER'    THEN 'NUMBER('||NVL(dt.data_precision,38)||CASE WHEN dt.data_scale IS NOT NULL AND dt.data_scale>0 THEN ','||dt.data_scale END||')'
    WHEN 'DATE'      THEN 'DATE'
    WHEN 'TIMESTAMP' THEN 'TIMESTAMP('||NVL(dt.data_scale,6)||')'
    WHEN 'FLOAT'     THEN 'FLOAT('||NVL(dt.data_precision,126)||')'
    ELSE dt.data_type
  END || ' NULL);'
FROM dba_tab_columns dt
WHERE dt.owner='${DIFF_USER}'
  AND (dt.table_name, dt.column_name) NOT IN (
        SELECT table_name, column_name FROM dba_tab_columns WHERE owner='DHERP')
ORDER BY dt.table_name, dt.column_id;
spool off
EXIT
SQL
run_sqlfile "$tmp"
rm -f "$tmp"

if [ -s /tmp/dherp_add_cols.sql ]; then
  tmp2="$(mktemp /tmp/dherp_run_cols_XXXXXX.sql)"
  {
    echo "WHENEVER SQLERROR CONTINUE"
    echo "ALTER SESSION SET CONTAINER = ${PDB};"
    cat /tmp/dherp_add_cols.sql
    echo "EXIT"
  } > "$tmp2"
  run_sqlfile "$tmp2"
  rm -f "$tmp2"
fi
echo ""

# ---------------------------------------------------------------------------
# 步骤 3: 重编译 DHERP
# ---------------------------------------------------------------------------
echo "=== 步骤3: 重编译 DHERP 模式 ==="
tmp="$(mktemp /tmp/dherp_cmp_XXXXXX.sql)"
cat > "$tmp" <<SQL
WHENEVER SQLERROR CONTINUE
ALTER SESSION SET CONTAINER = ${PDB};
SET SERVEROUTPUT ON
BEGIN
  DBMS_UTILITY.COMPILE_SCHEMA(schema => 'DHERP', compile_all => FALSE);
END;
/
EXIT
SQL
run_sqlfile "$tmp"
rm -f "$tmp"
echo ""

# ---------------------------------------------------------------------------
# 步骤 4: 报告仍 INVALID 的对象及其编译错误
#   (这些就是 dump 也给不了的, 需另找正确的 Oracle 源码/建表源)
# ---------------------------------------------------------------------------
echo "=== 步骤4: 仍 INVALID 的对象 ==="
tmp="$(mktemp /tmp/dherp_chk_XXXXXX.sql)"
cat > "$tmp" <<SQL
ALTER SESSION SET CONTAINER = ${PDB};
SELECT object_name, object_type, status
  FROM dba_objects
 WHERE owner='DHERP' AND status='INVALID'
 ORDER BY object_type, object_name;
EXIT
SQL
run_sqlfile "$tmp"
rm -f "$tmp"

echo ""
echo "=== 步骤4b: 上述对象的编译错误 (定位是否还有 dump 也给不了的列/表) ==="
tmp="$(mktemp /tmp/dherp_err_XXXXXX.sql)"
cat > "$tmp" <<SQL
ALTER SESSION SET CONTAINER = ${PDB};
SET LINESIZE 200
SET PAGESIZE 0
COLUMN NAME FORMAT A30
COLUMN TEXT FORMAT A120
SELECT NAME, LINE, POSITION, TEXT
  FROM dba_errors
 WHERE owner='DHERP'
 ORDER BY NAME, LINE, POSITION;
EXIT
SQL
run_sqlfile "$tmp"
rm -f "$tmp"

# 清理临时用户 (可选, 留着也无害)
echo ""
echo "=== 清理临时用户 $DIFF_USER ==="
tmp="$(mktemp /tmp/dherp_drop_XXXXXX.sql)"
cat > "$tmp" <<SQL
WHENEVER SQLERROR CONTINUE
ALTER SESSION SET CONTAINER = ${PDB};
DROP USER ${DIFF_USER} CASCADE;
EXIT
SQL
run_sqlfile "$tmp"
rm -f "$tmp"
