#!/bin/bash
#===============================================================================
# OMF - 健康检查命令
# 用法: omf check <subcommand>
#===============================================================================

cmd_check() {
    local subcmd="${1:-all}"
    shift || true

    case "$subcmd" in
        all)
            check_all "$@"
            ;;
        db)
            check_db "$@"
            ;;
        disk)
            check_disk "$@"
            ;;
        perf)
            check_perf "$@"
            ;;
        alert)
            check_alert "$@"
            ;;
        listener)
            check_listener "$@"
            ;;
        preflight)
            check_preflight "$@"
            ;;
        monitor)
            check_monitor "$@"
            ;;
        *)
            echo "用法: omf check {all|db|disk|perf|alert|listener|preflight|monitor}"
            exit 1
            ;;
    esac
}

#===============================================================================
# 安装/建库前预检
#===============================================================================
check_preflight() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          OMF 安装前预检 (Preflight)                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    local errors=0 warns=0 ok=0
    local ci
    ci() {
        case "$2" in
            ok)   echo "  ✓ $1"; ok=$((ok+1));;
            warn) echo "  ⚠ $1"; warns=$((warns+1));;
            err)  echo "  ✗ $1"; errors=$((errors+1));;
        esac
    }

    # 1. 运行用户
    echo "--- 运行环境 ---"
    if [ "$(id -u)" -eq 0 ]; then ci "以 root 执行 (将用 su 切换到 oracle)" ok
    elif [ "$(whoami)" = "oracle" ]; then ci "以 oracle 执行" ok
    else ci "需要 root 或 oracle 用户 (当前: $(whoami))" err; fi

    # 2. OS
    echo "--- 操作系统 ---"
    local os_info; os_info=$(detect_os)
    ci "OS: $os_info" ok

    # 3. 内存前置 (非致命: 仅记录, 不中断后续检查)
    echo "--- 内存 ---"
    if check_memory_prereq "" false; then
        ci "物理内存满足 Oracle 19c 最低要求 (≥4096MB)" ok
    else
        ci "物理内存低于 Oracle 19c 推荐最小值 4096MB (安装将失败!)" err
    fi

    # 4. 磁盘空间阈值 (数据盘/备份盘 ≥20G, /tmp ≥5G 供安装器暂存)
    echo "--- 磁盘空间 ---"
    # 格式: 路径:阈值MB:级别(warn|err)
    local -a disk_checks=(
        "${ORACLE_DATA_BASE}:20480:warn"
        "${ORACLE_BACKUP}:20480:warn"
        "/tmp:5120:err"
    )
    for entry in "${disk_checks[@]}"; do
        local dp="${entry%%:*}"
        local thr="${entry#*:}"; local lvl="${thr#*:}"; thr="${thr%:*}"
        local parent="$dp"
        while [ ! -d "$parent" ] && [ "$parent" != "/" ]; do parent=$(dirname "$parent"); done
        local free; free=$(get_disk_free_mb "$parent" 2>/dev/null || echo 0)
        if [ "${free:-0}" -lt "$thr" ]; then
            if [ "$lvl" = "err" ]; then
                ci "磁盘 ${parent} 剩余 ${free}MB (<${thr}MB, 安装将失败!)" err
            else
                ci "磁盘 ${parent} 剩余 ${free}MB (<${thr}MB, 建议扩容)" warn
            fi
        else
            ci "磁盘 ${parent} 剩余 ${free}MB" ok
        fi
    done

    # 5. 依赖库 (跨发行版, 用 ldconfig 探测, 不再依赖 rpm)
    echo "--- 依赖库 ---"
    local missing=0
    for lib in libaio.so.1 libnsl.so.1 libtirpc.so.3 libc.so.6 libstdc++.so.6 libelf.so.1; do
        if ! omf_lib_present "$lib"; then
            missing=$((missing+1)); echo "    ✗ 缺失: $lib"
        fi
    done
    [ "$missing" -eq 0 ] && ci "核心依赖库齐全" ok || ci "$missing 个依赖库缺失 (执行 omf env packages)" warn

    # 6. oracle 用户与目录
    echo "--- Oracle 用户/目录 ---"
    id oracle &>/dev/null && ci "oracle 用户存在" ok || ci "oracle 用户不存在 (执行 omf env user)" err
    [ -d "${ORACLE_BASE}" ] && ci "ORACLE_BASE 存在" ok || ci "ORACLE_BASE 不存在 (执行 omf env dirs)" warn

    # 7. 数据库连通性 (若已建库)
    echo "--- 数据库连通性 ---"
    if as_oracle "echo 'SELECT 1 FROM dual;' | sqlplus -s / as sysdba" &>/dev/null; then
        ci "数据库可连接且 OPEN" ok
    else
        ci "数据库暂不可连接 (未建库或已停止, 可忽略)" warn
    fi

    echo ""
    echo "═════════════════════════════════════════"
    echo "预检结果: ✓ $ok 正常  ⚠ $warns 警告  ✗ $errors 错误"
    echo "═════════════════════════════════════════"
    [ "$errors" -gt 0 ] && return 2
    return 0
}

