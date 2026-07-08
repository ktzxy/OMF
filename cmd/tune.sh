#!/bin/bash
#===============================================================================
# OMF - 性能调优命令
# 用法: omf tune <subcommand> [options]
#===============================================================================

cmd_tune() {
    local subcmd="${1:-memory}"
    shift || true

    case "$subcmd" in
        memory)
            tune_memory "$@"
            ;;
        storage)
            tune_storage "$@"
            ;;
        session)
            tune_session "$@"
            ;;
        analyze)
            tune_analyze "$@"
            ;;
        apply)
            tune_apply "$@"
            ;;
        *)
            echo "用法: omf tune {memory|storage|session|analyze|apply}"
            echo "  omf tune apply [--scope memory|sga|pga]   (--yes 可跳过交互确认)"
            exit 1
            ;;
    esac
}

#===============================================================================
# 内存调优
#===============================================================================
tune_memory() {
    log_step "内存参数调优"

    local total_mem
    total_mem=$(get_total_memory_mb)

    local sga_target=$((total_mem * 75 / 100))
    local pga_target=$((total_mem * 25 / 100))

    echo ""
    echo "=== 当前内存使用 ==="
    su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<SQL
SET PAGES 50
PROMPT SGA 参数:
SELECT name, ROUND(value/1024/1024,2) AS size_mb FROM v\$sga;

PROMPT
PROMPT PGA 参数:
SELECT name, ROUND(value/1024/1024,2) AS size_mb FROM v\$pgastat WHERE name IN ('total PGA allocated', 'maximum PGA allocated');

PROMPT
PROMPT Buffer Cache 命中率:
SELECT ROUND((1 - (phy.value - lob.value - dir.value) / ses.value) * 100, 2) AS buffer_hit_ratio
FROM v\$sysstat ses, v\$sysstat lob, v\$sysstat dir, v\$sysstat phy
WHERE ses.name = 'session logical reads'
  AND dir.name = 'physical reads direct'
  AND lob.name = 'physical reads direct (lob)'
  AND phy.name = 'physical reads';

PROMPT
PROMPT Library Cache 命中率:
SELECT ROUND(SUM(pinhits)/SUM(pins)*100, 2) AS library_cache_hit_ratio FROM v\$librarycache;

EXIT;
SQL
"

    echo ""
    echo "=== 建议配置 ==="
    echo "系统内存:  ${total_mem}MB"
    echo "建议 SGA:  ${sga_target}MB"
    echo "建议 PGA:  ${pga_target}MB"
    echo ""
    echo "执行 'omf tune apply' 应用建议配置"
}

#===============================================================================
# 存储调优
#===============================================================================
tune_storage() {
    log_step "存储参数调优"

    su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<SQL
SET PAGES 50

PROMPT === 表空间使用情况 ===
SELECT
    df.tablespace_name,
    ROUND(df.bytes/1024/1024,2) AS total_mb,
    ROUND(NVL(fs.bytes,0)/1024/1024,2) AS free_mb,
    ROUND((df.bytes - NVL(fs.bytes,0))/1024/1024,2) AS used_mb,
    ROUND((df.bytes - NVL(fs.bytes,0))*100/df.bytes,2) AS pct_used
FROM (SELECT tablespace_name, SUM(bytes) bytes FROM dba_data_files GROUP BY tablespace_name) df
LEFT JOIN (SELECT tablespace_name, SUM(bytes) bytes FROM dba_free_space GROUP BY tablespace_name) fs
    ON df.tablespace_name = fs.tablespace_name
ORDER BY 5 DESC;

PROMPT
PROMPT === Redo Log 信息 ===
SELECT group#, thread#, sequence#, bytes/1024/1024 AS size_mb, status FROM v\$log ORDER BY group#;

PROMPT
PROMPT === 归档日志统计 ===
SELECT COUNT(*) AS arch_count, ROUND(SUM(blocks*block_size)/1024/1024/1024,2) AS total_gb FROM v\$archived_log WHERE deleted='NO';

PROMPT
PROMPT === 数据文件 IO 统计 (Top 10) ===
SELECT * FROM (
    SELECT file#, name, phyrds, phywrts, readtim, writetim
    FROM v\$datafile df, v\$filestat fs
    WHERE df.file# = fs.file#
    ORDER BY phyrds + phywrts DESC
) WHERE ROWNUM <= 10;

EXIT;
SQL
"
}

