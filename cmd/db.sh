#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF - 数据库管理命令
# 用法: omf db <subcommand> [options]
#===============================================================================

cmd_db() {
    local subcmd="${1:-status}"
    shift || true
    log_set_subcmd "$subcmd"

    case "$subcmd" in
        create)
            db_create "$@"
            ;;
        status)
            db_status "$@"
            ;;
        start)
            db_start "$@"
            ;;
        stop)
            db_stop "$@"
            ;;
        restart)
            db_stop "$@"
            db_start "$@"
            ;;
        dg)
            db_dg "$@"
            ;;
        pdb)
            db_pdb "$@"
            ;;
        archivelog|arch)
            db_archivelog "$@"
            ;;
        *)
            echo "用法: omf db {create|status|start|stop|restart|dg|pdb|archivelog}"
            exit 1
            ;;
    esac
}

#===============================================================================
# 归档模式管理: omf db archivelog {status|enable|disable}
#   RMAN 物理/增量/归档备份的前置条件. enable 会重启数据库并切到 ARCHIVELOG.
#===============================================================================
db_archivelog() {
    local action="${1:-status}"
    local sid="${OMF_CONFIG[ORACLE_SID]}"
    local home="${OMF_CONFIG[ORACLE_HOME]}"

    case "$action" in
        status)
            require_db_user
            log_step "查询归档模式"
            oracle_su "
export ORACLE_SID=${sid}
export ORACLE_HOME=${home}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -S / as sysdba <<'SQL'
SET PAGESIZE 0 FEEDBACK OFF
SELECT 'log_mode=' || log_mode FROM v\$database;
ARCHIVE LOG LIST;
EXIT;
SQL
"
            ;;
        enable)
            require_db_user
            log_step "开启归档模式 (ARCHIVELOG)"
            log_warn "此操作将重启数据库 (SHUTDOWN IMMEDIATE -> MOUNT -> OPEN), 期间数据库短暂不可用"
            confirm "确认开启归档模式?"

            local arch_dir="${OMF_CONFIG[ORACLE_ARCH]}"
            # 确保归档目录存在 (以 oracle 用户创建, 保证属主正确)
            oracle_su "mkdir -p '${arch_dir}'" 2>/dev/null || true

            set +e
            oracle_su "
export ORACLE_SID=${sid}
export ORACLE_HOME=${home}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -S / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SYSTEM SET log_archive_dest_1='LOCATION=${arch_dir}' SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ARCHIVE LOG LIST;
EXIT;
SQL
"
            local rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then
                log_info "归档模式已开启, 归档目录: ${arch_dir}"
                log_info "现在可执行 RMAN 备份: omf backup physical"
            else
                log_error "开启归档模式失败 (sqlplus rc=${rc}), 请检查 alert 日志: omf log view alert"
            fi
            ;;
        disable)
            require_db_user
            log_step "关闭归档模式 (NOARCHIVELOG)"
            log_warn "关闭归档后将无法进行 RMAN 在线备份与时间点恢复; 此操作将重启数据库"
            confirm_danger "确认关闭归档模式? (关闭后将无法 RMAN 在线备份与时间点恢复)" || return 1

            set +e
            oracle_su "
export ORACLE_SID=${sid}
export ORACLE_HOME=${home}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -S / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE NOARCHIVELOG;
ALTER DATABASE OPEN;
ARCHIVE LOG LIST;
EXIT;
SQL
"
            local rc=$?
            set -e
            [ "$rc" -eq 0 ] && log_info "归档模式已关闭" || \
                log_error "关闭归档模式失败 (sqlplus rc=${rc}), 请检查 alert 日志"
            ;;
        *)
            echo "用法: omf db archivelog {status|enable|disable}"
            exit 1
            ;;
    esac
}

