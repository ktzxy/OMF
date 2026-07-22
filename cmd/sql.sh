#!/bin/bash
#===============================================================================
# OMF - SQL 脚本管理命令 v2
# 改进: 1) 失败检测 (退出码 + ORA-/SP2-/PLS-/TNS- 正则) 2) 去掉重复写日志
#       3) 失败即停 + 断点续跑 4) 执行前预检数据库可连
#===============================================================================

cmd_sql() {
    local subcmd="${1:-scan}"
    shift || true
    case "$subcmd" in
        scan)     sql_scan "$@";;
        run)      sql_run "$@";;
        import)    sql_import "$@";;
        init)     sql_init "$@";;
        status)   sql_status "$@";;
        rollback) sql_rollback "$@";;
        *) echo "用法: omf sql {scan|run|init|status|rollback}"; exit 1;;
    esac
}

get_sql_dirs() {
    local dirs=("${SQL_INIT_DIR}" "${SQL_UPGRADE_DIR}" "${SQL_PATCH_DIR}" "${SQL_CUSTOM_DIR}")
    for d in "${dirs[@]}"; do [ -d "$d" ] && echo "$d"; done
}

get_executed_file() {
    echo "${OMF_HOME}/sql/.executed/$(basename "$1")"
}

# 预检: 数据库是否可连接
sql_preflight() {
    if ! as_oracle "echo 'SELECT 1 FROM dual;' | sqlplus -s / as sysdba" &>/dev/null; then
        log_error "无法连接数据库, 请先 omf db start 并确保实例 OPEN"
    fi
}

#===============================================================================
# 扫描待执行脚本
#===============================================================================
sql_scan() {
    local auto_exec="${1:-false}"
    log_step "扫描待执行 SQL 脚本"
    local total=0 pending=0
    for dir in $(get_sql_dirs); do
        echo ""; echo "--- $(basename "$dir") ---"
        local scripts
        scripts=$(find "$dir" -maxdepth 1 -name "*.sql" -type f | sort)
        [ -z "$scripts" ] && { echo "  (无脚本)"; continue; }
        for script in $scripts; do
            total=$((total+1))
            local ef; ef=$(get_executed_file "$script")
            if [ -f "$ef" ]; then
                echo "  ✓ $(basename "$script") - 已执行 ($(cat "$ef"))"
            else
                pending=$((pending+1))
                echo "  → $(basename "$script") - 待执行"
            fi
        done
    done
    echo ""; echo "总计: $total, 待执行: $pending"
    if [ "$auto_exec" = "--auto" ] && [ "$pending" -gt 0 ]; then
        confirm "自动执行 $pending 个待处理脚本?"
        sql_execute_all
    fi
}

#===============================================================================
# 执行指定脚本
#===============================================================================
sql_run() {
    local script="$1"
    [ -z "$script" ] && { echo "用法: omf sql run <file.sql|内联SQL> | --all"; exit 1; }
    [ "$script" = "--all" ] && { sql_execute_all; return; }

    # 1) 文件优先: 直接路径 或 ${SQL_INIT_DIR} 下的脚本
    local file="$script"
    [ -f "$file" ] || file="${SQL_INIT_DIR}/$script"
    if [ -f "$file" ]; then
        sql_preflight
        sql_execute_one "$file"
        return
    fi

    # 2) 否则判定为内联 SQL (含空格或常见 SQL 关键字), 避免把拼错的文件名误当 SQL 执行
    if [[ "$script" =~ [[:space:]] ]] || [[ "$script" =~ (^|[[:space:];])(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|BEGIN|DECLARE|GRANT|REVOKE|MERGE|WITH|EXPLAIN|SET|SHOW|CALL|EXEC) ]]; then
        log_step "执行内联 SQL"
        sql_preflight
        sql_execute_inline "$script"
        return
    fi

    log_error "脚本不存在: $script"
}

