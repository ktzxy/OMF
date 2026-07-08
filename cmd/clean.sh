#!/bin/bash
#===============================================================================
# OMF - 定时清理命令
# 用法: omf clean <subcommand> [options]
#===============================================================================

cmd_clean() {
    local subcmd="${1:-all}"
    shift || true

    case "$subcmd" in
        logs)
            clean_logs "$@"
            ;;
        trace)
            clean_trace "$@"
            ;;
        audit)
            clean_audit "$@"
            ;;
        archive)
            clean_archive "$@"
            ;;
        all)
            clean_all "$@"
            ;;
        schedule)
            clean_schedule "$@"
            ;;
        *)
            echo "用法: omf clean {logs|trace|audit|archive|all|schedule}"
            exit 1
            ;;
    esac
}

#===============================================================================
# 清理日志
#===============================================================================
clean_logs() {
    local days="${1:-${OMF_CONFIG[LOG_RETENTION_DAYS]}}"
    log_step "清理 ${days} 天前的日志文件"

    # OMF 日志
    find "${OMF_HOME}/logs" -name "*.log" -mtime "+${days}" -delete 2>/dev/null || true

    # Alert 日志备份
    find "${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms" -name "alert_*.bak" -mtime "+${days}" -delete 2>/dev/null || true

    # 安装日志
    find /tmp -name "oracle_install*" -mtime "+${days}" -delete 2>/dev/null || true
    find /tmp -name "dbca_*" -mtime "+${days}" -delete 2>/dev/null || true

    log_info "日志清理完成"
}

#===============================================================================
# 清理 trace 文件
#===============================================================================
clean_trace() {
    local days="${1:-${OMF_CONFIG[TRACE_RETENTION_DAYS]}}"
    log_step "清理 ${days} 天前的 trace 文件"

    local trace_dir="${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms/${OMF_CONFIG[ORACLE_SID]}/${OMF_CONFIG[ORACLE_SID]}/trace"

    if [ -d "$trace_dir" ]; then
        local before_size
        before_size=$(du -sh "$trace_dir" 2>/dev/null | cut -f1)

        find "$trace_dir" -name "*.trc" -mtime "+${days}" -delete 2>/dev/null || true
        find "$trace_dir" -name "*.trm" -mtime "+${days}" -delete 2>/dev/null || true
        find "$trace_dir" -name "cdmp_*" -mtime "+${days}" -exec rm -rf {} \; 2>/dev/null || true

        local after_size
        after_size=$(du -sh "$trace_dir" 2>/dev/null | cut -f1)

        log_info "Trace 清理完成: ${before_size} -> ${after_size}"
    else
        log_warn "Trace 目录不存在: $trace_dir"
    fi
}

#===============================================================================
# 清理审计文件
#===============================================================================
clean_audit() {
    local days="${1:-${OMF_CONFIG[AUDIT_RETENTION_DAYS]}}"
    log_step "清理 ${days} 天前的审计文件"

    local audit_dir="${OMF_CONFIG[ORACLE_BASE]}/admin/${OMF_CONFIG[ORACLE_SID]}/adump"

    if [ -d "$audit_dir" ]; then
        local count
        count=$(find "$audit_dir" -name "*.aud" -mtime "+${days}" | wc -l)
        find "$audit_dir" -name "*.aud" -mtime "+${days}" -delete 2>/dev/null || true
        log_info "已删除 ${count} 个审计文件"
    fi

    # 也清理 XML 审计
    local xml_audit_dir="${OMF_CONFIG[ORACLE_BASE]}/audit/${OMF_CONFIG[ORACLE_SID]}"
    if [ -d "$xml_audit_dir" ]; then
        find "$xml_audit_dir" -name "*.xml" -mtime "+${days}" -delete 2>/dev/null || true
    fi
}

#===============================================================================
# 清理过期归档日志
#===============================================================================
clean_archive() {
    log_step "清理过期归档日志"

    # 检查是否在归档模式
    local arch_status
    arch_status=$(su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
echo \"select log_mode from v\\\$database;\" | sqlplus -s / as sysdba | grep -i 'ARCHIVELOG'
" 2>/dev/null)

    if [ -z "$arch_status" ]; then
        log_warn "数据库不在归档模式，跳过"
        return
    fi

    # 使用 RMAN 清理
    su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

rman target / <<RMANEOF
DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'SYSDATE-${OMF_CONFIG[BACKUP_RETENTION_DAYS]}';
DELETE NOPROMPT OBSOLETE;
RMANEOF
" 2>&1 | tail -10

    log_info "归档日志清理完成"
}

#===============================================================================
# 全面清理
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
    su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<SQL
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
# 每天凌晨 4:00 - 清理日志和 trace
0 4 * * * oracle ${OMF_HOME}/omf.sh clean all >> /var/log/omf_clean.log 2>&1

# 每周日凌晨 5:00 - 清理过期归档
0 5 * * 0 oracle ${OMF_HOME}/omf.sh clean archive >> /var/log/omf_clean.log 2>&1
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
