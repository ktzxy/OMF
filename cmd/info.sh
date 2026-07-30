#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF - 实例信息总览命令
# 用法: omf info
#   集中展示生产排障/部署验证/交接最关心的: 主机与 IP、Oracle 关键路径、
#   监听器端口与 HOST、实例与库基本信息、各 PDB 的 EZCONNECT 连接串、内存概要.
#===============================================================================

cmd_info() {
    # 复用其它命令模块里的辅助函数 (仅定义, 不会触发其入口)
    source "${OMF_HOME}/cmd/listener.sh" 2>/dev/null || true
    source "${OMF_HOME}/cmd/log.sh" 2>/dev/null || true

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║            OMF 实例信息总览 (info)                         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    # ---- 主机与网络 ----
    local host_ip
    host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$host_ip" ] && host_ip=$(ip -4 addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | grep -v '^127\.' | head -1)
    [ -z "$host_ip" ] && host_ip="(无法获取)"

    echo "──── 主机与网络 ────"
    printf "  %-16s %s\n" "主机名:"   "$(hostname)"
    printf "  %-16s %s\n" "操作系统:" "$(detect_os)"
    printf "  %-16s %s\n" "主机 IP:"  "$host_ip"
    printf "  %-16s %s\n" "当前用户:" "$(whoami)"
    echo ""

    # ---- Oracle 路径 ----
    echo "──── Oracle 路径 ────"
    printf "  %-16s %s\n" "ORACLE_HOME:" "${ORACLE_HOME}"
    printf "  %-16s %s\n" "ORACLE_BASE:" "${ORACLE_BASE}"
    printf "  %-16s %s\n" "ORACLE_SID:"  "${ORACLE_SID}"
    printf "  %-16s %s\n" "数据目录:"     "${ORACLE_DATA_BASE}"
    printf "  %-16s %s\n" "备份目录:"     "${ORACLE_BACKUP}"
    printf "  %-16s %s\n" "TNS_ADMIN:"   "${TNS_ADMIN:-${ORACLE_HOME}/network/admin}"
    local al; al=$(get_alert_log 2>/dev/null);    [ -n "$al" ] && printf "  %-16s %s\n" "Alert 日志:" "$al"
    local ll; ll=$(get_listener_log 2>/dev/null); [ -n "$ll" ] && printf "  %-16s %s\n" "监听器日志:" "$ll"
    local spf
    spf=$(as_oracle "sqlplus -s / as sysdba <<'SQL'
SET PAGES 0 FEEDBACK OFF
SELECT value FROM v\$parameter WHERE name='spfile';
EXIT;
SQL" 2>/dev/null | tr -d ' ')
    [ -n "$spf" ] && printf "  %-16s %s\n" "SPFILE:" "$spf"
    echo ""

    # ---- 监听器 (端口 / HOST) ----
    echo "──── 监听器 ────"
    local lp="" lh=""
    if command -v listener_running >/dev/null 2>&1 && listener_running; then
        lp=$(listener_port_listening 2>/dev/null)
        lh=$(oracle_su "export ORACLE_HOME=${ORACLE_HOME}; export PATH=\$ORACLE_HOME/bin:\$PATH; lsnrctl status" 2>/dev/null \
                | grep -oE 'HOST=[^)]+' | head -1 | cut -d= -f2)
        echo "  状态: 运行中"
        printf "  %-16s %s\n" "监听端口:" "${lp:-${LISTENER_PORT:-1521}}"
        [ -n "$lh" ] && printf "  %-16s %s\n" "监听 HOST:" "$lh"
    else
        echo "  状态: 未运行"
        printf "  %-16s %s\n" "配置端口:" "${LISTENER_PORT:-1521}"
    fi
    echo ""

    # ---- 实例与数据库 ----
    echo "──── 实例与数据库 ────"
    local db_out
    if db_out=$(as_oracle "sqlplus -s / as sysdba <<'SQL'
SET LINES 200 PAGES 0 FEEDBACK OFF
SELECT '实例: '||instance_name||'  '||version||'  '||status FROM v\$instance;
SELECT '数据库: '||name||'  '||open_mode||'  '||database_role||'  归档:'||log_mode FROM v\$database;
SELECT '服务名: '||value FROM v\$parameter WHERE name='service_names';
SELECT '归档目标: '||substr(value,1,120) FROM v\$parameter WHERE name='log_archive_dest_1';
EXIT;
SQL" 2>/dev/null); then
        [ -n "$db_out" ] && echo "$db_out" | sed 's/^/  /'
    else
        echo "  数据库未运行或无法连接"
    fi

    # PDB 连接串 (EZCONNECT)
    local pdbs
    pdbs=$(as_oracle "sqlplus -s / as sysdba <<'SQL'
SET PAGES 0 FEEDBACK OFF
SELECT name||'|'||open_mode FROM v\$pdbs;
EXIT;
SQL" 2>/dev/null)
    if [ -n "$pdbs" ]; then
        echo "  ---- PDB 连接串 (EZCONNECT) ----"
        local port="${lp:-${LISTENER_PORT:-1521}}"
        local pname pmode
        while IFS='|' read -r pname pmode; do
            [ -z "$pname" ] && continue
            printf "    %-16s //%s:%s/%s  (%s)\n" "$pname" "$host_ip" "$port" "$pname" "${pmode:-?}"
        done <<< "$pdbs"
    fi
    echo ""

    # ---- 内存概要 (命中"内存优化") ----
    echo "──── 内存概要 ────"
    local mem
    mem=$(as_oracle "sqlplus -s / as sysdba <<'SQL'
SET PAGES 0 FEEDBACK OFF
SELECT 'SGA_TARGET: '||ROUND(value/1024/1024,0)||'MB' FROM v\$parameter WHERE name='sga_target';
SELECT 'PGA_AGGREGATE_TARGET: '||ROUND(value/1024/1024,0)||'MB' FROM v\$parameter WHERE name='pga_aggregate_target';
SELECT 'SGA 当前使用: '||ROUND(SUM(value)/1024/1024,0)||'MB' FROM v\$sga;
EXIT;
SQL" 2>/dev/null)
    [ -n "$mem" ] && echo "$mem" | sed 's/^/  /'
    local hp; hp=$(awk '/HugePages_Total/ {t=$2} /HugePages_Free/ {f=$2} END{print t"/"f}' /proc/meminfo 2>/dev/null)
    [ -n "$hp" ] && printf "  %-16s %s\n" "系统大页:" "${hp} (总/空闲)"
    echo ""
}
