#!/bin/bash
#===============================================================================
# OMF - Oracle Management Framework (主入口) v2
# 用法: ./omf.sh [global options] <command> [subcommand] [options]
# 版权: (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================

set -e
set -o pipefail

# 注意: 通过 /usr/local/bin/omf 软链调用时, BASH_SOURCE[0] 指向软链本身,
# 必须用 readlink -f 解析到真实路径, 否则 OMF_HOME 会错成 /usr/local/bin
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMF_HOME="${SCRIPT_DIR}"
export OMF_VERSION="1.5.0"

# 全局选项 (在命令之前)
OMF_ASSUME_YES="false"
OMF_DEBUG="false"
OMF_CONFIG_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes|--assume-yes) OMF_ASSUME_YES="true"; shift;;
        -d|--debug) OMF_DEBUG="true"; shift;;
        -c|--config) OMF_CONFIG_FILE="$2"; shift 2;;
        -h|--help) OMF_SHOW_HELP="true"; break;;
        --) shift; break;;
        -*) echo "未知全局选项: $1"; exit 1;;
        *) break;;
    esac
done
export OMF_ASSUME_YES OMF_DEBUG

# 加载公共函数库与配置
source "${OMF_HOME}/lib/common.sh"
source "${OMF_HOME}/lib/config.sh"

# 退出码约定: 0=成功, 1=脚本/执行错误(真正失败), 2=检查/健康检查发现问题(预期内, 非崩溃)
# 退出时统一: 清理命令锁 (acquire_lock 设置) + 按退出码给出提示
OMF_LOCK_FILE=""
_omf_exit_trap() {
    local code=$?
    [ -n "$OMF_LOCK_FILE" ] && rm -f "$OMF_LOCK_FILE" 2>/dev/null
    if [ "$code" -eq 1 ]; then
        echo -e "${RED}✗ 执行失败, 日志: ${OMF_RUN_LOG:-无}${NC}" >&2
    elif [ "$code" -eq 2 ]; then
        echo -e "${YELLOW}⚠ 命令执行完成, 但检查未通过 (退出码 2)${NC}" >&2
    fi
}
trap _omf_exit_trap EXIT

# 命令分发
usage() {
    cat << EOF

╔══════════════════════════════════════════════════════════════╗
║     OMF - Oracle Management Framework v${OMF_VERSION}              ║
║     Oracle 数据库(CDB系列) 全生命周期管理框架                ║
╚══════════════════════════════════════════════════════════════╝

用法: omf [options] <command> [subcommand] [options]
全局选项:
  -y, --yes          非交互模式, 自动确认危险操作
  -d, --debug        调试模式
  -c, --config <f>   指定配置文件 (默认 conf/omf.conf)

核心命令:
  env        环境准备 (用户/内核/依赖/目录/变量/防火墙)
  install    安装 Oracle 软件 + 监听器
  db         数据库管理 (建库/启停/PDB/DG)
  backup     备份管理 (逻辑/物理/全量/增量, 配置驱动)
  sql        脚本执行管理 (断点续跑/失败即停)
  tune       性能调优 (内存/存储/会话/分析)
  check      健康检查 (含 preflight 预检)
  status     一键总览 (库/监听/磁盘/备份/日志)
  listener   监听器管理 (status/start/stop/restart/port)
  log        日志管理
  clean      定时清理
  config     配置管理
  self-update 框架自更新 (需配置 OMF_UPDATE_URL)
  selftest   框架自检 (语法/健全性, 不依赖 Oracle 环境)
  info       实例信息总览 (路径/端口/IP/连接串/内存)
  deploy     一键部署编排 (预检→环境→安装→建库→初始化→首次备份)

快速开始:
  omf config validate            # 校验配置
  omf check preflight            # 安装前预检
  omf env prepare                # 准备系统环境
  omf install software <zip>     # 安装 Oracle 软件
  omf db create                  # 创建数据库
  omf sql init                  # 初始化(建模式/表空间 + 逐目录执行 SQL)
  omf backup schedule setup      # 配置定时备份
  omf clean schedule setup       # 配置定时清理
  omf status                     # 一键总览

EOF
}

