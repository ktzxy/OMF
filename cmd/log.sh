#!/bin/bash
#===============================================================================
# OMF - 日志管理命令
# 用法: omf log <subcommand> [options]
#===============================================================================

cmd_log() {
    local subcmd="${1:-view}"
    shift || true

    case "$subcmd" in
        view)
            log_view "$@"
            ;;
        tail)
            log_tail "$@"
            ;;
        rotate)
            log_rotate "$@"
            ;;
        clean)
            log_clean "$@"
            ;;
        *)
            echo "用法: omf log {view|tail|rotate|clean}"
            exit 1
            ;;
    esac
}

# 获取日志文件路径
# get_alert_log() 已统一在 lib/common.sh 实现 (兼容 19c 文本/XML 及大小写变体)

get_listener_log() {
    echo "${OMF_CONFIG[ORACLE_BASE]}/diag/tnslsnr/$(hostname)/LISTENER/alert/log.xml"
}

get_trace_dir() {
    local d
    d=$(find "${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms" -type d -name trace 2>/dev/null | head -1)
    [ -n "$d" ] && { echo "$d"; return; }
    echo "${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms/${OMF_CONFIG[ORACLE_SID]}/${OMF_CONFIG[ORACLE_SID]}/trace"
}

get_audit_dir() {
    echo "${OMF_CONFIG[ORACLE_BASE]}/admin/${OMF_CONFIG[ORACLE_SID]}/adump"
}

#===============================================================================
# 查看日志
#===============================================================================
log_view() {
    local log_type="${1:-alert}"
    local lines="${2:-100}"

    case "$log_type" in
        alert)
            local f
            f=$(get_alert_log)
            [ -f "$f" ] || log_error "Alert 日志不存在: $f"
            echo "=== Alert 日志 (最后 ${lines} 行) ==="
            echo "文件: $f"
            echo "大小: $(du -h "$f" | cut -f1)"
            echo ""
            tail -"$lines" "$f"
            ;;
        listener)
            local f
            f=$(get_listener_log)
            [ -f "$f" ] || log_error "监听器日志不存在: $f"
            echo "=== 监听器日志 (最后 ${lines} 行) ==="
            tail -"$lines" "$f"
            ;;
        dbca)
            echo "=== DBCA 日志 ==="
            ls -lht "${OMF_CONFIG[ORACLE_BASE]}/cfgtoollogs/dbca/" 2>/dev/null || echo "(无)"
            ;;
        omf)
            echo "=== OMF 日志 ==="
            ls -lht "${OMF_HOME}/logs/" 2>/dev/null || echo "(无)"
            ;;
        *)
            echo "用法: omf log view {alert|listener|dbca|omf} [lines]"
            ;;
    esac
}

#===============================================================================
# 实时跟踪日志
#===============================================================================
log_tail() {
    local log_type="${1:-alert}"

    case "$log_type" in
        alert)
            local f
            f=$(get_alert_log)
            [ -f "$f" ] || log_error "Alert 日志不存在: $f"
            echo "实时跟踪 Alert 日志 (Ctrl+C 退出)..."
            tail -f "$f"
            ;;
        listener)
            local f
            f=$(get_listener_log)
            [ -f "$f" ] || log_error "监听器日志不存在: $f"
            echo "实时跟踪监听器日志 (Ctrl+C 退出)..."
            tail -f "$f"
            ;;
        *)
            echo "用法: omf log tail {alert|listener}"
            ;;
    esac
}

#===============================================================================
# 日志轮转
#===============================================================================
log_rotate() {
    log_step "日志轮转"

    local alert_log
    alert_log=$(get_alert_log)

    if [ -f "$alert_log" ]; then
        local alert_size
        alert_size=$(du -m "$alert_log" | cut -f1)
        if [ "$alert_size" -gt 500 ]; then
            log_info "Alert 日志过大 (${alert_size}MB)，正在轮转..."
            local backup_name="${alert_log}.$(date '+%Y%m%d_%H%M%S').bak"
            cp "$alert_log" "$backup_name"
            > "$alert_log"
            log_info "Alert 日志已轮转 -> $backup_name"
        else
            log_info "Alert 日志大小正常 (${alert_size}MB)"
        fi
    fi

    # 清理 trace 文件
    local trace_dir
    trace_dir=$(get_trace_dir)
    if [ -d "$trace_dir" ]; then
        find "$trace_dir" -name "*.trc" -mtime +7 -delete 2>/dev/null || true
        find "$trace_dir" -name "*.trm" -mtime +7 -delete 2>/dev/null || true
        log_info "已清理 7 天前的 trace 文件"
    fi
}

#===============================================================================
# 清理旧日志
#===============================================================================
log_clean() {
    local days="${1:-${OMF_CONFIG[LOG_RETENTION_DAYS]}}"
    # 注意: find -mtime +N 实际删 (N+1) 天前, 故用 +(days-1) 实现"保留 days 天"
    local mtime_arg=$((days-1))

    log_step "清理 ${days} 天前的日志"

    # Alert 日志备份
    local alert_log
    alert_log=$(get_alert_log)
    if [ -f "$alert_log" ]; then
        find "$(dirname "$alert_log")" -name "alert_*.bak" -mtime "+${mtime_arg}" -delete 2>/dev/null || true
    fi

    # Trace 文件
    local trace_dir
    trace_dir=$(get_trace_dir)
    if [ -d "$trace_dir" ]; then
        find "$trace_dir" -name "*.trc" -mtime "+${mtime_arg}" -delete 2>/dev/null || true
        find "$trace_dir" -name "*.trm" -mtime "+${mtime_arg}" -delete 2>/dev/null || true
        log_info "已清理 trace 文件"
    fi

    # 审计文件
    local audit_dir
    audit_dir=$(get_audit_dir)
    if [ -d "$audit_dir" ]; then
        find "$audit_dir" -name "*.aud" -mtime "+$((${OMF_CONFIG[AUDIT_RETENTION_DAYS]}-1))" -delete 2>/dev/null || true
        log_info "已清理审计文件"
    fi

    # OMF 自身日志
    if [ -d "${OMF_HOME}/logs" ]; then
        find "${OMF_HOME}/logs" -name "*.log" -mtime "+${mtime_arg}" -delete 2>/dev/null || true
    fi

    log_info "日志清理完成"
}
