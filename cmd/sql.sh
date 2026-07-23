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
        *) echo "用法: omf sql {scan|run|import|init|status|rollback}"; exit 1;;
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
#   用法:
#     omf sql import <dumpfile> [--remap 源模式[:目标模式]] [--remap-tablespace 源TS:目标TS]
#     omf sql import <dumpfile> --check            # 生成可编辑的 imp.par 并探测源模式, 不导入
#     omf sql import <dumpfile> --apply [parfile]  # 用生成/编辑过的 parfile 真正导入
#   设计:
#     - 一键命令自动从配置(config)生成 parfile, 并【持久化】到 sql/.import/<dump名>.par
#       (不再散落 /tmp, 也不会被自动删除), 方便用户编辑端口/用户/密码/remap/表空间
#     - imp.par.example 仅作手工高级用法的参考模板, 日常无需手改它
#     - 不指定 --remap 时, 假定 dump 中的模式名 == APP_USER (导入到该模式)
#     - 导入后自动按对象类型统计该模式的对象数做校验
#===============================================================================

# 持久化 parfile 存放目录
sql_import_parfile_dir() {
    echo "${OMF_HOME}/sql/.import"
}

# 确保数据泵目录对象 oracle_dumps 存在于目标 PDB 并授权给 APP_USER (幂等)
#   否则跳过 omf sql init 直接 import 会报 ORA-39070 / ORA-39002
ensure_dump_dir_object() {
    log_step "确保数据泵目录对象 oracle_dumps 存在 (PDB=${PDB_NAME})"
    local sql; sql="$(mktemp /tmp/omf_imp_XXXXXX.sql)"
    {
        echo "ALTER SESSION SET CONTAINER = ${PDB_NAME};"
        echo "CREATE OR REPLACE DIRECTORY oracle_dumps AS '${ORACLE_DUMP_DIR}';"
        echo "GRANT READ, WRITE ON DIRECTORY oracle_dumps TO ${APP_USER};"
        echo "EXIT"
    } > "$sql"
    chmod 600 "$sql"
    chown "${ORACLE_USER}:${ORACLE_GROUP}" "$sql" 2>/dev/null || true
    as_oracle "sqlplus -s / as sysdba @${sql}" 2>&1 \
        | tee -a "${OMF_HOME}/sql/.logs/imp_dir_$(date '+%Y%m%d_%H%M%S').log" \
        | grep -iE "ORA-|directory|grant" || true
    rm -f "$sql"
}

# 以 imp.par.example 为模板, 用配置值生成持久化 parfile 到 $4
sql_import_gen_parfile() {
    local base="$1" remap="$2" ts_remap="$3" out="$4"
    local tmpl="${OMF_HOME}/sql/imp.par.example"
    if [ -f "$tmpl" ]; then
        cp "$tmpl" "$out"
    else
        : > "$out"
    fi
    # 去掉模板里这些 key 的已有行(含注释外的同名行), 统一在末尾重写, 避免重复
    sed -i -E '/^[[:space:]]*userid=/d; /^[[:space:]]*directory=/d; /^[[:space:]]*dumpfile=/d; /^[[:space:]]*logfile=/d; /^[[:space:]]*transform=/d; /^[[:space:]]*remap_schema=/d; /^[[:space:]]*remap_tablespace=/d' "$out"
    {
        echo ""
        echo "# ---- 以下由 omf sql import 自动生成 ($(date '+%F %T')) ----"
        echo "userid=${APP_USER}/\"${APP_PASSWORD}\"@//localhost:${LISTENER_PORT}/${PDB_NAME}"
        echo "directory=oracle_dumps"
        echo "dumpfile=${base}"
        echo "logfile=${base}.imp.log"
        echo "transform=oid:n"
        [ -n "$remap" ] && echo "remap_schema=${remap}"
        [ -n "$ts_remap" ] && echo "remap_tablespace=${ts_remap}"
    } >> "$out"
    chmod 600 "$out"
    chown "${ORACLE_USER}:${ORACLE_GROUP}" "$out" 2>/dev/null || true
    echo "$out"
}

# 真正执行 impdp + 导入后校验
do_impdp() {
    local parfile="$1" base="$2"
    log_step "开始导入: ${base} -> 模式 ${APP_USER}@${PDB_NAME}"

    # impdp 经 as_oracle 以 oracle 用户运行; 持久化 parfile 常落在 root 家目录
    #   (如 /root/OMF), oracle 用户无权访问 -> LRM-00109. 故复制到 oracle 可读写的
    #   /tmp 并改属主; 同时 impdp 本地日志也落到 /tmp, 避免 oracle 写不进 /root/OMF.
    local tmp_par; tmp_par="$(mktemp /tmp/omf_imp_XXXXXX.par)"
    cp -f "$parfile" "$tmp_par"
    chown "${ORACLE_USER}:${ORACLE_GROUP}" "$tmp_par" 2>/dev/null || true
    chmod 600 "$tmp_par"
    local log_dir="/tmp"; mkdir -p "$log_dir"
    as_oracle "impdp parfile=${tmp_par}" 2>&1 | tee "${log_dir}/imp_$(date '+%Y%m%d_%H%M%S').log"
    rm -f "$tmp_par"
    log_step "导入后校验 (模式 ${APP_USER} 对象统计)"
    sql_execute_inline "ALTER SESSION SET CONTAINER = ${PDB_NAME};
SELECT object_type, COUNT(*) FROM dba_objects WHERE owner='${APP_USER}' GROUP BY object_type ORDER BY 1;"
}

