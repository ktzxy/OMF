#!/bin/bash
#===============================================================================
# OMF 引导脚本 (解压后执行一次)
# 典型流程:
#   wget http://host/omf.tar.gz && tar xzf omf.tar.gz && cd omf && ./setup.sh
# 作用: 自检 -> 可选交互配置 -> 建立 omf 命令软链 -> 校验 -> 预检
#===============================================================================
set -e

cd "$(dirname "$0")"
OMF_HOME="$(pwd)"
export OMF_HOME

# 加载函数与配置
source "${OMF_HOME}/lib/common.sh"
source "${OMF_HOME}/lib/config.sh"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          OMF 引导安装 (Bootstrap) v${OMF_VERSION}               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo "  OMF_HOME = ${OMF_HOME}"

# 1. 基本权限自检
if [ "$(id -u)" -ne 0 ]; then
    log_warn "建议以 root 运行 setup.sh (环境准备需要 root)"
fi

# 2. 可选交互: 快速设置关键配置
if [ -t 0 ] && [ "${OMF_NONINTERACTIVE:-false}" != "true" ]; then
    echo ""
    read -r -p "是否交互式配置关键参数? (yes/no, 默认 no): " ans
    if [ "$ans" = "yes" ] || [ "$ans" = "y" ]; then
        read -r -p "ORACLE_SID [${ORACLE_SID}]: " v; [ -n "$v" ] && set_config ORACLE_SID "$v"
        read -r -p "PDB_NAME [${PDB_NAME}]: " v; [ -n "$v" ] && set_config PDB_NAME "$v"
        read -r -p "ORACLE_BASE [${ORACLE_BASE}]: " v; [ -n "$v" ] && set_config ORACLE_BASE "$v"
        read -r -p "ORACLE_HOME [${ORACLE_HOME}]: " v; [ -n "$v" ] && set_config ORACLE_HOME "$v"
        read -r -p "ORACLE_DATA [${ORACLE_DATA}]: " v; [ -n "$v" ] && set_config ORACLE_DATA "$v"
        read -r -p "ORACLE_BACKUP [${ORACLE_BACKUP}]: " v; [ -n "$v" ] && set_config ORACLE_BACKUP "$v"
        read -r -p "APP_USER [${APP_USER}]: " v; [ -n "$v" ] && set_config APP_USER "$v"
        read -r -p "BACKUP_MODE (logical|physical|both) [${BACKUP_MODE}]: " v
        [ -n "$v" ] && set_config BACKUP_MODE "$v"
        echo "提示: 密码建议通过环境变量注入, 例如 export ORACLE_PASSWORD=xxx 后再运行"
    fi
fi

# 3. 重新加载配置并校验
load_config
echo ""
"${OMF_HOME}/omf.sh" config validate || log_error "配置校验未通过, 请修改 conf/omf.conf"

# 4. 建立全局命令软链
if [ -w /usr/local/bin ]; then
    ln -sf "${OMF_HOME}/omf.sh" /usr/local/bin/omf
    log_info "已创建命令: omf -> ${OMF_HOME}/omf.sh (任意目录可直接 omf ...)"
else
    log_warn "无 /usr/local/bin 写权限, 未创建软链; 请使用 ./omf.sh"
fi

# 5. 可选: 预检
if [ -t 0 ] && [ "${OMF_NONINTERACTIVE:-false}" != "true" ]; then
    read -r -p "是否执行安装前预检? (yes/no, 默认 yes): " ans
    if [ "$ans" != "no" ]; then
        "${OMF_HOME}/omf.sh" check preflight || true
    fi
fi

echo ""
log_info "引导完成! 后续步骤:"
echo "  1) omf env prepare          # 准备系统环境 (需 root)"
echo "  2) omf install software <zip> # 安装 Oracle 软件"
echo "  3) omf db create            # 创建数据库"
echo "  4) omf sql run --all        # 导入并执行 SQL"
echo "  5) omf backup schedule setup # 配置定时备份"
echo "  6) omf clean schedule setup   # 配置定时清理"
