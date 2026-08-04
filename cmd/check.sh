#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF - 健康检查命令
# 用法: omf check <subcommand>
#===============================================================================

cmd_check() {
    local subcmd="${1:-all}"
    shift || true

    # 退出码透传: omf.sh 用 set -e, 而 case 命令列表中的失败不会触发 set -e,
    # 故子检查的返回码(如 check_all 出错返回 2 / monitor --alert 告警返回 1)会被吞掉,
    # 导致 omf check 始终退出 0, cron 无法据此判障. 这里用 "cmd || rc=$?" 捕获并显式 exit.
    local rc=0
    case "$subcmd" in
        all)        check_all "$@"       || rc=$?;;
        db)         check_db "$@"        || rc=$?;;
        disk)       check_disk "$@"      || rc=$?;;
        perf)       check_perf "$@"      || rc=$?;;
        alert)      check_alert "$@"     || rc=$?;;
        listener)   check_listener "$@"  || rc=$?;;
        preflight)  check_preflight "$@" || rc=$?;;
        schemas)    check_schemas "$@"   || rc=$?;;
        dg)         check_dg "$@"        || rc=$?;;
        monitor)    check_monitor "$@"   || rc=$?;;
        *)
            echo "用法: omf check {all|db|disk|perf|alert|listener|preflight|schemas|dg|monitor}"
            echo "  monitor 额外参数: [json|prom] [--watch 秒] [--alert]"
            echo "    --watch 秒  持续采样 (每 N 秒输出一次, Ctrl-C 退出)"
            echo "    --alert      阈值告警 (超阈值返回非0并发送通知, 便于 cron 接入)"
            exit 1
            ;;
    esac
    # monitor 的 json/prom 正常输出应保持退出 0; --alert 告警时 rc=1 会透传, 便于 cron 判定
    exit "$rc"
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
    local missing=0 lib present
    for lib in libaio.so.1 libnsl.so.1 libtirpc libc.so.6 libstdc++.so.6 libelf.so.1; do
        case "$lib" in
            libtirpc) omf_lib_tirpc_present && present=1 || present=0 ;;
            *)        omf_lib_present "$lib" && present=1 || present=0 ;;
        esac
        if [ "$present" -eq 0 ]; then
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
    if as_oracle "echo 'WHENEVER SQLERROR EXIT SQL.SQLCODE
SELECT 1 FROM dual;' | sqlplus -s / as sysdba" &>/dev/null; then
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
    local ls_out listen_port cfg_port
    ls_out=$(oracle_su "${OMF_CONFIG[ORACLE_HOME]}/bin/lsnrctl status" 2>/dev/null)
    if echo "$ls_out" | grep -q "Uptime"; then
        listen_port=$(echo "$ls_out" | grep -i 'PROTOCOL=tcp' | grep -oE 'PORT=[0-9]+' | head -1 | cut -d= -f2)
        cfg_port="${OMF_CONFIG[LISTENER_PORT]:-1521}"
        if [ -n "$listen_port" ] && [ "$listen_port" != "$cfg_port" ]; then
            check_item "监听器 (实际端口 ${listen_port} ≠ 配置 ${cfg_port}, 请 omf listener port 同步)" warn
        else
            check_item "监听器 (${cfg_port})" ok
        fi
    else
        check_item "监听器 (${OMF_CONFIG[LISTENER_PORT]:-1521})" err
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
    local mem_free mem_total mem_pct hp_total hp_free hp_free_mb page_kb hp_info
    mem_free=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    mem_total=$(get_total_memory_mb)
    # 大页状态: SGA 走大页时, 常规内存被隔离给 SGA, 属预期, 仅作提示
    hp_total=$(awk '/HugePages_Total/ {print int($2)}' /proc/meminfo)
    hp_free=$(awk '/HugePages_Free/ {print int($2)}' /proc/meminfo)
    page_kb=$(awk '/Hugepagesize/ {print int($2)}' /proc/meminfo)
    hp_free_mb=$(( hp_free * page_kb / 1024 ))
    # 空闲大页可被释放回 OS, 计入可用内存; 否则 SGA 跑在大页时 MemAvailable 不含大页会误报内存不足
    mem_free=$(( mem_free + hp_free_mb ))
    mem_pct=$((mem_free * 100 / mem_total))
    hp_info=""
    [ "$hp_total" -gt 0 ] && hp_info=" (大页 ${hp_total}页, 空闲${hp_free_mb}MB)"
    if [ "$mem_pct" -lt 10 ]; then
        check_item "可用内存 (${mem_free}MB/${mem_total}MB)${hp_info}" err
    elif [ "$mem_pct" -lt 20 ]; then
        check_item "可用内存 (${mem_free}MB/${mem_total}MB)${hp_info}" warn
    else
        check_item "可用内存 (${mem_free}MB/${mem_total}MB)${hp_info}" ok
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

    # Alert 日志检查 (仅统计【本次实例启动以来】的 ORA- 错误, 避免建库历史错误干扰)
    echo "--- Alert 日志检查 ---"
    local alert_log="$(get_alert_log)"
    if [ -f "$alert_log" ]; then
        local total since_start start_ln
        total=$(grep -c "ORA-" "$alert_log" 2>/dev/null || true)
        # 取最后一次"库完全打开"的日志行号作为边界 (CDB OPEN / PDB 打开)
        start_ln=$(grep -nE "ALTER DATABASE OPEN|Pluggable database .*opened read write|alter pluggable database .* open" "$alert_log" 2>/dev/null | tail -1 | cut -d: -f1)
        if [ -n "$start_ln" ]; then
            since_start=$(tail -n +"$start_ln" "$alert_log" | grep -c "ORA-" 2>/dev/null || true)
        else
            since_start=$total
        fi
        if [ "$since_start" -gt 0 ]; then
            check_item "Alert 日志 (本次启动以来 $since_start 个 ORA- 错误, 历史共 $total 个)" warn
        elif [ "$total" -gt 0 ]; then
            check_item "Alert 日志 (历史 $total 个 ORA-, 本次启动以来 0 个)" ok
        else
            check_item "Alert 日志" ok
        fi
    else
        check_item "Alert 日志 (文件不存在)" warn
    fi

    # 模式(多库)存在性校验: 已配置的每个模式, 其 Oracle 用户是否真实存在
    echo "--- 模式(多库)存在性校验 ---"
    check_schemas_inner

    # Data Guard 健康 (仅 ENABLE_DG=true 时检查)
    if omf_dg_enabled; then
        echo "--- Data Guard 检查 ---"
        check_dg_inner
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

