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

    local zip="" edition=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --zip)     zip="$2"; shift 2;;
            --edition) edition="$2"; shift 2;;
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

    log_step "========== OMF 一键部署编排 =========="
    log_info "将依次执行 ${#steps[@]} 个步骤:"
    local n=1
    for s in "${steps[@]}"; do
        log_info "  ${n}) ${s##*:}  (omf ${s%%:*})"
        n=$((n+1))
    done
    [ -n "$zip" ]     && log_info "安装包(zip): $zip"
    [ -n "$edition" ] && log_info "安装版本: $edition"
    echo ""

    local i=1 total=${#steps[@]}
    for s in "${steps[@]}"; do
        local cmd="${s%%:*}" desc="${s##*:}"
        # install software 透传 zip / edition 参数
        local full="$cmd"
        if [ "$cmd" = "install software" ]; then
            [ -n "$zip" ]     && full="$full $zip"
            [ -n "$edition" ] && full="$full $edition"
        fi

        log_step "== [${i}/${total}] ${desc} =="
        log_info "执行: omf -y ${full}"
        echo "----------------------------------------"
        # 子进程非零退出码在 if 条件中, 不会触发父进程 set -e; 每步独立进程/日志, 错误隔离
        if "$self" -y $full; then
            log_info "✓ 完成: ${desc}"
        else
            log_error "✗ 步骤 [${i}/${total}] ${desc} 失败, 部署中止。可单独修复后重跑: omf -y ${full}"
        fi
        echo "----------------------------------------"
        i=$((i+1))
    done

    log_info "========== 部署编排完成 =========="
    log_info "后续建议: 配置定时备份 (omf backup schedule setup) 与定时清理 (omf clean schedule setup)"
    log_info "一手总览: omf status / omf info"
}
