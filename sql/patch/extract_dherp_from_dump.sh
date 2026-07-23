#!/bin/bash
#===============================================================================
# 从 01_fix_dherp_deps.sql.dump 提取 DHERP 损坏/缺失对象并覆盖到正式库 (ARTERYPDB)
#
# 背景:
#   dherp_202606290300.dmp 导入为正式库后, 有 6 个对象处于 INVALID:
#     GET_ORDERFLOORCNT, GET_ORDERFORMULA, GET_ORDERFLOOR,
#     SP_DIANSANQUERY, SP_DIANSANEXEC, WMS_PDA_WFH_PIECE, APP_STYLES_KCTJ
#   其中 APP_STYLES_KCTJ 在正式库中的源码已损坏 (PLS-00103), 而本 .dump 中保存的是
#   完好源码; 其余 5 个源码本身没问题, 仅因导入时依赖顺序而 INVALID。
#
#   本 .dump 是完整 expdp SQLFILE (1744 个对象), 并不包含那些"缺失列"的建表 DDL
#   (ARFLOOR / KK_* / ISREADY / KK_WFHTIME / IS_FH / KK_WLID 等只出现在过程体内,
#    从不作为 CREATE TABLE 的列定义)。因此"缺失列"必须由正式库 dherp_202606290300.dmp
#   自身提供 —— 若正式库完整, 覆盖源码 + 重编译即可全部生效。
#   注: 之前 dba_dependencies 返回 0 行属正常 (只记对象级依赖, 不含列级), 不影响本方案。
#
# 重要: 本脚本须以 root 运行 (或已是 oracle 用户)。root 下会:
#   1) 以 root 身份读取 /root/OMF 下(700)的 .dump 并提取到 /tmp 临时文件
#   2) chown oracle:oinstall + chmod 644 后, 用 runuser -l oracle (回退 su - oracle)
#      以 oracle 用户执行 sqlplus (自动带 ORACLE_HOME/PATH/ORACLE_SID)
#
# 用法:
#   cd <OMF>/sql/patch
#   bash extract_dherp_from_dump.sh
#===============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DUMP="$SCRIPT_DIR/01_fix_dherp_deps.sql.dump"
[ -f "$DUMP" ] || { echo "找不到 $DUMP"; exit 1; }

PDB="${PDB_NAME:-ARTERYPDB}"

# 需要覆盖的 6(+1) 个对象 (名称须与 .dump 中 CREATE 语句一致)
objects=(
  "get_orderFloorCnt"
  "get_orderFormula"
  "get_orderFloor"
  "sp_diansanQuery"
  "sp_diansanexec"
  "wms_pda_wfh_piece"
  "app_styles_kctj"
)

# 从 .dump 提取单个对象的 CREATE 块:
#   起点 = "^CREATE EDITIONABLE (procedure|function) <name>$" (忽略大小写)
#   终点 = 下一个顶层 "^CREATE " 或 "^ALTER " 之前 (即本对象自带的 "/" 终止符之后)
#   并把 CREATE 改为 CREATE OR REPLACE, 使其对已存在的对象可重复覆盖。
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

for o in "${objects[@]}"; do
  echo "=== 覆盖对象: $o ==="
  tmp="$(mktemp /tmp/dherp_ext_XXXXXX.sql)"
  {
    echo "WHENEVER SQLERROR CONTINUE"
    echo "ALTER SESSION SET CONTAINER = ${PDB};"
    echo "SET SERVEROUTPUT ON"
    extract_object "$o"
    echo "EXIT"
  } > "$tmp"
  run_sqlfile "$tmp"
  rm -f "$tmp"
  echo ""
done

echo "=== 重编译 DHERP 模式 (修复导入依赖顺序导致的级联 INVALID) ==="
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
echo "=== 校验: 仍 INVALID 的对象 (应为空) ==="
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
