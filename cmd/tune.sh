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
        awr)
            tune_awr "$@"
            ;;
        apply)
            tune_apply "$@"
            ;;
        *)
            echo "用法: omf tune {memory|storage|session|analyze|awr|apply}"
            echo "  omf tune awr [days]                      生成 AWR 报告 (默认最近1天, 输出到 logs/awr/)"
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

    local total_mem oracle_mem sga_target pga_target
    total_mem=$(get_total_memory_mb)
    # 复用 common.sh 的内存规划函数: 按 ORACLE_MEM_RATIO/SGA_RATIO 分配, 并为 OS 预留余量
    # (避免旧逻辑 SGA 75% + PGA 25% = 100% 物理内存, 不留 OS 余量导致 OOM)
    oracle_mem=$(omf_oracle_mem_mb)
    sga_target=$(omf_sga_mb)
    pga_target=$(( oracle_mem - sga_target ))
    [ "$pga_target" -lt 512 ] && pga_target=512

    echo ""
    echo "=== 当前内存使用 ==="
    oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<'SQL'
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
    echo "系统内存:    ${total_mem}MB"
    echo "Oracle 可用: ${oracle_mem}MB (已为 OS 预留 $(( total_mem - oracle_mem ))MB)"
    echo "建议 SGA:    ${sga_target}MB"
    echo "建议 PGA:    ${pga_target}MB"
    echo ""
    echo "执行 'omf tune apply' 应用建议配置"
}

#===============================================================================
# 存储调优
#===============================================================================
tune_storage() {
    log_step "存储参数调优"

    oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<'SQL'
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
    SELECT df.file#, df.name, fs.phyrds, fs.phywrts, fs.readtim, fs.writetim
    FROM v\$datafile df, v\$filestat fs
    WHERE df.file# = fs.file#
    ORDER BY fs.phyrds + fs.phywrts DESC
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

    oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<'SQL'
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

    oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<'SQL'
SET PAGES 0 FEEDBACK OFF

PROMPT === AWR 快照统计 ===
SELECT 'Snapshot count: ' || COUNT(*) FROM dba_hist_snapshot;

PROMPT
PROMPT === 最近 AWR 报告建议 ===
SELECT 'Use: omf tune awr [days] to generate AWR report' FROM dual;

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
    echo "生成 AWR 报告 (非交互, 调用 DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_HTML):"
    echo "  omf tune awr            # 生成最近 1 天 AWR 报告"
    echo "  omf tune awr 3         # 生成最近 3 天 AWR 报告"
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

    local total_mem oracle_mem sga_target pga_target
    total_mem=$(get_total_memory_mb)
    oracle_mem=$(omf_oracle_mem_mb)
    sga_target=$(omf_sga_mb)
    pga_target=$(( oracle_mem - sga_target ))
    [ "$pga_target" -lt 512 ] && pga_target=512

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

    # 直接用 oracle_su + 内联引号 heredoc (与 tune_session 一致的已验证写法), 不走 as_oracle 二次包装
    # (嵌套 heredoc 在 su -c 链路里行为不可靠, 会导致 SQL 被回显/输出为空, apply 静默失败)
    # ${sets} 用 $(echo ...) 在外层 shell 展开后注入 heredoc 体内
    oracle_su "export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}; \
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}; \
export PATH=\$ORACLE_HOME/bin:\$PATH; \
sqlplus -s / as sysdba <<'SQL'
$(echo "${sets}")
SHUTDOWN IMMEDIATE;
STARTUP;
EXIT;
SQL"
    log_info "内存参数已更新 (scope=${scope}) 并重启生效"
}