# 从 dump 文件明文抽取源模式 (数据泵 master table 目录多为明文)
#   返回按出现频次排序的候选模式名 (每行一个), 排除系统模式
#   19c 的 SQLFILE 模式会忽略 INCLUDE 且必报 ORA-39099, 故改用此秒级直读方式
_omf_dump_schema() {
    local dmp="$1"
    local ex
    command -v strings >/dev/null 2>&1 && ex=strings || ex="grep -a"
    $ex "$dmp" 2>/dev/null \
        | grep -oiE '"[A-Za-z0-9_$#]+"\."' \
        | tr -d '"' | sed 's/\.$//' \
        | grep -viE '^(SYS|SYSTEM|OUTLN|DBSNMP|APPQOSSYS|CTXSYS|DIP|ORACLE_OCM|MDSYS|OLAPSYS|ORDDATA|ORDPLUGINS|ORDSYS|WMSYS|XDB|ANONYMOUS|EXFSYS|FLOWS_FILES|MGMT_VIEW|SI_INFORMTN_SCHEMA|SPATIAL_CSW_ADMIN|SPATIAL_WFS_ADMIN|XS\$NULL)$' \
        | sort | uniq -c | sort -rn | awk '{print $2}'
}

# 从 dump 文件明文抽取源表空间 (best-effort)
_omf_dump_tablespace() {
    local dmp="$1"
    local ex
    command -v strings >/dev/null 2>&1 && ex=strings || ex="grep -a"
    $ex "$dmp" 2>/dev/null \
        | grep -oiE '(DEFAULT )?TABLESPACE "[^"]+"' \
        | grep -oiE '"[^"]+"' | tr -d '"' | sort -u \
        | grep -viE '^(SYSTEM|SYSAUX|TEMP|USERS|UNDOTBS1|UNDOTBS2)$'
}

