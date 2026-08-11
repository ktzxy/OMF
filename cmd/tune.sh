#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF - 性能调优命令
# 用法: omf tune <subcommand> [options]
#===============================================================================

cmd_tune() {
    local subcmd="${1:-memory}"
    shift || true
    log_set_subcmd "$subcmd"

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

    # 当前生效值对比 (未显式设 sga_target/pga_aggregate_target 时显示 0, 即 AMM 自动管理)
    local cur_sga cur_pga
    cur_sga=$(as_oracle "echo \"set pagesize 0 feedback off heading off SELECT NVL(value,0)/1024/1024 FROM v\\\$parameter WHERE name='sga_target';\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' \n' | awk '{printf "%.0f", $1+0}')
    cur_pga=$(as_oracle "echo \"set pagesize 0 feedback off heading off SELECT NVL(value,0)/1024/1024 FROM v\\\$parameter WHERE name='pga_aggregate_target';\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' \n' | awk '{printf "%.0f", $1+0}')
    echo ""
    echo "=== 当前 vs 建议 (单位 MB) ==="
    echo "  SGA_TARGET:        当前 ${cur_sga:-0}  建议 ${sga_target}  (差 $(( sga_target - ${cur_sga:-0} )) )"
    echo "  PGA_AGGREGATE_TGT: 当前 ${cur_pga:-0}  建议 ${pga_target}  (差 $(( pga_target - ${cur_pga:-0} )) )"

    # 大页(HugePages)建议
    local hp_total hp_free page_kb hp
    hp_total=$(awk '/HugePages_Total/ {print int($2)}' /proc/meminfo)
    hp_free=$(awk '/HugePages_Free/ {print int($2)}' /proc/meminfo)
    page_kb=$(awk '/Hugepagesize/ {print int($2)}' /proc/meminfo)
    hp=$(omf_hugepages_count)
    echo ""
    echo "=== 大页(HugePages)建议 ==="
    echo "  系统: HugePages_Total=${hp_total:-0}  Free=${hp_free:-0}  (页大小 ${page_kb:-0}KB)"
    echo "  建议 vm.nr_hugepages = ${hp}  (覆盖 SGA ${sga_target}MB, 页 2MB)"
    if [ "${hp_total:-0}" -lt "$hp" ]; then
        echo "  ⚠ 大页不足, 建议调大: echo 'vm.nr_hugepages=${hp}' >> /etc/sysctl.conf && sysctl -p"
    else
        echo "  ✓ 当前大页数量已满足 SGA 需求"
    fi

    echo ""
    echo "执行 'omf tune apply' 应用建议配置 (修改后需重启生效)"
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
PROMPT === 当前锁等待 (基于 BLOCKING_SESSION 阻塞链) ===
-- 用 v$session.BLOCKING_SESSION 识别阻塞链 (官方推荐), 避免 v$lock.id1(被锁对象ID) 误作 sid 的错误 JOIN。
SELECT
    '阻塞者: ' || b.username || '@' || b.machine || ' (sid=' || b.sid || ')' AS blocker,
    '等待者: ' || w.username || '@' || w.machine || ' (sid=' || w.sid || ')' AS waiter,
    '等待事件: ' || w.event || ' (已等 ' || ROUND(w.SECONDS_IN_WAIT) || 's)' AS wait_event,
    'SQL_ID: ' || NVL(w.sql_id,'-') AS sql_id
FROM v\$session w
JOIN v\$session b ON w.BLOCKING_SESSION = b.sid
WHERE w.BLOCKING_SESSION_STATUS = 'VALID'
ORDER BY w.SECONDS_IN_WAIT DESC;

PROMPT === 阻塞对象 (被锁对象类型) ===
SELECT '会话 ' || s.sid || ' 阻塞在: ' || s.row_wait_obj# || ' (对象 ' ||
       (SELECT o.object_name FROM dba_objects o WHERE o.object_id = s.row_wait_obj#) || ')' AS blocked_obj
FROM v\$session s
WHERE s.BLOCKING_SESSION_STATUS = 'VALID'
  AND s.row_wait_obj# > 0;

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

    # 查询 SPFILE 与当前运行值, 用于"值未变则跳过重启"的短路判断 (避免无谓停机)
    local q cur_sga_sp cur_sga_run cur_pga_sp cur_pga_run
    q=$(oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -s / as sysdba <<'SQL'
SET PAGES 0 FEEDBACK OFF HEADING OFF
SELECT 'SGA='||NVL((SELECT value FROM v\$spparameter WHERE name='sga_target' AND sid='*'),'0')||'|'||NVL(value,'0')
FROM v\$parameter WHERE name='sga_target';
SELECT 'PGA='||NVL((SELECT value FROM v\$spparameter WHERE name='pga_aggregate_target' AND sid='*'),'0')||'|'||NVL(value,'0')
FROM v\$parameter WHERE name='pga_aggregate_target';
EXIT;
SQL" 2>/dev/null)
    cur_sga_sp=$(echo "$q"  | awk -F'[=|]' '/^SGA=/{printf "%.0f", $2/1048576+0}')
    cur_sga_run=$(echo "$q" | awk -F'[=|]' '/^SGA=/{printf "%.0f", $3/1048576+0}')
    cur_pga_sp=$(echo "$q"  | awk -F'[=|]' '/^PGA=/{printf "%.0f", $2/1048576+0}')
    cur_pga_run=$(echo "$q" | awk -F'[=|]' '/^PGA=/{printf "%.0f", $3/1048576+0}')

    local need_restart=0 reasons=""
    if [ "$scope" = "memory" ] || [ "$scope" = "sga" ]; then
        if [ "${cur_sga_sp:-0}" != "$sga_target" ] || [ "${cur_sga_run:-0}" != "$sga_target" ]; then
            need_restart=1; reasons="${reasons} SGA(sp=${cur_sga_sp:-0}/run=${cur_sga_run:-0} -> ${sga_target})"
        fi
    fi
    if [ "$scope" = "memory" ] || [ "$scope" = "pga" ]; then
        if [ "${cur_pga_sp:-0}" != "$pga_target" ] || [ "${cur_pga_run:-0}" != "$pga_target" ]; then
            need_restart=1; reasons="${reasons} PGA(sp=${cur_pga_sp:-0}/run=${cur_pga_run:-0} -> ${pga_target})"
        fi
    fi

    if [ "$need_restart" -eq 0 ]; then
        log_info "内存参数已处于建议值 (SGA=${sga_target}MB, PGA=${pga_target}MB), 无需调整与重启"
        return 0
    fi

    local msg
    case "$scope" in
        sga)  msg="确认仅调整 SGA=${sga_target}MB (需重启数据库)?${reasons}";;
        pga)  msg="确认仅调整 PGA=${pga_target}MB (需重启数据库)?${reasons}";;
        *)    msg="确认应用内存调优 (SGA=${sga_target}MB, PGA=${pga_target}MB, 需重启)?${reasons}";;
    esac
    confirm "$msg"

    # 调优前保存当前 SGA/PGA 参数快照到日志目录, 供调整后对比/回滚参考 (SPFILE 修改前留档)
    local snap="${OMF_HOME}/logs/tune_${OMF_CONFIG[ORACLE_SID]}_before_$(date '+%Y%m%d_%H%M%S').snap"
    { echo "# OMF tune apply 前快照 (scope=${scope}, $(date '+%F %T'))"
      echo "sga_target_sp_mb=${cur_sga_sp:-0}"
      echo "sga_target_run_mb=${cur_sga_run:-0}"
      echo "pga_target_sp_mb=${cur_pga_sp:-0}"
      echo "pga_target_run_mb=${cur_pga_run:-0}"
      echo "target_sga_mb=${sga_target}"
      echo "target_pga_mb=${pga_target}"
    } > "$snap"
    chmod 600 "$snap" 2>/dev/null || true
    log_info "调优前参数快照已保存: $snap"

    # 调优前生成基线 AWR 报告 (供重启稳定后对比调优效果)。快照不足时仅提示不阻断。
    log_info "生成调优前基线 AWR 报告 (供对比)..."
    local awr_before=""
    awr_before=$(tune_awr "${TUNE_AWR_DAYS:-1}" 2>/dev/null | grep -oE 'awr_[0-9]+_[0-9]+\.html' | head -1)
    if [ -n "$awr_before" ] && [ -f "${OMF_HOME}/logs/awr/${awr_before}" ]; then
        log_info "调优前基线 AWR 报告: ${OMF_HOME}/logs/awr/${awr_before}"
    else
        log_warn "未能生成调优前 AWR 基线 (可能快照不足, 需 ≥2 个; 可稍后 omf tune awr 手动生成)"
    fi

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

    # 重启后健康验证: 确认实例重新 OPEN; 失败则提示用快照回滚 (生产调优最怕黑盒重启)
    local hstatus
    hstatus=$(as_oracle "echo 'select status from v\\\$instance;' | sqlplus -s / as sysdba" 2>/dev/null | grep -iE 'OPEN|STARTED|MOUNTED' | head -1 | tr -d ' ')
    if [ -n "$hstatus" ] && echo "$hstatus" | grep -qi "OPEN"; then
        log_info "重启后健康验证: 实例状态 ${hstatus} ✓ (参数已生效)"
        # 调优后对比指引: 等库运行稳定(建议 1-2 天积累快照)后, 用 tune awr 生成调优后报告与基线对比
        log_info "调优后对比: 等运行稳定后执行 'omf tune awr' 生成新报告, 与调优前基线 ${snap:-+}/logs/awr/ 下的报告对比 DB Time / 等待事件"
    else
        log_error "调优重启后实例未正常 OPEN (状态=${hstatus:-未知})。请立即用快照回滚参数: $snap, 或手动修复 SPFILE"
    fi
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
    log_info "快照范围: ${begin} -> ${end} (dbid=${dbid}, inst=${inst})"

    # 完全非交互: 直接调用 DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_HTML 取报告文本.
    # 不调用 awrrpt.sql/awrrpti.sql (交互式询问报告名, 非交互会卡死).
    # 做法: oracle 侧 sqlplus 把 HTML 直接输出到 stdout, 由 root 侧重定向写入报告文件,
    #   不再让 oracle 直接 SPOOL 写 /tmp(实测 SPOOL 写文件会失败, 报告内容反而落到 stdout 致校验失败).
    #   这种 "oracle 输出 -> root 重定向" 套路与上方快照查询 raw=$(oracle_su ...) 已被验证可用.
    # 校验以 "正文含 <html 且 End of Report" 为准: AWR 报告正文可能含 ORA- 字样(如 Alerts 段),
    #   故不能再用 "排除 ORA-" 作为成功判定, 否则会误杀正常报告.
    local sql_err="${out_dir}/.awr_sqlplus_${begin}_${end}.log"
    oracle_su "export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}; \
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}; \
export PATH=\$ORACLE_HOME/bin:\$PATH; \
sqlplus -s / as sysdba <<'SQL'
SET ECHO OFF TERMOUT ON FEEDBACK OFF HEADING OFF PAGES 0 LINESIZE 32767 LONG 1000000 LONGCHUNKSIZE 32767 TRIMOUT ON
SELECT output FROM TABLE(DBMS_WORKLOAD_REPOSITORY.AWR_REPORT_HTML(${dbid}, ${inst}, ${begin}, ${end}));
EXIT;
SQL" > "$report" 2>"$sql_err"

    # 校验: 文件存在且非空, 正文确为 AWR HTML (含 <html 与 End of Report)
    if [ -s "$report" ] && grep -qi '<html' "$report" && grep -qi 'End of Report' "$report"; then
        chown oracle:oinstall "$report" 2>/dev/null || true
        log_info "AWR 报告已生成: $report"
    else
        local reason=""
        if [ -s "$sql_err" ]; then
            reason=$(grep -iE 'ORA-[0-9]+|ERROR' "$sql_err" | head -3 | tr '\n' ' ')
        fi
        { echo "=== AWR 生成失败, sqlplus 错误(若有) ==="; [ -s "$sql_err" ] && tail -20 "$sql_err"; } >> "${out_dir}/.awr_error.log" 2>/dev/null || true
        log_error "AWR 报告生成失败${reason:+ ($reason)}. 可改用更小 days, 或等产生更多快照后再试; 错误详情见 ${out_dir}/.awr_error.log"
    fi
}