#===============================================================================
# 自动生成 AWR 报告 (非交互)
# 用法: omf tune awr [days]
#   取最近 days 天内的首尾两个快照, 调用 DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_HTML 生成 HTML 报告
#===============================================================================
tune_awr() {
    local days="${1:-1}"
    local out_dir="${OMF_HOME}/logs/awr"
    mkdir -p "$out_dir"
    chown oracle:oinstall "$out_dir" 2>/dev/null || true

    log_step "生成 AWR 报告 (最近 ${days} 天)"

    # 取最近两个快照 id (首尾) + dbid + inst_num
    # 直接用 oracle_su + 内联 heredoc (与 tune_session/tune_storage 一致的已验证可用写法),
    # 不走 as_oracle 二次包装: 嵌套 heredoc 在 su -c 链路里行为不可靠, 会导致 SQL 被回显或输出为空
    local where="SYSDATE - ${days}"
    local raw snaps
    # 先抓原始输出(raw), 再过滤; 解析为空时把 raw 写入调试日志, 便于定位 (ORA 报错 / 真无快照)
    raw=$(oracle_su "export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}; \
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}; \
export PATH=\$ORACLE_HOME/bin:\$PATH; \
sqlplus -s / as sysdba <<'SQL'
SET PAGES 0 FEEDBACK OFF HEADING OFF
SELECT MIN(s.snap_id) || ' ' || MAX(s.snap_id) || ' ' ||
       MAX(d.dbid) || ' ' || MAX(i.instance_number)
FROM dba_hist_snapshot s, v\$database d, v\$instance i
WHERE s.begin_interval_time >= (SELECT startup_time FROM v\$instance)
  AND s.begin_interval_time > ${where};
EXIT;
SQL" 2>&1)
    snaps=$(echo "$raw" | tr -d '\r' | awk '/^[[:space:]]*[0-9]+ [0-9]+ [0-9]+ [0-9]+[[:space:]]*$/{print; exit}')
    if [ -z "$snaps" ]; then
        echo "$raw" | head -20 > "${out_dir}/.awr_snaps_debug.log" 2>/dev/null || true
        log_debug "awr 快照查询原始输出已写入 ${out_dir}/.awr_snaps_debug.log"
    fi

    local begin end dbid inst
    begin=$(echo "$snaps" | awk '{print $1}')
    end=$(echo "$snaps" | awk '{print $2}')
    dbid=$(echo "$snaps" | awk '{print $3}')
    inst=$(echo "$snaps" | awk '{print $4}')

    if ! [[ "$begin" =~ ^[0-9]+$ ]] || ! [[ "$end" =~ ^[0-9]+$ ]] || [ "$begin" = "$end" ] || ! [[ "$dbid" =~ ^[0-9]+$ ]] || ! [[ "$inst" =~ ^[0-9]+$ ]]; then
        log_error "快照不足或查询异常 (需要至少 2 个 AWR 快照, 当前解析: '${snaps}'). 可能原因: 1) 库刚建, 默认 1 小时才采一个快照, 请稍后再试; 2) STATISTICS_LEVEL 非 TYPICAL/ALL; 3) 控制文件里快照已被清理. 可手动建快照: sqlplus / as sysdba -e \"EXEC DBMS_WORKLOAD_REPOSITORY.CREATE_SNAPSHOT;\" 然后间隔数分钟再建一个"
    fi

    local report="${out_dir}/awr_${begin}_${end}.html"
    # oracle 可能无 /root 目录遍历权限, 故先让 oracle 把报告写到 /tmp, 再由 root 移入 out_dir
    local tmp_report="/tmp/awr_${begin}_${end}_$$.html"
    log_info "快照范围: ${begin} -> ${end} (dbid=${dbid}, inst=${inst})"

    # 完全非交互: 直接调用 DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_HTML 取报告文本, SPOOL 写文件
    # 不调用 awrrpt.sql/awrrpti.sql, 它们内部会交互式询问报告名, 导致非交互卡死
    oracle_su "export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}; \
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}; \
export PATH=\$ORACLE_HOME/bin:\$PATH; \
sqlplus -s / as sysdba <<'SQL'
SET ECHO OFF TERMOUT OFF FEEDBACK OFF HEADING OFF PAGES 0 LINESIZE 32767 LONG 1000000 LONGCHUNKSIZE 32767 TRIMSPOOL ON
SPOOL ${tmp_report}
SELECT output FROM TABLE(DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_HTML(${dbid}, ${inst}, ${begin}, ${end}));
SPOOL OFF
EXIT;
SQL" 2>&1 | tail -8

    # 校验: 文件存在且非空, 且内容确为 AWR HTML (排除 ORA- 报错被 SPOOL 误记为成功)
    if [ -f "$tmp_report" ] && [ -s "$tmp_report" ] && ! grep -qi 'ORA-\|ERROR at line' "$tmp_report"; then
        mv -f "$tmp_report" "$report"
        chown oracle:oinstall "$report" 2>/dev/null || true
        log_info "AWR 报告已生成: $report"
    else
        { echo "=== AWR 生成失败, ${tmp_report} 内容(若有) ==="; [ -f "$tmp_report" ] && tail -15 "$tmp_report"; } >> "${out_dir}/.awr_error.log" 2>/dev/null || true
        log_error "AWR 报告生成失败 (快照区间可能跨越实例重启 ORA-20019, 或快照/权限不足). 可改用更小 days, 或等产生更多快照后再试"
    fi
}