sqlplus -s / as sysdba <<'SQL'
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
# 模式(多库)存在性校验
#   check_schemas_inner: 核心, 复用调用方已定义的 check_item (ok|warn|err)
#   check_schemas:       子命令入口, 自带计数并汇总
#===============================================================================
check_schemas_inner() {
    # 数据库未起时, dba_users 查不到, 直接跳过(不误报)
    if ! as_oracle "echo 'SELECT 1 FROM dual;' | sqlplus -s / as sysdba" &>/dev/null; then
        check_item "数据库未连接, 跳过模式存在性校验" warn
        return 0
    fi
    local s u exists
    for s in $(omf_schema_list); do
        u=$(omf_schema_user "$s")
        exists=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT COUNT(*) FROM dba_users WHERE username='${u}';\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ')
        if [ "$exists" = "1" ]; then
            check_item "模式[${s}] (用户 ${u}) 已存在" ok
        else
            check_item "模式[${s}] (用户 ${u}) 不存在于数据库! 请 omf sql init" err
        fi
    done
}

check_schemas() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          OMF 模式(多库)存在性校验                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    local errors=0 warns=0 ok=0
    check_item() {
        local desc="$1" status="$2"
        case "$status" in
            ok)   echo "  ✓ $desc"; ok=$((ok+1));;
            warn) echo "  ⚠ $desc"; warns=$((warns+1));;
            err)  echo "  ✗ $desc"; errors=$((errors+1));;
        esac
    }
    check_schemas_inner
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "校验结果: ✓ $ok 正常  ⚠ $warns 警告  ✗ $errors 错误"
    echo "══════════════════════════════════════════════════════════"
    [ "$errors" -gt 0 ] && return 2
    return 0
}

