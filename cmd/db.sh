#!/bin/bash
#===============================================================================
# OMF - 数据库管理命令
# 用法: omf db <subcommand> [options]
#===============================================================================

cmd_db() {
    local subcmd="${1:-status}"
    shift || true

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
        *)
            echo "用法: omf db {create|status|start|stop|restart|dg|pdb}"
            exit 1
            ;;
    esac
}

#===============================================================================
# 创建数据库（集成自 03_create_primary_db.sh）
#===============================================================================
db_create() {
    require_root

    local total_mem
    total_mem=$(get_total_memory_mb)
    local oracle_mb=$((total_mem * 80 / 100))
    [ "$oracle_mb" -lt 2048 ] && oracle_mb=2048

    local sga_mb=$((oracle_mb * 75 / 100))
    local pga_mb=$((oracle_mb - sga_mb))
    local align=128
    sga_mb=$(((sga_mb / align) * align))
    pga_mb=$(((pga_mb / align) * align))

    local fra_size_mb=${OMF_CONFIG[FRA_SIZE_MB]:-0}
    if [ "$fra_size_mb" -lt 20480 ]; then
        fra_size_mb=20480
        log_warn "FRA 已设为最低 20GB"
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

    confirm "确认创建数据库?"

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
    su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
echo 'shutdown abort;' | sqlplus -s / as sysdba
" >/dev/null 2>&1 || true

    # 清理旧文件
    rm -f "${OMF_CONFIG[ORACLE_HOME]}/dbs/init${OMF_CONFIG[ORACLE_SID]}.ora"
    rm -f "${OMF_CONFIG[ORACLE_HOME]}/dbs/spfile${OMF_CONFIG[ORACLE_SID]}.ora"
    rm -f "${OMF_CONFIG[ORACLE_HOME]}/dbs/orapw${OMF_CONFIG[ORACLE_SID]}"

    # DBCA 建库
    log_step "DBCA 创建数据库 (预计 15-30 分钟)..."
    log_info "日志: /tmp/dbca_create.log"

    set +e
    set +o pipefail

    su - oracle -c "
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
" 2>&1 | tee /tmp/dbca_create.log

    set -e
    set -o pipefail

    if grep -qi "Database creation complete" /tmp/dbca_create.log; then
        log_info "数据库创建成功!"
    else
        log_error "数据库创建可能失败，检查日志: /tmp/dbca_create.log"
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

    su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<SQL
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

    su - oracle -c "
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
#===============================================================================
db_start() {
    log_step "启动数据库..."

    su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<SQL
STARTUP;
ALTER PLUGGABLE DATABASE ALL OPEN;
EXIT;
SQL
"
    log_info "数据库已启动"
    db_status
}

#===============================================================================
# 数据库停止
#===============================================================================
db_stop() {
    log_step "停止数据库..."

    su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -s / as sysdba <<SQL
ALTER PLUGGABLE DATABASE ALL CLOSE IMMEDIATE;
SHUTDOWN IMMEDIATE;
EXIT;
SQL
"
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
            su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -s / as sysdba <<SQL
ALTER PLUGGABLE DATABASE ${pdb} OPEN;
EXIT;
SQL
"
            log_info "PDB $pdb 已打开"
            ;;
        close)
            su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -s / as sysdba <<SQL
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

    case "$action" in
        config)
            log_step "配置 Data Guard (主库)..."

            su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH

sqlplus -S / as sysdba << SQL
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
            su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -s / as sysdba <<SQL
ALTER SYSTEM SET log_archive_dest_state_2=ENABLE SCOPE=BOTH;
EXIT;
SQL
"
            log_info "日志传输已启用"
            ;;
        standby)
            db_dg_standby "$@"
            ;;
        validate)
            db_dg_validate
            ;;
        status)
            su - oracle -c "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
dgmgrl / 'show configuration'
"
            ;;
        *)
            echo "用法: omf db dg {config|enable|standby|validate|status}"
            ;;
    esac
}

#===============================================================================
# 构建物理备库 (在【备库服务器】执行)
# 通过 RMAN duplicate from active database 自动建备
#===============================================================================
db_dg_standby() {
    log_step "构建物理备库 (RMAN duplicate from active database)"

    local stb_sid="${STANDBY_SID:-${OMF_CONFIG[ORACLE_SID]}}"
    local stb_unique="${OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]}"
    local pri_conn="sys/${ORACLE_PASSWORD}@${OMF_CONFIG[PRIMARY_IP]}:1521/${OMF_CONFIG[ORACLE_SID]}"
    local stb_conn="sys/${ORACLE_PASSWORD}@${OMF_CONFIG[STANDBY_IP]}:1521/${stb_sid}"

    echo ""
    echo "前提条件 (请确认已满足):"
    echo "  1) 备库服务器已安装同版本 Oracle 软件 (omf install software)"
    echo "  2) 主库已执行 'omf db dg config' 并开启归档/Force Logging"
    echo "  3) 主备 TNS/静态监听已配置 (备库需静态监听注册 ${stb_sid})"
    echo "  4) 主库密码文件已复制到备库 \$ORACLE_HOME/dbs/orapw${stb_sid}"
    echo "  主库连接: ${pri_conn}"
    echo "  备库连接: ${stb_conn}"
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
    as_oracle "export ORACLE_SID=${stb_sid}; sqlplus -s / as sysdba <<SQL
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
    as_oracle "sqlplus -s / as sysdba <<SQL
SET LINES 200
SELECT db_unique_name, database_role, open_mode, protection_mode FROM v\$database;
SELECT dest_id, status, error FROM v\$archive_dest_status WHERE dest_id<=2;
SELECT process, status, thread#, sequence# FROM v\$managed_standby;
EXIT;
SQL"
}