sql_import() {
    local dumpfile="" remap="" ts_remap="" check_only=0 apply_mode=0 apply_parfile=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --remap)            remap="${2:-}"; shift 2;;
            --remap-tablespace) ts_remap="${2:-}"; shift 2;;
            --check)            check_only=1; shift;;
            --apply)
                apply_mode=1
                if [ $# -ge 2 ] && [[ "$2" != -* ]]; then
                    apply_parfile="$2"; shift 2
                else
                    shift
                fi
                ;;
            -*) log_error "未知选项: $1"; return 1;;
            *)  [ -z "$dumpfile" ] && dumpfile="$1"; shift;;
        esac
    done
    if [ -z "$dumpfile" ]; then
        if [ "$apply_mode" -eq 1 ] && [ -n "$apply_parfile" ]; then
            dumpfile="$(basename "$apply_parfile" .par)"
        else
            echo "用法: omf sql import <dumpfile> [--remap 源模式[:目标模式]] [--remap-tablespace 源TS:目标TS] [--check] [--apply [parfile]]"
            exit 1
        fi
    fi

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

    # 持久化 parfile 路径 (每个 dump 一份, 不再散落 /tmp)
    local impdir; impdir="$(sql_import_parfile_dir)"
    mkdir -p "$impdir"
    local parfile="${impdir}/${base}.par"

    # ---- --apply: 用既有(用户编辑过的) parfile 直接导入 ----
    if [ "$apply_mode" -eq 1 ]; then
        [ -n "$apply_parfile" ] && parfile="$apply_parfile"
        if [ ! -f "$parfile" ]; then
            log_error "找不到 parfile: $parfile (请先 omf sql import <dump> --check 生成, 或显式指定 --apply <parfile>)"
            return 1
        fi
        log_info "使用已有 parfile: $parfile"
        do_impdp "$parfile" "$base"
        return 0
    fi

    # 确保目录对象存在 (跳过 sql init 也能导入)
    ensure_dump_dir_object

    # ---- --check: 生成持久化 parfile + 抽取源模式, 不真正导入 ----
    if [ "$check_only" -eq 1 ]; then
        log_step "检查模式: 生成 parfile 并抽取 dump 中的源模式"
        sql_import_gen_parfile "$base" "$remap" "$ts_remap" "$parfile"

        # 主探测: 直接解析 dump 文件明文 (数据泵 master table 目录多为明文,
        #   "SCHEMA"."OBJECT" 限定符可秒级提取, 绕开 19c SQLFILE 必报的 ORA-39099)
        #   兜底: strings 提取为空时, 再退化为慢速 SQLFILE 抽取
        set +e
        local schemas tss
        schemas=$(_omf_dump_schema "$dmp")
        tss=$(_omf_dump_tablespace "$dmp")
        set -e

        if [ -z "$schemas" ]; then
            log_warn "明文探测未命中, 退化为 SQLFILE 抽取 (较慢, 可能报 ORA-39099)"
            # 注意: impdp 的 sqlfile/dumpfile/logfile 只能写【裸文件名】(落到 DIRECTORY 指向的
            #   ORACLE_DUMP_DIR 下), 不能带路径, 否则报 ORA-39088
            local sqlfile; sqlfile="omf_imp_$(date '+%s%N').sql"
            local chk; chk="$(mktemp /tmp/omf_imp_XXXXXX.par)"
            {
                grep -vE '^[[:space:]]*logfile=' "$parfile"
                echo "sqlfile=${sqlfile}"
                echo "nologfile"
            } > "$chk"
            chmod 600 "$chk"
            chown "${ORACLE_USER}:${ORACLE_GROUP}" "$chk" 2>/dev/null || true
            as_oracle "impdp parfile=${chk}" 2>&1 | tee -a "${OMF_HOME}/sql/.logs/imp_check_$(date '+%Y%m%d_%H%M%S').log"
            rm -f "$chk"
            local sf="${ORACLE_DUMP_DIR}/${sqlfile}"
            if [ -s "$sf" ]; then
                schemas=$(grep -oiE '"[A-Za-z0-9_$#]+"\."' "$sf" 2>/dev/null \
                          | tr -d '"' | sed 's/\.$//' | sort -u \
                          | grep -viE '^(SYS|SYSTEM|OUTLN|DBSNMP|APPQOSSYS|CTXSYS|DIP|ORACLE_OCM|MDSYS|OLAPSYS|ORDDATA|ORDPLUGINS|ORDSYS|WMSYS|XDB|ANONYMOUS|EXFSYS|FLOWS_FILES|MGMT_VIEW|SI_INFORMTN_SCHEMA|SPATIAL_CSW_ADMIN|SPATIAL_WFS_ADMIN|XS\$NULL)$')
                [ -z "$tss" ] && tss=$(grep -iE 'DEFAULT TABLESPACE "[^"]+"|TABLESPACE "[^"]+"' "$sf" 2>/dev/null | grep -oiE '"[^"]+"' | tr -d '"' | sort -u | grep -viE '^(SYSTEM|SYSAUX|TEMP|USERS|UNDOTBS1|UNDOTBS2)$')
            else
                echo "  ⚠ SQLFILE 也未生成 (ORA-39099 所致), 请手动编辑 parfile 指定 remap_schema"
            fi
            rm -f "$sf"
        fi

        echo ""
        echo "=== dump 中探测到的源模式/用户 ==="
        if [ -n "$schemas" ]; then
            echo "$schemas" | while read -r s; do echo "  - $s"; done
            # 单一源模式且与目标不同 -> 自动写入 remap (用户仍可改)
            local nsc; nsc=$(printf '%s\n' "$schemas" | grep -c .)
            if [ -z "$remap" ] && [ "$nsc" -eq 1 ] && [ "$schemas" != "${APP_USER}" ]; then
                echo ""
                echo "→ 探测到单一源模式 '$schemas', 已自动写入: remap_schema=${schemas}:${APP_USER}"
                echo "  如需改目标模式, 编辑 parfile 后: omf sql import ${base} --apply"
                sed -i -E '/^[[:space:]]*remap_schema=/d' "$parfile"
                printf 'remap_schema=%s:%s\n' "$schemas" "${APP_USER}" >> "$parfile"
            elif [ "$nsc" -gt 1 ]; then
                echo ""
                echo "→ 检测到多个模式, 未自动 remap; 请编辑 parfile 指定 remap_schema"
            fi
        else
            echo "  (未能从 dump 提取模式; 请手动编辑 parfile 指定 remap_schema=源模式:<目标>)"
        fi

        # 探测源表空间 (best-effort), 给出提示
        if [ -n "$tss" ] && [ "$tss" != "${APP_TABLESPACE}" ]; then
            echo ""
            echo "→ dump 中使用的表空间: $(echo $tss | tr '\n' ' ')"
            echo "  若目标库无该表空间, 建议加: remap_tablespace=<源TS>:${APP_TABLESPACE}"
            echo "  例: omf sql import ${base} --remap-tablespace $(echo $tss | head -1):${APP_TABLESPACE} --check"
        fi

        echo ""
        log_info "parfile 已生成并保留: $parfile"
        log_info "可直接编辑(端口/用户/密码/remap/表空间)后执行: omf sql import ${base} --apply"
        return 0
    fi

    # ---- 默认: 已知模式, 直接生成 parfile 并导入 ----
    sql_import_gen_parfile "$base" "$remap" "$ts_remap" "$parfile"
    do_impdp "$parfile" "$base"
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
        # 自动切到应用 PDB: 脚本以 / as sysdba 连入 CDB$ROOT, 在 PDB 内创建对象前必须先切容器。
        # 注入到开头, 使 patch/upgrade/custom/init 脚本无需在文件开头手写 ALTER SESSION SET CONTAINER。
        echo "ALTER SESSION SET CONTAINER = ${PDB_NAME};"
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