#===============================================================================
# Data Guard 健康检查
#   check_dg_inner: 核心, 复用调用方已定义的 check_item (ok|warn|err)
#   check_dg:       子命令入口, 自带计数并汇总 + 附加详情 (延迟/GAP)
#===============================================================================
check_dg_inner() {
    # 数据库未起时跳过 (不误报)
    local role; role="$(omf_db_role 2>/dev/null)"
    if [ -z "$role" ]; then
        check_item "数据库未连接, 跳过 DG 检查" warn
        return 0
    fi
    check_item "数据库角色: ${role}" ok

    if echo "$role" | grep -qi "PRIMARY"; then
        # 主库: dest_2 传输状态
        local dest2
        dest2=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT status || '|' || NVL(error,'-') FROM v\\\$archive_dest_status WHERE dest_id=2;\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ' | head -1)
        # 取 '|' 前的状态字段 (如 VALID / DEFERRED), 避免 case 中用转义 '\|' 匹配, 可读性差且易误改坏
        local dest_status="${dest2%%|*}"
        case "$dest_status" in
            VALID)      check_item "日志传输 dest_2: VALID" ok;;
            DEFERRED)   check_item "日志传输 dest_2: DEFERRED (未启用, 执行 omf db dg enable)" warn;;
            *)          check_item "日志传输 dest_2: ${dest2:-未知} (检查 omf db dg gap)" err;;
        esac
        # 归档间隙 (主库视角: 备库 applied 落后)
        local gap
        gap=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT COUNT(*) FROM v\\\$archive_gap;\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ' | head -1)
        if [ "${gap:-0}" = "0" ]; then
            check_item "归档间隙: 无" ok
        else
            check_item "归档间隙: ${gap} 个 (执行 omf db dg gap 查看)" err
        fi
    elif echo "$role" | grep -qi "PHYSICAL STANDBY"; then
        # 备库: MRP 是否在应用
        local mrp
        mrp=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT COUNT(*) FROM v\\\$managed_standby WHERE process LIKE 'MRP%';\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ' | head -1)
        if [ "${mrp:-0}" != "0" ]; then
            check_item "MRP 应用进程: 运行中" ok
        else
            check_item "MRP 应用进程: 未运行! (执行 omf db dg apply start)" err
        fi
        # 应用延迟
        local lag
        lag=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT NVL(MAX(value),'-') FROM v\\\$dataguard_stats WHERE name='apply lag';\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ' | head -1)
        if [ "$lag" = "-" ] || [ -z "$lag" ]; then
            check_item "应用延迟: 无法获取" warn
        elif echo "$lag" | grep -qE '^\+00 00:0[0-9]:'; then
            check_item "应用延迟: ${lag} (<10分钟)" ok
        else
            check_item "应用延迟: ${lag} (偏大, 检查网络/主库归档量)" warn
        fi
    fi
}

check_dg() {
    if ! omf_dg_enabled; then
        echo "ENABLE_DG=false, 未启用 Data Guard (conf 中开启后再检查)"
        return 0
    fi
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          OMF Data Guard 健康检查                           ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    local errors=0 warns=0 ok=0
    check_item() {
        local desc="$1" status="$2"
        case "$status" in
            ok)   echo "  ✓ $desc"; ok=$((ok+1));;
            warn) echo "  ⚠ $desc"; warns=$((warns+1));;
            err)  echo "  ✗ $desc"; errors=$((errors+1));;
        esac
    }
    check_dg_inner
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "检查结果: ✓ $ok 正常  ⚠ $warns 警告  ✗ $errors 错误"
    echo "══════════════════════════════════════════════════════════"
    echo ""
    echo "详情 (延迟/间隙/目的地): omf db dg gap;  Broker 状态: omf db dg status"
    [ "$errors" -gt 0 ] && return 2
    return 0
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
        ( shopt -s nullglob; du -sh "${OMF_CONFIG[ORACLE_DATA_BASE]}"/* 2>/dev/null ) || true
    fi
    echo ""

    echo "=== 备份目录磁盘使用 ==="
    if [ -d "${OMF_CONFIG[ORACLE_BACKUP]}" ]; then
        ( shopt -s nullglob; du -sh "${OMF_CONFIG[ORACLE_BACKUP]}"/* 2>/dev/null ) || true
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

sqlplus -s / as sysdba <<'SQL'
SET PAGES 50 LINES 200

PROMPT ===== Top 等待事件 (最近1小时) =====
SELECT event, total_waits, time_waited_micro/1000000 AS waited_sec,
       time_waited_micro/NULLIF(total_waits,0)/1000 AS avg_ms
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
    local alert_log="$(get_alert_log)"

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

    echo ""
    echo "=== 统计 ==="
    local total since_start start_ln
    total=$(grep -c "ORA-" "$alert_log" 2>/dev/null || true)
    start_ln=$(grep -nE "ALTER DATABASE OPEN|Pluggable database .*opened read write|alter pluggable database .* open" "$alert_log" 2>/dev/null | tail -1 | cut -d: -f1)
    if [ -n "$start_ln" ]; then
        since_start=$(tail -n +"$start_ln" "$alert_log" | grep -c "ORA-" 2>/dev/null || true)
    else
        since_start=$total
    fi
    echo "历史 ORA- 错误: $total 个; 本次启动以来: $since_start 个"
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
    _MC_INVAL=0; _MC_TS_MAX=0; _MC_BACKUP_AGE=-1; _MC_DG_LAG=-1
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
        echo "{\"ts\":\"$(date '+%Y-%m-%dT%H:%M:%S')\",\"db_up\":${db_up},\"mem_free_pct\":${mem_free_pct},\"ora_errors\":${ora_errors},\"status\":\"${status}\",\"disk\":{${_MC_DP_JSON}}}" >> "$hist" 2>/dev/null || true
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

    if [ "$alerts" -gt 0 ]; then
        printf "%b" "$lines"
        send_notification "OMF 监控告警 (${alerts} 项)" "$(printf '%b' "$lines")"
        return 1
    fi
    echo "OK: 所有监控指标在阈值内 (disk_warn=${d_warn}% disk_err=${d_err}% mem_warn=${m_warn}% mem_err=${m_err}%)"
    return 0
}