#===============================================================================
# 创建数据库（集成自 03_create_primary_db.sh）
#===============================================================================
db_create() {
    require_root

    # 若配置为延迟大页: 建库前预留 (需连续空闲内存, 趁数据库未起时做)
    if [ "${HUGEPAGES_DEFER:-false}" = "true" ]; then
        local hp; hp=$(omf_hugepages_count)
        log_info "应用延迟预留的 HugePages: vm.nr_hugepages=$hp"
        sysctl -w "vm.nr_hugepages=$hp" >/dev/null 2>&1 || \
            log_warn "大页预留失败(可能内存碎片化), 数据库将不使用大页(性能略降)"
    fi

    local total_mem
    total_mem=$(get_total_memory_mb)
    local oracle_mb; oracle_mb=$(omf_oracle_mem_mb)
    local sga_mb; sga_mb=$(omf_sga_mb)
    local pga_mb=$((oracle_mb - sga_mb))
    local align=128
    sga_mb=$(((sga_mb / align) * align))
    pga_mb=$(((pga_mb / align) * align))

    # 防御: 确保 kernel.shmmax >= SGA, 否则 DBCA 报 DBT-11207 (SGA > shmmax)
    local sga_bytes=$((sga_mb * 1024 * 1024))
    local cur_shmmax; cur_shmmax=$(sysctl -n kernel.shmmax 2>/dev/null || echo 0)
    if [ "${cur_shmmax:-0}" -lt "$sga_bytes" ]; then
        sysctl -w "kernel.shmmax=$sga_bytes" >/dev/null 2>&1 || \
            log_warn "无法设置 kernel.shmmax>=$sga_bytes (当前 $cur_shmmax), 若建库报 DBT-11207 请先 omf env kernel"
    fi

    local fra_size_mb=${OMF_CONFIG[FRA_SIZE_MB]:-0}
    if [ "$fra_size_mb" -lt 20480 ]; then
        fra_size_mb=20480
        log_warn "FRA 已设为最低 20GB"
    fi

    # 自适应: FRA 配置超过所在磁盘可用空间时自动下调, 避免 DBCA 报 DBT-06604
    local fra_parent="${OMF_CONFIG[ORACLE_FRA]}"
    while [ ! -d "$fra_parent" ] && [ "$fra_parent" != "/" ]; do fra_parent=$(dirname "$fra_parent"); done
    local fra_free; fra_free=$(get_disk_free_mb "$fra_parent" 2>/dev/null || echo 0)
    local fra_reserve=15360   # 预留给数据文件 + 归档日志的空间
    local fra_max=$((fra_free - fra_reserve))
    [ "$fra_max" -lt 20480 ] && fra_max=20480
    if [ "$fra_size_mb" -gt "$fra_max" ]; then
        log_warn "FRA 配置 ${fra_size_mb}MB 超过磁盘可用空间 (${fra_free}MB), 已自动下调为 ${fra_max}MB"
        fra_size_mb=$fra_max
    fi

    local total_gb=$((total_mem / 1024))

    # 显示配置确认
    echo ""
    echo "========== 数据库创建配置 =========="
    echo "系统内存:  ${total_gb}GB"
    echo "SGA:       ${sga_mb}MB ($((sga_mb/1024))GB)"
    echo "PGA:       ${pga_mb}MB ($((pga_mb/1024))GB)"
    echo "FRA:       ${fra_size_mb}MB ($((fra_size_mb/1024))GB)"
    echo "SID:       ${OMF_CONFIG[ORACLE_SID]}"
    echo "PDB:       ${OMF_CONFIG[PDB_NAME]}"
    echo "字符集:    ${OMF_CONFIG[CHARSET]}"
    echo "数据目录:  ${OMF_CONFIG[ORACLE_DATA]}"
    echo "====================================="
    echo ""

    # 建库前磁盘预检 (数据盘/备份盘 ≥20GB, FRA 需 ≥ 实际 FRA 配置大小)
    log_step "建库前磁盘预检"
    local -a db_disk_checks=(
        "${OMF_CONFIG[ORACLE_DATA_BASE]}:20480"
        "${OMF_CONFIG[ORACLE_FRA]}:${fra_size_mb}"
        "${OMF_CONFIG[ORACLE_BACKUP]}:20480"
    )
    for entry in "${db_disk_checks[@]}"; do
        local dp="${entry%%:*}"; local thr="${entry#*:}"
        local parent="$dp"
        while [ ! -d "$parent" ] && [ "$parent" != "/" ]; do parent=$(dirname "$parent"); done
        local free; free=$(get_disk_free_mb "$parent" 2>/dev/null || echo 0)
        if [ "${free:-0}" -lt "$thr" ]; then
            log_error "磁盘 ${parent} 剩余 ${free}MB < ${thr}MB, 不足以创建数据库"
        fi
    done

    confirm_danger "确认创建数据库? 此操作将 SHUTDOWN ABORT 并删除现有 SID 的数据文件/FRA/admin 后重建 (数据不可逆丢失)!" || return 1

    # 创建目录
    mkdir -p "${OMF_CONFIG[ORACLE_DATA]}/${OMF_CONFIG[ORACLE_SID]}"
    mkdir -p "${OMF_CONFIG[ORACLE_ARCH]}"
    mkdir -p "${OMF_CONFIG[ORACLE_FRA]}"
    mkdir -p "${OMF_CONFIG[ORACLE_BASE]}/admin/${OMF_CONFIG[ORACLE_SID]}/adump"
    mkdir -p "${OMF_CONFIG[ORACLE_BASE]}/admin/${OMF_CONFIG[ORACLE_SID]}/dpdump"
    chown -R oracle:oinstall \
        "${OMF_CONFIG[ORACLE_DATA_BASE]}" \
        "${OMF_CONFIG[ORACLE_BASE]}/admin"

    # 清理旧实例
    oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
echo 'shutdown abort;' | sqlplus -s / as sysdba
" >/dev/null 2>&1 || true

    # 清理旧文件
    rm -f "${OMF_CONFIG[ORACLE_HOME]}/dbs/init${OMF_CONFIG[ORACLE_SID]}.ora"
    rm -f "${OMF_CONFIG[ORACLE_HOME]}/dbs/spfile${OMF_CONFIG[ORACLE_SID]}.ora"
    rm -f "${OMF_CONFIG[ORACLE_HOME]}/dbs/orapw${OMF_CONFIG[ORACLE_SID]}"

    # 清理上次失败残留的 SID 级目录 (仅删本 SID 子目录, 避免误删整盘)
    # 否则 DBCA 重跑会因"数据库已存在/数据文件冲突"再次失败
    rm -rf "${OMF_CONFIG[ORACLE_DATA]}/${OMF_CONFIG[ORACLE_SID]}"
    rm -rf "${OMF_CONFIG[ORACLE_FRA]}/${OMF_CONFIG[ORACLE_SID]}"
    rm -rf "${OMF_CONFIG[ORACLE_BASE]}/admin/${OMF_CONFIG[ORACLE_SID]}"
    rm -rf "${OMF_CONFIG[ORACLE_BASE]}/cfgtoollogs/dbca/${OMF_CONFIG[ORACLE_SID]}"
    rm -rf "${OMF_CONFIG[ORACLE_BASE]}/diag/rdbms/${OMF_CONFIG[ORACLE_SID]}"
    # 清理 /etc/oratab 中本 SID 行
    [ -f /etc/oratab ] && sed -i "/^${OMF_CONFIG[ORACLE_SID]}:/d" /etc/oratab

    # DBCA 建库
    log_step "DBCA 创建数据库 (预计 15-30 分钟)..."
    log_info "日志: $OMF_RUN_LOG"

    set +e
    set +o pipefail

    oracle_su "
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export PATH=\$ORACLE_HOME/bin:\$PATH

dbca -silent -createDatabase \
    -templateName General_Purpose.dbc \
    -gdbname ${OMF_CONFIG[ORACLE_SID]} \
    -sid ${OMF_CONFIG[ORACLE_SID]} \
    -characterSet ${OMF_CONFIG[CHARSET]} \
    -nationalCharacterSet AL16UTF16 \
    -sysPassword ${OMF_CONFIG[ORACLE_PASSWORD]} \
    -systemPassword ${OMF_CONFIG[SYSTEM_PASSWORD]} \
    -createAsContainerDatabase true \
    -numberOfPDBs 1 \
    -pdbName ${OMF_CONFIG[PDB_NAME]} \
    -pdbAdminPassword ${OMF_CONFIG[PDB_PASSWORD]} \
    -databaseType MULTIPURPOSE \
    -automaticMemoryManagement false \
    -totalMemory 0 \
    -storageType FS \
    -datafileDestination ${OMF_CONFIG[ORACLE_DATA]} \
    -redoLogFileSize ${OMF_CONFIG[REDO_SIZE_MB]} \
    -recoveryAreaDestination ${OMF_CONFIG[ORACLE_FRA]} \
    -recoveryAreaSize ${fra_size_mb} \
    -emConfiguration NONE \
    -initParams \
memory_target=0,\
memory_max_target=0,\
sga_target=${sga_mb}M,\
sga_max_size=${sga_mb}M,\
pga_aggregate_target=${pga_mb}M,\
processes=${OMF_CONFIG[PROCESSES]},\
open_cursors=${OMF_CONFIG[OPEN_CURSORS]},\
db_create_file_dest=${OMF_CONFIG[ORACLE_DATA]},\
db_recovery_file_dest_size=${fra_size_mb}M
" 2>&1 | tee -a "$OMF_RUN_LOG"

    set -e
    set -o pipefail

    if grep -qi "Database creation complete" "$OMF_RUN_LOG"; then
        log_info "数据库创建成功!"
    else
        log_error "数据库创建可能失败，检查日志: $OMF_RUN_LOG"
    fi

    # 验证
    db_status

    # 优化配置
    db_optimize
}