#===============================================================================
# 会话调优
#===============================================================================
tune_session() {
    log_step "会话参数检查"

    su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<SQL
SET PAGES 50

PROMPT === 当前会话数 ===
SELECT
    COUNT(*) AS total_sessions,
    SUM(CASE WHEN status='ACTIVE' THEN 1 ELSE 0 END) AS active,
    SUM(CASE WHEN status='INACTIVE' THEN 1 ELSE 0 END) AS inactive
FROM v\$session;

PROMPT
PROMPT === 等待事件 Top 10 ===
SELECT * FROM (
    SELECT event, total_waits, time_waited_micro/1000000 AS waited_sec
    FROM v\$system_event
    WHERE wait_class != 'Idle'
    ORDER BY time_waited_micro DESC
) WHERE ROWNUM <= 10;

PROMPT
PROMPT === 当前锁等待 ===
SELECT
    s1.username || '@' || s1.machine AS blocker,
    s1.sid AS blocker_sid,
    s2.username || '@' || s2.machine AS waiter,
    s2.sid AS waiter_sid,
    l.type AS lock_type,
    l.ctime AS wait_secs
FROM v\$lock l
JOIN v\$session s1 ON l.sid = s1.sid
JOIN v\$session s2 ON l.id1 = s2.sid
WHERE l.block = 1;

EXIT;
SQL
"
}

#===============================================================================
# 自动分析建议
#===============================================================================
tune_analyze() {
    log_step "AWR/ADDM 分析报告"

    su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<SQL
SET PAGES 0 FEEDBACK OFF

PROMPT === AWR 快照统计 ===
SELECT 'Snapshot count: ' || COUNT(*) FROM dba_hist_snapshot;

PROMPT
PROMPT === 最近 AWR 报告建议 ===
SELECT 'Use: @?\rdbms\admin\awrrpt.sql to generate AWR report' FROM dual;

PROMPT
PROMPT === 自动内存建议 ===
SELECT
    'SGA Target: ' || sga_size || 'MB -> DB Time: ' || sga_size_factor || 'x' AS sga_advice
FROM v\$sga_target_advice
WHERE sga_size_factor = 1;

EXIT;
SQL
"
    echo ""
    echo "生成 AWR 报告:"
    echo "  su - oracle -c 'cd \$ORACLE_HOME/rdbms/admin && sqlplus / as sysdba @awrrpt.sql'"
}

#===============================================================================
# 应用建议配置
#   --scope memory (默认, 同时调 SGA+PGA)
#   --scope sga    (仅调 SGA)
#   --scope pga    (仅调 PGA)
# 注: SGA_TARGET / PGA_AGGREGATE_TARGET 修改需 SCOPE=SPFILE 并重启生效
#===============================================================================
tune_apply() {
    local scope="memory"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scope) scope="$2"; shift 2;;
            sga|pga|memory) scope="$1"; shift;;
            *) shift;;
        esac
    done

    [ "$scope" = "sga" ] || [ "$scope" = "pga" ] || [ "$scope" = "memory" ] || \
        log_error "无效 --scope: $scope (应为 memory|sga|pga)"

    local total_mem
    total_mem=$(get_total_memory_mb)
    local sga_target=$((total_mem * 75 / 100))
    local pga_target=$((total_mem * 25 / 100))

    local msg
    case "$scope" in
        sga)  msg="确认仅调整 SGA=${sga_target}MB (需重启数据库)?";;
        pga)  msg="确认仅调整 PGA=${pga_target}MB (需重启数据库)?";;
        *)    msg="确认应用内存调优 (SGA=${sga_target}MB, PGA=${pga_target}MB, 需重启)?";;
    esac
    confirm "$msg"

    local sets=""
    [ "$scope" = "sga" ]    && sets="ALTER SYSTEM SET sga_target=${sga_target}M SCOPE=SPFILE;"
    [ "$scope" = "pga" ]    && sets="ALTER SYSTEM SET pga_aggregate_target=${pga_target}M SCOPE=SPFILE;"
    [ "$scope" = "memory" ] && sets="ALTER SYSTEM SET sga_target=${sga_target}M SCOPE=SPFILE;
ALTER SYSTEM SET pga_aggregate_target=${pga_target}M SCOPE=SPFILE;"

    as_oracle "sqlplus -s / as sysdba <<SQL
${sets}
SHUTDOWN IMMEDIATE;
STARTUP;
EXIT;
SQL"
    log_info "内存参数已更新 (scope=${scope}) 并重启生效"
}