#===============================================================================
# 全面检查
#===============================================================================
check_all() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          OMF 全面健康检查                                  ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    local errors=0
    local warns=0
    local ok=0

    check_item() {
        local desc="$1"
        local status="$2"  # ok|warn|err
        case "$status" in
            ok)   echo "  ✓ $desc"; ok=$((ok+1));;
            warn) echo "  ⚠ $desc"; warns=$((warns+1));;
            err)  echo "  ✗ $desc"; errors=$((errors+1));;
        esac
    }

    # 数据库状态
    echo "--- 数据库检查 ---"
    if oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
echo \"select status from v\\\$instance;\" | sqlplus -s / as sysdba
" 2>/dev/null | grep -q "OPEN"; then
        check_item "实例状态" ok
    else
        check_item "实例状态" err
    fi

    # 监听器
    echo "--- 监听器检查 ---"
    if oracle_su "${OMF_CONFIG[ORACLE_HOME]}/bin/lsnrctl status" 2>/dev/null | grep -q "Uptime"; then
        check_item "监听器 (1521)" ok
    else
        check_item "监听器 (1521)" err
    fi

    # 归档模式
    echo "--- 归档检查 ---"
    local arch_status
    arch_status=$(oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
echo \"select log_mode from v\\\$database;\" | sqlplus -s / as sysdba | grep -i 'ARCHIVELOG'
" 2>/dev/null)
    if [ -n "$arch_status" ]; then
        check_item "归档模式" ok
    else
        check_item "归档模式 (NOARCHIVELOG)" warn
    fi

    # 磁盘空间
    echo "--- 磁盘空间检查 ---"
    local paths=("/" "${OMF_CONFIG[ORACLE_DATA_BASE]}" "${OMF_CONFIG[ORACLE_BACKUP]}")
    for p in "${paths[@]}"; do
        if [ -d "$p" ]; then
            local usage
            usage=$(get_disk_usage_pct "$p" 2>/dev/null)
            if [ -n "$usage" ]; then
                if [ "$usage" -gt 90 ]; then
                    check_item "磁盘 $p (${usage}%)" err
                elif [ "$usage" -gt 80 ]; then
                    check_item "磁盘 $p (${usage}%)" warn
                else
                    check_item "磁盘 $p (${usage}%)" ok
                fi
            fi
        fi
    done

    # 内存
    echo "--- 内存检查 ---"
    local mem_free
    mem_free=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    local mem_total
    mem_total=$(get_total_memory_mb)
    local mem_pct=$((mem_free * 100 / mem_total))
    if [ "$mem_pct" -lt 10 ]; then
        check_item "可用内存 (${mem_free}MB/${mem_total}MB)" err
    elif [ "$mem_pct" -lt 20 ]; then
        check_item "可用内存 (${mem_free}MB/${mem_total}MB)" warn
    else
        check_item "可用内存 (${mem_free}MB/${mem_total}MB)" ok
    fi

    # CPU
    echo "--- CPU 检查 ---"
    local load
    load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
    local cpu_cores
    cpu_cores=$(nproc)
    if command -v bc &>/dev/null && [ "$(echo "$load > $cpu_cores" | bc 2>/dev/null)" = "1" ]; then
        check_item "CPU 负载 ($load / ${cpu_cores}核)" warn
    else
        check_item "CPU 负载 ($load / ${cpu_cores}核)" ok
    fi

    # Alert 日志检查
    echo "--- Alert 日志检查 ---"
    local alert_log="${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms/${OMF_CONFIG[ORACLE_SID]}/${OMF_CONFIG[ORACLE_SID]}/trace/alert_${OMF_CONFIG[ORACLE_SID]}.log"
    if [ -f "$alert_log" ]; then
        local ora_errors
        ora_errors=$(grep -c "ORA-" "$alert_log" 2>/dev/null || echo 0)
        if [ "$ora_errors" -gt 0 ]; then
            check_item "Alert 日志 (最近有 $ora_errors 个 ORA- 错误)" warn
        else
            check_item "Alert 日志" ok
        fi
    else
        check_item "Alert 日志 (文件不存在)" warn
    fi

    echo ""
    echo "═══════════════════════════════════════"
    echo "检查结果: ✓ $ok 正常  ⚠ $warns 警告  ✗ $errors 错误"
    echo "═══════════════════════════════════════"

    [ "$errors" -gt 0 ] && return 2
    return 0
}

