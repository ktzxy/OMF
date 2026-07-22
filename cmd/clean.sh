#!/bin/bash
#===============================================================================
# OMF - 定时清理命令
# 用法: omf clean <subcommand> [-d 天数 | --all] [--yes]
#
# 两种模式 (对所有子命令统一):
#   -d N / --days N   清理 N 天前的数据 (默认取配置中的保留天数)
#   --all / -a        清理【全部】(不按天数), 高风险操作需确认
# 子命令: logs | trace | audit | archive | backup | all | schedule
#===============================================================================

cmd_clean() {
    local subcmd="all"
    CLEAN_DAYS=""
    CLEAN_ALL="false"
    local -a rest=()
    # 兼容 "omf clean logs -d 7" 与 "omf clean -d 7 logs" 两种顺序
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--days) CLEAN_DAYS="${2:-}"; shift 2;;
            --all|-a|--force) CLEAN_ALL="true"; shift;;
            -y|--yes) shift;;
            -*) shift;;                 # 忽略其它未知选项
            *)  # 第一个非选项参数即为子命令
                [ "$subcmd" = "all" ] && subcmd="$1"
                rest+=("$1"); shift;;
        esac
    done
    export CLEAN_DAYS CLEAN_ALL

    case "$subcmd" in
        logs)      clean_logs;;
        trace)     clean_trace;;
        audit)     clean_audit;;
        archive)   clean_archive;;
        backup)    backup_cleanup;;       # 实现位于 lib/common.sh, 与 omf backup cleanup 共用
        all)       clean_all;;
        schedule)  clean_schedule "${rest[@]}";;
        *)
            echo "用法: omf clean {logs|trace|audit|archive|backup|all|schedule} [-d 天数 | --all]"
            exit 1
            ;;
    esac
}

#===============================================================================
# 清理日志 (OMF 运行日志 / alert 备份 / tmp 安装日志)
#===============================================================================
clean_logs() {
    if [ "${CLEAN_ALL:-false}" = "true" ]; then
        confirm "确认清理【全部】OMF 日志? (所有运行日志 / alert 备份 / tmp 安装日志)"
        log_step "清理全部 OMF 日志 (--all)"
        find "${OMF_HOME}/logs" -name "*.log" -delete 2>/dev/null || true
        find "${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms" -name "alert_*.bak" -delete 2>/dev/null || true
        find /tmp -name "oracle_install*" -delete 2>/dev/null || true
        find /tmp -name "dbca_*" -delete 2>/dev/null || true
        log_info "日志清理完成 (全部)"
        return
    fi

    local days="${CLEAN_DAYS:-${OMF_CONFIG[LOG_RETENTION_DAYS]:-30}}"
    log_step "清理 ${days} 天前的日志文件"
    find "${OMF_HOME}/logs" -name "*.log" -mtime "+${days}" -delete 2>/dev/null || true
    find "${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms" -name "alert_*.bak" -mtime "+${days}" -delete 2>/dev/null || true
    find /tmp -name "oracle_install*" -mtime "+${days}" -delete 2>/dev/null || true
    find /tmp -name "dbca_*" -mtime "+${days}" -delete 2>/dev/null || true
    log_info "日志清理完成 (${days} 天前)"
}

#===============================================================================
# 清理 trace 文件
#===============================================================================
clean_trace() {
    local days="${CLEAN_DAYS:-${OMF_CONFIG[TRACE_RETENTION_DAYS]:-30}}"
    [ "${CLEAN_ALL:-false}" = "true" ] && days=0

    local trace_dir="${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms/${OMF_CONFIG[ORACLE_SID]}/${OMF_CONFIG[ORACLE_SID]}/trace"

    if [ -d "$trace_dir" ]; then
        if [ "$days" -eq 0 ]; then
            confirm "确认清理【全部】trace 文件? (${trace_dir})"
            log_step "清理全部 trace 文件"
            find "$trace_dir" -name "*.trc" -delete 2>/dev/null || true
            find "$trace_dir" -name "*.trm" -delete 2>/dev/null || true
            find "$trace_dir" -name "cdmp_*" -exec rm -rf {} \; 2>/dev/null || true
        else
            log_step "清理 ${days} 天前的 trace 文件"
            find "$trace_dir" -name "*.trc" -mtime "+${days}" -delete 2>/dev/null || true
            find "$trace_dir" -name "*.trm" -mtime "+${days}" -delete 2>/dev/null || true
            find "$trace_dir" -name "cdmp_*" -mtime "+${days}" -exec rm -rf {} \; 2>/dev/null || true
        fi
        local after_size
        after_size=$(du -sh "$trace_dir" 2>/dev/null | cut -f1)
        log_info "Trace 清理完成: ${after_size}"
    else
        log_warn "Trace 目录不存在: $trace_dir"
    fi
}

