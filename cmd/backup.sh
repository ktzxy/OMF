#!/bin/bash
#===============================================================================
# OMF - 备份管理命令 v2
# 修复: 1) 去掉 require_root (cron 以 oracle 运行) 2) dump 落盘到 backup/dump
#       3) 密码用 parfile 避免泄露 4) 备份失败不删旧备 5) 失败通知
#       6) BACKUP_MODE 配置驱动 (logical|physical|both)
#===============================================================================

cmd_backup() {
    local subcmd="${1:-auto}"
    shift || true

    case "$subcmd" in
        full|logical)  backup_logical "$@";;
        physical)      backup_physical "$@";;
        incr)          backup_incremental "$@";;
        archive)       backup_archive "$@";;
        auto)          backup_auto "$@";;
        schedule)      backup_schedule "$@";;
        list)          backup_list "$@";;
        validate)      backup_validate "$@";;
        restore)       backup_restore "$@";;
        cleanup)       backup_cleanup "$@";;
        *) echo "用法: omf backup {auto|full|physical|incr|archive|schedule|list|validate|restore|cleanup} [-d 天数 | --all] [--all|--root|--pdb a,b]"; exit 1;;
    esac
}

# 确保 OMF_DUMP 目录对象存在 (dump 统一落到 backup/dump)
ensure_dump_dir() {
    ensure_backup_dirs
    as_oracle "
export ORACLE_SID=${ORACLE_SID}
sqlplus -s / as sysdba <<'SQL'
WHENEVER SQLERROR CONTINUE
CREATE OR REPLACE DIRECTORY OMF_DUMP AS '${ORACLE_BACKUP}/dump';
GRANT READ, WRITE ON DIRECTORY OMF_DUMP TO system;
-- 目录对象按容器隔离, 在每个已打开的 PDB 中也创建 OMF_DUMP
BEGIN
    FOR r IN (SELECT name FROM v\$pdbs WHERE open_mode = 'READ WRITE') LOOP
        EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER=' || r.name;
        EXECUTE IMMEDIATE 'CREATE OR REPLACE DIRECTORY OMF_DUMP AS ''${ORACLE_BACKUP}/dump''';
        EXECUTE IMMEDIATE 'GRANT READ, WRITE ON DIRECTORY OMF_DUMP TO system';
    END LOOP;
END;
/
EXIT;
SQL
" 2>&1 | tail -5
}

# RMAN 物理/增量/归档备份的前置条件: 数据库须处于 ARCHIVELOG 模式.
# 若为 NOARCHIVELOG, 直接给出明确指引并退出, 避免让用户面对 RMAN-06149 错误栈.
require_archivelog() {
    local logmode
    logmode=$(as_oracle "echo \"select log_mode from v\\\$database;\" | sqlplus -s / as sysdba" 2>/dev/null)
    if echo "$logmode" | grep -qi 'NOARCHIVELOG'; then
        log_error "数据库处于 NOARCHIVELOG 模式, 无法执行 RMAN 备份。请先开启归档模式: omf db archivelog enable"
    fi
    # 查询失败(既非 ARCHIVELOG 也非 NOARCHIVELOG)时不阻断, 交由 RMAN 自行报错
}

# 解析范围参数 (--all / --root / --pdb <name[,name2]>), 设置全局变量:
#   SCOPE_MODE : all | root | pdb | ""(未指定, 由调用方决定默认)
#   SCOPE_PDBS : 逗号分隔的 PDB 名 (仅 pdb 模式)
#   SCOPE_REST : 去除范围参数后的剩余参数 (供调用方继续解析 --scn/--time 等)
parse_scope() {
    SCOPE_MODE=""
    SCOPE_PDBS=""
    local rest=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)  SCOPE_MODE="all"; shift;;
            --root) SCOPE_MODE="root"; shift;;
            --pdb)  SCOPE_MODE="pdb"; SCOPE_PDBS="${2:-}"; shift 2;;
            *)      rest+=("$1"); shift;;
        esac
    done
    SCOPE_REST=("${rest[@]}")
}