#===============================================================================
# 数据库检查
#===============================================================================
check_db() {
    oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<SQL
SET PAGES 50 LINES 200
PROMPT ===== 实例状态 =====
SELECT instance_name, host_name, version, status, startup_time, ROUND(sysdate-startup_time) AS days_up FROM v\$instance;

PROMPT ===== 数据库状态 =====
SELECT name, open_mode, log_mode, database_role, flashback_on, force_logging FROM v\$database;

PROMPT ===== PDB状态 =====
SELECT con_id, name, open_mode, restricted FROM v\$pdbs;

PROMPT ===== 无效对象 =====
SELECT COUNT(*) AS invalid_objects FROM dba_objects WHERE status='INVALID';

PROMPT ===== 表空间使用 =====
SELECT tablespace_name,
    ROUND(SUM(bytes)/1024/1024/1024,2) AS total_gb,
    ROUND(SUM(bytes)/1024/1024/1024 - SUM(free_bytes)/1024/1024/1024,2) AS used_gb,
    ROUND((SUM(bytes) - SUM(free_bytes))*100/SUM(bytes),1) AS pct
FROM (
    SELECT tablespace_name, bytes, 0 AS free_bytes FROM dba_data_files
    UNION ALL
    SELECT tablespace_name, 0 AS bytes, bytes AS free_bytes FROM dba_free_space
)
GROUP BY tablespace_name
ORDER BY pct DESC;

PROMPT ===== 最近备份 =====
SELECT TO_CHAR(MAX(start_time), 'YYYY-MM-DD HH24:MI') AS last_full_backup
FROM v\$rman_backup_job_details
WHERE input_type='DB FULL' AND status='COMPLETED';

EXIT;
SQL
"
}

