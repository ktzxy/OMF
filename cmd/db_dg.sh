#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF - Data Guard 管理 (从 db.sh 拆分)
# 由 omf.sh 在 db 命令分发时 source; 依赖 lib/common.sh 的 oracle_su/as_oracle/confirm 等.
# 内部完全自洽: db_dg 分发器 + 各 db_dg_* / dg_wallet_* / dg_conn_* 辅助函数.
#===============================================================================
#===============================================================================
# Data Guard 配置
#===============================================================================
db_dg() {
    local action="${1:-config}"
    shift || true

    case "$action" in
        config)
            log_step "配置 Data Guard (主库)..."

            oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -S / as sysdba << 'SQL'
SET SERVEROUTPUT ON
ALTER SYSTEM SET db_unique_name='${OMF_CONFIG[DB_UNIQUE_NAME_PRIMARY]}' SCOPE=SPFILE;

PROMPT 启用归档模式...
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ALTER DATABASE FORCE LOGGING;

PROMPT 配置DG参数...
ALTER SYSTEM SET standby_file_management=AUTO SCOPE=BOTH;
ALTER SYSTEM SET fal_server='${OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]}' SCOPE=BOTH;
ALTER SYSTEM SET dg_broker_start=TRUE SCOPE=BOTH;
ALTER SYSTEM SET log_archive_config='DG_CONFIG=(${OMF_CONFIG[DB_UNIQUE_NAME_PRIMARY]},${OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]})' SCOPE=BOTH;
ALTER SYSTEM SET log_archive_dest_2='SERVICE=${OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]} ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=${OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]}' SCOPE=BOTH;
ALTER SYSTEM SET log_archive_dest_state_2=DEFER SCOPE=BOTH;

-- 添加 Standby Redo Log
DECLARE
    v_group_count NUMBER;
    v_log_size NUMBER;
    v_sql VARCHAR2(500);
BEGIN
    SELECT MAX(GROUP#), MAX(BYTES/1024/1024)
    INTO v_group_count, v_log_size FROM V\$LOG;

    DBMS_OUTPUT.PUT_LINE('Redo log size: ' || v_log_size || 'M');

    FOR i IN 1..(v_group_count + 1) LOOP
        v_sql := 'ALTER DATABASE ADD STANDBY LOGFILE GROUP ' ||
                 (v_group_count + i) ||
                  ' (''' || '${OMF_CONFIG[ORACLE_DATA]}/${OMF_CONFIG[ORACLE_SID]}' || '/standby_redo' ||
                 LPAD(v_group_count + i, 2, '0') || '.log'') ' ||
                 'SIZE ' || v_log_size || 'M';
        EXECUTE IMMEDIATE v_sql;
        DBMS_OUTPUT.PUT_LINE('Standby redo group ' || (v_group_count + i) || ' added');
    END LOOP;
END;
/

CREATE PFILE='${OMF_CONFIG[ORACLE_BASE]}/admin/${OMF_CONFIG[ORACLE_SID]}/pfile/init${OMF_CONFIG[ORACLE_SID]}.ora' FROM SPFILE;

SHUTDOWN IMMEDIATE;
STARTUP;

PROMPT ===== 验证DG配置 =====
SELECT 'LOG_MODE: ' || LOG_MODE AS info FROM V\$DATABASE;
SELECT 'FORCE_LOGGING: ' || FORCE_LOGGING AS info FROM V\$DATABASE;
SELECT 'DATABASE_ROLE: ' || DATABASE_ROLE AS info FROM V\$DATABASE;
SELECT GROUP#, THREAD#, BYTES/1024/1024 AS SIZE_MB, STATUS FROM V\$STANDBY_LOG ORDER BY GROUP#;
EXIT;
SQL
"
            log_info "DG 主库配置完成 (log_archive_dest_state_2 仍为 DEFER, 备库就绪后执行 omf db dg enable)"
            ;;
        enable)
            log_step "启用日志传输 (log_archive_dest_state_2=ENABLE)..."
            oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -s / as sysdba <<'SQL'
