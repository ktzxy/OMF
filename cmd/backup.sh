#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF - 备份管理命令 v2
# 修复: 1) 去掉 require_root (cron 以 oracle 运行) 2) dump 落盘到 backup/dump
#       3) 密码用 parfile 避免泄露 4) 备份失败不删旧备 5) 失败通知
#       6) BACKUP_MODE 配置驱动 (logical|physical|both)
#===============================================================================

cmd_backup() {
    local subcmd="${1:-auto}"
    shift || true
    log_set_subcmd "$subcmd"

    case "$subcmd" in
        full|logical)  backup_logical "$@";;
        physical)      backup_physical "$@";;
        incr)          backup_incremental "$@";;
        archive)       backup_archive "$@";;
        auto)          backup_auto "$@";;
        schedule)      backup_schedule "$@";;
        list)          backup_list "$@";;
        validate)      backup_validate "$@";;
        restore)       backup_restore "$@";;
        cleanup)       backup_cleanup "$@";;
        *) echo "用法: omf backup {auto|full|physical|incr|archive|schedule|list|validate|restore|cleanup} [-d 天数 | --all] [--all|--root|--pdb a,b]"; exit 1;;
    esac
}

# 确保 OMF_DUMP 目录对象存在 (dump 统一落到 backup/dump)
ensure_dump_dir() {
    ensure_backup_dirs
    as_oracle "
export ORACLE_SID=${ORACLE_SID}
sqlplus -s / as sysdba <<'SQL'
WHENEVER SQLERROR CONTINUE
CREATE OR REPLACE DIRECTORY OMF_DUMP AS '${ORACLE_BACKUP}/dump';
GRANT READ, WRITE ON DIRECTORY OMF_DUMP TO system;
-- 目录对象按容器隔离, 在每个已打开的 PDB 中也创建 OMF_DUMP
BEGIN
    FOR r IN (SELECT name FROM v\$pdbs WHERE open_mode = 'READ WRITE') LOOP
        EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER=' || r.name;
        EXECUTE IMMEDIATE 'CREATE OR REPLACE DIRECTORY OMF_DUMP AS ''${ORACLE_BACKUP}/dump''';
        EXECUTE IMMEDIATE 'GRANT READ, WRITE ON DIRECTORY OMF_DUMP TO system';
    END LOOP;
END;
/
EXIT;
SQL
" 2>&1 | tail -5
}

# RMAN 物理/增量/归档备份的前置条件: 数据库须处于 ARCHIVELOG 模式.
# 若为 NOARCHIVELOG, 直接给出明确指引并退出, 避免让用户面对 RMAN-06149 错误栈.
require_archivelog() {
    local logmode
    logmode=$(as_oracle "echo \"select log_mode from v\\\$database;\" | sqlplus -s / as sysdba" 2>/dev/null)
    if echo "$logmode" | grep -qi 'NOARCHIVELOG'; then
        log_error "数据库处于 NOARCHIVELOG 模式, 无法执行 RMAN 备份。请先开启归档模式: omf db archivelog enable"
    fi
    # 查询失败(既非 ARCHIVELOG 也非 NOARCHIVELOG)时不阻断, 交由 RMAN 自行报错
}

# 解析范围参数 (--all / --root / --pdb <name[,name2]>), 设置全局变量:
#   SCOPE_MODE : all | root | pdb | ""(未指定, 由调用方决定默认)
#   SCOPE_PDBS : 逗号分隔的 PDB 名 (仅 pdb 模式)
#   SCOPE_REST : 去除范围参数后的剩余参数 (供调用方继续解析 --scn/--time 等)
parse_scope() {
    SCOPE_MODE=""
    SCOPE_PDBS=""
    local rest=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)  SCOPE_MODE="all"; shift;;
            --root) SCOPE_MODE="root"; shift;;
            --pdb)  SCOPE_MODE="pdb"; SCOPE_PDBS="${2:-}"; shift 2;;
            *)      rest+=("$1"); shift;;
        esac
    done
    SCOPE_REST=("${rest[@]}")
}