#===============================================================================
# 数据库优化
#===============================================================================
db_optimize() {
    log_step "配置数据库优化参数..."

    oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<'SQL'
SET HEADING OFF
SET FEEDBACK OFF

-- 保存PDB状态
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM v\$pdbs
    WHERE name='${OMF_CONFIG[PDB_NAME]}' AND open_mode='READ WRITE';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'ALTER PLUGGABLE DATABASE ${OMF_CONFIG[PDB_NAME]} SAVE STATE';
    END IF;
END;
/

-- 密码策略
ALTER PROFILE DEFAULT LIMIT
    FAILED_LOGIN_ATTEMPTS 10
    PASSWORD_LOCK_TIME 1
    PASSWORD_LIFE_TIME UNLIMITED
    PASSWORD_GRACE_TIME UNLIMITED
    PASSWORD_REUSE_TIME UNLIMITED
    PASSWORD_REUSE_MAX UNLIMITED
    PASSWORD_VERIFY_FUNCTION NULL;

PROMPT Optimization completed
EXIT;
SQL
"
    log_info "数据库优化完成"
}

#===============================================================================
# 数据库状态
#===============================================================================
db_status() {
    log_step "数据库状态"

    oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<'SQL'
SET PAGES 50 LINES 200
PROMPT ===== 实例状态 =====
SELECT instance_name, status, version, startup_time FROM v\$instance;
PROMPT
PROMPT ===== 数据库状态 =====
SELECT name, open_mode, log_mode, database_role FROM v\$database;
PROMPT
PROMPT ===== PDB状态 =====
SELECT name, open_mode, restricted FROM v\$pdbs;
EXIT;
SQL
"
}