# 执行内联 SQL (与 sql_execute_one 等价, 但 SQL 文本来自命令行而非文件)
sql_execute_inline() {
    local sql="$1"
    local log_dir="${OMF_HOME}/sql/.logs"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/inline_$(date '+%Y%m%d_%H%M%S').log"

    local wrapper; wrapper=$(mktemp /tmp/omf_sql_XXXXXX.sql)
    {
        echo "WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK"
        echo "WHENEVER OSERROR  EXIT FAILURE ROLLBACK"
        echo "DEFINE PDB_NAME     = '${PDB_NAME}'"
        echo "DEFINE ORACLE_SID   = '${ORACLE_SID}'"
        echo "DEFINE APP_USER     = '${APP_USER}'"
        echo "DEFINE APP_PASSWORD = '${APP_PASSWORD}'"
        echo "DEFINE APP_TABLESPACE = '${APP_TABLESPACE}'"
        echo "DEFINE ORACLE_DATA  = '${ORACLE_DATA}'"
        echo "DEFINE ORACLE_DUMP_DIR = '${ORACLE_DUMP_DIR}'"
        echo "SET SERVEROUTPUT ON"
        echo "SET ECHO ON"
        # SQL*Plus 仅当 ';' 位于行尾时才视为语句结束符; 内联 SQL 常把多条语句写在同一行,
        # 导致 ';' 后若紧跟下一条语句会被整体当作一条语句解析 -> ORA-00922。
        # 这里把语句结束处的 ';' 之后强制换行, 让每条语句独占一行。
        # 注意: 若字符串字面量内(如 WHERE x='a;b')含 ';' 会被误拆, 复杂语句请用脚本文件执行。
        printf '%s\n' "$sql" | sed 's/;[[:space:]]*/;\n/g'
        echo "EXIT"
    } > "$wrapper"
    chmod 600 "$wrapper"
    chown oracle:oinstall "$wrapper" 2>/dev/null || true

    set +e
    as_oracle "sqlplus -s / as sysdba @${wrapper}" 2>&1 | tee "$log_file"
    local rc=${PIPESTATUS[0]}
    set -e
    rm -f "$wrapper"

    # 三重检测: 退出码 / ORA- / SP2-/PLS-/TNS- 错误码
    local has_err=0
    [ "$rc" -ne 0 ] && has_err=1
    grep -Eq "ORA-[0-9]{4,}|SP2-[0-9]+|PLS-[0-9]+|TNS-[0-9]+" "$log_file" && has_err=1
    if [ "$has_err" -eq 1 ]; then
        log_warn "内联 SQL 包含错误, 请检查日志: $log_file"
        grep -E "ORA-[0-9]{4,}|SP2-[0-9]+|PLS-[0-9]+|TNS-[0-9]+" "$log_file" | head -10
        return 1
    fi

    log_info "执行成功"
    return 0
}

sql_init() {
    log_step "初始化基线数据"
    # 预建数据泵目录 (Oracle DIRECTORY 对象指向的 OS 路径), 确保 impdp 可直接使用。
    # 否则 omf sql import 会因 OS 目录不存在而报 ORA-27037 / permission denied。
    mkdir -p "$ORACLE_DUMP_DIR"
    chown "${ORACLE_USER}:${ORACLE_GROUP}" "$ORACLE_DUMP_DIR" 2>/dev/null || true
    chmod 750 "$ORACLE_DUMP_DIR"
    log_info "数据泵目录已就绪: $ORACLE_DUMP_DIR (属主 ${ORACLE_USER}:${ORACLE_GROUP})"
    sql_scan
    confirm "确认执行所有初始化脚本?"
    sql_preflight
    sql_execute_all
}

