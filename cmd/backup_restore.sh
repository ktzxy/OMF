#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF - 恢复 restore (从 backup.sh 拆分): backup_restore/restore_logical/restore_rman
# 依赖主文件 cmd/backup.sh 的 parse_scope/scope_clause/ensure_dump_dir (经 source 顺序提供).
#===============================================================================
#===============================================================================
# 恢复
#   omf backup restore <file>                             逻辑恢复 (impdp)
#   omf backup restore --rman [--scn N] [--time '...']     物理时间点/SCN 恢复
#   omf backup restore --rman --validate                  校验备份可恢复性
#===============================================================================
backup_restore() {
    local arg="$1"
    if [ "$arg" = "--rman" ]; then
        shift
        restore_rman "$@"
        return
    fi
    if [ -z "$arg" ]; then
        echo "用法:"
        echo "  omf backup restore <dumpfile> [--pdb <PDB>] [--schema <模式名>]  逻辑恢复(impdp)"
        echo "    --schema <模式名>  仅恢复指定模式(多库场景), 不传则整库 FULL 恢复"
        echo "  omf backup restore --rman [--all|--root|--pdb a,b] [--scn <SCN>] [--time 'YYYY-MM-DD HH24:MI:SS']  物理恢复"
        echo "  omf backup restore --rman [--all|--root|--pdb a,b] --validate 校验备份可恢复性"
        echo ""
        echo "  ※ DG 注意: 主库(ENABLE_DG=true)上执行物理恢复会破坏 Data Guard 备库,"
        echo "    恢复后需在主库重新 dgmgrl 重建备库(或重新 duplicate)。逻辑恢复(impdp)会经 redo 自动同步到备库, 无此问题。"
        echo ""
        echo "可用逻辑备份:"
        ls -1 "${ORACLE_BACKUP}/dump/"*.dmp 2>/dev/null || echo "(无)"
        exit 1
    fi
    restore_logical "$@"
}

# 逻辑恢复 (impdp 全库 REPLACE)
#   用法: omf backup restore <dump> [--pdb <name>]
#   默认恢复到配置 PDB_NAME; --pdb 指定恢复到目标 PDB
restore_logical() {
    local dump_arg="" pdb="" schema=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pdb) pdb="$2"; shift 2;;
            # 多模式(多库)场景: 仅恢复某个 ERP 库(模式), 而非整库 FULL 恢复
            --schema) schema="$2"; shift 2;;
            *)     dump_arg="$1"; shift;;
        esac
    done
    local dump_file="$dump_arg"
    local dump_basename="$(basename "$dump_arg")"

    # %U 是 Data Pump 并行分片通配符, 磁盘上无真实文件, 跳过存在性检查
    if [[ "$dump_basename" != *%U* ]]; then
        [ -f "$dump_file" ] || dump_file="${ORACLE_BACKUP}/dump/${dump_basename}"
        [ -f "$dump_file" ] || log_error "备份文件不存在: $dump_file"
    fi

    # 自动处理并行分片: 传任意一个具体分片(如 _01.dmp)时, 若同批次存在多个分片,
    # 自动改写为 %U 形式, 让 impdp 读入完整备份集, 避免只恢复单个分片导致数据不全
    if [[ "$dump_basename" != *%U* ]]; then
        local prefix="${dump_basename%_[0-9]*.dmp}"
        if [ "$prefix" != "$dump_basename" ]; then
            local shards
            shards=$(ls -1 "${ORACLE_BACKUP}/dump/${prefix}"_*.dmp 2>/dev/null | wc -l)
            if [ "$shards" -gt 1 ]; then
                dump_basename="${prefix}_%U.dmp"
                log_info "检测到 ${shards} 个并行分片, 自动改用 %U 形式: ${dump_basename}"
            fi
        fi
    fi

    [ -z "$pdb" ] && pdb="$PDB_NAME"

    local _scope_desc="PDB=${pdb} (整库 FULL 恢复)"
    [ -n "$schema" ] && _scope_desc="PDB=${pdb} 仅模式=${schema}"
    confirm "确认逻辑恢复 ${dump_file} -> ${_scope_desc}? 这将覆盖现有数据!"
    log_step "开始逻辑恢复: $dump_file -> PDB=${pdb}"
    ensure_dump_dir

    local connect
    if [ "$pdb" = "CDB\$ROOT" ]; then
        connect="system/${SYSTEM_PASSWORD}"
    else
        connect="system/${SYSTEM_PASSWORD}@//localhost:${LISTENER_PORT}/${pdb}"
    fi

    local parfile="/tmp/omf_impdp.par"
    cat > "$parfile" << EOF