# 根据 SCOPE_MODE/SCOPE_PDBS 输出 RMAN 对象表达式 (DATABASE / DATABASE ROOT / PLUGGABLE DATABASE x,y)
# 供 BACKUP/RESTORE/RECOVER/VALIDATE 拼接使用
scope_clause() {
    case "${SCOPE_MODE:-all}" in
        root) echo "DATABASE ROOT";;
        pdb)  echo "PLUGGABLE DATABASE ${SCOPE_PDBS}";;
        all|"") echo "DATABASE";;
    esac
}

# 备份前空间预检: 估算数据库数据文件体量, 与备份目录可用空间比较.
#   物理/增量备份会新增一个完整备份集(压缩后约为数据量 20%~40%), 若目录剩余空间
#   不足以容纳即必然盘满导致备份集损坏——这是生产上最常见的"备份中途失败"事故.
#   直接查询 v$datafile 字节数(不含临时文件), 作为最坏情况的估算下限.
#   余量阈值 BACKUP_SPACE_SAFETY (默认 20%, 即可用空间须 >= 估算备份量 ×(1+阈值)),
#   不足则中止备份并告警 (返回 1), 避免浪费一次注定失败的备份.
backup_spatial_check() {
    local backup_dir="${ORACLE_BACKUP:-/backup/oracle}"
    local safety="${BACKUP_SPACE_SAFETY:-20}"
    # 仅检查目标目录所在文件系统可用空间 (目录尚不存在时回退到其父级)
    local parent="$backup_dir"
    [ -d "$parent" ] || parent="$(dirname "$parent")"
    local avail; avail=$(df -Pk "$parent" 2>/dev/null | awk 'NR==2{print $4}')   # 1K 块
    [ -z "$avail" ] && { log_warn "无法获取备份目录可用空间, 跳过空间预检"; return 0; }
    local avail_bytes=$(( avail * 1024 ))

    # 估算数据文件总字节 (不含 TEMP)
    local dbsz
    dbsz=$(as_oracle "echo \"set pagesize 0 feedback off heading off SELECT SUM(bytes) FROM v\\\$datafile;\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ')
    if [ -z "$dbsz" ] || ! [[ "$dbsz" =~ ^[0-9]+$ ]]; then
        log_warn "无法连接数据库估算体量, 跳过空间预检 (交由 RMAN 自行报错)"
        return 0
    fi
    # 估算备份集大小: 压缩备份约为数据量 35% (经验保守值, 取 1/3)
    local est_backup=$(( dbsz / 3 ))
    local need=$(( est_backup * (100 + safety) / 100 ))
    local avail_h=$(human_size "$avail_bytes")
    local need_h=$(human_size "$need")
    local dbsz_h=$(human_size "$dbsz")

    log_info "空间预检: 数据文件≈${dbsz_h}, 估算备份集≈${need_h}(含 ${safety}% 安全余量), 可用空间=${avail_h}"
    if [ "$avail_bytes" -lt "$need" ]; then
        local short=$(( need - avail_bytes ))
        send_notification "OMF 备份空间不足, 已中止" "备份目录 ${backup_dir} 可用 ${avail_h}, 估算需 ${need_h} (差 $(human_size "$short"))。请清理旧备或扩容后重试。"
        log_error "备份空间不足: 可用 ${avail_h} < 所需 ${need_h}, 已中止以避免盘满损坏备份集"
        return 1
    fi
    return 0
}

# 配置驱动的自动备份
backup_auto() {
    local mode="${BACKUP_MODE:-both}"
    log_step "按配置 BACKUP_MODE=${mode} 执行备份"
    case "$mode" in
        logical)  backup_logical;;
        physical) backup_spatial_check || return 1; backup_physical;;
        both)     backup_logical; backup_spatial_check || return 1; backup_physical;;
        *) log_error "未知 BACKUP_MODE: $mode (应为 logical|physical|both)";;
    esac
}