#===============================================================================
# 数据泵导入 (impdp) 到应用模式
#   用法: omf sql import <dumpfile> [--remap 源模式[:目标模式]] [--check]
#   说明:
#     - dumpfile 可为绝对路径(自动拷入数据泵目录)或仅文件名(须已在目录中)
#     - 不指定 --remap 时, 假定 dump 中的模式名 == APP_USER (导入到该模式)
#     - --check: 仅抽取 DDL 预览源模式名, 不真正导入, 用于"未知模式名"场景
#     - 导入后自动按对象类型统计该模式的对象数做校验
#===============================================================================
sql_import() {
    local dumpfile="" remap="" check_only=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --remap) remap="${2:-}"; shift 2;;
            --check)  check_only=1; shift;;
            -*) log_error "未知选项: $1"; return 1;;
            *)  [ -z "$dumpfile" ] && dumpfile="$1"; shift;;
        esac
    done
    [ -z "$dumpfile" ] && { echo "用法: omf sql import <dumpfile> [--remap 源模式[:目标模式]] [--check]"; exit 1; }

    # 确保 OS 层数据泵目录存在且属主 oracle
    mkdir -p "$ORACLE_DUMP_DIR"
    chown "${ORACLE_USER}:${ORACLE_GROUP}" "$ORACLE_DUMP_DIR" 2>/dev/null || true
    chmod 750 "$ORACLE_DUMP_DIR"

    # 定位 dump 文件
    local base dmp
    base="$(basename "$dumpfile")"
    if [ -f "$dumpfile" ]; then
        if [ "$(dirname "$dumpfile")" != "$ORACLE_DUMP_DIR" ]; then
            cp -f "$dumpfile" "${ORACLE_DUMP_DIR}/${base}"
            chown "${ORACLE_USER}:${ORACLE_GROUP}" "${ORACLE_DUMP_DIR}/${base}" 2>/dev/null || true
            log_info "已拷入数据泵目录: ${ORACLE_DUMP_DIR}/${base}"
        fi
    elif [ -f "${ORACLE_DUMP_DIR}/${base}" ]; then
        : # 已在目录中
    else
        log_error "找不到 dump 文件: $dumpfile (或 ${ORACLE_DUMP_DIR}/${base})"
        return 1
    fi
    dmp="${ORACLE_DUMP_DIR}/${base}"

    # 组装 parfile
    local parfile; parfile="$(mktemp /tmp/omf_imp_XXXXXX.par)"
    {
        echo "userid=${APP_USER}/\"${APP_PASSWORD}\"@//localhost:${LISTENER_PORT}/${PDB_NAME}"
        echo "directory=oracle_dumps"
        echo "dumpfile=${base}"
        echo "logfile=${base}.imp.log"
        echo "transform=oid:n"
        if [ -n "$remap" ]; then
            local src_schema dst_schema
            src_schema="${remap%%:*}"
            dst_schema="${remap##*:}"
            [ "$dst_schema" = "$src_schema" ] && dst_schema="${APP_USER}"
            echo "remap_schema=${src_schema}:${dst_schema}"
        fi
    } > "$parfile"
    chmod 644 "$parfile"
    chown "${ORACLE_USER}:${ORACLE_GROUP}" "$parfile" 2>/dev/null || true

    if [ "$check_only" -eq 1 ]; then
        log_step "抽取 dump DDL 预览源模式名 (不真正导入)"
        local sqlfile; sqlfile="$(mktemp /tmp/omf_imp_XXXXXX.sql)"
        local chk; chk="$(mktemp /tmp/omf_imp_XXXXXX.par)"
        # 单独写一份不含 logfile 的 parfile (避免 logfile + nologfile 冲突)
        {
            echo "userid=${APP_USER}/\"${APP_PASSWORD}\"@//localhost:${LISTENER_PORT}/${PDB_NAME}"
            echo "directory=oracle_dumps"
            echo "dumpfile=${base}"
            echo "sqlfile=${sqlfile}"
            echo "nologfile"
            echo "transform=oid:n"
            if [ -n "$remap" ]; then
                local src_schema dst_schema
                src_schema="${remap%%:*}"
                dst_schema="${remap##*:}"
                [ "$dst_schema" = "$src_schema" ] && dst_schema="${APP_USER}"
                echo "remap_schema=${src_schema}:${dst_schema}"
            fi
        } > "$chk"
        chmod 644 "$chk"
        chown "${ORACLE_USER}:${ORACLE_GROUP}" "$chk" 2>/dev/null || true
        as_oracle "impdp parfile=${chk}" 2>&1 | tee -a "${OMF_HOME}/sql/.logs/imp_check_$(date '+%Y%m%d_%H%M%S').log"
        echo ""
        echo "=== dump 中的模式/用户 (如需改名, 用 --remap 源模式[:目标模式]) ==="
        grep -iE "CREATE USER|schema|REMAP" "$sqlfile" 2>/dev/null | head -20 || echo "(未能提取, 可手动: impdp ... sqlfile= 查看)"
        rm -f "$chk" "$sqlfile" "$parfile"
        return 0
    fi

    log_step "开始导入: ${base} -> 模式 ${APP_USER}@${PDB_NAME}"
    local log_dir="${OMF_HOME}/sql/.logs"; mkdir -p "$log_dir"
    as_oracle "impdp parfile=${parfile}" 2>&1 | tee "${log_dir}/imp_$(date '+%Y%m%d_%H%M%S').log"
    rm -f "$parfile"

    # 导入后校验: 按对象类型统计该模式对象数
    log_step "导入后校验 (模式 ${APP_USER} 对象统计)"
    sql_execute_inline "ALTER SESSION SET CONTAINER = ${PDB_NAME};
SELECT object_type, COUNT(*) FROM dba_objects WHERE owner='${APP_USER}' GROUP BY object_type ORDER BY 1;"
}

#===============================================================================
# 执行所有待处理脚本 (失败即停, 支持断点续跑)
#===============================================================================
sql_execute_all() {
    sql_preflight
    local success=0 failed=0
    local executed_dir="${OMF_HOME}/sql/.executed"
    mkdir -p "$executed_dir"

    for dir in $(get_sql_dirs); do
        local scripts
        scripts=$(find "$dir" -maxdepth 1 -name "*.sql" -type f | sort)
        for script in $scripts; do
            local ef; ef=$(get_executed_file "$script")
            [ -f "$ef" ] && continue   # 已执行, 跳过 (断点续跑)
            if sql_execute_one "$script"; then
                success=$((success+1))
                date '+%F %T' > "$ef"
            else
                failed=$((failed+1))
                log_error "脚本执行失败: $(basename "$script")
  → 已成功执行 $success 个, 失败的脚本及之后的脚本未执行
  → 修复后重新执行: omf sql run --all  (已成功的不会重复执行)"
            fi
        done
    done
    echo ""; log_info "SQL 执行完成: 成功 $success, 失败 $failed"
}