USERID="${connect}"
DIRECTORY=OMF_DUMP
DUMPFILE=${dump_basename}
FULL=Y
TABLE_EXISTS_ACTION=REPLACE
PARALLEL=${BACKUP_PARALLEL}
EOF
    # 多模式恢复: --schema 仅恢复指定模式(其余模式不受影响), 否则整库 FULL 恢复
    if [ -n "$schema" ]; then
        log_info "仅恢复模式(模式): ${schema} (其余模式不受影响)"
        # 移除 FULL=Y, 改用 SCHEMAS= 限制恢复范围
        sed -i '/^[[:space:]]*FULL=Y[[:space:]]*$/d' "$parfile"
        echo "SCHEMAS=${schema}" >> "$parfile"
    fi
    chown oracle:oinstall "$parfile" 2>/dev/null || true
    chmod 600 "$parfile"
    set +e
    local restore_log="${ORACLE_BACKUP}/dump/restore_$(date +%Y%m%d_%H%M%S).log"
    as_oracle "impdp parfile=${parfile}" 2>&1 | tee "$restore_log"
    local rc=${PIPESTATUS[0]}
    set -e
    rm -f "$parfile"

    if [ "$rc" -eq 0 ]; then
        log_info "逻辑恢复完成 (PDB=${pdb})"
    else
        # impdp 把"对象已存在"(ORA-31684)也计入 error, 但属非致命, 不影响数据导入
        # 若日志中除 ORA-31684 外无其他 ORA- 错误, 视为恢复成功(仅告警)
        local fatal
        # 注意: 当日志全是 ORA-31684 时, grep -v 排除后管道返回非0, 在 set -e 下会误杀脚本,
        # 故加 || true 保证赋值语句始终成功
        fatal=$(grep -E "ORA-[0-9]{5}" "$restore_log" 2>/dev/null | grep -v "ORA-31684" | head -1) || true
        if [ -z "$fatal" ]; then
            log_info "逻辑恢复完成 (PDB=${pdb}), 仅存在'对象已存在'(ORA-31684)提示, 不影响数据"
        else
            log_error "逻辑恢复失败, 查看日志: $restore_log"
        fi
    fi
}

# 物理恢复 (RMAN): 支持 SCN / 时间点 不完全恢复, 或完全恢复
restore_rman() {
    require_db_user
    parse_scope "$@"
    [ -z "$SCOPE_MODE" ] && SCOPE_MODE="all"
    local sc=$(scope_clause)

    local scn="" rman_time="" validate=0
    local i=0
    while [[ $i -lt ${#SCOPE_REST[@]} ]]; do
        case "${SCOPE_REST[$i]}" in
            --scn)        scn="${SCOPE_REST[$((i+1))]}"; i=$((i+2));;
            --time|--until-time) rman_time="${SCOPE_REST[$((i+1))]}"; i=$((i+2));;
            --validate)   validate=1; i=$((i+1));;
            *)            i=$((i+1));;
        esac
    done

    # 仅校验: 不修改数据库, 检查备份集完整性
    if [ "$validate" -eq 1 ]; then
        log_step "校验备份可恢复性 (RESTORE VALIDATE, scope=${SCOPE_MODE})"

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
        return 0
    fi

    local until_clause=""
    if [ -n "$scn" ]; then
        until_clause="SET UNTIL SCN $scn;"
    elif [ -n "$rman_time" ]; then
        until_clause="SET UNTIL TIME \"TO_DATE('$rman_time','YYYY-MM-DD HH24:MI:SS')\";"
    fi

    # PDB 级恢复需先将目标 PDB 置于 MOUNT
    local pre_sql=""
    if [ "$SCOPE_MODE" = "pdb" ]; then
        pre_sql="sql 'alter pluggable database ${SCOPE_PDBS} close immediate';
    sql 'alter pluggable database ${SCOPE_PDBS} mount';"
    fi

    if [ -z "$until_clause" ]; then
        log_warn "未指定 --scn/--time, 将执行【完全恢复】到最新归档 (不 OPEN RESETLOGS)"
    else
        log_warn "将执行【不完全恢复】${until_clause}"
    fi
    log_warn "恢复范围: ${SCOPE_MODE}$([ "$SCOPE_MODE" = "pdb" ] && echo " (${SCOPE_PDBS})")"

    # DG 守卫: 主库+DG 开启时, 物理恢复会破坏备库(备份集与备库 redo 流不一致)
    if omf_dg_enabled; then
        local role; role="$(omf_db_role 2>/dev/null)"
        if echo "$role" | grep -qi "PRIMARY"; then
            log_warn "检测到【主库 + ENABLE_DG=true】: 物理恢复会使 Data Guard 备库与重建后的主库不一致!"
            log_warn "恢复完成后, 必须重新在主库 dgmgrl 重建备库配置 (或重新 RMAN duplicate 备库), 否则备库永久失效。"
        fi
    fi

    confirm "确认执行物理恢复? 这将用备份覆盖当前数据文件!"

    log_step "执行物理恢复 (RESTORE + RECOVER)..."
    set +e
    as_oracle "rman target / <<RMANEOF
RUN {
    ${pre_sql}
    ${until_clause}
    RESTORE ${sc};
    RECOVER ${sc};
}
RMANEOF"
    local rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        if [ "$SCOPE_MODE" = "pdb" ]; then
            log_info "PDB 恢复完成. 打开 PDB: ALTER PLUGGABLE DATABASE ${SCOPE_PDBS} OPEN;"
        elif [ -n "$until_clause" ]; then
            log_info "不完全恢复完成. 需以 RESETLOGS 打开: ALTER DATABASE OPEN RESETLOGS;"
        else
            log_info "完全恢复完成. 可直接 ALTER DATABASE OPEN; (或 STARTUP)"
        fi
    else
        log_error "物理恢复失败 (rc=$rc), 查看上方 RMAN 输出"
    fi
}
