#!/bin/bash
#===============================================================================
# cmd/listener.sh - 监听器管理 (status / start / stop / restart / port)
# 注意: 本文件由 omf.sh 按需 source, 依赖 lib/common.sh 的 oracle_su / log_* 等
#===============================================================================

# listener.ora 路径 (尊重 TNS_ADMIN)
listener_ora_file() {
    echo "${TNS_ADMIN:-${OMF_CONFIG[ORACLE_HOME]}/network/admin}/listener.ora"
}

# tnsnames.ora 路径 (尊重 TNS_ADMIN)
listener_tns_file() {
    echo "${TNS_ADMIN:-${OMF_CONFIG[ORACLE_HOME]}/network/admin}/tnsnames.ora"
}

# 监听器是否运行中 (lsnrctl status 含 Uptime 即运行)
listener_running() {
    oracle_su "export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}; export PATH=\$ORACLE_HOME/bin:\$PATH; lsnrctl status" 2>/dev/null \
        | grep -q "Uptime"
}

# 当前实际监听的 TCP 端口 (从 lsnrctl status 解析, 库未起时为空)
listener_port_listening() {
    oracle_su "export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}; export PATH=\$ORACLE_HOME/bin:\$PATH; lsnrctl status" 2>/dev/null \
        | grep -i 'PROTOCOL=tcp' | grep -oE 'PORT=[0-9]+' | head -1 | cut -d= -f2
}

# 配置文件中监听器的 TCP 端口 (从 listener.ora 解析, 缺省回退 LISTENER_PORT/1521)
listener_port_cfg() {
    local f p=""
    f=$(listener_ora_file)
    if [ -f "$f" ]; then
        p=$(grep -iE 'PROTOCOL.*TCP' "$f" 2>/dev/null \
            | grep -oE 'PORT[ ]*=[ ]*[0-9]+' | head -1 | grep -oE '[0-9]+' | head -1)
    fi
    [ -n "$p" ] && echo "$p" || echo "${OMF_CONFIG[LISTENER_PORT]:-1521}"
}

# 数据库是否已 OPEN (用于改端口后刷新 local_listener)
listener_db_open() {
    as_oracle "sqlplus -s / as sysdba <<'SQL'
SET LINES 200 PAGES 0 FEEDBACK OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
SELECT 1 FROM v\$instance WHERE status='OPEN';
EXIT;
SQL" 2>/dev/null
}

listener_start() {
    set +e
    oracle_su "export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}; export PATH=\$ORACLE_HOME/bin:\$PATH; lsnrctl start" 2>&1
    local rc=$?
    set -e
    return $rc
}

listener_stop() {
    set +e
    oracle_su "export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}; export PATH=\$ORACLE_HOME/bin:\$PATH; lsnrctl stop" 2>&1
    local rc=$?
    set -e
    return $rc
}

# 防火墙: 开放新端口, 关闭旧端口 (firewalld 激活时)
listener_fw_update() {
    local oldp="$1" newp="$2"
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --add-port="${newp}/tcp" --permanent 2>/dev/null
        if [ "$oldp" != "$newp" ]; then
            firewall-cmd --remove-port="${oldp}/tcp" --permanent 2>/dev/null
        fi
        firewall-cmd --reload 2>/dev/null
        log_info "防火墙已更新: 开放 ${newp}/tcp"$([ "$oldp" != "$newp" ] && echo ", 关闭 ${oldp}/tcp")
    fi
}