ALTER SYSTEM SET log_archive_dest_state_2=ENABLE SCOPE=BOTH;
EXIT;
SQL
"
            log_info "日志传输已启用"
            ;;
        standby)
            db_dg_standby "$@"
            ;;
        wallet)
            dg_wallet_setup
            ;;
        validate)
            db_dg_validate
            ;;
        broker)
            db_dg_broker "$@"
            ;;
        switchover)
            db_dg_switchover "$@"
            ;;
        failover)
            db_dg_failover "$@"
            ;;
        reinstate)
            db_dg_reinstate "$@"
            ;;
        apply)
            db_dg_apply "$@"
            ;;
        gap)
            db_dg_gap "$@"
            ;;
        status)
            oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
dgmgrl / 'show configuration'
"
            ;;
        *)
            echo "用法: omf db dg {config|enable|standby|wallet|broker|switchover|failover|reinstate|apply|gap|validate|status}"
            echo "  config      配置主库 (归档/Force Logging/SRL/参数)"
            echo "  enable      开启日志传输 (dest_state_2=ENABLE)"
            echo "  standby     备库服务器自动建备 (RMAN duplicate)"
            echo "  wallet      创建 DG 钱包 (主备各执行一次)"
            echo "  broker      创建/重建 Broker 配置 (switchover/failover 前置)"
            echo "  switchover  计划内主备切换 (无数据丢失, 需 Broker 就绪)"
            echo "  failover [--immediate]  灾难切换 (主库故障时在备库执行)"
            echo "  reinstate   failover 后将旧主库回收为新备库 (需 Flashback)"
            echo "  apply {start|stop|status}  备库 MRP 应用管理"
            echo "  gap         查看传输/应用延迟与归档间隙"
            echo "  validate    校验 DG 配置/传输状态"
            echo "  status      查看 Broker 配置 (dgmgrl)"
            ;;
    esac
}

#===============================================================================
# 创建/重建 Data Guard Broker 配置 (在【主库】执行)
#   switchover/failover 的前置条件. 幂等: 已存在同名配置时先移除再重建.
#   前提: 主备均 dg_broker_start=TRUE, 备库已建好且日志传输正常 (omf db dg enable)
#===============================================================================
db_dg_broker() {
    require_db_user
    local pri="${OMF_CONFIG[DB_UNIQUE_NAME_PRIMARY]}"
    local stb="${OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]}"

    # 角色守卫: broker 配置只能在主库创建
    local role; role="$(omf_db_role 2>/dev/null)"
    if [ -n "$role" ] && ! echo "$role" | grep -qi "PRIMARY"; then
        log_error "当前数据库角色为 ${role}, Broker 配置须在【主库】创建"
    fi

    log_step "创建 Data Guard Broker 配置: ${pri} (主) + ${stb} (备)"
    echo ""
    echo "前提条件 (请确认已满足):"
    echo "  1) 备库已建好 (omf db dg standby) 且日志传输已开启 (omf db dg enable)"
    echo "  2) 主备均已配置 tnsnames 别名 ${pri}/${stb} (omf db dg wallet 会写入)"
    echo "  3) 主备 dg_broker_start=TRUE (omf db dg config 已设置主库)"
    echo ""
    confirm "确认创建 Broker 配置? (已存在同名配置将被移除重建)"

    set +e
    as_oracle "dgmgrl / <<DGEOF
REMOVE CONFIGURATION;
CREATE CONFIGURATION 'omf_dg' AS PRIMARY DATABASE IS '${pri}' CONNECT IDENTIFIER IS ${pri};
ADD DATABASE '${stb}' AS CONNECT IDENTIFIER IS ${stb} MAINTAINED AS PHYSICAL;
ENABLE CONFIGURATION;
SHOW CONFIGURATION;
DGEOF" 2>&1 | tee -a "$OMF_RUN_LOG"
    local rc=${PIPESTATUS[0]}
    set -e

    if [ "$rc" -eq 0 ] && grep -qi "SUCCESS\|Configuration.*enabled" "$OMF_RUN_LOG"; then
        log_info "Broker 配置已创建。等待 1-2 分钟让 broker 完成健康检查, 再执行 omf db dg status 确认 SUCCESS"
    else
        log_warn "Broker 配置可能未完全成功, 请执行 omf db dg status 查看; 常见原因: 备库未注册静态监听/别名不可达"
    fi
}