#===============================================================================
# 逻辑备份 (expdp) -> 落盘到 ${ORACLE_BACKUP}/dump
#   默认: 仅配置 PDB_NAME;  --all: 所有 PDB 各导一份;  --pdb a,b: 指定 PDB;  --root: CDB$ROOT
#   --schema <名>: 仅导出指定模式(多库场景), 复用 omf_schema_user 解析实际用户;
#               此时忽略 scope, 固定导出 PDB_NAME 中的该模式。
#   DG 守卫: 物理备库(PHYSICAL STANDBY)不可做 expdp (需读写库), 必须在主库执行。
#===============================================================================
backup_logical() {
    require_db_user
    local schema="" rest_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --schema) schema="${2:-}"; shift 2;;
            *)       rest_args+=("$1"); shift;;
        esac
    done
    parse_scope "${rest_args[@]}"

    # DG 守卫: 物理备库上 expdp 不可用, 必须到主库执行逻辑备份
    local role; role="$(omf_db_role 2>/dev/null)"
    if echo "$role" | grep -qi "PHYSICAL STANDBY"; then
        log_error "当前为【物理备库 PHYSICAL STANDBY】, 无法执行 expdp 逻辑备份 (需读写库)。请到【主库】执行 omf backup logical"
    fi

    # --schema 限定: 固定单 PDB + 切到 SCHEMAS= 导出
    if [ -n "$schema" ]; then
        SCOPE_MODE="single"
        local su; su="$(omf_schema_user "$schema")"
        log_info "按模式逻辑备份: 模式=${schema} -> 用户=${su} @ PDB=${PDB_NAME}"
    fi
    ensure_dump_dir

    local log_file="$OMF_RUN_LOG"
    local pdbs=()
    case "${SCOPE_MODE:-single}" in
        all)
            log_step "解析所有 PDB 列表"
            mapfile -t pdbs < <(as_oracle "echo \"set pagesize 0 feedback off heading off
select name from v\\\$pdbs;\" | sqlplus -s / as sysdba" 2>/dev/null \
                | sed 's/[[:space:]]//g' | grep -v '^$')
            # 过滤只读种子 PDB (PDB$SEED): 非业务数据, 其服务通常不向监听器注册,
            # 逻辑备份无意义且必现 ORA-12514, 直接排除避免拖垮整个 --all
            local _f=()
            for _p in "${pdbs[@]}"; do
                if [ "$_p" = "PDB\$SEED" ]; then
                    log_info "跳过种子 PDB ($_p), 无需逻辑备份"
                else
                    _f+=("$_p")
                fi
            done
            pdbs=("${_f[@]}")
            [ "${#pdbs[@]}" -gt 0 ] || log_error "未查询到任何 PDB(已排除种子 PDB\$SEED), 请确认业务 PDB 已打开"
            ;;
        root)
            pdbs=("CDB\$ROOT")
            ;;
        pdb)
            local IFS=','; read -r -a pdbs <<< "$SCOPE_PDBS"
            ;;
        single|"")
            pdbs=("$PDB_NAME")
            ;;
    esac

    local _fail=0
    for pdb in "${pdbs[@]}"; do
        local su=""
        [ -n "$schema" ] && su="$(omf_schema_user "$schema")"
        backup_logical_one "$pdb" "$log_file" "$su" || _fail=$((_fail+1))
    done
    # 仅当本次【所有】逻辑备份都成功时才清理旧 dump; 若任一分片失败, 保留旧 dump
    # 以维持可恢复窗口 (与物理备份"失败不删旧备"语义一致, 避免失败时清掉可用的历史备份)。
    if [ "$_fail" -eq 0 ]; then
        backup_cleanup_disks "dump" "${BACKUP_RETENTION_DAYS}"
    else
        log_warn "本次逻辑备份有 ${_fail} 个分片失败, 已保留旧 dump (未清理), 请检查后重试"
    fi
    unset _fail
}