#===============================================================================
# 入口
#===============================================================================
cmd_listener() {
    local sub="${1:-status}"; [ $# -gt 0 ] && shift || true

    case "$sub" in
        status)
            echo "──── 监听器 ────"
            if listener_running; then
                local p; p=$(listener_port_listening)
                echo "  状态: 运行中"
                [ -n "$p" ] && echo "  监听端口: $p"
            else
                echo "  状态: 未运行 (用 omf listener start 启动)"
            fi
            ;;

        start)
            log_step "启动监听器"
            if listener_running; then
                log_warn "监听器已在运行"
            else
                listener_start
                if listener_running; then
                    log_info "监听器已启动, 端口: $(listener_port_listening)"
                else
                    log_error "监听器启动失败, 查看日志: omf log view listener"
                    exit 1
                fi
            fi
            ;;

        stop)
            log_step "停止监听器"
            if listener_running; then
                listener_stop
                listener_running && log_error "监听器停止失败" || log_info "监听器已停止"
            else
                log_warn "监听器未运行"
            fi
            ;;

        restart)
            log_step "重启监听器"
            set +e
            listener_stop >/dev/null 2>&1
            set -e
            sleep 2
            listener_start
            if listener_running; then
                log_info "监听器已重启, 端口: $(listener_port_listening)"
            else
                log_error "监听器重启失败, 查看日志: omf log view listener"
                exit 1
            fi
            ;;

        port)
            local newport="${1:-}"
            [ -z "$newport" ] && log_error "用法: omf listener port <新端口> (1024-65535)"
            case "$newport" in
                ''|*[!0-9]*) log_error "端口必须是数字: $newport"; exit 1;;
            esac
            if [ "$newport" -lt 1024 ] || [ "$newport" -gt 65535 ]; then
                log_error "端口超出范围 (1024-65535): $newport"; exit 1
            fi

            local f; f=$(listener_ora_file)
            [ -f "$f" ] || log_error "未找到 listener.ora: $f (请先 omf install listener)"
            local t; t=$(listener_tns_file)
            local oldport; oldport=$(listener_port_cfg)
            [ -z "$oldport" ] && oldport="1521"

            if [ "$oldport" = "$newport" ]; then
                log_warn "监听器端口已是 $newport, 无需修改"
                return 0
            fi

            log_step "修改监听器端口: ${oldport} -> ${newport}"

            # 1) 改 listener.ora (TCP PORT + EXTPROC KEY)
            cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
            sed -i -E "s/(PORT[[:space:]]*=[[:space:]]*)${oldport}/\1${newport}/g" "$f"
            sed -i -E "s/(KEY[[:space:]]*=[[:space:]]*EXTPROC)${oldport}/\1${newport}/g" "$f"
            log_info "已更新 listener.ora: $f"

            # 2) 改 tnsnames.ora (若有, 同步客户端连接端口)
            if [ -f "$t" ]; then
                cp -a "$t" "${t}.bak.$(date +%Y%m%d%H%M%S)"
                sed -i -E "s/(PORT[[:space:]]*=[[:space:]]*)${oldport}/\1${newport}/g" "$t"
                log_info "已同步 tnsnames.ora 端口: $t"
            fi

            # 3) 防火墙
            listener_fw_update "$oldport" "$newport"

            # 4) 持久化配置
            set_config LISTENER_PORT "$newport"
            # 同步 env.sh 注入的客户端连接端口 (若文件存在)
            local envf="${OMF_HOME}/cmd/env.sh"
            [ -f "$envf" ] && sed -i -E "s/(PORT=)${oldport}/\1${newport}/g" "$envf" 2>/dev/null || true

            # 5) 重启监听器使新端口生效
            set +e
            listener_stop >/dev/null 2>&1
            set -e
            sleep 2
            listener_start
            if ! listener_running; then
                log_error "监听器重启失败, 已备份原配置在 ${f}.bak.* , 查看: omf log view listener"
                exit 1
            fi
            log_info "监听器已在端口 ${newport} 上重启"

            # 6) 若数据库已 OPEN, 刷新 local_listener 让其重新注册到新端口
            if listener_db_open >/dev/null 2>&1; then
                as_oracle "sqlplus -s / as sysdba <<'SQL'
ALTER SYSTEM SET LOCAL_LISTENER='(ADDRESS=(PROTOCOL=TCP)(HOST=localhost)(PORT=${newport}))' SCOPE=BOTH;
ALTER SYSTEM REGISTER;
EXIT;
SQL" 2>&1 | tail -3
                log_info "已刷新数据库 LOCAL_LISTENER 并触发注册"
            else
                log_warn "数据库当前未运行, 跳过 LOCAL_LISTENER 刷新 (建库/启动后 PMON 会按 listener.ora 注册)"
            fi
            ;;

        *)
            echo "用法: omf listener {status|start|stop|restart|port <新端口>}"
            exit 1
            ;;
    esac
}
