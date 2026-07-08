#!/bin/bash
#===============================================================================
# OMF - 一键总览命令
# 用法: omf status
#===============================================================================

cmd_status() {
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
    if as_oracle "sqlplus -s / as sysdba <<'SQL'
SET LINES 200 PAGES 0 FEEDBACK OFF
SELECT '  实例: '||instance_name||'  '||status||'  启动于 '||TO_CHAR(startup_time,'YYYY-MM-DD HH24:MI') FROM v\$instance;
SELECT '  数据库: '||name||'  '||open_mode||'  '||database_role||'  归档:'||log_mode FROM v\$database;
SELECT '  PDB:  '||name||'  '||open_mode FROM v\$pdbs;
EXIT;
SQL" 2>/dev/null; then
        :
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
    dmp_cnt=$(ls -1 "${ORACLE_BACKUP}/dump/"*.dmp 2>/dev/null | wc -l)
    echo "  逻辑备份(dmp)文件数: ${dmp_cnt}"
    as_oracle "rman target / <<'RMANEOF' 2>/dev/null
LIST BACKUP SUMMARY;
RMANEOF" 2>/dev/null | grep -E "Full|Incr|Arch" | head -6 || echo "  (无 RMAN 备份记录)"

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