# 单个 PDB/CDB$ROOT 的 expdp 全库导出
#   $3 = schema_user (可选): 非空则导出该模式(替换 FULL=Y 为 SCHEMAS=), 仅该模式数据落盘
backup_logical_one() {
    local pdb="$1"; local log_file="$2"; local schema_user="${3:-}"
    local ts=$(date '+%Y%m%d_%H%M%S')
    local dump_dir="${ORACLE_BACKUP}/dump"
    # 注意: parfile 路径不能含 PDB 名, 因为 PDB 名可能含 '$' (如 PDB$SEED/CDB$ROOT),
    # 该路径经 as_oracle 多层双引号链后在 oracle 层 '$SEED' 会被当变量展开成空, 导致 LRM-00109.
    # 改用 ts+PID 保证唯一且无 '$'; parfile 内部 DUMPFILE/USERID 仍用 ${pdb} (由 expdp 直接读取, 不经 shell).
    local parfile="/tmp/omf_expdp_${ts}_$$.par"

    local connect
    if [ "$pdb" = "CDB\$ROOT" ]; then
        connect="system/${SYSTEM_PASSWORD}"
    else
        # EZCONNECT: 不依赖 tnsnames 别名, 直接连 PDB 服务名
        connect="system/${SYSTEM_PASSWORD}@//localhost:${LISTENER_PORT}/${pdb}"
    fi

    # 用 parfile 避免密码出现在 ps; 密码含 #/! 等特殊字符时须用双引号包裹 USERID,
    # 否则 Data Pump 会把 # 当作注释导致密码被截断 (ORA-01017)
    cat > "$parfile" << EOF
USERID="${connect}"
DIRECTORY=OMF_DUMP
DUMPFILE=full_${pdb}_${ts}_%U.dmp
LOGFILE=full_${pdb}_${ts}.log
FULL=Y
COMPRESSION=${BACKUP_COMPRESSION}
PARALLEL=${BACKUP_PARALLEL}
FLASHBACK_TIME=SYSTIMESTAMP
CLUSTER=N
EOF
    chown oracle:oinstall "$parfile" 2>/dev/null || true
    chmod 600 "$parfile"

    # 按模式导出: 移除 FULL=Y, 改用 SCHEMAS= 限定模式 (多库场景按库单独备份)
    if [ -n "$schema_user" ]; then
        sed -i '/^[[:space:]]*FULL=Y[[:space:]]*$/d' "$parfile"
        sed -i "s|^DUMPFILE=.*|DUMPFILE=schema_${schema_user}_${ts}_%U.dmp|" "$parfile"
        sed -i "s|^LOGFILE=.*|LOGFILE=schema_${schema_user}_${ts}.log|" "$parfile"
        echo "SCHEMAS=${schema_user}" >> "$parfile"
        log_step "逻辑备份(按模式)开始 (expdp SCHEMAS=${schema_user} -> PDB=${pdb}) -> ${dump_dir}"
    else
        log_step "逻辑全量备份开始 (expdp -> PDB=${pdb}) -> ${dump_dir}"
    fi
    set +e
    as_oracle "expdp parfile=${parfile}" 2>&1 | tee -a "$log_file"
    local rc=${PIPESTATUS[0]}
    set -e

    # 清理临时 parfile (含密码)
    rm -f "$parfile"

    if [ "$rc" -eq 0 ] && grep -qi "successfully completed" "$log_file"; then
        if [ -n "$schema_user" ]; then
            log_info "逻辑备份(按模式)完成 (${schema_user}@${pdb}): ${dump_dir}/schema_${schema_user}_${ts}_*.dmp"
        else
            log_info "逻辑全量备份完成 (PDB=${pdb}): ${dump_dir}/full_${pdb}_${ts}_*.dmp"
        fi
    else
        send_notification "OMF 逻辑备份失败 (PDB=${pdb})" "日志: $log_file"
        log_error "逻辑备份失败 (PDB=${pdb}), 查看日志: $log_file"
    fi
}

# RMAN 执行 + 失败重试 (缓解网络存储抖动等偶发瞬断导致的误报失败)
#   $1  = 重试次数 (默认读 RMAN_RETRY, 再回退 1: 即失败重试 1 次, 共最多 2 次)
#   $2  = 重试间隔秒 (默认读 RMAN_RETRY_INTERVAL, 再回退 5)
#   $3  = rman 脚本 (heredoc 内容, 不含外层 rman target / <<RMANEOF 包装)
#   成功判定: rc=0 且日志中不含 RMAN-/ORA- 错误; 返回 0 成功 / 1 失败
rman_run() {
    local retries="${1:-${OMF_CONFIG[RMAN_RETRY]:-1}}"; shift || true
    local interval="${2:-${OMF_CONFIG[RMAN_RETRY_INTERVAL]:-5}}"; shift || true
    local script="$1"
    local attempt=0 log_file="$OMF_RUN_LOG"
    while [ "$attempt" -le "$retries" ]; do
        [ "$attempt" -gt 0 ] && log_warn "RMAN 备份失败, 第 ${attempt} 次重试 (共 ${retries} 次, 间隔 ${interval}s)..."
        set +e
        as_oracle "rman target / <<RMANEOF
${script}
RMANEOF" 2>&1 | tee "$log_file"
        local rc=${PIPESTATUS[0]}
        set -e
        if [ "$rc" -eq 0 ] && ! grep -qiE "RMAN-[0-9]{5}|ORA-[0-9]{5}" "$log_file"; then
            return 0
        fi
        attempt=$(( attempt + 1 ))
        [ "$attempt" -le "$retries" ] && sleep "$interval"
    done
    return 1
}

