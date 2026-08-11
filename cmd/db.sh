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
# 创建数据库（集成自 03_create_primary_db.sh）
#===============================================================================
db_create() {
    require_root

    # 内存下限强校验: <4GB 直接中止 (Oracle 19c 在小内存上运行极慢/易 OOM)。
    # 即使绕过 omf check preflight 直接建库也能拦截。
    check_memory_prereq "" true

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
        # 建库后钩子: conf/hooks/db_create_after.d/ (可对接 CMDB 登记新库、权限初始化、合规上报)
        run_hooks "db_create_after" "sid=${OMF_CONFIG[ORACLE_SID]}" "pdb=${OMF_CONFIG[PDB_NAME]}"
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

