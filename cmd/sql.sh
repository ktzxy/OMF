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
    # 预检数据库可连 (DB 未起时提前报错, 避免下面逐模式建用户静默失败)
    sql_preflight
    # 预建数据泵目录 (Oracle DIRECTORY 对象指向的 OS 路径), 确保 impdp 可直接使用。
    mkdir -p "$ORACLE_DUMP_DIR"
    chown "${ORACLE_USER}:${ORACLE_GROUP}" "$ORACLE_DUMP_DIR" 2>/dev/null || true
    chmod 750 "$ORACLE_DUMP_DIR"
    log_info "数据泵目录已就绪: $ORACLE_DUMP_DIR (属主 ${ORACLE_USER}:${ORACLE_GROUP})"

    # ---- 逐个模式创建用户/表空间 (遍历 APP_SCHEMAS, 支持 N 个库) ----
    # 数据文件按 <SID>/<模式名>/ 子目录隔离, 彻底避免多个表空间同名数据文件冲突(ORA-01537)。
    local template="${SQL_INIT_DIR}/_create_schema.sql"
    if [ -f "$template" ]; then
        local names; names="$(omf_schema_list)"
        log_info "待初始化模式: $names"
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
        done
    else
        log_warn "未找到模式模板: $template (跳过模式创建, 仅执行其余 init 脚本)"
    fi

    # ---- 执行其余 init 脚本 (非模板 _*.sql), 支持断点续跑 ----
    sql_scan
    confirm "确认执行所有初始化脚本(模式模板除外)?"
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

# 确保数据泵目录对象 oracle_dumps 存在并授权给指定用户 (默认主模式 APP_USER)
#   多模式导入时, 需对目标模式用户单独授权, 否则 impdp 报 ORA-39070
ensure_dump_dir_object() {
    local target_user="${1:-${APP_USER}}"
    log_step "确保数据泵目录对象 oracle_dumps 存在并授权给 ${target_user} (PDB=${PDB_NAME})"
    local sql; sql="$(mktemp /tmp/omf_imp_XXXXXX.sql)"
    {
        echo "ALTER SESSION SET CONTAINER = ${PDB_NAME};"
        echo "CREATE OR REPLACE DIRECTORY oracle_dumps AS '${ORACLE_DUMP_DIR}';"
        echo "GRANT READ, WRITE ON DIRECTORY oracle_dumps TO ${target_user};"
        echo "EXIT"
    } > "$sql"
    chmod 600 "$sql"
    chown "${ORACLE_USER}:${ORACLE_GROUP}" "$sql" 2>/dev/null || true
    as_oracle "sqlplus -s / as sysdba @${sql}" 2>&1 \
        | tee -a "${OMF_HOME}/sql/.logs/imp_dir_$(date '+%Y%m%d_%H%M%S').log" \
        | grep -iE "ORA-|directory|grant" || true
    rm -f "$sql"
}

# 授予用户跨模式导入所需权限 (impdp 以该用户连接并 remap 到其它模式时需要 IMP_FULL_DATABASE)
_grant_import_privs() {
    local u="$1"
    [ -z "$u" ] && return 0
    log_step "授予 ${u} 导入权限 (IMP_FULL_DATABASE, 支持跨模式 remap)"
    local sql; sql="$(mktemp /tmp/omf_imp_XXXXXX.sql)"
    {
        echo "ALTER SESSION SET CONTAINER = ${PDB_NAME};"
        echo "GRANT IMP_FULL_DATABASE TO ${u};"
        echo "GRANT CREATE SESSION TO ${u};"
        echo "EXIT"
    } > "$sql"
    chmod 600 "$sql"
    chown "${ORACLE_USER}:${ORACLE_GROUP}" "$sql" 2>/dev/null || true
    as_oracle "sqlplus -s / as sysdba @${sql}" 2>&1 \
        | grep -iE "ORA-|grant" || true
    rm -f "$sql"
}