#===============================================================================
# 执行单个脚本 (核心: 严格错误检测)
#===============================================================================
sql_execute_one() {
    local script="$1"
    local log_dir="${OMF_HOME}/sql/.logs"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/$(basename "$script" .sql)_$(date '+%Y%m%d_%H%M%S').log"

    log_step "执行: $(basename "$script")"
    log_info "日志: $log_file"

    # 注入 DEFINE, 使脚本中的 &PDB_NAME/&ORACLE_SID/&APP_USER/&APP_PASSWORD
    # 等非交互变量自动替换, 避免 sqlplus 卡在交互输入
    #
    # 关键: 不用 "@${script}" 引用原始脚本, 而是由 root 读取脚本内容直接嵌入 wrapper。
    # 原因: 脚本常位于 /root/OMF/sql/... 下, 而 oracle 经 runuser 无权进入 /root (默认 700),
    #       sqlplus 打开 @文件 时会报 "O/S Message: Permission denied"。
    #       内联到 /tmp 的 wrapper (已 chown oracle) 后, oracle 只需读该 wrapper 即可。
    local wrapper; wrapper=$(mktemp /tmp/omf_sql_XXXXXX.sql)
    {
        echo "WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK"
        echo "WHENEVER OSERROR  EXIT FAILURE ROLLBACK"
        echo "DEFINE PDB_NAME     = '${PDB_NAME}'"
        echo "DEFINE ORACLE_SID   = '${ORACLE_SID}'"
        echo "DEFINE APP_USER     = '${APP_USER}'"
        echo "DEFINE APP_PASSWORD = '${APP_PASSWORD}'"
        echo "DEFINE APP_TABLESPACE = '${APP_TABLESPACE}'"
        echo "DEFINE ORACLE_DATA  = '${ORACLE_DATA}'"
        echo "DEFINE ORACLE_DUMP_DIR = '${ORACLE_DUMP_DIR}'"
        echo "SET SERVEROUTPUT ON"
        echo "SET ECHO ON"
        cat "$script"
        echo ""
        echo "EXIT"
    } > "$wrapper"
    chmod 600 "$wrapper"
    # oracle 经 runuser 执行, 需能读此 wrapper (含脚本内容与 DEFINE 变量)
    chown oracle:oinstall "$wrapper" 2>/dev/null || true

    set +e
    as_oracle "sqlplus -s / as sysdba @${wrapper}" 2>&1 | tee "$log_file"
    local rc=${PIPESTATUS[0]}
    set -e
    rm -f "$wrapper"

    # 三重检测: 退出码 / ORA- / SP2-/PLS-/TNS- 错误码
    local has_err=0
    if [ "$rc" -ne 0 ]; then has_err=1; fi
    if grep -Eq "ORA-[0-9]{4,}|SP2-[0-9]+|PLS-[0-9]+|TNS-[0-9]+" "$log_file"; then
        has_err=1
    fi

    if [ "$has_err" -eq 1 ]; then
        log_warn "脚本包含错误, 请检查日志: $log_file"
        grep -E "ORA-[0-9]{4,}|SP2-[0-9]+|PLS-[0-9]+|TNS-[0-9]+" "$log_file" | head -10
        return 1
    fi

    log_info "执行成功: $(basename "$script")"
    return 0
}

#===============================================================================
# 查看执行状态
#===============================================================================
sql_status() {
    log_step "SQL 脚本执行状态"
    local executed_dir="${OMF_HOME}/sql/.executed"
    if [ ! -d "$executed_dir" ]; then echo "尚无执行记录"; return; fi
    echo ""; echo "已执行脚本:"
    for f in "$executed_dir"/*; do
        [ -f "$f" ] || continue
        echo "  $(basename "$f") - $(cat "$f")"
    done
    echo ""; echo "执行日志:"
    ls -lht "${OMF_HOME}/sql/.logs/" 2>/dev/null | head -20 || echo "  (无)"
}

#===============================================================================
# 回滚 (重置执行记录, 允许重跑)
#===============================================================================
sql_rollback() {
    local name="$1"
    [ -z "$name" ] && { echo "用法: omf sql rollback <name> | --all"; exit 1; }
    local executed_dir="${OMF_HOME}/sql/.executed"
    if [ "$name" = "--all" ]; then
        confirm "确认重置所有 SQL 执行记录?"
        rm -rf "$executed_dir"; log_info "所有执行记录已清除"
    else
        rm -f "${executed_dir}/${name}"; log_info "已清除执行记录: $name"
    fi
}