# 各命令的子命令用法 (供 omf help <cmd> / omf <cmd> -h 使用)
cmd_help() {
    case "${1:-}" in
        env)        echo "用法: omf env {all|prepare|check|user|kernel|packages|profile}";;
        install)    echo "用法: omf install {software|listener|check} [zip路径] [EE|SE]";;
        db)         echo "用法: omf db {create|start|stop|restart|status|pdb|dg|archivelog}"; echo "  dg {config|enable|standby|wallet|broker|switchover|failover|reinstate|apply|gap|validate|status}"; echo "    broker              创建 Broker 配置 (切换前置)"; echo "    switchover [--to X] 计划内主备切换 (主库执行, 无数据丢失)"; echo "    failover [--to X] [--immediate]  灾难切换 (备库执行)"; echo "    reinstate [X]       failover 后回收旧主库为备库"; echo "    apply {start|stop|status}  备库 MRP 应用管理"; echo "    gap                 传输/应用延迟与归档间隙";;
        backup)     echo "用法: omf backup {logical|physical|incremental|archive|auto|schedule|list|validate|restore|cleanup} [选项]"; echo "  logical [--schema <模式名>] [--all|--root|--pdb a,b]  # 逻辑备份; --schema 仅导出该模式(多库)"; echo "  incremental [--level N] [--cumulative|--differential] [--all|--root|--pdb a,b]  # RMAN 增量 (默认 Level1 累积 CUMULATIVE)"; echo "  physical [--all|--root|--pdb a,b]  # 物理全量 (备份成功自动清理过期归档防FRA满)"; echo "  validate [--all|--root|--pdb a,b]  # 可恢复性校验 (RESTORE VALIDATE, 不真恢复; 失败发告警)"; echo "  schedule setup [--validate-day <0-7|off>] [--pdb <name> [--pdb-day <0-7>]]  # 定时: 每天auto+每4h归档+每周校验+可选PDB单独备份"; echo "  cleanup: [--logical|--physical] [-d 天数 | --all] [-p|--dry-run|list] [-y]"; echo "    --logical 仅逻辑备份(dump) | --physical 仅物理备份(RMAN) | 默认两者"; echo "    -d N 删 N 天前(默认30) | --all 删全部 | -p|list 仅预览 | -y 免确认";;
        sql)        echo "用法: omf sql {scan|run|import|init|status|usage|rollback}"; echo "  init [--schema <模式名>]            # 初始化; --schema 仅重建该模式(用户/表空间), 不重跑全局脚本"; echo "  import <dump> [--schema 模式名] [--remap 源[:目标]] [--remap-tablespace 源TS:目标TS] [--check] [--apply [parfile]]"; echo "    --schema 指定导入到的目标模式(多库多模式); 不指定则默认主模式 APP_USER"; echo "  rollback <name> | --all [--schema <模式名>]   # 重置执行记录; --schema 仅清该模式的记录"; echo "  usage                             # 多模式空间使用与无效对象一览";;
        tune)       echo "用法: omf tune {memory|storage|session|analyze|awr|apply}";;
        check)      echo "用法: omf check {all|db|disk|perf|alert|listener|preflight|schemas|dg|monitor}"; echo "  schemas  校验已配置模式(多库)是否真实存在于数据库"; echo "  dg       Data Guard 健康检查 (传输/MRP/延迟/间隙, 需 ENABLE_DG=true)";;
        listener)   echo "用法: omf listener {status|start|stop|restart|port <新端口>}";;
        status)     echo "用法: omf status [history [N]]";;
        log)        echo "用法: omf log {view|tail|rotate|clean|errors}"; echo "  errors [天数]  汇总最近 N 天 Alert/监听器日志的 ORA-/TNS-/ASM- 错误并聚合 Top10";;
        clean)      echo "用法: omf clean {logs|trace|audit|archive|backup|recyclebin|all|schedule} [-d 天数 | --all] [-p|--preview] [-y]"; echo "  backup: ≡ omf backup cleanup (清理旧备份), 支持 --logical/--physical/-d N/--all/-p/-y"; echo "  recyclebin: 清空数据库回收站 (PURGE DBA_RECYCLEBIN, 不可逆, 需显式调用)";;
        config)     echo "用法: omf config {get|set|list|validate|show|init|password}"; echo "  password [KEY...] 交互式设置敏感口令到 conf/.omf.secret (600); 默认设 ORACLE/SYSTEM/PDB/APP 四口令; --remove <KEY> 移除";;
        self-update) echo "用法: omf self-update [version|force]";;
        selftest)  echo "用法: omf selftest";;
        info)      echo "用法: omf info";;
        deploy)     echo "用法: omf deploy [--zip <db_home.zip>] [--edition EE|SE] [--from <序号|步骤>] [--skip <序号|步骤>[,...]] [--list]";;
        *)          usage;;
    esac
}