#===============================================================================
# RMAN 增量备份
#===============================================================================
backup_incremental() {
    require_db_user
    parse_scope "$@"
    [ -z "$SCOPE_MODE" ] && SCOPE_MODE="all"   # 物理默认整 CDB
    require_archivelog
    ensure_backup_dirs

    local level="${SCOPE_REST[0]:-1}"
    local ts=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="${ORACLE_BACKUP}/incremental"
    local log_file="$OMF_RUN_LOG"
    local sc=$(scope_clause)

    log_step "RMAN 增量备份 (Level $level, scope=${SCOPE_MODE})"
    local rman_script="CONFIGURE BACKUP OPTIMIZATION ON;
CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${BACKUP_RETENTION_DAYS} DAYS;
CONFIGURE DEVICE TYPE DISK PARALLELISM ${BACKUP_PARALLEL};
CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT '${backup_dir}/%d_%T_%s_%p';
RUN {
    BACKUP INCREMENTAL LEVEL ${level} ${sc} PLUS ARCHIVELOG;
    BACKUP CURRENT CONTROLFILE FORMAT '${ORACLE_BACKUP}/controlfile/controlfile_%d_%T_%s';
    BACKUP SPFILE FORMAT '${ORACLE_BACKUP}/spfile/spfile_%d_%T_%s';
}"
    if rman_run "" "" "$rman_script"; then
        log_info "RMAN 增量备份完成"
        # 备份成功后才清理 obsolete
        as_oracle "rman target / <<RMANEOF
DELETE NOPROMPT OBSOLETE;
RMANEOF" 2>&1 | tail -3
    else
        send_notification "OMF 增量备份失败" "日志: $log_file"
        log_error "RMAN 增量备份失败, 查看日志: $log_file"
    fi
}

#===============================================================================
# 归档日志备份
#===============================================================================
backup_archive() {
    require_db_user
    parse_scope "$@"
    require_archivelog
    ensure_backup_dirs

    local ts=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="${ORACLE_BACKUP}/archive"
    local log_file="$OMF_RUN_LOG"
    local arch_clause="ARCHIVELOG ALL"
    [ "$SCOPE_MODE" = "pdb" ] && arch_clause="ARCHIVELOG FOR PLUGGABLE DATABASE ${SCOPE_PDBS}"

    log_step "归档日志备份 (scope=${SCOPE_MODE:-all})"
    set +e
    as_oracle "rman target / <<RMANEOF
BACKUP ${arch_clause} FORMAT '${backup_dir}/arch_%d_%T_%s_%p';
RMANEOF" 2>&1 | tee "$log_file"
    local rc=${PIPESTATUS[0]}
    set -e

    [ "$rc" -eq 0 ] && log_info "归档日志备份完成" || \
        { send_notification "OMF 归档备份失败" "日志: $log_file"; log_error "归档备份失败: $log_file"; }
}

#===============================================================================
# 物理备份 (RMAN 全量) -> 失败不删旧备
#===============================================================================
backup_physical() {
    require_db_user
    parse_scope "$@"
    [ -z "$SCOPE_MODE" ] && SCOPE_MODE="all"   # 物理默认整 CDB
    require_archivelog
    ensure_backup_dirs

    local ts=$(date '+%Y%m%d_%H%M%S')
    local backup_dir="${ORACLE_BACKUP}/full"
    local log_file="$OMF_RUN_LOG"
    local sc=$(scope_clause)

    log_step "RMAN 物理全量备份 (scope=${SCOPE_MODE})"
    local rman_script="CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${BACKUP_RETENTION_DAYS} DAYS;
CONFIGURE DEVICE TYPE DISK PARALLELISM ${BACKUP_PARALLEL};
CONFIGURE CHANNEL DEVICE TYPE DISK FORMAT '${backup_dir}/%d_%T_%s_%p';
RUN {
    BACKUP AS COMPRESSED BACKUPSET ${sc} PLUS ARCHIVELOG;
    BACKUP CURRENT CONTROLFILE FORMAT '${ORACLE_BACKUP}/controlfile/controlfile_%d_%T_%s';
    BACKUP SPFILE FORMAT '${ORACLE_BACKUP}/spfile/spfile_%d_%T_%s';
}"
    if rman_run "" "" "$rman_script"; then
        log_info "RMAN 物理全量备份完成"
        as_oracle "rman target / <<RMANEOF
DELETE NOPROMPT OBSOLETE;
RMANEOF" 2>&1 | tail -3
        backup_cleanup_disks "full" "${BACKUP_RETENTION_DAYS}"
    else
        send_notification "OMF 物理备份失败" "日志: $log_file"
        log_error "RMAN 物理备份失败 (已保留旧备), 查看: $log_file"
    fi
}