#===============================================================================
# 计划内主备切换 Switchover (在【主库】执行, 无数据丢失)
#   预检: Broker 配置 SUCCESS + 目标备库 Ready for Switchover: Yes
#===============================================================================
db_dg_switchover() {
    require_db_user
    local target="${OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to) target="${2:-$target}"; shift 2;;
            *) shift;;
        esac
    done

    log_step "计划内主备切换 (Switchover) -> 目标: ${target}"

    # 1. 角色守卫: switchover 应在主库发起
    local role; role="$(omf_db_role 2>/dev/null)"
    if [ -z "$role" ]; then
        log_error "数据库不可连接, 无法执行 switchover"
    fi
    if ! echo "$role" | grep -qi "PRIMARY"; then
        log_error "当前角色为 ${role}, switchover 须在【主库】发起 (主库故障请用 omf db dg failover)"
    fi

    # 2. Broker 健康预检
    local cfg
    cfg=$(as_oracle "dgmgrl / 'show configuration'" 2>/dev/null)
    if ! echo "$cfg" | grep -qi "SUCCESS"; then
        log_warn "Broker 配置状态非 SUCCESS:"
        echo "$cfg"
        log_error "请先修复 Broker 状态 (omf db dg status / validate), 或先执行 omf db dg broker 创建配置"
    fi

    # 3. 切换就绪预检 (validate database 输出 Ready for Switchover)
    local vout
    vout=$(as_oracle "dgmgrl / 'validate database ${target}'" 2>/dev/null)
    echo "$vout"
    if ! echo "$vout" | grep -qi "Ready for Switchover:.*Yes"; then
        log_error "目标备库 ${target} 未就绪 (Ready for Switchover 非 Yes), 请检查日志传输/应用延迟 (omf db dg gap)"
    fi

    log_warn "切换后: 本机变为【备库】, ${target} 变为【主库】; 应用连接串需指向新主库"
    confirm "确认执行 switchover 到 ${target}?"

    set +e
    as_oracle "dgmgrl / 'switchover to ${target}'" 2>&1 | tee -a "$OMF_RUN_LOG"
    local rc=${PIPESTATUS[0]}
    set -e

    if [ "$rc" -eq 0 ] && ! grep -qi "ORA-\|error" "$OMF_RUN_LOG"; then
        log_info "Switchover 完成! 本机现为备库, 新主库: ${target}"
        log_info "后续: 1) 应用改连新主库  2) omf db dg status 确认配置 SUCCESS  3) 本机备库确认 MRP 应用 (omf db dg apply status)"
        # 多组织应用重连指引: 切换后新主库为原备库 (STANDBY_IP)
        dg_app_conn_guide "${OMF_CONFIG[STANDBY_IP]}" "$target"
        # 切换后钩子: conf/hooks/dg_switchover_after.d/ (可对接 CMDB 翻转连接串、通知应用侧、合规留痕)
        run_hooks "dg_switchover_after" "new_primary=$target" "old_primary=${OMF_CONFIG[ORACLE_SID]}"
        send_notification "OMF DG Switchover 完成" "新主库: ${target}"
    else
        log_warn "Switchover 可能未完全成功, 请立即检查: omf db dg status 与两端 alert 日志"
        send_notification "OMF DG Switchover 异常" "请检查 dgmgrl 输出与 alert 日志"
    fi
}