main() {
    if [ $# -eq 0 ]; then
        usage
        exit 0
    fi

    local cmd="$1"; shift

    # 帮助: omf help <cmd> 或 omf <cmd> -h
    if [ "$cmd" = "help" ]; then
        cmd_help "${1:-}"
        exit 0
    fi
    # 子命令级 -h/--help: omf <cmd> <sub> -h 也显示帮助, 避免把 -h 当参数传入子命令导致误执行
    for _a in "$@"; do
        if [ "$_a" = "-h" ] || [ "$_a" = "--help" ]; then
            cmd_help "$cmd"
            exit 0
        fi
    done

    # 全局 -h/--help (omf -h <cmd> / omf --help <cmd>): 仅打印帮助并退出, 绝不执行命令本身
    # (全局选项循环里 -h 会 break, 此时 $@ 已是命令名, 若不清这里直接 dispatch 会误执行命令)
    if [ "${OMF_SHOW_HELP:-false}" = "true" ]; then
        if [ -n "$cmd" ]; then cmd_help "$cmd"; else usage; fi
        exit 0
    fi

    # 为每个命令初始化集中日志 (命令名作为日志前缀)
    # 记录当前命令名, 供结构化日志 (cmd 维度) 使用
    export OMF_CMD="$cmd"
    log_init "$cmd"

    # 防并发锁 (按一级命令隔离); 只读命令不加锁, 避免阻塞并发查询
    case "$cmd" in
        check|status|log|config|selftest|info) ;;   # 只读/静态命令, 跳过锁
        *) acquire_lock "$cmd";;
    esac

    case "$cmd" in
        -h|--help) usage;;
        -v|--version) echo "OMF v${OMF_VERSION}";;
        env)      source "${OMF_HOME}/cmd/env.sh";      cmd_env "$@";;
        install)  source "${OMF_HOME}/cmd/install.sh";  cmd_install "$@";;
        db)       source "${OMF_HOME}/cmd/db.sh";       source "${OMF_HOME}/cmd/db_dg.sh";       source "${OMF_HOME}/cmd/db_archivelog.sh";       source "${OMF_HOME}/cmd/db_pdb.sh";       cmd_db "$@";;
        backup)   source "${OMF_HOME}/cmd/backup.sh";   source "${OMF_HOME}/cmd/backup_restore.sh";   cmd_backup "$@";;
        sql)      source "${OMF_HOME}/cmd/sql.sh";      source "${OMF_HOME}/cmd/sql_import.sh";      cmd_sql "$@";;
        tune)     source "${OMF_HOME}/cmd/tune.sh";     cmd_tune "$@";;
        check)    source "${OMF_HOME}/cmd/check.sh";    source "${OMF_HOME}/cmd/check_monitor.sh";    cmd_check "$@";;
        listener)  source "${OMF_HOME}/cmd/listener.sh";  cmd_listener "$@";;
        status)   source "${OMF_HOME}/cmd/status.sh";   cmd_status "$@";;
        log)      source "${OMF_HOME}/cmd/log.sh";      cmd_log "$@";;
        clean)    source "${OMF_HOME}/cmd/clean.sh";    cmd_clean "$@";;
        config)   source "${OMF_HOME}/cmd/config.sh";   cmd_config "$@";;
        self-update|self_update) source "${OMF_HOME}/cmd/self_update.sh"; cmd_self_update "$@";;
        selftest)  source "${OMF_HOME}/cmd/selftest.sh"; cmd_selftest "$@";;
        info)      source "${OMF_HOME}/cmd/info.sh";      cmd_info "$@";;
        deploy)     source "${OMF_HOME}/cmd/deploy.sh";    cmd_deploy "$@";;
        *)
            log_error "未知命令: $cmd"
            usage
            exit 1;;
    esac
}

# 全局 -h/--help: 函数均已定义, 直接打印并退出
if [ "${OMF_SHOW_HELP:-false}" = "true" ]; then
    usage
    exit 0
fi

main "$@"
