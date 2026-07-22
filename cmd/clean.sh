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
            -p|--preview) CLEAN_PREVIEW="true"; shift;;
            -y|--yes) shift;;
            -*) shift;;                 # 忽略其它未知选项
            *)  # 第一个非选项参数即为子命令
                [ "$subcmd" = "all" ] && subcmd="$1"
                rest+=("$1"); shift;;
        esac
    done
    export CLEAN_DAYS CLEAN_ALL CLEAN_PREVIEW

    case "$subcmd" in
        logs)      clean_logs;;
        trace)     clean_trace;;
        audit)     clean_audit;;
        archive)   clean_archive;;
        backup)    backup_cleanup;;       # 实现位于 lib/common.sh, 与 omf backup cleanup 共用
        all)       clean_all;;
        schedule)  clean_schedule "${rest[@]}";;
        *)
            echo "用法: omf clean {logs|trace|audit|archive|backup|all|schedule} [-d 天数 | --all] [-p|--preview]"
            exit 1
            ;;
    esac
}

#===============================================================================
# 清理预览 / "即将过期"高亮 公共辅助
#===============================================================================
# 即将过期阈值: 取保留期的 1/5, 钳制 2~7 天
_clean_warn_days() {
    local ret="${1:-30}"
    local w=$(( ret / 5 ))
    [ "$w" -lt 2 ] && w=2
    [ "$w" -gt 7 ] && w=7
    echo "$w"
}

# 按"dir|pattern"规格扫描文件, 按保留天数高亮
#   $1 = 模式: full(逐条列出) | summary(仅汇总行)
#   $2 = 保留天数   $3 = 即将过期阈值
#   $4.. = "目录|通配符" 规格 (如 "/backup/oracle/dump|*.dmp")
_clean_preview() {
    local mode="$1" days="$2" warn="$3"; shift 3
    local now_ts; now_ts=$(date +%s)
    local total=0 to_del=0 soon=0 f m age rem tag spec dir pat
    for spec in "$@"; do
        dir="${spec%%|*}"; pat="${spec##*|}"
        [ -d "$dir" ] || continue
        while IFS= read -r -d '' f; do
            [ -e "$f" ] || continue
            m=$(stat -c %Y "$f" 2>/dev/null) || continue
            age=$(( (now_ts - m) / 86400 ))
            rem=$(( days - age ))
            total=$((total+1))
            if [ "$rem" -le 0 ]; then
                to_del=$((to_del+1)); tag="${RED}将清理${NC}"
            elif [ "$rem" -le "$warn" ]; then
                soon=$((soon+1)); tag="${YELLOW}即将过期${NC}"
            else
                tag="${GREEN}正常${NC}"
            fi
            if [ "$mode" = "full" ]; then
                printf "  %-70s %6s天前  %s\n" "${f##*/}" "$age" "$tag"
            fi
        done < <(find "$dir" -name "$pat" -print0 2>/dev/null)
    done
    echo -e "  共 ${total} 个 | 将清理(超过${days}天): ${RED}${to_del}${NC} | 即将过期(≤${warn}天): ${YELLOW}${soon}${NC}"
}

