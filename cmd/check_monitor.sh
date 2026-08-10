#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF - 监控输出 (从 check.sh 拆分): omf check monitor [json|prom] [--watch] [--alert]
# 内部自洽, 仅依赖 lib/common.sh (oracle_su/get_disk_usage_pct/get_alert_log/omf_dg_enabled 等).
#===============================================================================
#===============================================================================
# 监控输出 (机器可读): omf check monitor [json|prom]
# 用于对接 Prometheus / 外部监控, 不做人类排版
#===============================================================================
check_monitor() {
    local fmt="json" watch=0 alert_mode=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            json|prom) fmt="$1"; shift;;
            --watch)   watch="${2:-10}"; shift 2;;
            --alert)   alert_mode=1; shift;;
            *)         shift;;
        esac
    done

    # 阈值 (conf 可覆盖, 回退默认): 磁盘使用率 / 可用内存率
    local d_warn="${OMF_CONFIG[MONITOR_DISK_WARN_PCT]:-85}"
    local d_err="${OMF_CONFIG[MONITOR_DISK_ERR_PCT]:-92}"
    local m_warn="${OMF_CONFIG[MONITOR_MEM_WARN_PCT]:-20}"
    local m_err="${OMF_CONFIG[MONITOR_MEM_ERR_PCT]:-10}"
    # 扩展阈值 (--alert 使用, 详见 _monitor_alert):
    #   MONITOR_INVALID_WARN/ERR  无效对象数
    #   MONITOR_TBS_WARN_PCT/ERR_PCT  表空间最大使用率
    #   MONITOR_BACKUP_MAX_DAYS   备份时效 (全量备份最久天数, 0/未配=不检查)
    #   MONITOR_DG_LAG_WARN_SEC   DG 应用延迟秒数

    if [ "$alert_mode" -eq 1 ]; then
        _monitor_alert "$d_warn" "$d_err" "$m_warn" "$m_err"
        return $?
    fi

    if [ "$watch" -gt 0 ]; then
        echo "持续采样模式: 每 ${watch}s 输出一次 (Ctrl-C 退出)"
        while true; do
            _monitor_run_once "$fmt"
            sleep "$watch" 2>/dev/null || break
        done
        return 0
    fi
    _monitor_run_once "$fmt"
}

