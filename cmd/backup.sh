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
        *) echo "用法: omf backup {auto|full|physical|incr|archive|schedule|list|validate|restore}"; exit 1;;
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
EXIT;
SQL
" 2>&1 | tail -3
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
# 逻辑备份 (expdp 全库) -> 落盘到 ${ORACLE_BACKUP}/dump
#===============================================================================
backup_logical() {
    require_db_user
    ensure_dump_dir

    local ts=$(date '+%Y%m%d_%H%M%S')
    local dump_dir="${ORACLE_BACKUP}/dump"
    local parfile="/tmp/omf_expdp_${ts}.par"
    local log_file="$OMF_RUN_LOG"

    # 用 parfile 避免密码出现在 ps
    cat > "$parfile" << EOF
USERID=system/${SYSTEM_PASSWORD}@${PDB_NAME}
DIRECTORY=OMF_DUMP
DUMPFILE=full_${ts}_%U.dmp
LOGFILE=full_${ts}.log
FULL=Y
COMPRESSION=${BACKUP_COMPRESSION}
PARALLEL=${BACKUP_PARALLEL}
FLASHBACK_TIME=SYSTIMESTAMP
CLUSTER=N
EOF
    chown oracle:oinstall "$parfile" 2>/dev/null || true
    chmod 600 "$parfile"

    log_step "逻辑全量备份开始 (expdp) -> ${dump_dir}"
    set +e
    as_oracle "expdp parfile=${parfile}" 2>&1 | tee -a "$log_file"
    local rc=${PIPESTATUS[0]}
    set -e

    # 清理临时 parfile (含密码)
    rm -f "$parfile"

    if [ "$rc" -eq 0 ] && grep -qi "successfully completed" "$log_file"; then
        log_info "逻辑全量备份完成: ${dump_dir}/full_${ts}_*.dmp"
        backup_cleanup "dump" "${BACKUP_RETENTION_DAYS}"
    else
        send_notification "OMF 逻辑备份失败" "日志: $log_file"
        log_error "逻辑备份失败, 查看日志: $log_file"
    fi
}