# 根据 SCOPE_MODE/SCOPE_PDBS 输出 RMAN 对象表达式 (DATABASE / DATABASE ROOT / PLUGGABLE DATABASE x,y)
# 供 BACKUP/RESTORE/RECOVER/VALIDATE 拼接使用
scope_clause() {
    case "${SCOPE_MODE:-all}" in
        root) echo "DATABASE ROOT";;
        pdb)  echo "PLUGGABLE DATABASE ${SCOPE_PDBS}";;
        all|"") echo "DATABASE";;
    esac
}

# 配置驱动的自动备份
backup_auto() {
    local mode="${BACKUP_MODE:-both}"
    log_step "按配置 BACKUP_MODE=${mode} 执行备份"
    case "$mode" in
        logical)  backup_logical;;
        physical) backup_physical;;
        both)     backup_logical; backup_physical;;
        *) log_error "未知 BACKUP_MODE: $mode (应为 logical|physical|both)";;
    esac
}

#===============================================================================
# 逻辑备份 (expdp) -> 落盘到 ${ORACLE_BACKUP}/dump
#   默认: 仅配置 PDB_NAME;  --all: 所有 PDB 各导一份;  --pdb a,b: 指定 PDB;  --root: CDB$ROOT
#===============================================================================
backup_logical() {
    require_db_user
    parse_scope "$@"
    ensure_dump_dir

    local log_file="$OMF_RUN_LOG"
    local pdbs=()
    case "${SCOPE_MODE:-single}" in
        all)
            log_step "解析所有 PDB 列表"
            mapfile -t pdbs < <(as_oracle "echo \"set pagesize 0 feedback off heading off
select name from v\\\$pdbs;\" | sqlplus -s / as sysdba" 2>/dev/null \
                | sed 's/[[:space:]]//g' | grep -v '^$')
            # 过滤只读种子 PDB (PDB$SEED): 非业务数据, 其服务通常不向监听器注册,
            # 逻辑备份无意义且必现 ORA-12514, 直接排除避免拖垮整个 --all
            local _f=()
            for _p in "${pdbs[@]}"; do
                if [ "$_p" = "PDB\$SEED" ]; then
                    log_info "跳过种子 PDB ($_p), 无需逻辑备份"
                else
                    _f+=("$_p")
                fi
            done
            pdbs=("${_f[@]}")
            [ "${#pdbs[@]}" -gt 0 ] || log_error "未查询到任何 PDB(已排除种子 PDB\$SEED), 请确认业务 PDB 已打开"
            ;;
        root)
            pdbs=("CDB\$ROOT")
            ;;
        pdb)
            local IFS=','; read -r -a pdbs <<< "$SCOPE_PDBS"
            ;;
        single|"")
            pdbs=("$PDB_NAME")
            ;;
    esac

    for pdb in "${pdbs[@]}"; do
        backup_logical_one "$pdb" "$log_file"
    done
    backup_cleanup_disks "dump" "${BACKUP_RETENTION_DAYS}"
}