#===============================================================================
# 灾难切换 Failover (主库故障时在【备库】执行)
#   默认完全 failover (尽量零丢失); --immediate 立即切换 (可能丢数据)
#   切换后旧主库须 reinstate (需提前开 Flashback) 或重建
#===============================================================================
db_dg_failover() {
    require_db_user
    local target="${OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]}" immediate="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to)        target="${2:-$target}"; shift 2;;
            --immediate) immediate="true"; shift;;
            *) shift;;
        esac
    done

    log_step "灾难切换 (Failover) -> 目标: ${target}"

    # 角色守卫: failover 在备库发起 (主库还活着就不该 failover)
    # 注: 用不带锚点的 PRIMARY 匹配 (sqlplus 输出可能带空白); PHYSICAL/LOGICAL STANDBY 不含 PRIMARY, 无误判
    local role; role="$(omf_db_role 2>/dev/null)"
    if echo "$role" | grep -qi "PRIMARY"; then
        log_error "当前是【主库】且存活, 不应执行 failover! 计划内切换请用 omf db dg switchover"
    fi
    if [ -z "$role" ]; then
        log_error "本机数据库不可连接, 无法执行 failover (failover 须在存活的【备库】上执行)"
    fi

    echo ""
    log_warn "⚠ Failover 是灾难操作, 仅当主库确认不可恢复时执行!"
    log_warn "  - 旧主库将被 Broker 标记为需要 reinstate (需其 Flashback Database 已开启)"
    log_warn "  - 若 Flashback 未开, 旧主库只能重建 (omf db dg standby)"
    [ "$immediate" = "true" ] && log_warn "  - IMMEDIATE 模式: 不等待剩余 redo 应用, 【可能丢失数据】!"
    echo ""
    confirm_danger "确认主库已不可恢复, 执行 failover 到 ${target}? (灾难切换: 旧主库需 reinstate 或重建, 可能造成数据差异/脑裂)" || return 1

    local fo_cmd="failover to ${target}"
    [ "$immediate" = "true" ] && fo_cmd="failover to ${target} immediate"

    set +e
    as_oracle "dgmgrl / '${fo_cmd}'" 2>&1 | tee -a "$OMF_RUN_LOG"
    local rc=${PIPESTATUS[0]}
    set -e

    if [ "$rc" -eq 0 ]; then
        log_info "Failover 完成! 本机现为新主库: ${target}"
        log_info "后续: 1) 应用改连本机  2) 旧主库修复后执行 omf db dg reinstate 回收为备库"
        # 多组织应用重连指引: failover 后本机(原备库)为新主库
        dg_app_conn_guide "${OMF_CONFIG[STANDBY_IP]}" "$target"
        # 灾难切换后钩子: conf/hooks/dg_failover_after.d/ (可对接告警升级、CMDB 主备翻转、应急流程)
        run_hooks "dg_failover_after" "new_primary=$target"
        send_notification "OMF DG Failover 完成" "新主库: ${target}, 请尽快处理旧主库 (reinstate 或重建)"
    else
        log_error "Failover 失败 (rc=$rc), 请检查 dgmgrl 输出与 alert 日志"
    fi
}

#===============================================================================
# Reinstate: failover 后将旧主库回收为新备库 (在【新主库】执行)
#   前提: 旧主库已 STARTUP MOUNT 且其 Flashback Database 在 failover 前已开启
#===============================================================================
db_dg_reinstate() {
    require_db_user
    local target="${1:-${OMF_CONFIG[DB_UNIQUE_NAME_PRIMARY]}}"

    log_step "Reinstate 旧主库 ${target} 为新备库"

    local role; role="$(omf_db_role 2>/dev/null)"
    if [ -n "$role" ] && ! echo "$role" | grep -qi "PRIMARY"; then
        log_error "当前角色为 ${role}, reinstate 须在【新主库】执行"
    fi

    echo "前提: 旧主库 (${target}) 已修复并 STARTUP MOUNT, 且其 Flashback 在 failover 前已开启"
    confirm "确认 reinstate ${target}?"

    set +e
    as_oracle "dgmgrl / 'reinstate database ${target}'" 2>&1 | tee -a "$OMF_RUN_LOG"
    local rc=${PIPESTATUS[0]}
    set -e

    if [ "$rc" -eq 0 ]; then
        log_info "Reinstate 完成, ${target} 现为新备库。执行 omf db dg status 确认配置 SUCCESS"
    else
        log_warn "Reinstate 失败。若旧主库 Flashback 未开启, 只能重建备库: 在旧主库服务器执行 omf db dg standby"
    fi
}

#===============================================================================
# 备库 MRP (Managed Recovery Process) 应用管理 (在【备库】执行)
#   apply start: 开启实时应用; apply stop: 停止应用; apply status: 查看应用进程
#===============================================================================
db_dg_apply() {
    require_db_user
    local action="${1:-status}"
    local role; role="$(omf_db_role 2>/dev/null)"

    case "$action" in
        start)
            if [ -n "$role" ] && ! echo "$role" | grep -qi "STANDBY"; then
                log_error "当前角色为 ${role}, MRP 应用只能在【备库】开启"
            fi
            log_step "开启备库实时应用 (MRP, USING CURRENT LOGFILE)"
            as_oracle "sqlplus -s / as sysdba <<'SQL'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
EXIT;
SQL" 2>/dev/null || \
            as_oracle "sqlplus -s / as sysdba <<'SQL'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
