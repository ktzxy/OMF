#!/bin/bash
#===============================================================================
# OMF 配置管理 v2
# 加载优先级: 命令行参数 > 环境变量 > conf/omf.conf > 默认值
# 新增: FRA_SIZE_MB 修正 / OS 探测 / set_config 落盘 / 更严格校验
#===============================================================================

declare -A OMF_CONFIG

load_config() {
    # ---------- 默认值 ----------
    OMF_CONFIG[ORACLE_USER]="oracle"
    OMF_CONFIG[ORACLE_GROUP]="oinstall"
    OMF_CONFIG[ORACLE_BASE]="/u01/app/oracle"
    OMF_CONFIG[ORACLE_HOME]="/u01/app/oracle/product/19.3.0/dbhome_1"
    # Oracle 主版本 (仅支持 CDB 系列: 18 / 19 / 21 / 23), 用于推导默认安装包名与提示
    OMF_CONFIG[ORACLE_VERSION]="${ORACLE_VERSION:-19}"
    # 安装包路径 (留空则按 ORACLE_VERSION 推导默认名, 见 install.sh 的 oracle_default_zip)
    OMF_CONFIG[ORACLE_ZIP]="${ORACLE_ZIP:-}"
    OMF_CONFIG[ORACLE_SID]="ARTERY"
    OMF_CONFIG[PDB_NAME]="ARTERYPDB"
    OMF_CONFIG[ORACLE_DATA_BASE]="/data/oracle"
    OMF_CONFIG[ORACLE_DATA]="/data/oracle/oradata"
    OMF_CONFIG[ORACLE_ARCH]="/data/oracle/archivelog"
    OMF_CONFIG[ORACLE_FRA]="/data/oracle/fast_recovery"
    OMF_CONFIG[ORACLE_BACKUP]="/backup/oracle"
    OMF_CONFIG[CHARSET]="AL32UTF8"
    OMF_CONFIG[NLS_LANG]="AMERICAN_AMERICA.AL32UTF8"

    OMF_CONFIG[ORACLE_PASSWORD]="${ORACLE_PASSWORD:-Qiyuan!960#123}"
    OMF_CONFIG[SYSTEM_PASSWORD]="${SYSTEM_PASSWORD:-Qiyuan!960#123}"
    OMF_CONFIG[PDB_PASSWORD]="${PDB_PASSWORD:-Qiyuan!960#123}"
    OMF_CONFIG[APP_USER]="${APP_USER:-dherp}"
    OMF_CONFIG[APP_PASSWORD]="${APP_PASSWORD:-dherp_skzy}"

    OMF_CONFIG[PROCESSES]="1500"
    OMF_CONFIG[OPEN_CURSORS]="1000"
    OMF_CONFIG[REDO_SIZE_MB]="2048"
    OMF_CONFIG[FRA_SIZE_MB]="${FRA_SIZE_MB:-40960}"        # 修正: 原 FRA_SIZE_MB_MIN 未被读取
    OMF_CONFIG[FRA_SIZE_MB_MIN]="20480"

    OMF_CONFIG[ENABLE_DG]="false"
    OMF_CONFIG[DB_UNIQUE_NAME_PRIMARY]="${OMF_CONFIG[ORACLE_SID]}_PRIMARY"
    OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]="${OMF_CONFIG[ORACLE_SID]}_STANDBY"
    OMF_CONFIG[STANDBY_SID]="${STANDBY_SID:-${OMF_CONFIG[ORACLE_SID]}}"
    OMF_CONFIG[PRIMARY_IP]="${PRIMARY_IP:-192.168.0.108}"
    OMF_CONFIG[STANDBY_IP]="${STANDBY_IP:-192.168.0.110}"

    # 备份策略 (逻辑/物理/两者, 全量/增量 由 BACKUP_MODE 控制)
    OMF_CONFIG[BACKUP_MODE]="${BACKUP_MODE:-both}"   # logical | physical | both
    OMF_CONFIG[BACKUP_RETENTION_DAYS]="30"
    OMF_CONFIG[BACKUP_COMPRESSION]="ALL"
    OMF_CONFIG[BACKUP_PARALLEL]="4"

    OMF_CONFIG[LOG_RETENTION_DAYS]="7"
    OMF_CONFIG[AUDIT_RETENTION_DAYS]="30"
    OMF_CONFIG[TRACE_RETENTION_DAYS]="7"

    # 框架自更新 (omf self-update 使用的 tar.gz 地址, 留空则报错提示)
    OMF_CONFIG[OMF_UPDATE_URL]="${OMF_UPDATE_URL:-}"

    OMF_CONFIG[SQL_INIT_DIR]="${OMF_HOME}/sql/init"
    OMF_CONFIG[SQL_UPGRADE_DIR]="${OMF_HOME}/sql/upgrade"
    OMF_CONFIG[SQL_PATCH_DIR]="${OMF_HOME}/sql/patch"
    OMF_CONFIG[SQL_CUSTOM_DIR]="${OMF_HOME}/sql/custom"

    # ---------- 加载配置文件 ----------
    local config_file="${OMF_CONFIG_FILE:-${OMF_HOME}/conf/omf.conf}"
    if [ -f "$config_file" ]; then
        log_debug "加载配置文件: $config_file"
        source "$config_file"
    fi

    # ---------- 导出为环境变量 ----------
    for key in "${!OMF_CONFIG[@]}"; do
        export "${key}"="${OMF_CONFIG[$key]}"
    done
    log_debug "配置加载完成"
}