# 单个 PDB/CDB$ROOT 的 expdp 全库导出
backup_logical_one() {
    local pdb="$1"; local log_file="$2"
    local ts=$(date '+%Y%m%d_%H%M%S')
    local dump_dir="${ORACLE_BACKUP}/dump"
    # 注意: parfile 路径不能含 PDB 名, 因为 PDB 名可能含 '$' (如 PDB$SEED/CDB$ROOT),
    # 该路径经 as_oracle 多层双引号链后在 oracle 层 '$SEED' 会被当变量展开成空, 导致 LRM-00109.
    # 改用 ts+PID 保证唯一且无 '$'; parfile 内部 DUMPFILE/USERID 仍用 ${pdb} (由 expdp 直接读取, 不经 shell).
    local parfile="/tmp/omf_expdp_${ts}_$$.par"

    local connect
    if [ "$pdb" = "CDB\$ROOT" ]; then
        connect="system/${SYSTEM_PASSWORD}"
    else
        # EZCONNECT: 不依赖 tnsnames 别名, 直接连 PDB 服务名
        connect="system/${SYSTEM_PASSWORD}@//localhost:${LISTENER_PORT}/${pdb}"
    fi

    # 用 parfile 避免密码出现在 ps; 密码含 #/! 等特殊字符时须用双引号包裹 USERID,
    # 否则 Data Pump 会把 # 当作注释导致密码被截断 (ORA-01017)
    cat > "$parfile" << EOF
USERID="${connect}"
DIRECTORY=OMF_DUMP
DUMPFILE=full_${pdb}_${ts}_%U.dmp
LOGFILE=full_${pdb}_${ts}.log
FULL=Y
COMPRESSION=${BACKUP_COMPRESSION}
PARALLEL=${BACKUP_PARALLEL}
FLASHBACK_TIME=SYSTIMESTAMP
CLUSTER=N
EOF
    chown oracle:oinstall "$parfile" 2>/dev/null || true
    chmod 600 "$parfile"

    log_step "逻辑全量备份开始 (expdp -> PDB=${pdb}) -> ${dump_dir}"
    set +e
    as_oracle "expdp parfile=${parfile}" 2>&1 | tee -a "$log_file"
    local rc=${PIPESTATUS[0]}
    set -e

    # 清理临时 parfile (含密码)
    rm -f "$parfile"

    if [ "$rc" -eq 0 ] && grep -qi "successfully completed" "$log_file"; then
        log_info "逻辑全量备份完成 (PDB=${pdb}): ${dump_dir}/full_${pdb}_${ts}_*.dmp"
    else
        send_notification "OMF 逻辑备份失败 (PDB=${pdb})" "日志: $log_file"
        log_error "逻辑备份失败 (PDB=${pdb}), 查看日志: $log_file"
    fi
}

#===============================================================================
# RMAN 增量备份
#===============================================================================
backup_incremental() {
    require_db_user
    parse_scope "$@"
    [ -z "$SCOPE_MODE" ] && SCOPE_MODE="all"   # 物理默认整 CDB
    require_archivelog
    ensure_backup_dirs

    local level="${SCOPE_REST[0]:-1}"
    local ts=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="${ORACLE_BACKUP}/incremental"
    local log_file="$OMF_RUN_LOG"
    local sc=$(scope_clause)

    log_step "RMAN 增量备份 (Level $level, scope=${SCOPE_MODE})"
    set +e
    as_oracle "rman target / <<RMANEOF
CONFIGURE BACKUP OPTIMIZATION ON;
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${BACKUP_RETENTION_DAYS} DAYS;
CONFIGURE DEVICE TYPE DISK PARALLELISM ${BACKUP_PARALLEL};
CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT '${backup_dir}/%d_%T_%s_%p';
RUN {
    BACKUP INCREMENTAL LEVEL ${level} ${sc} PLUS ARCHIVELOG;
    BACKUP CURRENT CONTROLFILE FORMAT '${ORACLE_BACKUP}/controlfile/controlfile_%d_%T_%s';
    BACKUP SPFILE FORMAT '${ORACLE_BACKUP}/spfile/spfile_%d_%T_%s';
}
RMANEOF" 2>&1 | tee "$log_file"
    local rc=${PIPESTATUS[0]}
    set -e

    if [ "$rc" -eq 0 ] && ! grep -qiE "RMAN-[0-9]{5}|ORA-[0-9]{5}" "$log_file"; then
        log_info "RMAN 增量备份完成"
        # 备份成功后才清理 obsolete
        as_oracle "rman target / <<RMANEOF
DELETE NOPROMPT OBSOLETE;
RMANEOF" 2>&1 | tail -3
    else
        send_notification "OMF 增量备份失败" "日志: $log_file"
        log_error "RMAN 增量备份失败, 查看日志: $log_file"
    fi
}