EXIT;
SQL"
            log_info "MRP 已开启 (实时应用)"
            ;;
        stop)
            # 停止 MRP 后备库不再追平主库: 长期不重启应用会累积应用延迟与归档间隙,
            #   主库归档可能因备库未确认而堆积撑满 FRA (可逆: apply start 恢复并自动追平)
            log_warn "此操作将停止备库 MRP 应用, 备库不再追平主库; 长期停止会累积归档间隙并可能撑满 FRA"
            log_warn "维护完成后请及时执行: omf db dg apply start"
            confirm "确认停止备库应用 (MRP CANCEL)?"
            log_step "停止备库应用 (MRP CANCEL)"
            as_oracle "sqlplus -s / as sysdba <<'SQL'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
EXIT;
SQL"
            log_info "MRP 已停止"
            ;;
        status|*)
            log_step "备库应用进程状态"
            as_oracle "sqlplus -s / as sysdba <<'SQL'
SET LINES 200 PAGES 50
SELECT process, status, thread#, sequence#, block# FROM v\$managed_standby ORDER BY process;
EXIT;
SQL"
            ;;
    esac
}

#===============================================================================
# 传输/应用延迟与归档间隙 (主备均可执行)
#===============================================================================
db_dg_gap() {
    require_db_user
    log_step "Data Guard 传输/应用延迟与归档间隙"
    as_oracle "sqlplus -s / as sysdba <<'SQL'
SET LINES 200 PAGES 50
PROMPT ===== 当前角色 =====
SELECT db_unique_name, database_role, open_mode, protection_mode FROM v\$database;
PROMPT
PROMPT ===== 传输/应用延迟 (备库上有值) =====
SELECT name, value, time_computed FROM v\$dataguard_stats
WHERE name IN ('transport lag','apply lag','apply finish time');
PROMPT
PROMPT ===== 归档间隙 (有行即存在 GAP) =====
SELECT thread#, low_sequence#, high_sequence# FROM v\$archive_gap;
PROMPT
PROMPT ===== 归档目的地状态 =====
SELECT dest_id, status, error FROM v\$archive_dest_status WHERE dest_id<=2;
PROMPT
PROMPT ===== 主库: 最新归档序列 vs 备库已应用 (主库上执行有意义) =====
SELECT dest_id, MAX(sequence#) AS max_seq, MAX(CASE WHEN applied='YES' THEN sequence# END) AS max_applied
FROM v\$archived_log GROUP BY dest_id ORDER BY dest_id;
EXIT;
SQL"
}

#===============================================================================
# 构建物理备库 (在【备库服务器】执行)
# 通过 RMAN duplicate from active database 自动建备
#===============================================================================
db_dg_standby() {
    log_step "构建物理备库 (RMAN duplicate from active database)"

    local stb_sid="${STANDBY_SID:-${OMF_CONFIG[ORACLE_SID]}}"
    local stb_unique="${OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]}"
    # 钱包就绪则用 /@别名 免密 (不在 ps 暴露密码), 否则回退 EZConnect
    local pri_conn; pri_conn=$(dg_conn_primary)
    local stb_conn; stb_conn=$(dg_conn_standby)

    echo ""
    echo "前提条件 (请确认已满足):"
    echo "  1) 备库服务器已安装同版本 Oracle 软件 (omf install software)"
    echo "  2) 主库已执行 'omf db dg config' 并开启归档/Force Logging"
    echo "  3) 主备 TNS/静态监听已配置 (备库需静态监听注册 ${stb_sid})"
    echo "  4) 主库密码文件已复制到备库 \$ORACLE_HOME/dbs/orapw${stb_sid}"
    if dg_wallet_ready; then
        echo "  连接方式: 钱包免密 (/@别名, 已在主备执行 'omf db dg wallet')"
    else
        echo "  主库连接: sys/****@${OMF_CONFIG[PRIMARY_IP]}:${OMF_CONFIG[LISTENER_PORT]:-1521}/${OMF_CONFIG[ORACLE_SID]}"
        echo "  备库连接: sys/****@${OMF_CONFIG[STANDBY_IP]}:${OMF_CONFIG[LISTENER_PORT]:-1521}/${stb_sid}"
        echo "  建议: 主备均执行 'omf db dg wallet' 以消除 ps 中密码残留"
    fi
    echo ""
    confirm "确认在【当前备库服务器】执行建备? (将创建目录/参数文件并启动 duplicate)"

    # 1. 创建备库目录
    mkdir -p "${OMF_CONFIG[ORACLE_DATA]}/${stb_sid}" \
             "${OMF_CONFIG[ORACLE_ARCH]}" \
             "${OMF_CONFIG[ORACLE_FRA]}" \
             "${OMF_CONFIG[ORACLE_BASE]}/admin/${stb_sid}/adump"
    chown -R oracle:oinstall "${OMF_CONFIG[ORACLE_DATA_BASE]}" \
        "${OMF_CONFIG[ORACLE_BASE]}/admin" 2>/dev/null || true

    # 2. 生成备库最小参数文件
    local pfile="/tmp/init_${stb_sid}.ora"
    cat > "$pfile" << EOF
*.db_name='${OMF_CONFIG[ORACLE_SID]}'
*.db_unique_name='${stb_unique}'
*.control_files='${OMF_CONFIG[ORACLE_DATA]}/${stb_sid}/control01.ctl'
*.db_file_name_convert='${OMF_CONFIG[ORACLE_DATA]}/${OMF_CONFIG[ORACLE_SID]}','${OMF_CONFIG[ORACLE_DATA]}/${stb_sid}'
*.log_file_name_convert='${OMF_CONFIG[ORACLE_DATA]}/${OMF_CONFIG[ORACLE_SID]}','${OMF_CONFIG[ORACLE_DATA]}/${stb_sid}'
*.log_archive_dest_1='LOCATION=${OMF_CONFIG[ORACLE_ARCH]}'
*.log_archive_dest_2='SERVICE=${OMF_CONFIG[DB_UNIQUE_NAME_PRIMARY]} ASYNC VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE) DB_UNIQUE_NAME=${OMF_CONFIG[DB_UNIQUE_NAME_PRIMARY]}'
*.standby_file_management=AUTO
*.fal_server='${OMF_CONFIG[DB_UNIQUE_NAME_PRIMARY]}'
*.remote_login_passwordfile=EXCLUSIVE
*.db_recovery_file_dest='${OMF_CONFIG[ORACLE_FRA]}'
*.db_recovery_file_dest_size=${OMF_CONFIG[FRA_SIZE_MB]}M
EOF
    chown oracle:oinstall "$pfile" 2>/dev/null || true

    # 3. 启动到 nomount
    log_step "启动备库实例到 NOMOUNT..."
    as_oracle "export ORACLE_SID=${stb_sid}; sqlplus -s / as sysdba <<'SQL'
STARTUP NOMOUNT PFILE='${pfile}';
EXIT;
SQL"

    # 4. RMAN duplicate
    log_step "执行 RMAN duplicate (可能耗时较长)..."
    set +e
    as_oracle "rman <<RMANEOF
CONNECT TARGET '${pri_conn}'
CONNECT AUXILIARY '${stb_conn}'
DUPLICATE TARGET DATABASE
  FOR STANDBY
  FROM ACTIVE DATABASE
  DORECOVER
  SPFILE
  SET db_unique_name='${stb_unique}'
  NOFILENAMECHECK;
RMANEOF"
    local rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        log_info "物理备库构建完成! 在主库执行 'omf db dg enable' 开启日志传输, 再 'omf db dg validate' 校验"
    else
        log_error "duplicate 失败 (rc=$rc), 请检查主备网络/静态监听/密码文件/目录权限"
    fi
}

#===============================================================================
# 校验 Data Guard 配置
#===============================================================================
db_dg_validate() {
    log_step "校验 Data Guard 配置"
    if as_oracle "dgmgrl / 'validate database ${OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]}'" 2>/dev/null; then
        return 0
    fi
    # 退化方案: 直接查视图
    as_oracle "sqlplus -s / as sysdba <<'SQL'
SET LINES 200
SELECT db_unique_name, database_role, open_mode, protection_mode FROM v\$database;
SELECT dest_id, status, error FROM v\$archive_dest_status WHERE dest_id<=2;
SELECT process, status, thread#, sequence# FROM v\$managed_standby;
EXIT;
SQL"
}

#===============================================================================
# Data Guard 钱包 (Wallet) —— 消除 ps 中的 sys/密码 残留 (根因修复)
# 在【主库与备库】各自执行一次:
#   1) 创建自动登录钱包 (orapki, 钱包密码为随机值, 仅建库用, 运行时免输入)
#   2) 将 sys 凭据存入钱包 (密码经文件管道传入, 不进命令行/ps)
#   3) 写入 sqlnet.ora / tnsnames.ora
#   之后 DG 连接改用 /@<别名> 免密, 详见 dg_conn_*
# 说明: 建钱包时 orapki 的 -pwd 随机钱包密码会短暂出现在 ps, 但其为一次性随机值,
#       并非数据库密码; 数据库 sys 密码全程不出现在命令行/ps, 达成根因修复目标。
#===============================================================================
dg_wallet_setup() {
    require_db_user
    local wdir="${OMF_CONFIG[ORACLE_BASE]}/wallet"
    local net_admin="${OMF_CONFIG[ORACLE_HOME]}/network/admin"
    local pri_alias="${OMF_CONFIG[DB_UNIQUE_NAME_PRIMARY]}"
    local stb_alias="${OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]}"
    local stb_sid="${STANDBY_SID:-${OMF_CONFIG[ORACLE_SID]}}"
    local wallet_pwd_file="${wdir}/.walletpwd"
    local sys_pwd_file="${wdir}/.syspwd"
    local ready="${wdir}/.omf_dg_wallet_ready"

    log_step "配置 DG 钱包 (Wallet): ${wdir}"

    mkdir -p "$wdir" "$net_admin"
    chown -R oracle:oinstall "$wdir" 2>/dev/null || true

    # 钱包密码随机生成; 真实数据库密码经 heredoc 写入文件 (不在命令行暴露)
    local wpwd
    wpwd=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 32)
    [ -z "$wpwd" ] && wpwd="OmF_$(date +%s)_wAl3t"
    cat > "$wallet_pwd_file" <<PWD_EOF
$wpwd
PWD_EOF
    cat > "$sys_pwd_file" <<PWD_EOF
${OMF_CONFIG[ORACLE_PASSWORD]}
PWD_EOF
    chmod 600 "$wallet_pwd_file" "$sys_pwd_file"
    chown oracle:oinstall "$wallet_pwd_file" "$sys_pwd_file" 2>/dev/null || true

    # 以 oracle 执行钱包与凭据创建 (密码经 cat 管道传入, 不在 ps 暴露)
    oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export ORACLE_BASE=${OMF_CONFIG[ORACLE_BASE]}
export PATH=\$ORACLE_HOME/bin:\$PATH

# 1. 创建自动登录钱包 (钱包密码为随机一次性值, 运行时自动登录无需输入)
orapki wallet create -wallet '${wdir}' -auto_login -pwd \"\$(cat '${wallet_pwd_file}')\"

# 2. 写入 sys 凭据 (钱包密码 + 凭据密码, 经管道依次读入, 不在命令行暴露)
cat '${wallet_pwd_file}' '${sys_pwd_file}' '${sys_pwd_file}' | mkstore -wrl '${wdir}' -createCredential '${pri_alias}' sys
cat '${wallet_pwd_file}' '${sys_pwd_file}' '${sys_pwd_file}' | mkstore -wrl '${wdir}' -createCredential '${stb_alias}' sys
"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        log_error "钱包或凭据创建失败 (rc=$rc), 请检查 ORACLE_HOME/bin 下 orapki/mkstore 是否可用"
    fi

    # 3. sqlnet.ora: 钱包位置与覆盖 (幂等)
    if ! grep -q "OMF_DG_WALLET" "$net_admin/sqlnet.ora" 2>/dev/null; then
        cat >> "$net_admin/sqlnet.ora" <<EOF

# OMF_DG_WALLET (auto-login)
WALLET_LOCATION=(SOURCE=(METHOD=FILE)(METHOD_DATA=(DIRECTORY=${wdir})))
SQLNET.WALLET_OVERRIDE=TRUE
SSL_CLIENT_AUTHENTICATION=FALSE
EOF
    fi

    # 4. tnsnames.ora: 主备别名 (幂等)
    if ! grep -q "OMF_DG_WALLET" "$net_admin/tnsnames.ora" 2>/dev/null; then
        cat >> "$net_admin/tnsnames.ora" <<EOF

# OMF_DG_WALLET aliases
${pri_alias} =
  (DESCRIPTION=
    (ADDRESS=(PROTOCOL=TCP)(HOST=${OMF_CONFIG[PRIMARY_IP]})(PORT=${OMF_CONFIG[LISTENER_PORT]:-1521}))
    (CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=${OMF_CONFIG[ORACLE_SID]}))
  )