#===============================================================================
# 磁盘检查
#===============================================================================
check_disk() {
    echo ""
    echo "=== 磁盘使用情况 ==="
    df -h
    echo ""

    echo "=== Oracle 目录磁盘使用 ==="
    if [ -d "${OMF_CONFIG[ORACLE_DATA_BASE]}" ]; then
        du -sh "${OMF_CONFIG[ORACLE_DATA_BASE]}"/* 2>/dev/null
    fi
    echo ""

    echo "=== 备份目录磁盘使用 ==="
    if [ -d "${OMF_CONFIG[ORACLE_BACKUP]}" ]; then
        du -sh "${OMF_CONFIG[ORACLE_BACKUP]}"/* 2>/dev/null
    fi
}

#===============================================================================
# 性能检查
#===============================================================================
check_perf() {
    oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<SQL
SET PAGES 50 LINES 200

PROMPT ===== Top 等待事件 (最近1小时) =====
SELECT event, total_waits, time_waited_micro/1000000 AS waited_sec,
       average_wait_micro/1000 AS avg_ms
FROM v\$system_event
WHERE wait_class != 'Idle' AND time_waited_micro > 0
ORDER BY time_waited_micro DESC
FETCH FIRST 10 ROWS ONLY;

PROMPT ===== Buffer Cache 命中率 =====
SELECT ROUND((1 - (phy.value - lob.value - dir.value) / ses.value) * 100, 2) AS buffer_hit_pct
FROM v\$sysstat ses, v\$sysstat lob, v\$sysstat dir, v\$sysstat phy
WHERE ses.name = 'session logical reads'
  AND dir.name = 'physical reads direct'
  AND lob.name = 'physical reads direct (lob)'
  AND phy.name = 'physical reads';

PROMPT ===== 活跃会话 =====
SELECT COUNT(*) AS active_sessions FROM v\$session WHERE status='ACTIVE' AND type!='BACKGROUND';

PROMPT ===== Redo 生成速率 (MB/s) =====
SELECT ROUND(value/1024/1024,2) AS redo_mb_per_sec
FROM v\$sysstat WHERE name='redo size';

EXIT;
SQL
"
}

#===============================================================================
# Alert 日志检查
#===============================================================================
check_alert() {
    local lines="${1:-200}"
    local alert_log="${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms/${OMF_CONFIG[ORACLE_SID]}/${OMF_CONFIG[ORACLE_SID]}/trace/alert_${OMF_CONFIG[ORACLE_SID]}.log"

    if [ ! -f "$alert_log" ]; then
        log_error "Alert 日志不存在: $alert_log"
    fi

    echo ""
    echo "=== Alert 日志最后 ${lines} 行 ==="
    echo "文件: $alert_log"
    echo "大小: $(du -h "$alert_log" | cut -f1)"
    echo ""

    tail -"$lines" "$alert_log"

    echo ""
    echo "=== 最近 ORA- 错误 ==="
    grep "ORA-" "$alert_log" | tail -20 || echo "(无 ORA- 错误)"
}

#===============================================================================
# 监听器检查
#===============================================================================
check_listener() {
    oracle_su "
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
lsnrctl status
lsnrctl services
"
}

#===============================================================================
# 监控输出 (机器可读): omf check monitor [json|prom]
# 用于对接 Prometheus / 外部监控, 不做人类排版
#===============================================================================
check_monitor() {
    local fmt="${1:-json}"
    local db_up=0 mem_free_pct=0 ora_errors=0 status="ok" u=""
    local mps=("/" "${OMF_CONFIG[ORACLE_DATA_BASE]}" "${OMF_CONFIG[ORACLE_BACKUP]}")

    # 1. 数据库存活
    if oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
echo 'SELECT 1 FROM v\$instance;' | sqlplus -s / as sysdba" &>/dev/null; then
        db_up=1
    fi

    # 2. 内存可用率
    local mem_free mem_total
    mem_free=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    mem_total=$(get_total_memory_mb)
    [ "${mem_total:-0}" -gt 0 ] && mem_free_pct=$((mem_free * 100 / mem_total))

    # 3. Alert 日志 ORA- 错误数
    local alert_log="${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms/${OMF_CONFIG[ORACLE_SID]}/${OMF_CONFIG[ORACLE_SID]}/trace/alert_${OMF_CONFIG[ORACLE_SID]}.log"
    [ -f "$alert_log" ] && ora_errors=$(grep -c "ORA-" "$alert_log" 2>/dev/null || echo 0)

    # 4. 状态判定
    if [ "$db_up" -eq 0 ] || [ "$mem_free_pct" -lt 10 ]; then
        status="err"
    elif [ "$mem_free_pct" -lt 20 ] || [ "$ora_errors" -gt 0 ]; then
        status="warn"
    fi

    # 5. 持久化快照 (供 omf status history 趋势展示, 写入失败不影响监控输出)
    local hist="${OMF_HOME}/logs/monitor_history.jsonl"
    mkdir -p "$(dirname "$hist")" 2>/dev/null || true
    local dp_json="" dp_first=1 dp_u
    for p in "${mps[@]}"; do
        [ -d "$p" ] || continue
        dp_u=$(get_disk_usage_pct "$p" 2>/dev/null || echo 0)
        if [ "$dp_first" -eq 1 ]; then dp_json="\"$(basename "$p")\":${dp_u}"; dp_first=0
        else dp_json="${dp_json}, \"$(basename "$p")\":${dp_u}"; fi
    done
    echo "{\"ts\":\"$(date '+%Y-%m-%dT%H:%M:%S')\",\"db_up\":${db_up},\"mem_free_pct\":${mem_free_pct},\"ora_errors\":${ora_errors},\"status\":\"${status}\",\"disk\":{${dp_json}}}" >> "$hist" 2>/dev/null || true

    case "$fmt" in
        prom)
            echo "# HELP omf_db_up Oracle 实例是否存活 (1=up, 0=down)"
            echo "# TYPE omf_db_up gauge"
            echo "omf_db_up $db_up"
            for p in "${mps[@]}"; do
                [ -d "$p" ] || continue
                u=$(get_disk_usage_pct "$p" 2>/dev/null || echo 0)
                echo "omf_disk_usage_pct{mount=\"$p\"} $u"
            done
            echo "omf_mem_free_pct $mem_free_pct"
            echo "omf_alert_ora_errors $ora_errors"
            echo "omf_status{state=\"$status\"} 1"
            ;;
        *)
            local first=1 disk_json=""
            for p in "${mps[@]}"; do
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
            echo "  \"status\": \"$status\""
            echo "}"
            ;;
    esac
}
