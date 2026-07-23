#!/bin/bash
#===============================================================================
# 修复 DHERP (ARTERYPDB) 中因"缺失底层表/序列/类型"而 INVALID 的对象
#
# 背景诊断 (见 extract_dherp_from_dump.sh 的运行结果):
#   6 个 INVALID 对象的根因分两类:
#   (A) 源码没问题, 仅因正式库缺它们引用的表/序列/类型 -> 可修复:
#         GET_ORDERFLOORCNT  -> 缺 wmsoutdt / WMSLOCGOODS / WMSLOCCLASS / WMSRESEAREA
#         GET_ORDERFLOOR     -> 同上 (还用到 WMSRESEAREA.ARFLOOR)
#         WMS_PDA_WFH_PIECE  -> 缺 wmspiece 表 + SEQ_WMSPIECE 等
#         SP_DIANSANQUERY / SP_DIANSANEXEC -> 依赖上述修复后重编译即可
#   (B) 源码本身在 dump 里就是坏的, 无法用 dump 修复, 需另找正确 Oracle 源码:
#         GET_ORDERFORMULA  -> dump 里是 SQL Server T-SQL (+ / substring / (nolock) / @变量)
#         APP_STYLES_KCTJ   -> dump 里过程头是 "procedure app_styles_kctj ()" 空参数列表非法
#
# 本脚本做的事:
#   1) 从 01_fix_dherp_deps.sql.dump 提取 DHERP 所有 CREATE TABLE / SEQUENCE /
#      TYPE / VIEW 的 DDL, 建到正式库。已存在的对象会因 ORA-00955 跳过 (安全),
#      只补齐真正缺失的表/序列/类型。
#   2) 用 dump 里的完好源码覆盖 (B) 之外的 5 个对象。
#   3) 重编译整个 DHERP 模式。
#   4) 报告仍 INVALID 的对象及其编译错误 (定位是否还有缺列等情况)。
#
# 重要: 须以 root 运行。root 下读取 /root/OMF(700) 的 .dump, 提取到 /tmp,
#   再 chown oracle 后由 runuser -l oracle (回退 su - oracle) 执行 sqlplus。
#
# 用法:
#   cd <OMF>/sql/patch
#   bash fix_dherp_schema.sh
#===============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DUMP="$SCRIPT_DIR/01_fix_dherp_deps.sql.dump"
[ -f "$DUMP" ] || { echo "找不到 $DUMP"; exit 1; }

PDB="${PDB_NAME:-ARTERYPDB}"

# ---------------------------------------------------------------------------
# 从 .dump 提取 DHERP 的所有 TABLE/SEQUENCE/TYPE/VIEW DDL (供补齐缺失对象用)
#   起点: ^CREATE (OR REPLACE )?(FORCE )?(GLOBAL TEMPORARY )?(EDITIONABLE )?
#         (TABLE|SEQUENCE|TYPE|TYPE BODY) "DHERP".
#   不含 VIEW (避免改动现有视图定义); 只补齐让过程编译所需的表/序列/类型。
#   终点: 下一个顶层关键字行 (CREATE/ALTER/COMMENT/GRANT/BEGIN/DECLARE/INSERT/...)
#   (这样不会把 INSERT 数据、索引、约束等一并带出, 且已存在对象会被 ORA-00955 跳过)
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

# 以 oracle 用户执行 sqlplus @file (root 下经 runuser -l / su - , 自动带环境)
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
# 步骤 1: 补齐缺失的表/序列/类型/视图
# ---------------------------------------------------------------------------
echo "=== 步骤1: 从 dump 提取并创建缺失的 DHERP 表/序列/类型 ==="
tmp="$(mktemp /tmp/dherp_ddl_XXXXXX.sql)"
{
  echo "WHENEVER SQLERROR CONTINUE"
  echo "ALTER SESSION SET CONTAINER = ${PDB};"
  echo "SET ECHO OFF"
  echo "SET TERMOUT ON"
  extract_ddl
  echo "EXIT"
} > "$tmp"
run_sqlfile "$tmp"
rm -f "$tmp"
echo ""

# ---------------------------------------------------------------------------
# 步骤 2: 用 dump 里的完好源码覆盖 (B) 类之外的对象
#   仅覆盖源码确实正常的 5 个; get_orderFormula / app_styles_kctj 源码在 dump 中损坏, 跳过。
# ---------------------------------------------------------------------------
objects=(
  "get_orderFloorCnt"
  "get_orderFloor"
  "sp_diansanQuery"
  "sp_diansanexec"
  "wms_pda_wfh_piece"
)

extract_object() {
  local name="$1"
  awk -v name="$name" '
    BEGIN { IGNORECASE=1 }
    $0 ~ ("^CREATE EDITIONABLE (procedure|function) " name "$") { f=1 }
    f && seen>0 && $0 ~ /^(CREATE|ALTER) / { exit }
    f { print; seen++ }
  ' "$DUMP" \
    | sed 's/^CREATE EDITIONABLE/CREATE OR REPLACE EDITIONABLE/'
}

for o in "${objects[@]}"; do
  echo "=== 覆盖对象: $o ==="
  tmp="$(mktemp /tmp/dherp_ext_XXXXXX.sql)"
  {
    echo "WHENEVER SQLERROR CONTINUE"
    echo "ALTER SESSION SET CONTAINER = ${PDB};"
    echo "SET SERVEROUTPUT ON"
    extract_object "$o"
    echo "SHOW ERRORS"
    echo "EXIT"
  } > "$tmp"
  run_sqlfile "$tmp"
  rm -f "$tmp"
  echo ""
done

# ---------------------------------------------------------------------------
# 步骤 3: 重编译 DHERP 模式
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
#   注意: DBA_ERRORS 的列名是 NAME (不是 OBJECT_NAME)
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
echo "=== 步骤4b: 上述对象的编译错误 (定位是否还有缺列 ORA-00904) ==="
tmp="$(mktemp /tmp/dherp_err_XXXXXX.sql)"
cat > "$tmp" <<SQL
ALTER SESSION SET CONTAINER = ${PDB};
SET LINESIZE 200
SET PAGESIZE 0
COLUMN NAME       FORMAT A30
COLUMN TEXT       FORMAT A120
SELECT NAME, LINE, POSITION, TEXT
  FROM dba_errors
 WHERE owner='DHERP'
   AND NAME IN
       ('GET_ORDERFLOORCNT','GET_ORDERFORMULA','GET_ORDERFLOOR',
        'SP_DIANSANQUERY','SP_DIANSANEXEC','WMS_PDA_WFH_PIECE','APP_STYLES_KCTJ')
 ORDER BY NAME, LINE, POSITION;
EXIT
SQL
run_sqlfile "$tmp"
rm -f "$tmp"