${stb_alias} =
  (DESCRIPTION=
    (ADDRESS=(PROTOCOL=TCP)(HOST=${OMF_CONFIG[STANDBY_IP]})(PORT=${OMF_CONFIG[LISTENER_PORT]:-1521}))
    (CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=${stb_sid}))
  )
EOF
    fi

    # 5. 清理临时数据库密码副本 (保留钱包密码文件供后续维护, 权限 600)
    rm -f "$sys_pwd_file"
    touch "$ready"
    chmod 600 "$ready"
    chown -R oracle:oinstall "$wdir" 2>/dev/null || true

    log_info "DG 钱包配置完成: 主备别名 ${pri_alias} / ${stb_alias}"
    log_info "请在【主库与备库】均执行一次本命令; 之后 'omf db dg standby' 将自动改用 /@别名 免密连接"
}

# 钱包是否就绪 (由 dg_wallet_setup 写入标记)
dg_wallet_ready() {
    [ -f "${OMF_CONFIG[ORACLE_BASE]}/wallet/.omf_dg_wallet_ready" ]
}

# 返回 DG 连接串: 钱包就绪用 /@别名 (免密, 不在 ps 暴露), 否则回退 EZConnect
dg_conn_primary() {
    if dg_wallet_ready; then
        echo "/@${OMF_CONFIG[DB_UNIQUE_NAME_PRIMARY]}"
    else
        echo "sys/${OMF_CONFIG[ORACLE_PASSWORD]}@${OMF_CONFIG[PRIMARY_IP]}:${OMF_CONFIG[LISTENER_PORT]:-1521}/${OMF_CONFIG[ORACLE_SID]}"
    fi
}
dg_conn_standby() {
    local stb_sid="${STANDBY_SID:-${OMF_CONFIG[ORACLE_SID]}}"
    if dg_wallet_ready; then
        echo "/@${OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]}"
    else
        echo "sys/${OMF_CONFIG[ORACLE_PASSWORD]}@${OMF_CONFIG[STANDBY_IP]}:${OMF_CONFIG[LISTENER_PORT]:-1521}/${stb_sid}"
    fi
}