# 确保目标模式存在: 若不存在, 按模板自动创建 (幂等)
#   使 omf sql import --schema X 即使未先跑 sql init 也能自举建好用户/表空间
_ensure_schema_exists() {
    local name="$1"
    local tmpl="${SQL_INIT_DIR}/_create_schema.sql"
    [ -f "$tmpl" ] || { log_warn "未找到模式模板 ${tmpl}, 请先 omf sql init 创建模式 ${name}"; return 0; }
    local u ts pw dd
    u=$(omf_schema_user "$name"); ts=$(omf_schema_tablespace "$name")
    pw=$(omf_schema_password "$name"); dd=$(omf_schema_datadir "$name")
    mkdir -p "$dd"; chown "${ORACLE_USER}:${ORACLE_GROUP}" "$dd" 2>/dev/null || true; chmod 750 "$dd"
    log_step "确保模式[${name}]存在 (用户=${u}); 若不存在则按模板创建"
    _sql_run_file "$tmpl" "$u" "$pw" "$ts" "$dd" || \
        log_warn "模式[${name}]创建失败或部分失败, 请检查日志"
}

# 以 imp.par.example 为模板, 用配置值生成持久化 parfile 到 $4
#   $5 目标用户名, $6 目标用户密码 (缺省回退全局 APP_USER/APP_PASSWORD)
sql_import_gen_parfile() {
    local base="$1" remap="$2" ts_remap="$3" out="$4" tgt_user="$5" tgt_pw="$6"
    [ -z "$tgt_user" ] && tgt_user="${APP_USER}"
    [ -z "$tgt_pw" ] && tgt_pw="${APP_PASSWORD}"
    local tmpl="${OMF_HOME}/sql/imp.par.example"
    if [ -f "$tmpl" ]; then
        cp "$tmpl" "$out"
    else
        : > "$out"
    fi
    # 去掉模板里这些 key 的已有行(含注释外的同名行), 统一在末尾重写, 避免重复
    sed -i -E '/^[[:space:]]*userid=/d; /^[[:space:]]*directory=/d; /^[[:space:]]*dumpfile=/d; /^[[:space:]]*logfile=/d; /^[[:space:]]*transform=/d; /^[[:space:]]*remap_schema=/d; /^[[:space:]]*remap_tablespace=/d; /^[[:space:]]*table_exists_action=/d' "$out"
    {
        echo ""
        echo "# ---- 以下由 omf sql import 自动生成 ($(date '+%F %T')) ----"
        echo "userid=${tgt_user}/\"${tgt_pw}\"@//localhost:${LISTENER_PORT}/${PDB_NAME}"
        echo "directory=oracle_dumps"
        echo "dumpfile=${base}"
        echo "logfile=${base}.imp.log"
        echo "transform=oid:n"
        echo "# table_exists_action: 默认 replace(覆盖)——同一库不同时间备份, 结构相同, 直接用本 dump 重建对象并导入;"
        echo "#   如需保留目标已存在数据, 改为 append(追加) 或 skip(跳过已存在对象)"
        echo "table_exists_action=replace"
        [ -n "$remap" ] && echo "remap_schema=${remap}"
        [ -n "$ts_remap" ] && echo "remap_tablespace=${ts_remap}"
    } >> "$out"
    chmod 600 "$out"
    chown "${ORACLE_USER}:${ORACLE_GROUP}" "$out" 2>/dev/null || true
    echo "$out"
}