# 采集一次, 结果写入全局 _MC_* 变量 (供 run_once 输出与 alert 判定的复用, 避免重复连库)
_monitor_collect() {
    _MC_DB_UP=0; _MC_MEM=0; _MC_ORA=0; _MC_STATUS="ok"; _MC_DISK=""; _MC_DP_JSON=""
    _MC_INVAL=0; _MC_TS_MAX=0; _MC_BACKUP_AGE=-1; _MC_DG_LAG=-1; _MC_ARCH_PCT=-1; _MC_DG_PDB=""
    _MC_CPU=0; _MC_ACTIVE_SESS=0; _MC_REDO_MBPS=0; _MC_TOP_WAIT=""
    local db_up=0 mem_free_pct=0 ora_errors=0 status="ok" u=""
    local mps=("/" "${OMF_CONFIG[ORACLE_DATA_BASE]}" "${OMF_CONFIG[ORACLE_BACKUP]}")

    if oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
echo 'SELECT 1 FROM v\$instance;' | sqlplus -s / as sysdba" &>/dev/null; then
        db_up=1
    fi

    local mem_free mem_total hp_free page_kb
    mem_free=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    mem_total=$(get_total_memory_mb)
    hp_free=$(awk '/HugePages_Free/ {print int($2)}' /proc/meminfo)
    page_kb=$(awk '/Hugepagesize/ {print int($2)}' /proc/meminfo)
    mem_free=$(( mem_free + hp_free * page_kb / 1024 ))
    [ "${mem_total:-0}" -gt 0 ] && mem_free_pct=$((mem_free * 100 / mem_total))

    # CPU 使用率 (%): /proc/stat 两次采样 (间隔0.5s) 的 busy/total 差值
    if [ -r /proc/stat ]; then
        local c1 c2
        c1=$(awk '/^cpu /{print $2+$3+$4,$5}' /proc/stat 2>/dev/null)
        sleep 0.5 2>/dev/null
        c2=$(awk '/^cpu /{print $2+$3+$4,$5}' /proc/stat 2>/dev/null)
        local b1 t1 b2 t2
        b1=${c1%% *}; t1=${c1#* }
        b2=${c2%% *}; t2=${c2#* }
        local db=$((b2-b1)) dt=$(((b2+t2)-(b1+t1)))
        [ "$dt" -gt 0 ] && _MC_CPU=$(( db*100/dt ))
    fi

    local alert_log="$(get_alert_log)"
    if [ -f "$alert_log" ]; then
        local start_ln
        start_ln=$(grep -nE "ALTER DATABASE OPEN|Pluggable database .*opened read write|alter pluggable database .* open" "$alert_log" 2>/dev/null | tail -1 | cut -d: -f1)
        if [ -n "$start_ln" ]; then
            ora_errors=$(tail -n +"$start_ln" "$alert_log" | grep -c "ORA-" 2>/dev/null || true)
        else
            ora_errors=$(grep -c "ORA-" "$alert_log" 2>/dev/null || true)
        fi
    fi

    # ---- 额外告警维度 (仅数据库可用时采集) ----
    if [ "$db_up" -eq 1 ]; then
        # 无效对象数
        _MC_INVAL=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT COUNT(*) FROM dba_objects WHERE status='INVALID';\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ')
        [ -z "$_MC_INVAL" ] && _MC_INVAL=0

        # 表空间最大使用率
        _MC_TS_MAX=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT NVL(MAX(ROUND((SUM(bytes)-SUM(free_bytes))*100/SUM(bytes),1)),0) FROM (
  SELECT tablespace_name, bytes, 0 AS free_bytes FROM dba_data_files
  UNION ALL
  SELECT tablespace_name, 0 AS bytes, bytes AS free_bytes FROM dba_free_space
) GROUP BY tablespace_name;\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ')
        [ -z "$_MC_TS_MAX" ] && _MC_TS_MAX=0

        # 活动会话数 (生产瓶颈/并发信号)
        _MC_ACTIVE_SESS=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT COUNT(*) FROM v\\\$session WHERE status='ACTIVE' AND type!='BACKGROUND';\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ')
        [ -z "$_MC_ACTIVE_SESS" ] && _MC_ACTIVE_SESS=0

        # Redo 平均生成速率 (MB/s): 当前 redo size / 实例启动时长(秒), 近似平均速率, 供容量评估
        _MC_REDO_MBPS=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT ROUND(NVL((SELECT value FROM v\\\$sysstat WHERE name='redo size')/1048576 /
       NULLIF((SELECT (SYSDATE-startup_time)*86400 FROM v\\\$instance),0),0),2) FROM dual;\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ')
        [ -z "$_MC_REDO_MBPS" ] && _MC_REDO_MBPS=0

        # Top 等待事件名 (非 Idle, 生产瓶颈首要信号; 取第1个供输出/告警参考)
        _MC_TOP_WAIT=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT event FROM (SELECT event, time_waited_micro FROM v\\\$system_event
  WHERE wait_class != 'Idle' ORDER BY time_waited_micro DESC) WHERE ROWNUM=1;\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ' | head -1)

        # 最近一次成功全量备份距今天数 (无备份则为 -1, 由 alert 判定为告警)
        local last_bk
        last_bk=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT TO_CHAR(MAX(start_time),'YYYY-MM-DD HH24:MI') FROM v\\\$rman_backup_job_details
WHERE input_type='DB FULL' AND status='COMPLETED';\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ')
        if [ -n "$last_bk" ] && [ "$last_bk" != "-" ]; then
            local bk_ts; bk_ts=$(date -d "$last_bk" +%s 2>/dev/null)
            [ -n "$bk_ts" ] && _MC_BACKUP_AGE=$(( ( $(date +%s) - bk_ts ) / 86400 ))
        else
            _MC_BACKUP_AGE=-1
        fi

        # DG 应用延迟 (秒): 仅启用 DG 时采集; 解析 +DD HH:MM:SS → 秒
        if omf_dg_enabled; then
            local lag_raw
            lag_raw=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT NVL(MAX(value),'-') FROM v\\\$dataguard_stats WHERE name='apply lag';\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ' | head -1)
            if [ -n "$lag_raw" ] && [ "$lag_raw" != "-" ]; then
                # 格式 +DD HH:MM:SS (如 +00 00:05:30) → 提取天数/时/分/秒累计秒
                local dd hhmmss d h m s
                dd="${lag_raw%% *}"; dd="${dd#+}"
                hhmmss="${lag_raw#* }"
                h="${hhmmss%%:*}"; mmss="${hhmmss#*:}"; m="${mmss%%:*}"; s="${mmss#*:}"
                _MC_DG_LAG=$(( ${dd:-0}*86400 + ${h:-0}*3600 + ${m:-0}*60 + ${s:-0} ))
            fi
            # PDB 级 redo 应用情况 (备库视角): 列出各 PDB 的 open_mode, 辅助定位多组织下
            # 某个组织所在 PDB 是否单独异常 (CDB 内 v$pdbs 反映备库各 PDB 打开状态)。
            # 格式: con_id:name:open_mode (逗号分隔); 主库视角也可见各 PDB 打开情况。
            local pdb_out
            pdb_out=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT con_id||':'||name||':'||open_mode FROM v\\\$pdbs ORDER BY con_id;\" | sqlplus -s / as sysdba" 2>/dev/null \
                | tr -d ' ' | grep -v '^$' | paste -sd, - 2>/dev/null)
            [ -n "$pdb_out" ] && _MC_DG_PDB="$pdb_out"
        fi

        # 快速恢复区(FRA)使用率 (%): 满仓会阻塞归档/备份, 是 DG 与备份场景的高危指标。
        # v$recovery_area_usage 的 PERCENT_SPACE_USED 为 FRA 整体水位; 不可用(如未配置 FRA)时留 -1。
        local arch_pct
        arch_pct=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT ROUND(SUM(PERCENT_SPACE_USED),1) FROM v\\\$recovery_area_usage;\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ')
        if [ -n "$arch_pct" ] && [[ "$arch_pct" =~ ^[0-9.]+$ ]]; then
            _MC_ARCH_PCT=$arch_pct
        fi
    fi

    if [ "$db_up" -eq 0 ] || [ "$mem_free_pct" -lt 10 ]; then
        status="err"
    elif [ "$mem_free_pct" -lt 20 ] || [ "$ora_errors" -gt 0 ]; then
        status="warn"
    fi

    local dp_json="" dp_first=1 p pu
    for p in "${mps[@]}"; do
        [ -d "$p" ] || continue
        pu=$(get_disk_usage_pct "$p" 2>/dev/null || echo 0)
        _MC_DISK="${_MC_DISK}${p}:${pu} "
        if [ "$dp_first" -eq 1 ]; then dp_json="\"$(basename "$p")\":${pu}"; dp_first=0
        else dp_json="${dp_json}, \"$(basename "$p")\":${pu}"; fi
    done

    _MC_DB_UP=$db_up; _MC_MEM=$mem_free_pct; _MC_ORA=$ora_errors
    _MC_STATUS=$status; _MC_DP_JSON="$dp_json"
}

# 单次采样 + 输出 (json/prom) + 持久化快照 (fmt=none 时仅采集, 由 alert 复用)
_monitor_run_once() {
    local fmt="${1:-json}"
    _monitor_collect
    local db_up=$_MC_DB_UP mem_free_pct=$_MC_MEM ora_errors=$_MC_ORA status=$_MC_STATUS

    if [ "$fmt" != "none" ]; then
        local hist="${OMF_HOME}/logs/monitor_history.jsonl"
        mkdir -p "$(dirname "$hist")" 2>/dev/null || true
        echo "{\"ts\":\"$(date '+%Y-%m-%dT%H:%M:%S')\",\"db_up\":${db_up},\"mem_free_pct\":${mem_free_pct},\"ora_errors\":${ora_errors},\"status\":\"${status}\",\"disk\":{${_MC_DP_JSON}},\"invalid_objects\":${_MC_INVAL},\"tbs_max_pct\":${_MC_TS_MAX},\"backup_age_days\":${_MC_BACKUP_AGE},\"dg_lag_sec\":${_MC_DG_LAG},\"arch_used_pct\":${_MC_ARCH_PCT},\"cpu_pct\":${_MC_CPU},\"active_sessions\":${_MC_ACTIVE_SESS},\"redo_mbps\":${_MC_REDO_MBPS}}" >> "$hist" 2>/dev/null || true
    fi

    case "$fmt" in
        prom)
            echo "# HELP omf_db_up Oracle 实例是否存活 (1=up, 0=down)"
            echo "# TYPE omf_db_up gauge"
            echo "omf_db_up $db_up"
            local p u
            for p in "/" "${OMF_CONFIG[ORACLE_DATA_BASE]}" "${OMF_CONFIG[ORACLE_BACKUP]}"; do
                [ -d "$p" ] || continue
                u=$(get_disk_usage_pct "$p" 2>/dev/null || echo 0)
                echo "omf_disk_usage_pct{mount=\"$p\"} $u"
            done
            echo "omf_mem_free_pct $mem_free_pct"
            echo "omf_alert_ora_errors $ora_errors"
            echo "# HELP omf_invalid_objects 数据库无效对象数 (db 不可用时为 0)"
            echo "# TYPE omf_invalid_objects gauge"
            echo "omf_invalid_objects ${_MC_INVAL}"
            echo "# HELP omf_tbs_max_pct 所有表空间中最大使用率 (%)"
            echo "# TYPE omf_tbs_max_pct gauge"
            echo "omf_tbs_max_pct ${_MC_TS_MAX}"
            echo "# HELP omf_backup_age_days 最近一次成功全量备份距今天数 (-1 表示无备份)"
            echo "# TYPE omf_backup_age_days gauge"
            echo "omf_backup_age_days ${_MC_BACKUP_AGE}"
            echo "# HELP omf_dg_lag_sec Data Guard 应用延迟秒数 (未启用 DG 时为 -1)"
            echo "# TYPE omf_dg_lag_sec gauge"
            echo "omf_dg_lag_sec ${_MC_DG_LAG}"
            echo "# HELP omf_arch_used_pct 快速恢复区(FRA)使用率 (%) (-1 表示未配置/不可用)"
            echo "# TYPE omf_arch_used_pct gauge"
            echo "omf_arch_used_pct ${_MC_ARCH_PCT}"
            echo "# HELP omf_cpu_pct 主机 CPU 使用率 (%)"
            echo "# TYPE omf_cpu_pct gauge"
            echo "omf_cpu_pct ${_MC_CPU}"
            echo "# HELP omf_active_sessions 数据库活动会话数"
            echo "# TYPE omf_active_sessions gauge"
            echo "omf_active_sessions ${_MC_ACTIVE_SESS}"
            echo "# HELP omf_redo_mbps Redo 平均生成速率 (MB/s)"
            echo "# TYPE omf_redo_mbps gauge"
            echo "omf_redo_mbps ${_MC_REDO_MBPS}"
            echo "omf_status{state=\"$status\"} 1"
            ;;
        json)
            local first=1 disk_json=""
            for p in "/" "${OMF_CONFIG[ORACLE_DATA_BASE]}" "${OMF_CONFIG[ORACLE_BACKUP]}"; do
                [ -d "$p" ] || continue
                u=$(get_disk_usage_pct "$p" 2>/dev/null || echo 0)
                if [ "$first" -eq 1 ]; then disk_json="\"$p\":${u}"; first=0
                else disk_json="${disk_json}, \"$p\":${u}"; fi
            done
            echo "{"
            echo "  \"db_up\": $db_up,"
            echo "  \"disk_usage_pct\": {${disk_json}},"
            echo "  \"mem_free_pct\": $mem_free_pct,"
            echo "  \"alert_ora_errors\": $ora_errors,"
            echo "  \"invalid_objects\": ${_MC_INVAL},"
            echo "  \"tbs_max_pct\": ${_MC_TS_MAX},"
            echo "  \"backup_age_days\": ${_MC_BACKUP_AGE},"
            echo "  \"dg_lag_sec\": ${_MC_DG_LAG},"
            echo "  \"arch_used_pct\": ${_MC_ARCH_PCT},"
            echo "  \"dg_pdbs\": \"${_MC_DG_PDB}\","
            echo "  \"cpu_pct\": ${_MC_CPU},"
            echo "  \"active_sessions\": ${_MC_ACTIVE_SESS},"
            echo "  \"redo_mbps\": ${_MC_REDO_MBPS},"
            echo "  \"top_wait\": \"${_MC_TOP_WAIT}\","
            echo "  \"status\": \"$status\""
            echo "}"
            ;;
    esac
}

