#!/bin/bash
#===============================================================================
# OMF - 一键总览命令
# 用法: omf status
#===============================================================================

cmd_status() {
    # 子命令: omf status history [N]
    if [ "${1:-}" = "history" ]; then
        status_history "${2:-10}"
        return 0
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              OMF 一键总览 (status)                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    printf "  %-16s %s\n" "OMF 版本:"   "${OMF_VERSION}"
    printf "  %-16s %s\n" "主机:"       "$(hostname)  ($(detect_os))"
    printf "  %-16s %s\n" "当前用户:"   "$(whoami)"
    printf "  %-16s %s\n" "ORACLE_HOME:" "${ORACLE_HOME}"
    printf "  %-16s %s\n" "ORACLE_SID:"  "${ORACLE_SID}"
    printf "  %-16s %s\n" "备份模式:"   "${BACKUP_MODE}"
    echo ""

    echo "──── 数据库 ────"
    # 捕获输出: sqlplus 的 ORA- 报错在 stdout, 仅成功时回显, 失败则只显示干净提示
    # 注意: 赋值放在 if 条件内, 避免 set -e 下 as_oracle 非0退出导致整脚本中断
    local db_out
    if db_out=$(as_oracle "sqlplus -s / as sysdba <<'SQL'
SET LINES 200 PAGES 0 FEEDBACK OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
WHENEVER OSERROR EXIT FAILURE
SELECT '  实例: '||instance_name||'  '||status||'  启动于 '||TO_CHAR(startup_time,'YYYY-MM-DD HH24:MI') FROM v\$instance;
SELECT '  数据库: '||name||'  '||open_mode||'  '||database_role||'  归档:'||log_mode FROM v\$database;
SELECT '  PDB:  '||name||'  '||open_mode FROM v\$pdbs;
EXIT;
SQL" 2>/dev/null); then
        if [ -n "$db_out" ]; then
            echo "$db_out"
        else
            echo "  数据库未运行或无法连接"
        fi
    else
        echo "  数据库未运行或无法连接"
    fi
    echo ""

    echo "──── 监听器 ────"
    if as_oracle "lsnrctl status" 2>/dev/null | grep -q "Uptime"; then
        echo "  监听器运行中"
    else
        echo "  监听器未运行"
    fi
    echo ""

    echo "──── 磁盘 ────"
    for p in "${ORACLE_DATA_BASE}" "${ORACLE_BACKUP}" "/"; do
        if [ -d "$p" ]; then
            printf "  %-28s %s\n" "$p" "$(df -h "$p" 2>/dev/null | awk 'NR==2{print $5" 已用, "$4" 可用"}')"
        fi
    done
    echo ""

    echo "──── 备份概览 ────"
    local dmp_cnt
    # 无 dump 目录或目录内无 .dmp 时, ls 返回 2, pipefail 会让整句非零; ||true 防止 set -e 中断 (这是 omf status 在备份概览段崩溃的根因)
    dmp_cnt=$(ls -1 "${ORACLE_BACKUP}/dump/"*.dmp 2>/dev/null | wc -l || true)
    echo "  逻辑备份(dmp)文件数: ${dmp_cnt}"
    # RMAN LIST BACKUP SUMMARY 的 LV 列为单字母 (A=归档/F=全量/I=增量), 并不含 Full/Incr/Arch 字样,
    # 原 grep 模式匹配不到 -> 误报"无 RMAN 备份记录". 改为按 Key 行(行首为数字)计数判断.
    local rman_out rman_cnt
    rman_out=$(as_oracle "rman target / <<'RMANEOF' 2>/dev/null
LIST BACKUP SUMMARY;
RMANEOF" 2>/dev/null)
    rman_cnt=$(echo "$rman_out" | grep -cE '^[[:space:]]*[0-9]+' || true)
    if [ "$rman_cnt" -gt 0 ]; then
        echo "  RMAN 备份记录数: ${rman_cnt}"
        echo "$rman_out" | grep -E '^[[:space:]]*[0-9]+' | tail -3 | sed 's/^/    /'
    else
        echo "  (无 RMAN 备份记录)"
    fi

    echo ""
    echo "──── 最近运行日志 ────"
    if ls -t "${OMF_HOME}/logs"/omf_*.log >/dev/null 2>&1; then
        local latest
        latest=$(ls -t "${OMF_HOME}/logs"/omf_*.log | head -1)
        echo "  最新: $latest"
        echo "  结尾:"
        tail -5 "$latest" | sed 's/^/    /'
    else
        echo "  (暂无运行日志)"
    fi
    echo ""
}

#===============================================================================
# 监控历史趋势: omf status history [N]
# 读取 check monitor 持久化的 JSONL 快照, 打印最近 N 次趋势
#===============================================================================
status_history() {
    local n="${1:-10}"
    local hist="${OMF_HOME}/logs/monitor_history.jsonl"
    echo ""
    echo "──── 监控历史趋势 (最近 ${n} 次) ────"
    if [ ! -f "$hist" ]; then
        echo "  (暂无历史, 请先运行: omf check monitor)"
        echo ""
        return 0
    fi

    printf "  %-12s %-3s %-7s %-6s %-5s %-7s\n" "时间" "库" "内存%" "ORA错" "状态" "磁盘%"
    tail -n "$n" "$hist" | while IFS= read -r line; do
        local ts db mem oe st dk
        ts=$(echo "$line" | grep -o '"ts":"[^"]*"' | sed 's/"ts":"//;s/"//' | cut -c6-16)
        db=$(echo "$line" | grep -o '"db_up":[0-9]*'      | grep -o '[0-9]*$')
        mem=$(echo "$line" | grep -o '"mem_free_pct":[0-9]*' | grep -o '[0-9]*$')
        oe=$(echo "$line"  | grep -o '"ora_errors":[0-9]*'  | grep -o '[0-9]*$')
        st=$(echo "$line"  | grep -o '"status":"[^"]*"'     | sed 's/"status":"//;s/"//')
        dk=$(echo "$line"  | grep -o '"disk":{[^}]*}'      | grep -o ':[0-9]*' | head -1 | grep -o '[0-9]*$')
        [ -z "$db" ] && db="-"
        [ -z "$mem" ] && mem="-"
        [ -z "$oe" ] && oe="-"
        [ -z "$st" ] && st="-"
        [ -z "$dk" ] && dk="-"
        printf "  %-12s %-3s %-7s %-6s %-5s %-7s\n" "${ts:-?}" "$db" "$mem" "$oe" "$st" "$dk"
    done
    echo ""
    echo "  说明: 库=1(up)/0(down), 磁盘%=首个挂载点使用率; 完整数据见 $hist"
    echo ""
}