# 真正执行 impdp + 导入后校验
do_impdp() {
    local parfile="$1" base="$2" tgt_user="${3:-${APP_USER}}"
    log_step "开始导入: ${base} -> 模式 ${tgt_user}@${PDB_NAME}"

    # 覆盖/清空类动作会破坏目标已存在对象及其数据, 必须显式确认
    #   replace/truncate_data 会删/清空已有对象; append/skip/content=metadata_only 不破坏现有数据
    local tea
    tea=$(grep -iE '^[[:space:]]*table_exists_action[[:space:]]*=' "$parfile" 2>/dev/null | tail -1 | sed -E 's/^[^=]*=//I' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$tea" in
        replace|truncate_data)
            confirm "table_exists_action=${tea} 将【覆盖/清空】目标模式 ${tgt_user}@${PDB_NAME} 中已存在的对象及其数据! 确认继续?"
            ;;
    esac

    # impdp 经 as_oracle 以 oracle 用户运行; 持久化 parfile 常落在 root 家目录
    #   (如 /root/OMF), oracle 用户无权访问 -> LRM-00109. 故复制到 oracle 可读写的
    #   /tmp 并改属主; 同时 impdp 本地日志也落到 /tmp, 避免 oracle 写不进 /root/OMF.
    local tmp_par; tmp_par="$(mktemp /tmp/omf_imp_XXXXXX.par)"
    cp -f "$parfile" "$tmp_par"
    chown "${ORACLE_USER}:${ORACLE_GROUP}" "$tmp_par" 2>/dev/null || true
    chmod 600 "$tmp_par"
    local log_dir="/tmp"; mkdir -p "$log_dir"
    local imp_log="${log_dir}/imp_$(date '+%Y%m%d_%H%M%S').log"
    # 终端只显示"非良性跳过"的内容(ORA-31684/39111/39151 已计入下方计数, 无需刷屏);
    # 完整日志(含良性行)仍落盘到 imp_log 供后面解析统计
    #   注意: impdp 在 "completed with errors" 时退出码非 0, 配合 omf.sh 的 set -e + pipefail
    #   会让整条管道非零而直接杀进程, 导致下面的"导入覆盖完成"结论打印不出来.
    #   故管道末尾 || true, 使非零退出不再致命(日志已落盘, 解析不受影响).
    as_oracle "impdp parfile=${tmp_par}" 2>&1 | tee "$imp_log" | grep -vE 'ORA-(31684|39111|39151)' || true
    rm -f "$tmp_par"

    # ---- 解析 impdp 日志: 区分"良性跳过"与"真正失败" ----
    # 同库覆盖场景下, 非表对象(视图/过程/函数/类型/序列)若目标已存在, Data Pump
    # 会报 ORA-31684(已存在) / ORA-39111(依赖对象随基对象跳过) / ORA-39151(表已存在,
    # skip 模式); 这些均属正常, 不代表导入失败. 真正需关注的是除此之外的其它 ORA- 码,
    # 以及 ORA-39082(对象创建后编译失败 -> INVALID).
    local benign='ORA-(31684|39111|39151)'
    local compile='ORA-39082'
    local fatal_cnt skip_cnt comp_cnt tbl_cnt
    fatal_cnt=$(grep -E 'ORA-[0-9]{4,}' "$imp_log" 2>/dev/null | grep -vE "$benign" | grep -vE "$compile" | grep -c 'ORA-' || true)
    skip_cnt=$(grep -cE "$benign" "$imp_log" 2>/dev/null || true)
    comp_cnt=$(grep -cE "$compile" "$imp_log" 2>/dev/null || true)
    tbl_cnt=$(grep -cE '^\. \. imported ' "$imp_log" 2>/dev/null || true)

    if [ "${fatal_cnt:-0}" -gt 0 ]; then
        log_warn "导入完成, 但存在 ${fatal_cnt} 个真正错误(非良性跳过/编译告警), 请检查日志: $imp_log"
    else
        log_info "导入覆盖完成 (无真正错误)"
        log_info "  - 表数据已重新导入: ${tbl_cnt} 张表"
        log_info "  - 非表对象因目标已存在被跳过: ${skip_cnt} 个 (视图/过程/函数/类型/序列; Data Pump 正常行为, 结构一致无需覆盖)"
        [ "${comp_cnt:-0}" -gt 0 ] && log_warn "  - 另有 ${comp_cnt} 个对象创建后编译失败(INVALID), 多为已知的 6 个依赖缺失对象, 详见下方 INVALID 检查"
    fi

    log_step "导入后校验 (模式 ${tgt_user} 对象统计 + INVALID 检查)"
    sql_execute_inline "ALTER SESSION SET CONTAINER = ${PDB_NAME};
SELECT object_type, COUNT(*) FROM dba_objects WHERE owner='${tgt_user}' GROUP BY object_type ORDER BY 1;
SELECT 'INVALID 对象数: '||COUNT(*) FROM dba_objects WHERE owner='${tgt_user}' AND status='INVALID';"
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
    local schema=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --remap)            remap="${2:-}"; shift 2;;
            --remap-tablespace) ts_remap="${2:-}"; shift 2;;
            --schema)           schema="${2:-}"; shift 2;;
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
            echo "用法: omf sql import <dumpfile> [--schema 模式名] [--remap 源模式[:目标模式]] [--remap-tablespace 源TS:目标TS] [--check] [--apply [parfile]]"
            exit 1
        fi
    fi

    # ---- 解析目标模式 (默认主模式 APP_USER) ----
    #   --schema <name> 指定导入到某个已配置模式(如 lsdherp); 框架自动解析其
    #   用户/表空间/密码, 确保该模式存在, 并授予目录与跨模式导入权限。
    local tgt_user tgt_ts tgt_pw
    if [ -n "$schema" ]; then
        tgt_user=$(omf_schema_user "$schema")
        tgt_ts=$(omf_schema_tablespace "$schema")
        tgt_pw=$(omf_schema_password "$schema")
        log_info "目标模式: ${schema} -> 用户=${tgt_user} 表空间=${tgt_ts}"
        # 自举: 若目标用户尚未创建, 按模板自动建好(幂等)
        _ensure_schema_exists "$schema"
        # 确保目标用户有目录读写的权限 (否则 impdp 报 ORA-39070)
        ensure_dump_dir_object "$tgt_user"
        # 授予跨模式 remap 所需权限 (impdp 以该用户连接并 remap 到其它模式)
        _grant_import_privs "$tgt_user"
    else
        tgt_user="$APP_USER"; tgt_ts="$APP_TABLESPACE"; tgt_pw="$APP_PASSWORD"
        ensure_dump_dir_object
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
        do_impdp "$parfile" "$base" "$tgt_user"
        return 0
    fi

    # ---- --check: 生成持久化 parfile + 抽取源模式, 不真正导入 ----
    if [ "$check_only" -eq 1 ]; then
        log_step "检查模式: 生成 parfile 并抽取 dump 中的源模式"
        sql_import_gen_parfile "$base" "$remap" "$ts_remap" "$parfile" "$tgt_user" "$tgt_pw"

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
            if [ -z "$remap" ] && [ "$nsc" -eq 1 ] && [ "$schemas" != "$tgt_user" ]; then
                echo ""
                echo "→ 探测到单一源模式 '$schemas', 已自动写入: remap_schema=${schemas}:${tgt_user}"
                echo "  如需改目标模式, 编辑 parfile 后: omf sql import ${base} --apply"
                sed -i -E '/^[[:space:]]*remap_schema=/d' "$parfile"
                printf 'remap_schema=%s:%s\n' "$schemas" "$tgt_user" >> "$parfile"
            elif [ "$nsc" -gt 1 ]; then
                echo ""
                echo "→ 检测到多个模式, 未自动 remap; 请编辑 parfile 指定 remap_schema"
            fi
        else
            echo "  (未能从 dump 提取模式; 请手动编辑 parfile 指定 remap_schema=源模式:<目标>)"
        fi

        # 探测源表空间 (best-effort), 给出提示
        if [ -n "$tss" ] && [ "$tss" != "$tgt_ts" ]; then
            echo ""
            echo "→ dump 中使用的表空间: $(echo $tss | tr '\n' ' ')"
            echo "  若目标库无该表空间, 建议加: remap_tablespace=<源TS>:${tgt_ts}"
            echo "  例: omf sql import ${base} --remap-tablespace $(echo $tss | head -1):${tgt_ts} --check"
        fi

        echo ""
        log_info "parfile 已生成并保留: $parfile"
        log_info "可直接编辑(端口/用户/密码/remap/表空间)后执行: omf sql import ${base} --apply"
        return 0
    fi

    # ---- 默认: 已知模式, 直接生成 parfile 并导入 ----
    sql_import_gen_parfile "$base" "$remap" "$ts_remap" "$parfile" "$tgt_user" "$tgt_pw"
    do_impdp "$parfile" "$base" "$tgt_user"
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
        echo "DEFINE PDB_NAME     = '${PDB_NAME}'"
        echo "DEFINE ORACLE_SID   = '${ORACLE_SID}'"
        echo "DEFINE APP_USER     = '${app_user}'"
        echo "DEFINE APP_PASSWORD = '${app_pw}'"
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
