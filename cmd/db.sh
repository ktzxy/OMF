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
#===============================================================================
db_start() {
    log_step "启动数据库..."

    oracle_su "
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

    oracle_su "
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
            oracle_su "
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
            oracle_su "
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

            oracle_su "
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
            oracle_su "
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
        wallet)
            dg_wallet_setup
            ;;
        validate)
            db_dg_validate
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
            echo "用法: omf db dg {config|enable|standby|wallet|validate|status}"
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
        echo "  主库连接: sys/****@${OMF_CONFIG[PRIMARY_IP]}:1521/${OMF_CONFIG[ORACLE_SID]}"
        echo "  备库连接: sys/****@${OMF_CONFIG[STANDBY_IP]}:1521/${stb_sid}"
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
    (ADDRESS=(PROTOCOL=TCP)(HOST=${OMF_CONFIG[PRIMARY_IP]})(PORT=1521))
    (CONNECT_DATA=(SERVER=DEDICATED)(SERVICE_NAME=${OMF_CONFIG[ORACLE_SID]}))
  )
${stb_alias} =
  (DESCRIPTION=
    (ADDRESS=(PROTOCOL=TCP)(HOST=${OMF_CONFIG[STANDBY_IP]})(PORT=1521))
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
        echo "sys/${OMF_CONFIG[ORACLE_PASSWORD]}@${OMF_CONFIG[PRIMARY_IP]}:1521/${OMF_CONFIG[ORACLE_SID]}"
    fi
}
dg_conn_standby() {
    local stb_sid="${STANDBY_SID:-${OMF_CONFIG[ORACLE_SID]}}"
    if dg_wallet_ready; then
        echo "/@${OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]}"
    else
        echo "sys/${OMF_CONFIG[ORACLE_PASSWORD]}@${OMF_CONFIG[STANDBY_IP]}:1521/${stb_sid}"
    fi
}
