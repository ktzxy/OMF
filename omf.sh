#!/bin/bash
#===============================================================================
# OMF - Oracle Management Framework (主入口) v2
# 用法: ./omf.sh [global options] <command> [subcommand] [options]
#===============================================================================

set -e
set -o pipefail

# 注意: 通过 /usr/local/bin/omf 软链调用时, BASH_SOURCE[0] 指向软链本身,
# 必须用 readlink -f 解析到真实路径, 否则 OMF_HOME 会错成 /usr/local/bin
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export OMF_HOME="${SCRIPT_DIR}"
export OMF_VERSION="1.1.0"

# 全局选项 (在命令之前)
OMF_ASSUME_YES="false"
OMF_DEBUG="false"
OMF_CONFIG_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes|--assume-yes) OMF_ASSUME_YES="true"; shift;;
        -d|--debug) OMF_DEBUG="true"; shift;;
        -c|--config) OMF_CONFIG_FILE="$2"; shift 2;;
        --) shift; break;;
        -*) echo "未知全局选项: $1"; exit 1;;
        *) break;;
    esac
done
export OMF_ASSUME_YES OMF_DEBUG

# 加载公共函数库与配置
source "${OMF_HOME}/lib/common.sh"
source "${OMF_HOME}/lib/config.sh"

# 退出码处理: 任何错误都给出运行日志位置
trap 'code=$?; [ $code -ne 0 ] && echo -e "${RED}✗ 执行失败, 日志: ${OMF_RUN_LOG:-无}${NC}" >&2' EXIT

# 命令分发
usage() {
    cat << EOF

╔══════════════════════════════════════════════════════════════╗
║     OMF - Oracle Management Framework v${OMF_VERSION}              ║
║     Oracle 19c 全生命周期管理框架                           ║
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
  log        日志管理
  clean      定时清理
  config     配置管理
  self-update 框架自更新 (需配置 OMF_UPDATE_URL)

快速开始:
  omf config validate            # 校验配置
  omf check preflight            # 安装前预检
  omf env prepare                # 准备系统环境
  omf install software <zip>     # 安装 Oracle 软件
  omf db create                  # 创建数据库
  omf sql run --all              # 导入并执行 SQL
  omf backup schedule setup      # 配置定时备份
  omf clean schedule setup       # 配置定时清理
  omf status                     # 一键总览

EOF
}

main() {
    if [ $# -eq 0 ]; then
        usage
        exit 0
    fi

    local cmd="$1"; shift

    # 为每个命令初始化集中日志 (命令名作为日志前缀)
    log_init "$cmd"

    # 防并发锁 (按一级命令隔离)
    acquire_lock "$cmd"

    case "$cmd" in
        -h|--help) usage;;
        -v|--version) echo "OMF v${OMF_VERSION}";;
        env)      source "${OMF_HOME}/cmd/env.sh";      cmd_env "$@";;
        install)  source "${OMF_HOME}/cmd/install.sh";  cmd_install "$@";;
        db)       source "${OMF_HOME}/cmd/db.sh";       cmd_db "$@";;
        backup)   source "${OMF_HOME}/cmd/backup.sh";   cmd_backup "$@";;
        sql)      source "${OMF_HOME}/cmd/sql.sh";      cmd_sql "$@";;
        tune)     source "${OMF_HOME}/cmd/tune.sh";     cmd_tune "$@";;
        check)    source "${OMF_HOME}/cmd/check.sh";    cmd_check "$@";;
        status)   source "${OMF_HOME}/cmd/status.sh";   cmd_status "$@";;
        log)      source "${OMF_HOME}/cmd/log.sh";      cmd_log "$@";;
        clean)    source "${OMF_HOME}/cmd/clean.sh";    cmd_clean "$@";;
        config)   source "${OMF_HOME}/cmd/config.sh";   cmd_config "$@";;
        self-update|self_update) source "${OMF_HOME}/cmd/self_update.sh"; cmd_self_update "$@";;
        *)
            log_error "未知命令: $cmd"
            usage
            exit 1;;
    esac
}

main "$@"
