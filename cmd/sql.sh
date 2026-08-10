#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF - SQL 脚本管理命令 v2
# 改进: 1) 失败检测 (退出码 + ORA-/SP2-/PLS-/TNS- 正则) 2) 去掉重复写日志
#       3) 失败即停 + 断点续跑 4) 执行前预检数据库可连
#===============================================================================

cmd_sql() {
    local subcmd="${1:-scan}"
    shift || true
    log_set_subcmd "$subcmd"
    case "$subcmd" in
        scan)     sql_scan "$@";;
        run)      sql_run "$@";;
        import)    sql_import "$@";;
        init)     sql_init "$@";;
        status)   sql_status "$@";;
        usage)    sql_usage "$@";;
        rollback) sql_rollback "$@";;
        *) echo "用法: omf sql {scan|run|import|init|status|usage|rollback}"; exit 1;;
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
        scripts=$(find "$dir" -maxdepth 1 -name "*.sql" ! -name '_*.sql' -type f | sort)
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
        echo "SET DEFINE OFF"
        echo "DEFINE PDB_NAME     = '${PDB_NAME}'"
        echo "DEFINE ORACLE_SID   = '${ORACLE_SID}'"
        echo "DEFINE APP_USER     = '${APP_USER}'"
        echo "DEFINE APP_PASSWORD = $(omf_quote_sql "${APP_PASSWORD}")"
        echo "DEFINE APP_TABLESPACE = '${APP_TABLESPACE}'"
        echo "DEFINE ORACLE_DATA  = '${ORACLE_DATA}'"
        echo "DEFINE ORACLE_DUMP_DIR = '${ORACLE_DUMP_DIR}'"
        echo "SET SERVEROUTPUT ON"
        echo "SET ECHO ON"
        # 自动切到应用 PDB: 以 / as sysdba 连入 CDB$ROOT, 操作 PDB 内对象前先切容器。
        echo "ALTER SESSION SET CONTAINER = ${PDB_NAME};"
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
    local only_schema=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --schema) only_schema="${2:-}"; shift 2;;
            *) shift;;
        esac
    done

    log_step "初始化基线数据"
    # 预检数据库可连 (DB 未起时提前报错, 避免下面逐模式建用户静默失败)
    sql_preflight
    # 预建数据泵目录 (Oracle DIRECTORY 对象指向的 OS 路径), 确保 impdp 可直接使用。
    mkdir -p "$ORACLE_DUMP_DIR"
    chown "${ORACLE_USER}:${ORACLE_GROUP}" "$ORACLE_DUMP_DIR" 2>/dev/null || true
    chmod 750 "$ORACLE_DUMP_DIR"
    log_info "数据泵目录已就绪: $ORACLE_DUMP_DIR (属主 ${ORACLE_USER}:${ORACLE_GROUP})"

    local executed_dir="${OMF_HOME}/sql/.executed"
    mkdir -p "$executed_dir"

    # ---- 逐个模式创建用户/表空间 (遍历 APP_SCHEMAS, 支持 N 个库) ----
    # 数据文件按 <SID>/<模式名>/ 子目录隔离, 彻底避免多个表空间同名数据文件冲突(ORA-01537)。
    local template="${SQL_INIT_DIR}/_create_schema.sql"
    if [ -f "$template" ]; then
        local names
        if [ -n "$only_schema" ]; then
            names="$only_schema"
            log_info "仅初始化单模式: ${names} (其余模式不受影响)"
            # 单模式"重建"实际会以 _create_schema.sql 重跑 CREATE USER / CREATE TABLESPACE,
            # 会改变该模式连接状态并可能中断正在访问该模式的业务, 属有副作用操作;
            # 必须在真正执行(重建落库)前确认, 否则 confirm 形同虚设。
            confirm "确认重建模式 ${only_schema}? (将重建其用户/表空间, 可能中断该模式现有连接)"
        else
            names="$(omf_schema_list)"
            log_info "待初始化模式: $names"
        fi
        local name u ts pw dd
        for name in $names; do
            u=$(omf_schema_user "$name")
            ts=$(omf_schema_tablespace "$name")
            pw=$(omf_schema_password "$name")
            dd=$(omf_schema_datadir "$name")
            # 数据文件子目录必须存在, 否则 CREATE TABLESPACE 报 ORA-01119
            mkdir -p "$dd"
            chown "${ORACLE_USER}:${ORACLE_GROUP}" "$dd" 2>/dev/null || true
            chmod 750 "$dd"
            log_step "创建模式[${name}] -> 用户=${u} 表空间=${ts} 数据目录=${dd}"
            if ! _sql_run_file "$template" "$u" "$pw" "$ts" "$dd"; then
                log_warn "模式[${name}] 创建失败或部分失败, 请检查日志 (可能用户已存在, 属正常幂等跳过)"
            fi
            # 记录该模式基线已建 (供 omf sql rollback --schema <名> 定点重置)
            mkdir -p "${executed_dir}/${name}"
            date '+%F %T' > "${executed_dir}/${name}/.schema_created"
        done
    else
        log_warn "未找到模式模板: $template (跳过模式创建, 仅执行其余 init 脚本)"
    fi

    # ---- 执行其余 init 脚本 (非模板 _*.sql), 支持断点续跑 ----
    # 仅全量 init 时执行全局脚本; 单模式(--schema)重建只重建该模式的用户/表空间,
    # 不重跑全局 init 脚本(通常只需一次, 且非模式专属)。
    if [ -n "$only_schema" ]; then
        log_info "单模式重建完成 (已重建 ${only_schema} 的用户/表空间)。全局 init 脚本未重跑。"
        return 0
    fi
    sql_scan
    confirm "确认执行所有初始化脚本(模式模板除外)?"
    sql_preflight
    sql_execute_all
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
        scripts=$(find "$dir" -maxdepth 1 -name "*.sql" ! -name '_*.sql' -type f | sort)
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
#===============================================================================
# 执行单个脚本 (核心: 严格错误检测)
#   _sql_run_file: 用显式传入的变量构建 wrapper 并执行 (供模式创建按每个模式注入不同值)
#   sql_execute_one: 兼容旧调用, 用全局 APP_USER 上下文执行 (patch/upgrade/custom 等)
#===============================================================================
_sql_run_file() {
    local script="$1" app_user="$2" app_pw="$3" app_ts="$4" data_dir="$5"
    [ -f "$script" ] || { log_error "脚本不存在: $script"; return 1; }
    local log_dir="${OMF_HOME}/sql/.logs"
    mkdir -p "$log_dir"
    local log_file="${log_dir}/$(basename "$script" .sql)_$(date '+%Y%m%d_%H%M%S').log"

    log_step "执行: $(basename "$script") (上下文用户=${app_user}, 表空间=${app_ts})"
    log_info "日志: $log_file"

    local wrapper; wrapper=$(mktemp /tmp/omf_sql_XXXXXX.sql)
    {
        echo "WHENEVER SQLERROR EXIT SQL.SQLCODE ROLLBACK"
        echo "WHENEVER OSERROR  EXIT FAILURE ROLLBACK"
        echo "SET DEFINE OFF"   # 避免密码/内容含 & 触发 SQL*Plus 变量替换
        echo "DEFINE PDB_NAME     = '${PDB_NAME}'"
        echo "DEFINE ORACLE_SID   = '${ORACLE_SID}'"
        echo "DEFINE APP_USER     = '${app_user}'"
        echo "DEFINE APP_PASSWORD = $(omf_quote_sql "${app_pw}")"   # 密码单引号翻倍, 防 ' 破坏
        echo "DEFINE APP_TABLESPACE = '${app_ts}'"
        echo "DEFINE ORACLE_DATA  = '${ORACLE_DATA}'"
        echo "DEFINE APP_DATA_DIR = '${data_dir}'"
        echo "DEFINE ORACLE_DUMP_DIR = '${ORACLE_DUMP_DIR}'"
        echo "SET SERVEROUTPUT ON"
        echo "SET ECHO ON"
        # 自动切到应用 PDB: 脚本以 / as sysdba 连入 CDB$ROOT, 在 PDB 内创建对象前必须先切容器。
        echo "ALTER SESSION SET CONTAINER = ${PDB_NAME};"
        cat "$script"
        echo ""
        echo "EXIT"
    } > "$wrapper"
    chmod 600 "$wrapper"
    # oracle 经 runuser 执行, 需能读此 wrapper (含脚本内容与 DEFINE 变量)
    chown "${ORACLE_USER}:${ORACLE_GROUP}" "$wrapper" 2>/dev/null || true

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

sql_execute_one() {
    local script="$1"
    local data_dir="${ORACLE_DATA}/${ORACLE_SID}/${APP_USER}"
    # 非模式创建类脚本(patch/upgrade/custom)用全局 APP_USER 上下文执行
    _sql_run_file "$script" "$APP_USER" "$APP_PASSWORD" "$APP_TABLESPACE" "$data_dir"
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
#   omf sql rollback <name>              清除单个脚本记录(全局命名空间)
#   omf sql rollback --all                清除全部执行记录
#   omf sql rollback --all  --schema X  仅清除模式 X 的执行记录(定点重置单库)
#   omf sql rollback <name> --schema X   仅清除模式 X 下该脚本的记录
#   模式命名空间: sql/.executed/<模式名>/, 由 omf sql init --schema 写入 .schema_created 标记
#===============================================================================
sql_rollback() {
    local name="" schema=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --schema) schema="${2:-}"; shift 2;;
            --all)    name="--all"; shift;;
            *)        [ -z "$name" ] && name="$1"; shift;;
        esac
    done
    [ -z "$name" ] && { echo "用法: omf sql rollback <name> | --all [--schema <模式名>]"; exit 1; }
    local executed_dir="${OMF_HOME}/sql/.executed"
    if [ "$name" = "--all" ]; then
        if [ -n "$schema" ]; then
            # 重置模式执行记录不可恢复: 之后重跑会把该模式所有 init 脚本从头执行,
            # 可能重复创建对象/数据; 属不可逆的高危重置, 用 confirm_danger 防止 -y 静默执行。
            confirm_danger "确认重置模式 ${schema} 的全部 SQL 执行记录? (不可恢复, 重跑将从头重建该模式)" || return 1
            rm -rf "${executed_dir}/${schema}"; log_info "模式 ${schema} 的执行记录已清除 (可重新 omf sql init --schema ${schema})"
        else
            # 全库执行记录清除同样不可逆: 所有模式/全局脚本将被从头重跑, 风险面更大。
            confirm_danger "确认重置所有 SQL 执行记录? (不可恢复, 所有模式将从头重跑)" || return 1
            rm -rf "$executed_dir"; log_info "所有执行记录已清除"
        fi
    else
        if [ -n "$schema" ]; then
            rm -f "${executed_dir}/${schema}/${name}"; log_info "已清除模式 ${schema} 的执行记录: $name"
        else
            rm -f "${executed_dir}/${name}"; log_info "已清除执行记录: $name"
        fi
    fi
}

