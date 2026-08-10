#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF - 数据泵导入 import (从 sql.sh 拆分): sql_import 及 impdp 系列
# 依赖主文件 cmd/sql.sh 的 _sql_run_file (经 source 顺序提供).
#===============================================================================
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
    #   注意: impdp 始终以 tgt_user 连接, 当 --remap 的目标模式 != 连接用户,
    #   或显式 --schema 指定了其它模式时, 该连接用户需 IMP_FULL_DATABASE 才能在
    #   目标模式内建对象; 否则报 ORA-31631/ORA-39149 权限不足. 故统一按条件授权.
    local tgt_user tgt_ts tgt_pw
    tgt_user="$APP_USER"; tgt_ts="$APP_TABLESPACE"; tgt_pw="$APP_PASSWORD"
    if [ -n "$schema" ]; then
        tgt_user=$(omf_schema_user "$schema")
        tgt_ts=$(omf_schema_tablespace "$schema")
        tgt_pw=$(omf_schema_password "$schema")
        log_info "目标模式: ${schema} -> 用户=${tgt_user} 表空间=${tgt_ts}"
        # 自举: 若目标用户尚未创建, 按模板自动建好(幂等)
        _ensure_schema_exists "$schema"
    fi
    # 确保当前连接用户有数据泵目录读写权限 (否则 impdp 报 ORA-39070)
    ensure_dump_dir_object "$tgt_user"
    # 跨模式 remap (目标模式 != 连接用户) 或 --schema 时, 授予 IMP_FULL_DATABASE
    if [ -n "$remap" ] || [ -n "$schema" ]; then
        _grant_import_privs "$tgt_user"
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