# 探测 OS (用于依赖包选择)
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID:-linux} ${VERSION_ID:-}"
    else
        echo "linux unknown"
    fi
}

show_config() {
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║           OMF 当前配置                         ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
    echo "[数据库配置]"
    echo "  ORACLE_VERSION: ${OMF_CONFIG[ORACLE_VERSION]}c (CDB)"
    echo "  ORACLE_SID:     ${OMF_CONFIG[ORACLE_SID]}"
    echo "  PDB_NAME:       ${OMF_CONFIG[PDB_NAME]}"
    echo "  CHARSET:        ${OMF_CONFIG[CHARSET]}"
    echo "  APP_USER:       ${OMF_CONFIG[APP_USER]}"
    echo ""
    echo "[路径配置]"
    echo "  ORACLE_BASE:    ${OMF_CONFIG[ORACLE_BASE]}"
    echo "  ORACLE_HOME:    ${OMF_CONFIG[ORACLE_HOME]}"
    echo "  DATA:           ${OMF_CONFIG[ORACLE_DATA]}"
    echo "  ARCHIVE:        ${OMF_CONFIG[ORACLE_ARCH]}"
    echo "  FRA:            ${OMF_CONFIG[ORACLE_FRA]} (${OMF_CONFIG[FRA_SIZE_MB]}MB)"
    echo "  BACKUP:         ${OMF_CONFIG[ORACLE_BACKUP]}"
    echo ""
    echo "[数据库参数]"
    echo "  PROCESSES:      ${OMF_CONFIG[PROCESSES]}"
    echo "  OPEN_CURSORS:   ${OMF_CONFIG[OPEN_CURSORS]}"
    echo "  REDO_SIZE_MB:   ${OMF_CONFIG[REDO_SIZE_MB]}"
    echo ""
    echo "[备份策略]"
    echo "  MODE:           ${OMF_CONFIG[BACKUP_MODE]}"
    echo "  RETENTION:      ${OMF_CONFIG[BACKUP_RETENTION_DAYS]} 天"
    echo "  COMPRESSION:    ${OMF_CONFIG[BACKUP_COMPRESSION]}"
    echo "  PARALLEL:       ${OMF_CONFIG[BACKUP_PARALLEL]}"
    echo ""
    echo "[Data Guard]"
    echo "  ENABLED:        ${OMF_CONFIG[ENABLE_DG]}"
    echo "  PRIMARY_IP:     ${OMF_CONFIG[PRIMARY_IP]}"
    echo "  STANDBY_IP:     ${OMF_CONFIG[STANDBY_IP]}"
    echo ""
}

# 设置配置项并持久化到配置文件
set_config() {
    local key="$1"; local value="$2"
    [ -z "$key" ] && log_error "用法: omf config set <KEY> <VALUE>"
    [ -z "$value" ] && log_error "用法: omf config set <KEY> <VALUE>"

    OMF_CONFIG["$key"]="$value"
    export "${key}"="$value"

    local config_file="${OMF_CONFIG_FILE:-${OMF_HOME}/conf/omf.conf}"
    [ -f "$config_file" ] || log_error "配置文件不存在: $config_file"

    # 已存在则替换, 否则追加
    if grep -q "^${key}=" "$config_file" 2>/dev/null; then
        # 转义 sed 替换串中的特殊字符: & 表示整段匹配, | 为分隔符, \ 为转义符
        local safe_value="${value//\\/\\\\}"
        safe_value="${safe_value//&/\\&}"
        safe_value="${safe_value//|/\\|}"
        sed -i "s|^${key}=.*|${key}=\"${safe_value}\"|" "$config_file"
    else
        echo "${key}=\"${value}\"" >> "$config_file"
    fi
    log_info "配置已更新并持久化: $key = $value"
}

# 自动加载
load_config