#===============================================================================
# RMAN 增量备份
#===============================================================================
backup_incremental() {
    require_db_user
    require_archivelog
    ensure_backup_dirs

    local level="${1:-1}"
    local ts=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="${ORACLE_BACKUP}/incremental"
    local log_file="$OMF_RUN_LOG"

    log_step "RMAN 增量备份 (Level $level)"
    set +e
    as_oracle "rman target / <<RMANEOF
CONFIGURE BACKUP OPTIMIZATION ON;
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${BACKUP_RETENTION_DAYS} DAYS;
CONFIGURE DEVICE TYPE DISK PARALLELISM ${BACKUP_PARALLEL};
CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT '${backup_dir}/%d_%T_%s_%p';
RUN {
    BACKUP INCREMENTAL LEVEL ${level} DATABASE PLUS ARCHIVELOG;
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
    require_archivelog
    ensure_backup_dirs

    local ts=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="${ORACLE_BACKUP}/archive"
    local log_file="$OMF_RUN_LOG"

    log_step "归档日志备份"
    set +e
    as_oracle "rman target / <<RMANEOF
BACKUP ARCHIVELOG ALL FORMAT '${backup_dir}/arch_%d_%T_%s_%p';
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
    require_archivelog
    ensure_backup_dirs

    local ts=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="${ORACLE_BACKUP}/full"
    local log_file="$OMF_RUN_LOG"

    log_step "RMAN 物理全量备份"
    set +e
    as_oracle "rman target / <<RMANEOF
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${BACKUP_RETENTION_DAYS} DAYS;
CONFIGURE DEVICE TYPE DISK PARALLELISM ${BACKUP_PARALLEL};
CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT '${backup_dir}/%d_%T_%s_%p';
RUN {
    BACKUP AS COMPRESSED BACKUPSET DATABASE PLUS ARCHIVELOG;
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
        backup_cleanup "full" "${BACKUP_RETENTION_DAYS}"
    else
        send_notification "OMF 物理备份失败" "日志: $log_file"
        log_error "RMAN 物理备份失败 (已保留旧备), 查看: $log_file"
    fi
}

#===============================================================================
# 备份列表
#===============================================================================
backup_list() {
    local type="${1:-all}"
    echo ""
    echo "========== 备份文件列表 =========="
    if [ "$type" = "all" ] || [ "$type" = "expdp" ]; then
        echo ""; echo "[Expdp 备份]"
        ls -lht "${ORACLE_BACKUP}/dump/"*.dmp 2>/dev/null || echo '(空)'
    fi
    if [ "$type" = "all" ] || [ "$type" = "rman" ]; then
        echo ""; echo "[RMAN 备份]"
        as_oracle "rman target / <<RMANEOF
LIST BACKUP SUMMARY;
RMANEOF" 2>/dev/null || echo "(无 RMAN 备份)"
    fi
    echo ""; echo "[备份目录]"
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
        echo "  omf backup restore <dumpfile>                                 逻辑恢复(impdp)"
        echo "  omf backup restore --rman [--scn <SCN>] [--time 'YYYY-MM-DD HH24:MI:SS']  物理恢复"
        echo "  omf backup restore --rman --validate                          校验备份可恢复性"
        echo ""
        echo "可用逻辑备份:"
        ls -1 "${ORACLE_BACKUP}/dump/"*.dmp 2>/dev/null || echo "(无)"
        exit 1
    fi
    restore_logical "$arg"
}

# 逻辑恢复 (impdp 全库 REPLACE)
restore_logical() {
    local dump_file="$1"
    [ -f "$dump_file" ] || dump_file="${ORACLE_BACKUP}/dump/$(basename "$dump_file")"
    [ -f "$dump_file" ] || log_error "备份文件不存在: $dump_file"

    confirm "确认逻辑恢复 ${dump_file}? 这将覆盖现有数据!"
    log_step "开始逻辑恢复: $dump_file"
    ensure_dump_dir

    local parfile="/tmp/omf_impdp.par"
    cat > "$parfile" << EOF
USERID=system/${SYSTEM_PASSWORD}@${PDB_NAME}
DIRECTORY=OMF_DUMP
DUMPFILE=$(basename "$dump_file")
FULL=Y
TABLE_EXISTS_ACTION=REPLACE
PARALLEL=${BACKUP_PARALLEL}
EOF
    chmod 600 "$parfile"
    set +e
    as_oracle "impdp parfile=${parfile}" 2>&1 | tee "${ORACLE_BACKUP}/dump/restore_$(date +%Y%m%d_%H%M%S).log"
    local rc=${PIPESTATUS[0]}
    set -e
    rm -f "$parfile"
    [ "$rc" -eq 0 ] && log_info "逻辑恢复完成" || log_error "逻辑恢复失败, 查看上方日志"
}

# 物理恢复 (RMAN): 支持 SCN / 时间点 不完全恢复, 或完全恢复
restore_rman() {
    require_db_user
    local scn="" rman_time="" validate=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scn)        scn="$2"; shift 2;;
            --time|--until-time) rman_time="$2"; shift 2;;
            --validate)   validate=1; shift;;
            *) shift;;
        esac
    done

    # 仅校验: 不修改数据库, 检查备份集完整性
    if [ "$validate" -eq 1 ]; then
        log_step "校验备份可恢复性 (RESTORE VALIDATE)"

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
RESTORE DATABASE VALIDATE;
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

    if [ -z "$until_clause" ]; then
        log_warn "未指定 --scn/--time, 将执行【完全恢复】到最新归档 (不 OPEN RESETLOGS)"
    else
        log_warn "将执行【不完全恢复】${until_clause}"
    fi

    confirm "确认执行物理恢复? 这将用备份覆盖当前数据文件!"

    log_step "执行物理恢复 (RESTORE + RECOVER)..."
    set +e
    as_oracle "rman target / <<RMANEOF
RUN {
    ${until_clause}
    RESTORE DATABASE;
    RECOVER DATABASE;
}
RMANEOF"
    local rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        if [ -n "$until_clause" ]; then
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
    log_step "备份可恢复性校验"

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
RESTORE DATABASE VALIDATE;
RESTORE ARCHIVELOG ALL VALIDATE;
RMANEOF"

    echo ""
    echo "逻辑备份文件:"
    ls -lht "${ORACLE_BACKUP}/dump/"*.dmp 2>/dev/null || echo "(无逻辑备份)"
}

#===============================================================================
# 清理过期备份
#===============================================================================
backup_cleanup() {
    local type="${1:-dump}"
    local days="${2:-30}"
    log_debug "清理 ${days} 天前的 ${type} 备份"
    find "${ORACLE_BACKUP}/${type}" -name "*.dmp" -mtime "+${days}" -delete 2>/dev/null || true
    find "${ORACLE_BACKUP}/${type}" -name "*.log" -mtime "+${days}" -delete 2>/dev/null || true
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
                echo "0 2 * * * oracle ${OMF_HOME}/omf.sh backup auto >> /var/log/omf_backup.log 2>&1"
                echo "0 */4 * * * oracle ${OMF_HOME}/omf.sh backup archive >> /var/log/omf_backup.log 2>&1"
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