#===============================================================================
# 清理审计文件
#===============================================================================
clean_audit() {
    local days="${CLEAN_DAYS:-${OMF_CONFIG[AUDIT_RETENTION_DAYS]:-30}}"
    [ "${CLEAN_ALL:-false}" = "true" ] && days=0

    local audit_dir="${OMF_CONFIG[ORACLE_BASE]}/admin/${OMF_CONFIG[ORACLE_SID]}/adump"
    local xml_audit_dir="${OMF_CONFIG[ORACLE_BASE]}/audit/${OMF_CONFIG[ORACLE_SID]}"

    if [ "$days" -eq 0 ]; then
        confirm "确认清理【全部】审计文件?"
        log_step "清理全部审计文件"
        [ -d "$audit_dir" ] && find "$audit_dir" -name "*.aud" -delete 2>/dev/null || true
        [ -d "$xml_audit_dir" ] && find "$xml_audit_dir" -name "*.xml" -delete 2>/dev/null || true
        log_info "审计文件清理完成 (全部)"
    else
        log_step "清理 ${days} 天前的审计文件"
        [ -d "$audit_dir" ] && find "$audit_dir" -name "*.aud" -mtime "+${days}" -delete 2>/dev/null || true
        [ -d "$xml_audit_dir" ] && find "$xml_audit_dir" -name "*.xml" -mtime "+${days}" -delete 2>/dev/null || true
        log_info "审计文件清理完成 (${days} 天前)"
    fi
}

#===============================================================================
# 清理过期归档日志
#===============================================================================
clean_archive() {
    local retention="${CLEAN_DAYS:-${OMF_CONFIG[BACKUP_RETENTION_DAYS]:-30}}"
    [ "${CLEAN_ALL:-false}" = "true" ] && retention=0

    if [ "$retention" -eq 0 ]; then
        confirm "确认清理【全部】归档日志? (将删除所有归档, 影响可恢复性)"
        log_step "清理全部归档日志 (--all)"
    else
        log_step "清理 ${retention} 天前的归档日志"
    fi

    # 检查是否在归档模式
    local arch_status
    arch_status=$(oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
echo \"select log_mode from v\\\$database;\" | sqlplus -s / as sysdba | grep -i 'ARCHIVELOG'
" 2>/dev/null)

    if [ -z "$arch_status" ]; then
        log_warn "数据库不在归档模式，跳过"
        return
    fi

    if [ "$retention" -eq 0 ]; then
        oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
rman target / <<RMANEOF
DELETE NOPROMPT ARCHIVELOG ALL;
DELETE NOPROMPT OBSOLETE;
RMANEOF
" 2>&1 | tail -10
    else
        oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
rman target / <<RMANEOF
DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-${retention}';
DELETE NOPROMPT OBSOLETE;
RMANEOF
" 2>&1 | tail -10
    fi

    log_info "归档日志清理完成"
}

#===============================================================================
# 全面清理 (各分类按保留天数; 配合 --all 则全部删除)
#===============================================================================
clean_all() {
    log_step "========== 全面清理 =========="

    clean_logs
    clean_trace
    clean_audit
    clean_archive

    # 清理监听器日志
    if [ -f "${OMF_CONFIG[ORACLE_BASE]}/diag/tnslsnr/$(hostname)/listener/trace/listener.log" ]; then
        > "${OMF_CONFIG[ORACLE_BASE]}/diag/tnslsnr/$(hostname)/listener/trace/listener.log"
        log_info "监听器日志已清空"
    fi

    # 清理回收站
    oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<'SQL'
PURGE DBA_RECYCLEBIN;
EXIT;
SQL
" 2>/dev/null
    log_info "回收站已清空"

    echo ""
    log_info "全面清理完成!"
}

#===============================================================================
# 配置定时清理
#===============================================================================
clean_schedule() {
    require_root
    local action="${1:-show}"

    case "$action" in
        setup)
            cat > /etc/cron.d/omf_clean << EOF
# OMF 定时清理任务
# 每天凌晨 4:00 - 清理日志和 trace (按保留天数)
0 4 * * * oracle ${OMF_HOME}/omf.sh clean all >> ${OMF_HOME}/logs/omf_clean_cron.log 2>&1

# 每周日凌晨 5:00 - 清理过期归档
0 5 * * 0 oracle ${OMF_HOME}/omf.sh clean archive >> ${OMF_HOME}/logs/omf_clean_cron.log 2>&1
EOF
            chmod 644 /etc/cron.d/omf_clean
            systemctl restart crond 2>/dev/null || service cron restart 2>/dev/null || true
            log_info "定时清理已配置"
            echo ""
            cat /etc/cron.d/omf_clean
            ;;
        show)
            if [ -f /etc/cron.d/omf_clean ]; then
                cat /etc/cron.d/omf_clean
            else
                echo "未配置定时清理，执行 'omf clean schedule setup' 来配置"
            fi
            ;;
        remove)
            rm -f /etc/cron.d/omf_clean
            log_info "定时清理已移除"
            ;;
        *)
            echo "用法: omf clean schedule {setup|show|remove}"
            ;;
    esac
}