#===============================================================================
# 多模式空间使用 / 无效对象一览 (命中"多模式"维度)
#   遍历 APP_SCHEMAS, 逐个输出该模式的段空间占用、无效对象数与对象类型分布
#===============================================================================
sql_usage() {
    log_step "多模式空间使用与无效对象一览"
    sql_preflight
    local names; names="$(omf_schema_list)"
    [ -z "$names" ] && { log_warn "未配置任何模式 (APP_SCHEMAS 为空)"; return 0; }
    local name u
    for name in $names; do
        u=$(omf_schema_user "$name")
        echo ""
        echo "=== 模式[${name}] 用户=${u} @ ${PDB_NAME} ==="
        # sql_execute_inline 已自动切到 PDB, 此处无需再 ALTER SESSION
        # 段空间 + 无效对象 + 对象类型分布 + 按表空间拆分 (表空间维度明细)
        sql_execute_inline "SELECT '段空间(MB):' AS metric, ROUND(SUM(bytes)/1024/1024,2) AS val FROM dba_segments WHERE owner='${u}';
SELECT '无效对象:' AS metric, COUNT(*) AS val FROM dba_objects WHERE owner='${u}' AND status='INVALID';
SELECT object_type, COUNT(*) AS cnt FROM dba_objects WHERE owner='${u}' GROUP BY object_type ORDER BY 2 DESC;
SELECT tablespace_name, ROUND(SUM(bytes)/1024/1024,2) AS mb FROM dba_segments WHERE owner='${u}' GROUP BY tablespace_name ORDER BY 2 DESC;"
    done

    # 全 PDB 表空间容量概览 (总量/已用/空闲/使用率)
    echo ""
    echo "=== 全库表空间容量概览 (PDB=${PDB_NAME}) ==="
    sql_execute_inline "SELECT t.tablespace_name,
       ROUND(NVL(d.total,0)/1024/1024,2)  AS total_mb,
       ROUND(NVL(d.total,0)/1024/1024 - NVL(f.free,0)/1024/1024,2) AS used_mb,
       ROUND(NVL(f.free,0)/1024/1024,2)   AS free_mb,
       ROUND((NVL(d.total,0) - NVL(f.free,0)) / NULLIF(NVL(d.total,0),0) * 100,1) AS used_pct
FROM (SELECT tablespace_name, SUM(bytes) AS total FROM dba_data_files GROUP BY tablespace_name) d
LEFT JOIN (SELECT tablespace_name, SUM(bytes) AS free FROM dba_free_space GROUP BY tablespace_name) f
  ON d.tablespace_name = f.tablespace_name
ORDER BY used_pct DESC NULLS LAST;"
}