#===============================================================================
# 归档日志备份
#===============================================================================
backup_archive() {
    require_db_user
    parse_scope "$@"
    require_archivelog
    ensure_backup_dirs

    local ts=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="${ORACLE_BACKUP}/archive"
    local log_file="$OMF_RUN_LOG"
    local arch_clause="ARCHIVELOG ALL"
    [ "$SCOPE_MODE" = "pdb" ] && arch_clause="ARCHIVELOG FOR PLUGGABLE DATABASE ${SCOPE_PDBS}"

    log_step "归档日志备份 (scope=${SCOPE_MODE:-all})"
    set +e
    as_oracle "rman target / <<RMANEOF
BACKUP ${arch_clause} FORMAT '${backup_dir}/arch_%d_%T_%s_%p';
RMANEOF" 2>&1 | tee "$log_file"
    local rc=${PIPESTATUS[0]}
    set -e

    [ "$rc" -eq 0 ] && log_info "归档日志备份完成" || \
        { send_notification "OMF 归档备份失败" "日志: $log_file"; log_error "归档备份失败: $log_file"; }
}

#===============================================================================
# 物理备份 (RMAN 全量) -> 失败不删旧备
#===============================================================================
backup_physical() {
    require_db_user
    parse_scope "$@"
    [ -z "$SCOPE_MODE" ] && SCOPE_MODE="all"   # 物理默认整 CDB
    require_archivelog
    ensure_backup_dirs

    local ts=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="${ORACLE_BACKUP}/full"
    local log_file="$OMF_RUN_LOG"
    local sc=$(scope_clause)

    log_step "RMAN 物理全量备份 (scope=${SCOPE_MODE})"
    set +e
    as_oracle "rman target / <<RMANEOF
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${BACKUP_RETENTION_DAYS} DAYS;
CONFIGURE DEVICE TYPE DISK PARALLELISM ${BACKUP_PARALLEL};
CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT '${backup_dir}/%d_%T_%s_%p';
RUN {
    BACKUP AS COMPRESSED BACKUPSET ${sc} PLUS ARCHIVELOG;
    BACKUP CURRENT CONTROLFILE FORMAT '${ORACLE_BACKUP}/controlfile/controlfile_%d_%T_%s';
    BACKUP SPFILE FORMAT '${ORACLE_BACKUP}/spfile/spfile_%d_%T_%s';
}
RMANEOF" 2>&1 | tee "$log_file"
    local rc=${PIPESTATUS[0]}
    set -e

    if [ "$rc" -eq 0 ] && ! grep -qiE "RMAN-[0-9]{5}|ORA-[0-9]{5}" "$log_file"; then
        log_info "RMAN 物理全量备份完成"
        as_oracle "rman target / <<RMANEOF
DELETE NOPROMPT OBSOLETE;
RMANEOF" 2>&1 | tail -3
        backup_cleanup_disks "full" "${BACKUP_RETENTION_DAYS}"
    else
        send_notification "OMF 物理备份失败" "日志: $log_file"
        log_error "RMAN 物理备份失败 (已保留旧备), 查看: $log_file"
    fi
}