#===============================================================================
# 备份列表 (含按保留天数高亮的"即将过期"提示)
#   omf backup list [all|expdp|rman]
#   保留期: BACKUP_RETENTION_DAYS (默认 30); 即将过期阈值: BACKUP_WARN_DAYS
#     (留空则取保留期的 1/5, 钳制在 2~7 天)
#===============================================================================
backup_list() {
    local type="${1:-all}"
    local retention="${BACKUP_RETENTION_DAYS:-30}"
    # 即将过期阈值: 优先 BACKUP_WARN_DAYS, 否则按保留期的 1/5 (钳制 2~7 天)
    local warn_days="${BACKUP_WARN_DAYS:-}"
    if [ -z "$warn_days" ]; then
        warn_days=$(( retention / 5 ))
        [ "$warn_days" -lt 2 ] && warn_days=2
        [ "$warn_days" -gt 7 ] && warn_days=7
    fi
    local now_ts; now_ts=$(date +%s)

    # ---- RPO (恢复点目标) 概览: 距上次成功备份的时长 ----
    # 逻辑 RPO = 最新 dump 文件的 mtime; 物理 RPO = V\$BACKUP_SET 最大完成时间
    # 综合 RPO 取两者较旧者 (更保守, 反映最坏情况可能丢失的数据时长)
    local rpo_logical_min="" rpo_physical_min="" newest_dmp=""
    if [ "$type" = "all" ] || [ "$type" = "expdp" ]; then
        newest_dmp=$(ls -t "${ORACLE_BACKUP}/dump/"*.dmp 2>/dev/null | head -1)
        if [ -n "$newest_dmp" ]; then
            local m; m=$(stat -c %Y "$newest_dmp" 2>/dev/null || echo "$now_ts")
            rpo_logical_min=$(( (now_ts - m) / 60 ))
        fi
    fi
    if [ "$type" = "all" ] || [ "$type" = "rman" ]; then
        local max_bs
        max_bs=$(as_oracle "echo \"set pagesize 0 feedback off heading off SELECT TO_CHAR(MAX(completion_time),'YYYY-MM-DD HH24:MI:SS') FROM v\\\$backup_set;\" | sqlplus -s / as sysdba" 2>/dev/null | tr -d ' ')
        if [ -n "$max_bs" ] && [ "$max_bs" != "-" ]; then
            local bs_ts; bs_ts=$(date -d "$max_bs" +%s 2>/dev/null)
            [ -n "$bs_ts" ] && rpo_physical_min=$(( (now_ts - bs_ts) / 60 ))
        fi
    fi

    # 计算文件 mtime 距今天数 -> _age
    local _age=0
    _file_age_days() {
        local m; m=$(stat -c %Y "$1" 2>/dev/null) || { _age=0; return; }
        _age=$(( (now_ts - m) / 86400 ))
    }
    # 按剩余天数输出带色标签 (剩余<=0 红, <=warn 黄, 否则绿)
    _retain_tag() {
        local rem="$1"
        if [ "$rem" -le 0 ]; then
            echo -e "${RED}已过期(将清理)${NC}"
        elif [ "$rem" -le "$warn_days" ]; then
            echo -e "${YELLOW}即将过期(剩${rem}天)${NC}"
        else
            echo -e "${GREEN}正常(剩${rem}天)${NC}"
        fi
    }

    echo ""
    echo "========== 备份 RPO / 恢复点目标概览 =========="
    if [ -n "$rpo_logical_min" ]; then
        echo -e "  逻辑备份 RPO: ${BOLD}$(fmt_duration "$rpo_logical_min")${NC}  (最新 dump: $(basename "$newest_dmp"))"
    fi
    if [ -n "$rpo_physical_min" ]; then
        echo -e "  物理备份 RPO: ${BOLD}$(fmt_duration "$rpo_physical_min")${NC}  (基于 V\$BACKUP_SET)"
    fi
    if [ -z "$rpo_logical_min" ] && [ -z "$rpo_physical_min" ]; then
        echo "  (暂无备份, RPO 不可评估)"
    else
        local overall=""
        if [ -n "$rpo_logical_min" ] && [ -n "$rpo_physical_min" ]; then
            if [ "$rpo_logical_min" -gt "$rpo_physical_min" ]; then overall=$rpo_logical_min
            else overall=$rpo_physical_min; fi
        elif [ -n "$rpo_logical_min" ]; then overall=$rpo_logical_min
        elif [ -n "$rpo_physical_min" ]; then overall=$rpo_physical_min; fi
        echo -e "  ⇒ 综合 RPO (最坏情况): ${BOLD}${RED}$(fmt_duration "$overall")${NC}"
    fi

    echo ""
    echo "========== 备份文件列表 =========="
    echo -e "保留策略: ${BOLD}BACKUP_RETENTION_DAYS=${retention} 天${NC}  |  即将过期: 剩余 ≤ ${warn_days} 天标黄, ≤ 0 天标红"

    if [ "$type" = "all" ] || [ "$type" = "expdp" ]; then
        echo ""; echo "[Expdp 逻辑备份] (${ORACLE_BACKUP}/dump)"
        echo "  $(printf '%-40s %9s  %6s   %s' '文件名' '大小' '年龄' '保留状态')"
        local any=0 f_name
        shopt -s nullglob
        for f in "${ORACLE_BACKUP}/dump/"*.dmp; do
            any=1
            _file_age_days "$f"
            local rem=$(( retention - _age ))
            f_name="$(basename "$f")"
            local sz; sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
            printf "  %-40s %9s  %5s天前  %s\n" "$f_name" "$(human_size "$sz")" "$_age" "$(_retain_tag "$rem")"
        done
        shopt -u nullglob
        [ "$any" -eq 0 ] && echo "  (空)"
    fi

    if [ "$type" = "all" ] || [ "$type" = "rman" ]; then
        echo ""; echo "[RMAN 备份集]"
        as_oracle "rman target / <<RMANEOF
LIST BACKUP SUMMARY;
RMANEOF" 2>/dev/null || echo "  (无 RMAN 备份)"

        # 即将过期分析: 直接查控制文件中的备份集完成时间
        echo ""; echo "  -- 即将过期分析 (基于 V\$BACKUP_SET) --"
        local sql_out
        sql_out=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT TO_CHAR(completion_time,'YYYY-MM-DD')||'|'||ROUND(SYSDATE-completion_time,1) FROM v\\\$backup_set ORDER BY completion_time;\" | sqlplus -s / as sysdba" 2>/dev/null)
        if [ -z "$sql_out" ]; then
            echo "  (无法连接数据库, 跳过 RMAN 过期分析)"
        else
            local total=0 expired=0 soon=0 line ct age rem tag
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                # 跳过 SQL*Plus 报错/标题行 (不含 '|' 分隔符)
                [[ "$line" == *"|"* ]] || continue
                ct="${line%%|*}"; age="${line##*|}"
                # 规范化年龄: 去前导空格, 补前导零 (如 .1 -> 0.1)
                age=$(printf '%.1f' "$age" 2>/dev/null || echo "$age")
                # age 为小数, 用 awk 做减法得到整数剩余天数
                rem=$(awk "BEGIN{printf \"%d\", $retention - $age}" 2>/dev/null) || rem=0
                [ -z "$rem" ] && rem=0
                total=$((total+1))
                if [ "$rem" -le 0 ]; then expired=$((expired+1)); fi
                if [ "$rem" -le "$warn_days" ]; then
                    soon=$((soon+1))
                    tag=$(_retain_tag "$rem")
                    printf "    %s  年龄%s天  %s\n" "$ct" "$age" "$tag"
                fi
            done <<< "$sql_out"
            echo -e "  备份集总数: ${total}  |  已过期(将清理): ${RED}${expired}${NC}  |  即将过期(≤${warn_days}天): ${YELLOW}${soon}${NC}"
        fi
    fi

    echo ""; echo "[备份目录占用]"
    du -sh "${ORACLE_BACKUP}"/* 2>/dev/null || echo "(空)"
}


#===============================================================================
# 备份可恢复性校验 (演练前必做)
#===============================================================================
backup_validate() {
    require_db_user
    parse_scope "$@"
    [ -z "$SCOPE_MODE" ] && SCOPE_MODE="all"
    local sc=$(scope_clause)
    log_step "备份可恢复性校验 (scope=${SCOPE_MODE})"

    # 前置判断: 无任何 RMAN 备份集时, 直接提示并退出, 避免把 RMAN 错误栈暴露给用户
    local rman_list
    rman_list=$(as_oracle "rman target / <<RMANEOF
LIST BACKUP SUMMARY;
RMANEOF" 2>&1) || true
    if ! echo "$rman_list" | grep -qiE "BS Key|List of Backup"; then
        log_warn "无备份可校验: 未检测到任何 RMAN 备份集"
        echo "  请先创建备份后再校验, 例如:"
        echo "    omf backup physical      # RMAN 物理全量备份"
        echo "    omf backup auto          # 按 BACKUP_MODE 配置执行"
        exit 2
    fi

    as_oracle "rman target / <<RMANEOF
RESTORE ${sc} VALIDATE;
RESTORE ARCHIVELOG ALL VALIDATE;
RMANEOF"

    echo ""
    echo "逻辑备份文件:"
    ls -lht "${ORACLE_BACKUP}/dump/"*.dmp 2>/dev/null || echo "(无逻辑备份)"
}

#===============================================================================
# 内部清理: 删除指定子目录下 N 天前的 .dmp/.log (无交互确认, 供备份后自动清理)
# 注意: 与 lib/common.sh 的 backup_cleanup (支持 --all/-d 的交互式清理) 区分,
#       本函数仅作备份成功后的"顺手清旧"使用, 不会被 omf backup cleanup 调用.
#===============================================================================
backup_cleanup_disks() {
    local type="${1:-dump}"
    local days="${2:-30}"
    # 注意: find -mtime +N 实际删 (N+1) 天前, 故用 +(days-1) 实现"保留 days 天"
    log_debug "清理 ${days} 天前的 ${type} 备份"
    find "${ORACLE_BACKUP}/${type}" -name "*.dmp" -mtime "+$((days-1))" -delete 2>/dev/null || true
    find "${ORACLE_BACKUP}/${type}" -name "*.log" -mtime "+$((days-1))" -delete 2>/dev/null || true
}

#===============================================================================
# 配置定时备份 (按 BACKUP_MODE 生成)
#===============================================================================
backup_schedule() {
    local action="${1:-show}"
    case "$action" in
        setup|remove) require_root;;
    esac
    case "$action" in
        setup)
            local mode="${BACKUP_MODE:-both}"
            {
                echo "# OMF 备份定时任务 (BACKUP_MODE=${mode})"
                echo "0 2 * * * oracle ${OMF_HOME}/omf.sh -y backup auto >> ${OMF_HOME}/logs/omf_backup.log 2>&1"
                echo "0 */4 * * * oracle ${OMF_HOME}/omf.sh -y backup archive >> ${OMF_HOME}/logs/omf_backup.log 2>&1"
            } > /etc/cron.d/omf_backup
            chmod 644 /etc/cron.d/omf_backup
            systemctl restart crond 2>/dev/null || service cron restart 2>/dev/null || true
            log_info "定时备份已配置 (BACKUP_MODE=${mode})"
            cat /etc/cron.d/omf_backup
            ;;
        show)
            [ -f /etc/cron.d/omf_backup ] && cat /etc/cron.d/omf_backup \
                || echo "未配置, 执行 'omf backup schedule setup'"
            ;;
        remove) rm -f /etc/cron.d/omf_backup; log_info "定时备份已移除";;
        *) echo "用法: omf backup schedule {setup|show|remove}";;
    esac
}