#===============================================================================
# 数据库启动
#   DG 感知: ENABLE_DG=true 时先 STARTUP MOUNT 探测角色;
#     物理备库 -> 保持 MOUNT + 开启 MRP 实时应用 (备库不应 OPEN PDB)
#     主库/未启 DG -> 正常 OPEN + 打开所有 PDB
#===============================================================================
db_start() {
    log_step "启动数据库..."

    if omf_dg_enabled; then
        # 先 MOUNT, 查角色再决定 OPEN 还是留 MOUNT+MRP
        oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -s / as sysdba <<'SQL'
STARTUP MOUNT;
EXIT;
SQL
" || true
        local role; role="$(omf_db_role 2>/dev/null)"
        if echo "$role" | grep -qi "PHYSICAL STANDBY"; then
            log_info "检测到物理备库, 保持 MOUNT 并开启 MRP 实时应用"
            as_oracle "sqlplus -s / as sysdba <<'SQL'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE USING CURRENT LOGFILE DISCONNECT FROM SESSION;
EXIT;
SQL"
            log_info "备库已启动 (MOUNT + MRP)"
            db_status
            return 0
        fi
        # 主库: 继续 OPEN
        as_oracle "sqlplus -s / as sysdba <<'SQL'
ALTER DATABASE OPEN;
ALTER PLUGGABLE DATABASE ALL OPEN;
EXIT;
SQL"
    else
        oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<'SQL'
STARTUP;
ALTER PLUGGABLE DATABASE ALL OPEN;
EXIT;
SQL
"
    fi
    log_info "数据库已启动"
    db_status
}

#===============================================================================
# 数据库停止
#   DG 感知: 物理备库先 CANCEL MRP 再 SHUTDOWN (否则 shutdown 等待 MRP 变慢/报错);
#            备库处于 MOUNT 无 PDB 打开, 跳过 PDB CLOSE (避免 ORA-01109)
#===============================================================================
db_stop() {
    log_step "停止数据库..."
    log_warn "此操作将停止数据库 (SHUTDOWN IMMEDIATE), 期间数据库不可用"
    confirm "确认停止数据库?"

    local role=""
    if omf_dg_enabled; then
        role="$(omf_db_role 2>/dev/null)"
    fi
    if echo "$role" | grep -qi "PHYSICAL STANDBY"; then
        log_info "检测到物理备库, 先停止 MRP 再关库"
        as_oracle "sqlplus -s / as sysdba <<'SQL'
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;
SHUTDOWN IMMEDIATE;
EXIT;
SQL" || true
    else
        oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<'SQL'
ALTER PLUGGABLE DATABASE ALL CLOSE IMMEDIATE;
SHUTDOWN IMMEDIATE;
EXIT;
SQL
"
    fi
    log_info "数据库已停止"
}

#===============================================================================
# PDB 管理
#===============================================================================
db_pdb() {
    local action="${1:-status}"
    local pdb="${2:-${OMF_CONFIG[PDB_NAME]}}"

    case "$action" in
        open)
            oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -s / as sysdba <<'SQL'
ALTER PLUGGABLE DATABASE ${pdb} OPEN;
EXIT;
SQL
"
            log_info "PDB $pdb 已打开"
            ;;
        close)
            # CLOSE IMMEDIATE 会回滚未提交事务并断开该 PDB 上所有会话, 业务立即中断 (可逆: pdb open 恢复)
            log_warn "此操作将关闭 PDB ${pdb} (CLOSE IMMEDIATE), 该 PDB 上的业务会话将被中断"
            confirm "确认关闭 PDB ${pdb}?"
            oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -s / as sysdba <<'SQL'
ALTER PLUGGABLE DATABASE ${pdb} CLOSE IMMEDIATE;
EXIT;
SQL
"
            log_info "PDB $pdb 已关闭"
            ;;
        status|*)
            db_status
            ;;
    esac
}

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