#===============================================================================
# 备份列表 (含按保留天数高亮的"即将过期"提示)
#   omf backup list [all|expdp|rman]
#   保留期: BACKUP_RETENTION_DAYS (默认 30); 即将过期阈值: BACKUP_WARN_DAYS
#     (留空则取保留期的 1/5, 钳制在 2~7 天)
#===============================================================================
backup_list() {
    local type="${1:-all}"
    local retention="${BACKUP_RETENTION_DAYS:-30}"
    # 即将过期阈值: 优先 BACKUP_WARN_DAYS, 否则按保留期的 1/5 (钳制 2~7 天)
    local warn_days="${BACKUP_WARN_DAYS:-}"
    if [ -z "$warn_days" ]; then
        warn_days=$(( retention / 5 ))
        [ "$warn_days" -lt 2 ] && warn_days=2
        [ "$warn_days" -gt 7 ] && warn_days=7
    fi
    local now_ts; now_ts=$(date +%s)

    # 计算文件 mtime 距今天数 -> _age
    local _age=0
    _file_age_days() {
        local m; m=$(stat -c %Y "$1" 2>/dev/null) || { _age=0; return; }
        _age=$(( (now_ts - m) / 86400 ))
    }
    # 按剩余天数输出带色标签 (剩余<=0 红, <=warn 黄, 否则绿)
    _retain_tag() {
        local rem="$1"
        if [ "$rem" -le 0 ]; then
            echo -e "${RED}已过期(将清理)${NC}"
        elif [ "$rem" -le "$warn_days" ]; then
            echo -e "${YELLOW}即将过期(剩${rem}天)${NC}"
        else
            echo -e "${GREEN}正常(剩${rem}天)${NC}"
        fi
    }

    echo ""
    echo "========== 备份文件列表 =========="
    echo -e "保留策略: ${BOLD}BACKUP_RETENTION_DAYS=${retention} 天${NC}  |  即将过期: 剩余 ≤ ${warn_days} 天标黄, ≤ 0 天标红"

    if [ "$type" = "all" ] || [ "$type" = "expdp" ]; then
        echo ""; echo "[Expdp 逻辑备份] (${ORACLE_BACKUP}/dump)"
        local any=0 f_name
        shopt -s nullglob
        for f in "${ORACLE_BACKUP}/dump/"*.dmp; do
            any=1
            _file_age_days "$f"
            local rem=$(( retention - _age ))
            f_name="$(basename "$f")"
            printf "  %-46s %6s天前  %s\n" "$f_name" "$_age" "$(_retain_tag "$rem")"
        done
        shopt -u nullglob
        [ "$any" -eq 0 ] && echo "  (空)"
    fi

    if [ "$type" = "all" ] || [ "$type" = "rman" ]; then
        echo ""; echo "[RMAN 备份集]"
        as_oracle "rman target / <<RMANEOF
LIST BACKUP SUMMARY;
RMANEOF" 2>/dev/null || echo "  (无 RMAN 备份)"

        # 即将过期分析: 直接查控制文件中的备份集完成时间
        echo ""; echo "  -- 即将过期分析 (基于 V\$BACKUP_SET) --"
        local sql_out
        sql_out=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT TO_CHAR(completion_time,'YYYY-MM-DD')||'|'||ROUND(SYSDATE-completion_time,1) FROM v\\\$backup_set ORDER BY completion_time;\" | sqlplus -s / as sysdba" 2>/dev/null)
        if [ -z "$sql_out" ]; then
            echo "  (无法连接数据库, 跳过 RMAN 过期分析)"
        else
            local total=0 expired=0 soon=0 line ct age rem tag
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                # 跳过 SQL*Plus 报错/标题行 (不含 '|' 分隔符)
                [[ "$line" == *"|"* ]] || continue
                ct="${line%%|*}"; age="${line##*|}"
                # 规范化年龄: 去前导空格, 补前导零 (如 .1 -> 0.1)
                age=$(printf '%.1f' "$age" 2>/dev/null || echo "$age")
                # age 为小数, 用 awk 做减法得到整数剩余天数
                rem=$(awk "BEGIN{printf \"%d\", $retention - $age}" 2>/dev/null) || rem=0
                [ -z "$rem" ] && rem=0
                total=$((total+1))
                if [ "$rem" -le 0 ]; then expired=$((expired+1)); fi
                if [ "$rem" -le "$warn_days" ]; then
                    soon=$((soon+1))
                    tag=$(_retain_tag "$rem")
                    printf "    %s  年龄%s天  %s\n" "$ct" "$age" "$tag"
                fi
            done <<< "$sql_out"
            echo -e "  备份集总数: ${total}  |  已过期(将清理): ${RED}${expired}${NC}  |  即将过期(≤${warn_days}天): ${YELLOW}${soon}${NC}"
        fi
    fi

    echo ""; echo "[备份目录占用]"
    du -sh "${ORACLE_BACKUP}"/* 2>/dev/null || echo "(空)"
}

#===============================================================================
# 恢复
#   omf backup restore <file>                             逻辑恢复 (impdp)
#   omf backup restore --rman [--scn N] [--time '...']     物理时间点/SCN 恢复
#   omf backup restore --rman --validate                  校验备份可恢复性
#===============================================================================
backup_restore() {
    local arg="$1"
    if [ "$arg" = "--rman" ]; then
        shift
        restore_rman "$@"
        return
    fi
    if [ -z "$arg" ]; then
        echo "用法:"
        echo "  omf backup restore <dumpfile> [--pdb <PDB>]                  逻辑恢复(impdp)"
        echo "  omf backup restore --rman [--all|--root|--pdb a,b] [--scn <SCN>] [--time 'YYYY-MM-DD HH24:MI:SS']  物理恢复"
        echo "  omf backup restore --rman [--all|--root|--pdb a,b] --validate 校验备份可恢复性"
        echo ""
        echo "可用逻辑备份:"
        ls -1 "${ORACLE_BACKUP}/dump/"*.dmp 2>/dev/null || echo "(无)"
        exit 1
    fi
    restore_logical "$@"
}

# 逻辑恢复 (impdp 全库 REPLACE)
#   用法: omf backup restore <dump> [--pdb <name>]
#   默认恢复到配置 PDB_NAME; --pdb 指定恢复到目标 PDB
restore_logical() {
    local dump_arg="" pdb=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pdb) pdb="$2"; shift 2;;
            *)     dump_arg="$1"; shift;;
        esac
    done
    local dump_file="$dump_arg"
    local dump_basename="$(basename "$dump_arg")"

    # %U 是 Data Pump 并行分片通配符, 磁盘上无真实文件, 跳过存在性检查
    if [[ "$dump_basename" != *%U* ]]; then
        [ -f "$dump_file" ] || dump_file="${ORACLE_BACKUP}/dump/${dump_basename}"
        [ -f "$dump_file" ] || log_error "备份文件不存在: $dump_file"
    fi

    # 自动处理并行分片: 传任意一个具体分片(如 _01.dmp)时, 若同批次存在多个分片,
    # 自动改写为 %U 形式, 让 impdp 读入完整备份集, 避免只恢复单个分片导致数据不全
    if [[ "$dump_basename" != *%U* ]]; then
        local prefix="${dump_basename%_[0-9]*.dmp}"
        if [ "$prefix" != "$dump_basename" ]; then
            local shards
            shards=$(ls -1 "${ORACLE_BACKUP}/dump/${prefix}"_*.dmp 2>/dev/null | wc -l)
            if [ "$shards" -gt 1 ]; then
                dump_basename="${prefix}_%U.dmp"
                log_info "检测到 ${shards} 个并行分片, 自动改用 %U 形式: ${dump_basename}"
            fi
        fi
    fi

    [ -z "$pdb" ] && pdb="$PDB_NAME"

    confirm "确认逻辑恢复 ${dump_file} -> PDB=${pdb}? 这将覆盖现有数据!"
    log_step "开始逻辑恢复: $dump_file -> PDB=${pdb}"
    ensure_dump_dir

    local connect
    if [ "$pdb" = "CDB\$ROOT" ]; then
        connect="system/${SYSTEM_PASSWORD}"
    else
        connect="system/${SYSTEM_PASSWORD}@//localhost:${LISTENER_PORT}/${pdb}"
    fi

    local parfile="/tmp/omf_impdp.par"
    cat > "$parfile" << EOF
USERID="${connect}"
DIRECTORY=OMF_DUMP
DUMPFILE=${dump_basename}
FULL=Y
TABLE_EXISTS_ACTION=REPLACE
PARALLEL=${BACKUP_PARALLEL}
EOF
    chown oracle:oinstall "$parfile" 2>/dev/null || true
    chmod 600 "$parfile"
    set +e
    local restore_log="${ORACLE_BACKUP}/dump/restore_$(date +%Y%m%d_%H%M%S).log"
    as_oracle "impdp parfile=${parfile}" 2>&1 | tee "$restore_log"
    local rc=${PIPESTATUS[0]}
    set -e
    rm -f "$parfile"

    if [ "$rc" -eq 0 ]; then
        log_info "逻辑恢复完成 (PDB=${pdb})"
    else
        # impdp 把"对象已存在"(ORA-31684)也计入 error, 但属非致命, 不影响数据导入
        # 若日志中除 ORA-31684 外无其他 ORA- 错误, 视为恢复成功(仅告警)
        local fatal
        # 注意: 当日志全是 ORA-31684 时, grep -v 排除后管道返回非0, 在 set -e 下会误杀脚本,
        # 故加 || true 保证赋值语句始终成功
        fatal=$(grep -E "ORA-[0-9]{5}" "$restore_log" 2>/dev/null | grep -v "ORA-31684" | head -1) || true
        if [ -z "$fatal" ]; then
            log_info "逻辑恢复完成 (PDB=${pdb}), 仅存在'对象已存在'(ORA-31684)提示, 不影响数据"
        else
            log_error "逻辑恢复失败, 查看日志: $restore_log"
        fi
    fi
}

# 物理恢复 (RMAN): 支持 SCN / 时间点 不完全恢复, 或完全恢复
restore_rman() {
    require_db_user
    parse_scope "$@"
    [ -z "$SCOPE_MODE" ] && SCOPE_MODE="all"
    local sc=$(scope_clause)

    local scn="" rman_time="" validate=0
    local i=0
    while [[ $i -lt ${#SCOPE_REST[@]} ]]; do
        case "${SCOPE_REST[$i]}" in
            --scn)        scn="${SCOPE_REST[$((i+1))]}"; i=$((i+2));;
            --time|--until-time) rman_time="${SCOPE_REST[$((i+1))]}"; i=$((i+2));;
            --validate)   validate=1; i=$((i+1));;
            *)            i=$((i+1));;
        esac
    done

    # 仅校验: 不修改数据库, 检查备份集完整性
    if [ "$validate" -eq 1 ]; then
        log_step "校验备份可恢复性 (RESTORE VALIDATE, scope=${SCOPE_MODE})"

        # 前置判断: 无任何 RMAN 备份集时, 直接提示并退出, 避免把 RMAN 错误栈暴露给用户
        local rman_list
        rman_list=$(as_oracle "rman target / <<RMANEOF
LIST BACKUP SUMMARY;
RMANEOF" 2>&1) || true
        if ! echo "$rman_list" | grep -qiE "BS Key|List of Backup"; then
            log_warn "无备份可校验: 未检测到任何 RMAN 备份集"
            echo "  请先创建备份后再校验, 例如:"
            echo "    omf backup physical      # RMAN 物理全量备份"
            echo "    omf backup auto          # 按 BACKUP_MODE 配置执行"
            exit 2
        fi

        as_oracle "rman target / <<RMANEOF
RESTORE ${sc} VALIDATE;
RESTORE ARCHIVELOG ALL VALIDATE;
RMANEOF"
        return 0
    fi

    local until_clause=""
    if [ -n "$scn" ]; then
        until_clause="SET UNTIL SCN $scn;"
    elif [ -n "$rman_time" ]; then
        until_clause="SET UNTIL TIME \"TO_DATE('$rman_time','YYYY-MM-DD HH24:MI:SS')\";"
    fi

    # PDB 级恢复需先将目标 PDB 置于 MOUNT
    local pre_sql=""
    if [ "$SCOPE_MODE" = "pdb" ]; then
        pre_sql="sql 'alter pluggable database ${SCOPE_PDBS} close immediate';
    sql 'alter pluggable database ${SCOPE_PDBS} mount';"
    fi

    if [ -z "$until_clause" ]; then
        log_warn "未指定 --scn/--time, 将执行【完全恢复】到最新归档 (不 OPEN RESETLOGS)"
    else
        log_warn "将执行【不完全恢复】${until_clause}"
    fi
    log_warn "恢复范围: ${SCOPE_MODE}$([ "$SCOPE_MODE" = "pdb" ] && echo " (${SCOPE_PDBS})")"

    confirm "确认执行物理恢复? 这将用备份覆盖当前数据文件!"

    log_step "执行物理恢复 (RESTORE + RECOVER)..."
    set +e
    as_oracle "rman target / <<RMANEOF
RUN {
    ${pre_sql}
    ${until_clause}
    RESTORE ${sc};
    RECOVER ${sc};
}
RMANEOF"
    local rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        if [ "$SCOPE_MODE" = "pdb" ]; then
            log_info "PDB 恢复完成. 打开 PDB: ALTER PLUGGABLE DATABASE ${SCOPE_PDBS} OPEN;"
        elif [ -n "$until_clause" ]; then
            log_info "不完全恢复完成. 需以 RESETLOGS 打开: ALTER DATABASE OPEN RESETLOGS;"
        else
            log_info "完全恢复完成. 可直接 ALTER DATABASE OPEN; (或 STARTUP)"
        fi
    else
        log_error "物理恢复失败 (rc=$rc), 查看上方 RMAN 输出"
    fi
}

#===============================================================================
# 备份可恢复性校验 (演练前必做)
#===============================================================================
backup_validate() {
    require_db_user
    parse_scope "$@"
    [ -z "$SCOPE_MODE" ] && SCOPE_MODE="all"
    local sc=$(scope_clause)
    log_step "备份可恢复性校验 (scope=${SCOPE_MODE})"

    # 前置判断: 无任何 RMAN 备份集时, 直接提示并退出, 避免把 RMAN 错误栈暴露给用户
    local rman_list
    rman_list=$(as_oracle "rman target / <<RMANEOF
LIST BACKUP SUMMARY;
RMANEOF" 2>&1) || true
    if ! echo "$rman_list" | grep -qiE "BS Key|List of Backup"; then
        log_warn "无备份可校验: 未检测到任何 RMAN 备份集"
        echo "  请先创建备份后再校验, 例如:"
        echo "    omf backup physical      # RMAN 物理全量备份"
        echo "    omf backup auto          # 按 BACKUP_MODE 配置执行"
        exit 2
    fi

    as_oracle "rman target / <<RMANEOF
RESTORE ${sc} VALIDATE;
RESTORE ARCHIVELOG ALL VALIDATE;
RMANEOF"

    echo ""
    echo "逻辑备份文件:"
    ls -lht "${ORACLE_BACKUP}/dump/"*.dmp 2>/dev/null || echo "(无逻辑备份)"
}

#===============================================================================
# 内部清理: 删除指定子目录下 N 天前的 .dmp/.log (无交互确认, 供备份后自动清理)
# 注意: 与 lib/common.sh 的 backup_cleanup (支持 --all/-d 的交互式清理) 区分,
#       本函数仅作备份成功后的"顺手清旧"使用, 不会被 omf backup cleanup 调用.
#===============================================================================
backup_cleanup_disks() {
    local type="${1:-dump}"
    local days="${2:-30}"
    # 注意: find -mtime +N 实际删 (N+1) 天前, 故用 +(days-1) 实现"保留 days 天"
    log_debug "清理 ${days} 天前的 ${type} 备份"
    find "${ORACLE_BACKUP}/${type}" -name "*.dmp" -mtime "+$((days-1))" -delete 2>/dev/null || true
    find "${ORACLE_BACKUP}/${type}" -name "*.log" -mtime "+$((days-1))" -delete 2>/dev/null || true
}

#===============================================================================
# 配置定时备份 (按 BACKUP_MODE 生成)
#===============================================================================
backup_schedule() {
    local action="${1:-show}"
    case "$action" in
        setup|remove) require_root;;
    esac
    case "$action" in
        setup)
            local mode="${BACKUP_MODE:-both}"
            {
                echo "# OMF 备份定时任务 (BACKUP_MODE=${mode})"
                echo "0 2 * * * oracle ${OMF_HOME}/omf.sh backup auto >> ${OMF_HOME}/logs/omf_backup.log 2>&1"
                echo "0 */4 * * * oracle ${OMF_HOME}/omf.sh backup archive >> ${OMF_HOME}/logs/omf_backup.log 2>&1"
            } > /etc/cron.d/omf_backup
            chmod 644 /etc/cron.d/omf_backup
            systemctl restart crond 2>/dev/null || service cron restart 2>/dev/null || true
            log_info "定时备份已配置 (BACKUP_MODE=${mode})"
            cat /etc/cron.d/omf_backup
            ;;
        show)
            [ -f /etc/cron.d/omf_backup ] && cat /etc/cron.d/omf_backup \
                || echo "未配置, 执行 'omf backup schedule setup'"
            ;;
        remove) rm -f /etc/cron.d/omf_backup; log_info "定时备份已移除";;
        *) echo "用法: omf backup schedule {setup|show|remove}";;
    esac
}
