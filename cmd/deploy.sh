#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF - 一键部署编排
# 串联: 预检 -> 环境准备 -> 安装软件 -> 建库 -> 开归档 -> 初始化 -> 首次备份
# 通过调用 omf.sh 子进程复用既有子命令, 每步独立进程/日志, 错误隔离
# 用法: omf deploy [--zip <db_home.zip>] [--edition EE|SE]
#===============================================================================

cmd_deploy() {
    require_root

    local zip="" edition="" from_step="" skip_csv="" list_only=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --zip)     zip="$2"; shift 2;;
            --edition) edition="$2"; shift 2;;
            --from)    from_step="$2"; shift 2;;
            --skip)    skip_csv="${skip_csv:+$skip_csv,}$2"; shift 2;;
            --list)    list_only=1; shift;;
            # 全局 -y 已在 omf.sh 入口解析并设置 OMF_ASSUME_YES, 这里吞掉以免被当参数传给子命令
            -y|--yes|--assume-yes) shift;;
            -*) shift;;   # 忽略其它未知选项
            *)  shift;;
        esac
    done

    local self="${OMF_HOME}/omf.sh"
    [ -x "$self" ] || log_error "找不到 omf 入口: $self"

    # 步骤定义: "子命令: 中文描述" —— 子命令即 omf 的一级+二级命令
    local steps=()
    steps+=("check preflight:预检环境 (用户/OS/内存/磁盘/依赖)")
    steps+=("env all:准备系统环境 (用户/内核/依赖/目录/防火墙)")
    steps+=("install software:安装 Oracle 软件")
    steps+=("db create:创建数据库 (CDB + PDB)")
    steps+=("db archivelog enable:开启归档模式 (物理备份前置)")
    steps+=("sql init:初始化 (建模式/表空间 + 执行初始化 SQL)")
    steps+=("backup auto:首次备份 (按 BACKUP_MODE: 逻辑/物理)")

    # 解析 --from / --skip 为待跳过的步骤下标集合 (1-based)
    # 支持: 序号(3) / 命令(db create) / 逗号分隔 / 重复 --skip
    local -a skip_idx=()
    _deploy_resolve_skip() {
        local spec="$1" i cmd desc key
        local -a toks
        IFS=',' read -ra toks <<< "$spec"
        for key in "${toks[@]}"; do
            [ -z "$key" ] && continue
            if [[ "$key" =~ ^[0-9]+$ ]]; then
                skip_idx[$key]=1
            else
                i=1
                for s in "${steps[@]}"; do
                    cmd="${s%%:*}"; desc="${s##*:}"
                    if [ "$key" = "$cmd" ] || [ "$key" = "$desc" ]; then
                        skip_idx[$i]=1; break
                    fi
                    i=$((i+1))
                done
            fi
        done
    }
    local resolved_from=0
    if [ -n "$from_step" ]; then
        if [[ "$from_step" =~ ^[0-9]+$ ]]; then
            resolved_from=$from_step
        else
            local i=1 cmd
            for s in "${steps[@]}"; do
                cmd="${s%%:*}"
                if [ "$from_step" = "$cmd" ]; then resolved_from=$i; break; fi
                i=$((i+1))
            done
        fi
        [ "$resolved_from" -ge 1 ] 2>/dev/null || log_error "无法识别 --from 步骤: $from_step (可用 omf deploy --list 查看)"
    fi
    [ -n "$skip_csv" ] && _deploy_resolve_skip "$skip_csv"
    # --from N: 跳过 N 之前的所有步骤
    if [ "$resolved_from" -gt 0 ]; then
        local j
        for (( j=1; j<resolved_from; j++ )); do skip_idx[$j]=1; done
    fi

    if [ "$list_only" -eq 1 ]; then
        log_step "========== OMF 部署步骤清单 =========="
        local n=1
        for s in "${steps[@]}"; do
            echo "  ${n}) omf ${s%%:*}  -  ${s##*:}"
            n=$((n+1))
        done
        echo "";
        echo "用法: omf deploy [--from <序号|步骤>] [--skip <序号|步骤>[,...]] [--zip <zip>] [--edition EE|SE]"
        return 0
    fi

    log_step "========== OMF 一键部署编排 =========="
    log_info "将依次执行 ${#steps[@]} 个步骤 (--from=$from_step --skip=$skip_csv):"
    # 总耗时预估: install(15-30分) + db create(15-30分) 是大头, 加上其余步骤合计约 40-70 分钟
    log_info "⚠ 预计总耗时约 40-70 分钟 (软件安装 + 建库各 15-30 分钟; 若 --skip 跳过 install/db 会显著缩短)。期间请勿中断终端或 Ctrl-C!"
    local n=1
    for s in "${steps[@]}"; do
        local tag=""
        [ "${skip_idx[$n]:-0}" = "1" ] && tag=" [跳过]"
        log_info "  ${n}) ${s##*:}  (omf ${s%%:*})${tag}"
        n=$((n+1))
    done
    [ -n "$zip" ]     && log_info "安装包(zip): $zip"
    [ -n "$edition" ] && log_info "安装版本: $edition"
    echo ""

    local i=1 total=${#steps[@]}
    for s in "${steps[@]}"; do
        local cmd="${s%%:*}" desc="${s##*:}"
        if [ "${skip_idx[$i]:-0}" = "1" ]; then
            log_info "↷ [${i}/${total}] 跳过: ${desc}  (omf ${cmd})"
            i=$((i+1)); continue
        fi
        # install software / db create 透传参数与危险放行
        local full="$cmd" dangerous=0
        if [ "$cmd" = "install software" ]; then
            [ -n "$zip" ]     && full="$full $zip"
            [ -n "$edition" ] && full="$full $edition"
        fi
        # db create 会 SHUTDOWN ABORT 并删除现有 SID 数据后重建 (不可逆); 其 confirm_danger
        #   在 -y/非交互下默认中止, 故 deploy 以 OMF_ALLOW_DANGEROUS=1 显式放行 (部署即重建语义)
        [ "$cmd" = "db create" ] && dangerous=1

        log_step "== [${i}/${total}] ${desc} =="
        log_info "执行: omf -y ${full}"
        echo "----------------------------------------"
        # 子进程非零退出码在 if 条件中, 不会触发父进程 set -e; 每步独立进程/日志, 错误隔离
        local rc_dep
        if [ "$dangerous" -eq 1 ]; then
            OMF_ALLOW_DANGEROUS=1 "$self" -y $full; rc_dep=$?
        else
            "$self" -y $full; rc_dep=$?
        fi
        if [ "$rc_dep" -eq 0 ]; then
            log_info "✓ 完成: ${desc}"
        else
            log_error "✗ 步骤 [${i}/${total}] ${desc} 失败, 部署中止。可单独修复后重跑: omf -y ${full}"
            echo "----------------------------------------"
            return 1
        fi
        echo "----------------------------------------"
        i=$((i+1))
    done

    log_info "========== 部署编排完成 =========="
    log_info "后续建议: 配置定时备份 (omf backup schedule setup) 与定时清理 (omf clean schedule setup)"
    log_info "一手总览: omf status / omf info"
    # 部署完成钩子: conf/hooks/deploy_after.d/ (可对接 CMDB 登记新环境、初始化监控、发送上线通知)
    run_hooks "deploy_after" "sid=${OMF_CONFIG[ORACLE_SID]}" "pdb=${OMF_CONFIG[PDB_NAME]}"
}