# 阈值告警模式: 超阈值返回非0 并发送通知, 便于 cron 接入
_monitor_alert() {
    local d_warn="$1" d_err="$2" m_warn="$3" m_err="$4"
    _monitor_collect
    local alerts=0 lines=""

    # 扩展阈值 (conf 可覆盖, 回退默认):
    #   无效对象数 / 表空间水位 / 备份时效 / DG 应用延迟
    local i_warn="${OMF_CONFIG[MONITOR_INVALID_WARN]:-20}"
    local i_err="${OMF_CONFIG[MONITOR_INVALID_ERR]:-100}"
    local t_warn="${OMF_CONFIG[MONITOR_TBS_WARN_PCT]:-85}"
    local t_err="${OMF_CONFIG[MONITOR_TBS_ERR_PCT]:-92}"
    local b_max="${OMF_CONFIG[MONITOR_BACKUP_MAX_DAYS]:-1}"
    local g_warn="${OMF_CONFIG[MONITOR_DG_LAG_WARN_SEC]:-600}"   # 默认 10 分钟
    local a_warn="${OMF_CONFIG[MONITOR_ARCH_WARN_PCT]:-80}"      # FRA 使用率 warn
    local a_err="${OMF_CONFIG[MONITOR_ARCH_ERR_PCT]:-90}"        # FRA 使用率 err
    local c_warn="${OMF_CONFIG[MONITOR_CPU_WARN_PCT]:-90}"       # CPU 使用率 warn
    local c_err="${OMF_CONFIG[MONITOR_CPU_ERR_PCT]:-98}"         # CPU 使用率 err

    [ "$_MC_DB_UP" -eq 0 ] && { alerts=$((alerts+1)); lines="${lines}ALERT: 数据库不可用(db_up=0)\n"; }

    local kv p pu
    for kv in ${_MC_DISK}; do
        [ -n "$kv" ] || continue
        p="${kv%%:*}"; pu="${kv##*:}"
        [ -z "$pu" ] && continue
        if [ "${pu:-0}" -gt "$d_err" ]; then alerts=$((alerts+1)); lines="${lines}ALERT[${p}]: 磁盘 ${pu}% > ${d_err}%\n"; fi
        if [ "${pu:-0}" -gt "$d_warn" ]; then alerts=$((alerts+1)); lines="${lines}WARN[${p}]: 磁盘 ${pu}% > ${d_warn}%\n"; fi
    done

    if [ "$_MC_MEM" -lt "$m_err" ]; then alerts=$((alerts+1)); lines="${lines}ALERT: 可用内存 ${_MC_MEM}% < ${m_err}%\n"; fi
    if [ "$_MC_MEM" -lt "$m_warn" ]; then alerts=$((alerts+1)); lines="${lines}WARN: 可用内存 ${_MC_MEM}% < ${m_warn}%\n"; fi
    if [ "$_MC_ORA" -gt 0 ]; then alerts=$((alerts+1)); lines="${lines}WARN: Alert 日志本次启动以来 ${_MC_ORA} 个 ORA- 错误\n"; fi

    # 无效对象数
    if [ "$_MC_INVAL" -ge "$i_err" ]; then alerts=$((alerts+1)); lines="${lines}ALERT: 无效对象 ${_MC_INVAL} >= ${i_err}\n"; \
    elif [ "$_MC_INVAL" -ge "$i_warn" ]; then alerts=$((alerts+1)); lines="${lines}WARN: 无效对象 ${_MC_INVAL} >= ${i_warn}\n"; fi

    # 表空间水位
    if [ "${_MC_TS_MAX:-0}" -gt "$t_err" ]; then alerts=$((alerts+1)); lines="${lines}ALERT: 表空间最大使用率 ${_MC_TS_MAX}% > ${t_err}%\n"; \
    elif [ "${_MC_TS_MAX:-0}" -gt "$t_warn" ]; then alerts=$((alerts+1)); lines="${lines}WARN: 表空间最大使用率 ${_MC_TS_MAX}% > ${t_warn}%\n"; fi

    # 备份时效 (RPO 风险): -1 表示无备份
    if [ "$_MC_BACKUP_AGE" -lt 0 ]; then alerts=$((alerts+1)); lines="${lines}ALERT: 无已完成的全量备份 (RPO 风险! 执行 omf backup auto)\n"; \
    elif [ "${b_max:-1}" -gt 0 ] && [ "$_MC_BACKUP_AGE" -gt "$b_max" ]; then alerts=$((alerts+1)); lines="${lines}WARN: 最近全量备份 ${_MC_BACKUP_AGE} 天前 > ${b_max} 天 (RPO 偏大)\n"; fi

    # DG 应用延迟 (>0 表示已采集)
    if [ "$_MC_DG_LAG" -gt "$g_warn" ]; then alerts=$((alerts+1)); lines="${lines}WARN: DG 应用延迟 ${_MC_DG_LAG}s > ${g_warn}s\n"; fi

    # FRA 使用率 (>=0 表示已采集); 满仓会阻塞归档/备份
    if [ "${_MC_ARCH_PCT:-0}" -ge 0 ] && [ "${_MC_ARCH_PCT:-0}" -gt "$a_err" ]; then
        alerts=$((alerts+1)); lines="${lines}ALERT: FRA 使用率 ${_MC_ARCH_PCT}% > ${a_err}% (满仓将阻塞归档!)\n"; \
    elif [ "${_MC_ARCH_PCT:-0}" -ge 0 ] && [ "${_MC_ARCH_PCT:-0}" -gt "$a_warn" ]; then
        alerts=$((alerts+1)); lines="${lines}WARN: FRA 使用率 ${_MC_ARCH_PCT}% > ${a_warn}%\n"; fi

    # CPU 使用率 (0-100); 持续高 CPU 是生产瓶颈信号
    if [ "${_MC_CPU:-0}" -gt "$c_err" ]; then alerts=$((alerts+1)); lines="${lines}ALERT: CPU 使用率 ${_MC_CPU}% > ${c_err}% (接近饱和, 检查 Top 等待: ${_MC_TOP_WAIT:-未知})\n"; \
    elif [ "${_MC_CPU:-0}" -gt "$c_warn" ]; then alerts=$((alerts+1)); lines="${lines}WARN: CPU 使用率 ${_MC_CPU}% > ${c_warn}%\n"; fi

    if [ "$alerts" -gt 0 ]; then
        printf "%b" "$lines"
        send_notification "OMF 监控告警 (${alerts} 项)" "$(printf '%b' "$lines")"
        return 1
    fi
    echo "OK: 所有监控指标在阈值内 (disk_warn=${d_warn}% disk_err=${d_err}% mem_warn=${m_warn}% mem_err=${m_err}%)"
    return 0
}