# 归档日志预览 (基于控制文件 V$ARCHIVED_LOG, 非磁盘文件)
_clean_archive_preview() {
    local mode="$1" days="$2" warn="$3"
    local sql_out
    sql_out=$(as_oracle "sqlplus -s / as sysdba <<'SQL'
SET PAGESIZE 0 FEEDBACK OFF HEADING OFF
SELECT TO_CHAR(completion_time,'YYYY-MM-DD')||'|'||ROUND(SYSDATE-completion_time,1) FROM v\\\$archived_log ORDER BY completion_time;
SQL" 2>/dev/null)
    if [ -z "$sql_out" ]; then
        echo "  (无法连接数据库 / 不在归档模式, 跳过归档预览)"
        return
    fi
    local total=0 to_del=0 soon=0 line ct age rem tag
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # 跳过 SQL*Plus 报错/标题行 (不含 '|' 分隔符)
        [[ "$line" == *"|"* ]] || continue
        ct="${line%%|*}"; age="${line##*|}"
        rem=$(awk "BEGIN{printf \"%d\", $days - $age}" 2>/dev/null) || rem=0
        [ -z "$rem" ] && rem=0
        total=$((total+1))
        if [ "$rem" -le 0 ]; then
            to_del=$((to_del+1)); tag="${RED}将清理${NC}"
        elif [ "$rem" -le "$warn" ]; then
            soon=$((soon+1)); tag="${YELLOW}即将过期${NC}"
        else
            tag="${GREEN}正常${NC}"
        fi
        if [ "$mode" = "full" ]; then
            printf "    %s  年龄%s天  %s\n" "$ct" "$age" "$tag"
        fi
    done <<< "$sql_out"
    echo -e "  共 ${total} 个归档 | 将清理(超过${days}天): ${RED}${to_del}${NC} | 即将过期(≤${warn}天): ${YELLOW}${soon}${NC}"
}

#===============================================================================
# 清理日志 (OMF 运行日志 / alert 备份 / tmp 安装日志)
#===============================================================================
clean_logs() {
    local days
    if [ "${CLEAN_ALL:-false}" = "true" ]; then
        days=0
    else
        days="${CLEAN_DAYS:-${OMF_CONFIG[LOG_RETENTION_DAYS]:-30}}"
    fi
    local warn; warn=$(_clean_warn_days "$days")

    if [ "${CLEAN_PREVIEW:-false}" = "true" ]; then
        echo -e "[预览] OMF 日志 (保留 ${days} 天, 即将过期阈值 ${warn} 天)"
        _clean_preview full "$days" "$warn" \
            "${OMF_HOME}/logs|*.log" \
            "${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms|alert_*.bak" \
            "/tmp|oracle_install*" \
            "/tmp|dbca_*"
        return
    fi

    if [ "$days" -eq 0 ]; then
        confirm "确认清理【全部】OMF 日志? (所有运行日志 / alert 备份 / tmp 安装日志)"
        log_step "清理全部 OMF 日志 (--all)"
        find "${OMF_HOME}/logs" -name "*.log" -delete 2>/dev/null || true
        find "${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms" -name "alert_*.bak" -delete 2>/dev/null || true
        find /tmp -name "oracle_install*" -delete 2>/dev/null || true
        find /tmp -name "dbca_*" -delete 2>/dev/null || true
        log_info "日志清理完成 (全部)"
        return
    fi

    # 正常清理前先展示"将清理/即将过期"统计
    _clean_preview summary "$days" "$warn" \
        "${OMF_HOME}/logs|*.log" \
        "${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms|alert_*.bak" \
        "/tmp|oracle_install*" \
        "/tmp|dbca_*"
    confirm "确认清理 ${days} 天前的日志文件?"
    log_step "清理 ${days} 天前的日志文件"
        find "${OMF_HOME}/logs" -name "*.log" -mtime "+$((days-1))" -delete 2>/dev/null || true
        find "${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms" -name "alert_*.bak" -mtime "+$((days-1))" -delete 2>/dev/null || true
        find /tmp -name "oracle_install*" -mtime "+$((days-1))" -delete 2>/dev/null || true
        find /tmp -name "dbca_*" -mtime "+$((days-1))" -delete 2>/dev/null || true
    log_info "日志清理完成 (${days} 天前)"
}

#===============================================================================
# 清理 trace 文件
#===============================================================================
clean_trace() {
    local days
    if [ "${CLEAN_ALL:-false}" = "true" ]; then
        days=0
    else
        days="${CLEAN_DAYS:-${OMF_CONFIG[TRACE_RETENTION_DAYS]:-30}}"
    fi
    local warn; warn=$(_clean_warn_days "$days")

    local trace_dir="${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms/${OMF_CONFIG[ORACLE_SID]}/${OMF_CONFIG[ORACLE_SID]}/trace"

    if [ "${CLEAN_PREVIEW:-false}" = "true" ]; then
        echo -e "[预览] Trace 文件 (保留 ${days} 天, 即将过期阈值 ${warn} 天): ${trace_dir}"
        if [ -d "$trace_dir" ]; then
            _clean_preview full "$days" "$warn" \
                "${trace_dir}|*.trc" \
                "${trace_dir}|*.trm" \
                "${trace_dir}|cdmp_*"
        else
            echo "  (目录不存在: $trace_dir)"
        fi
        return
    fi

    if [ -d "$trace_dir" ]; then
        if [ "$days" -eq 0 ]; then
            confirm "确认清理【全部】trace 文件? (${trace_dir})"
            log_step "清理全部 trace 文件"
            find "$trace_dir" -name "*.trc" -delete 2>/dev/null || true
            find "$trace_dir" -name "*.trm" -delete 2>/dev/null || true
            find "$trace_dir" -name "cdmp_*" -exec rm -rf {} \; 2>/dev/null || true
        else
            _clean_preview summary "$days" "$warn" \
                "${trace_dir}|*.trc" \
                "${trace_dir}|*.trm" \
                "${trace_dir}|cdmp_*"
            confirm "确认清理 ${days} 天前的 trace 文件?"
            log_step "清理 ${days} 天前的 trace 文件"
            find "$trace_dir" -name "*.trc" -mtime "+$((days-1))" -delete 2>/dev/null || true
            find "$trace_dir" -name "*.trm" -mtime "+$((days-1))" -delete 2>/dev/null || true
            find "$trace_dir" -name "cdmp_*" -mtime "+$((days-1))" -exec rm -rf {} \; 2>/dev/null || true
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
    local days
    if [ "${CLEAN_ALL:-false}" = "true" ]; then
        days=0
    else
        days="${CLEAN_DAYS:-${OMF_CONFIG[AUDIT_RETENTION_DAYS]:-30}}"
    fi
    local warn; warn=$(_clean_warn_days "$days")

    local audit_dir="${OMF_CONFIG[ORACLE_BASE]}/admin/${OMF_CONFIG[ORACLE_SID]}/adump"
    local xml_audit_dir="${OMF_CONFIG[ORACLE_BASE]}/audit/${OMF_CONFIG[ORACLE_SID]}"

    if [ "${CLEAN_PREVIEW:-false}" = "true" ]; then
        echo -e "[预览] 审计文件 (保留 ${days} 天, 即将过期阈值 ${warn} 天)"
        _clean_preview full "$days" "$warn" \
            "${audit_dir}|*.aud" \
            "${xml_audit_dir}|*.xml"
        return
    fi

    if [ "$days" -eq 0 ]; then
        confirm "确认清理【全部】审计文件?"
        log_step "清理全部审计文件"
        [ -d "$audit_dir" ] && find "$audit_dir" -name "*.aud" -delete 2>/dev/null || true
        [ -d "$xml_audit_dir" ] && find "$xml_audit_dir" -name "*.xml" -delete 2>/dev/null || true
        log_info "审计文件清理完成 (全部)"
    else
        _clean_preview summary "$days" "$warn" \
            "${audit_dir}|*.aud" \
            "${xml_audit_dir}|*.xml"
        confirm "确认清理 ${days} 天前的审计文件?"
        log_step "清理 ${days} 天前的审计文件"
        [ -d "$audit_dir" ] && find "$audit_dir" -name "*.aud" -mtime "+$((days-1))" -delete 2>/dev/null || true
        [ -d "$xml_audit_dir" ] && find "$xml_audit_dir" -name "*.xml" -mtime "+$((days-1))" -delete 2>/dev/null || true
        log_info "审计文件清理完成 (${days} 天前)"
    fi
}

#===============================================================================
# 清理过期归档日志
#===============================================================================
clean_archive() {
    local retention
    if [ "${CLEAN_ALL:-false}" = "true" ]; then
        retention=0
    else
        # 注: 变量名须为 CLEAN_DAYS (与 cmd_clean 导出一致), 旧版误写为 CLEAN_DAYS 导致 -d 对归档无效
        retention="${CLEAN_DAYS:-${OMF_CONFIG[BACKUP_RETENTION_DAYS]:-30}}"
    fi
    local warn; warn=$(_clean_warn_days "$retention")

    if [ "${CLEAN_PREVIEW:-false}" = "true" ]; then
        echo -e "[预览] 归档日志 (保留 ${retention} 天, 即将过期阈值 ${warn} 天)"
        _clean_archive_preview full "$retention" "$warn"
        return
    fi

    if [ "$retention" -eq 0 ]; then
        confirm "确认清理【全部】归档日志? (将删除所有归档, 影响可恢复性)"
        log_step "清理全部归档日志 (--all)"
    else
        _clean_archive_preview summary "$retention" "$warn"
        confirm "确认清理 ${retention} 天前的归档日志?"
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

    if [ "${CLEAN_PREVIEW:-false}" = "true" ]; then
        echo -e "[预览] 以下将在正式清理时执行: 清空监听器日志, 清空数据库回收站 (PURGE DBA_RECYCLEBIN)"
    else
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
    fi

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