#===============================================================================
# 多组织应用连接串指引 (switchover/failover 后调用)
#   $1 = 新主库 IP (switchover 后=原 STANDBY_IP; failover 后=本机/STANDBY_IP)
#   $2 = 新主库唯一名 (用于钱包免密提示)
# 遍历 APP_SCHEMAS(多组织模式), 输出每个组织的应用连接串与重连指引。
# 多组织应用都连同一 PDB 的同一服务, 切换后必须统一把连接串指向新主库 IP;
# OMF 不自动翻转 tnsnames 别名, 这里给出每个组织的明确连接串供应用侧改配置。
#===============================================================================
dg_app_conn_guide() {
    local new_pri_ip="$1" new_pri_name="${2:-${OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]}}"
    local port="${OMF_CONFIG[LISTENER_PORT]:-1521}"
    local pdb="${OMF_CONFIG[PDB_NAME]}"
    local schema s u

    echo ""
    echo "══════ 多组织应用重连指引 (新主库: ${new_pri_name} @ ${new_pri_ip}:${port}/${pdb}) ══════"
    echo "各组织应用需把连接串指向新主库 IP。钱包免密可继续用 /@别名, 否则用 EZConnect 直连:"
    for schema in $(omf_schema_list); do
        u=$(omf_schema_user "$schema")
        echo "  - 模式[${schema}] 用户=${u}"
        echo "      EZConnect: ${u}/密码@${new_pri_ip}:${port}/${pdb}"
        echo "      钱包免密: ${u}@//localhost:${port}/${pdb} (若钱包未指向新主库, 请更新 TNS_ADMIN 别名或重建钱包)"
    done
    echo "  - 管理连接: sys@${new_pri_ip}:${port}/${pdb} (as sysdba)"
    echo "═══════════════════════════════════════════════════════════════════════"
    echo ""
    log_warn "注意: OMF 不自动翻转 tnsnames/钱包别名指向的 IP, 请确保各组织应用实际连到新主库 IP, 否则会连到已变备库(不可写)"
}
