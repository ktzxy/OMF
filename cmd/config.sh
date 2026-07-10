#!/bin/bash
#===============================================================================
# OMF - 配置管理命令
# 用法: omf config <subcommand> [options]
#===============================================================================

cmd_config() {
    local subcmd="${1:-show}"
    shift || true

    case "$subcmd" in
        show)
            show_config
            ;;
        set)
            set_config "$@"
            ;;
        list)
            list_config "$@"
            ;;
        validate)
            validate_config "$@"
            ;;
        init)
            init_config "$@"
            ;;
        *)
            echo "用法: omf config {show|set|list|validate|init}"
            exit 1
            ;;
    esac
}

#===============================================================================
# 列出所有配置项
#===============================================================================
list_config() {
    echo ""
    echo "========== 所有配置项 =========="
    for key in $(echo "${!OMF_CONFIG[@]}" | tr ' ' '\n' | sort); do
        local val="${OMF_CONFIG[$key]}"
        # 密码类配置项掩码, 避免明文泄露
        case "$key" in
            *PASSWORD*) val="****";;
        esac
        printf "  %-35s = %s\n" "$key" "$val"
    done
}

#===============================================================================
# 验证配置
#===============================================================================
validate_config() {
    local errors=0

    log_step "验证配置..."

    # 检查必要配置
    check_required() {
        local key="$1"
        local desc="$2"
        if [ -z "${OMF_CONFIG[$key]}" ]; then
            echo "  ✗ $desc ($key) 未配置"
            errors=$((errors + 1))
        else
            local val="${OMF_CONFIG[$key]}"
            # 密码类配置项掩码, 避免明文泄露
            case "$key" in
                *PASSWORD*) val="****";;
            esac
            echo "  ✓ $desc: $val"
        fi
    }

    echo "--- 必要配置 ---"
    check_required "ORACLE_SID"    "Oracle SID"
    check_required "ORACLE_HOME"   "Oracle Home"
    check_required "ORACLE_BASE"   "Oracle Base"
    check_required "PDB_NAME"      "PDB Name"
    check_required "ORACLE_DATA"   "数据目录"
    check_required "ORACLE_PASSWORD" "Oracle 密码"
    check_required "APP_USER"      "应用用户"
    check_required "APP_PASSWORD"  "应用密码"

    echo ""
    echo "--- 路径检查 ---"
    check_path() {
        local path="$1"
        local desc="$2"
        if [ -d "$path" ]; then
            echo "  ✓ $desc: $path"
        elif [ -f "$path" ]; then
            echo "  ✓ $desc: $path"
        else
            echo "  ⚠ $desc 不存在: $path"
        fi
    }

    check_path "${OMF_CONFIG[ORACLE_HOME]}/bin/sqlplus" "sqlplus"
    check_path "${OMF_CONFIG[ORACLE_HOME]}/bin/lsnrctl" "lsnrctl"
    check_path "${OMF_CONFIG[ORACLE_HOME]}/bin/rman"    "rman"

    echo ""
    echo "--- 磁盘空间 ---"
    local paths=("${OMF_CONFIG[ORACLE_DATA_BASE]}" "${OMF_CONFIG[ORACLE_BACKUP]}" "/tmp")
    for p in "${paths[@]}"; do
        local parent
        parent=$(dirname "$p" 2>/dev/null)
        while [ ! -d "$parent" ] && [ "$parent" != "/" ]; do
            parent=$(dirname "$parent")
        done
        local usage
        usage=$(get_disk_usage_pct "$parent" 2>/dev/null || echo "N/A")
        local free
        free=$(get_disk_free_mb "$parent" 2>/dev/null || echo "N/A")
        printf "  %-40s 使用: %s%%  剩余: %sMB\n" "$p" "$usage" "$free"
    done

    echo ""
    if [ "$errors" -eq 0 ]; then
        log_info "配置验证通过"
    else
        log_warn "发现 $errors 个配置问题"
    fi
}

#===============================================================================
# 初始化配置文件
#===============================================================================
init_config() {
    local config_file="${1:-${OMF_HOME}/conf/omf.conf}"

    if [ -f "$config_file" ]; then
        confirm "配置文件已存在，覆盖? ($config_file)"
    fi

    mkdir -p "$(dirname "$config_file")"

    cat > "$config_file" << 'EOF'
# OMF 配置文件
# 修改后执行: omf config validate

# ===== 数据库配置 =====
ORACLE_USER="oracle"
ORACLE_GROUP="oinstall"
ORACLE_BASE="/u01/app/oracle"
# ORACLE_HOME 留空则按 ORACLE_VERSION 自动推导 (19 -> /u01/app/oracle/product/19.3.0/dbhome_1)
ORACLE_HOME="/u01/app/oracle/product/19.3.0/dbhome_1"
# Oracle 主版本 (仅支持 CDB 系列: 18 / 19 / 21 / 23)
ORACLE_VERSION="19"
# 安装包 zip 路径 (留空则按 ORACLE_VERSION 推导默认名)
ORACLE_ZIP=""
ORACLE_SID="ARTERY"
PDB_NAME="ARTERYPDB"

# ===== 内存规划 (用于 SGA / HugePages 估算) =====
# Oracle 内存占物理内存百分比 (默认 80)
ORACLE_MEM_RATIO="80"
# SGA 占 Oracle 内存百分比 (默认 75)
SGA_RATIO="75"
# 预留大页后至少给 OS 保留的空闲内存(MB), 防止小内存机器被大页吃满 (默认 2048)
HUGEPAGES_RESERVE_FREE_MB="2048"
# 是否将大页预留推迟到 omf db create 之前 (true/false)
#   true:  env prepare 不立即预留大页(释放内存给安装器), 建库前再预留
#   false: env prepare 立即预留大页(传统行为)
HUGEPAGES_DEFER="false"

# ===== 密码配置 =====
# 可通过环境变量覆盖: export ORACLE_PASSWORD=xxx
ORACLE_PASSWORD="${ORACLE_PASSWORD:-Qiyuan!960#123}"
SYSTEM_PASSWORD="${SYSTEM_PASSWORD:-Qiyuan!960#123}"
PDB_PASSWORD="${PDB_PASSWORD:-Qiyuan!960#123}"
APP_USER="dherp"
APP_PASSWORD="${APP_PASSWORD:-dherp_skzy}"

# ===== 存储路径 =====
ORACLE_DATA_BASE="/data/oracle"
ORACLE_DATA="/data/oracle/oradata"
ORACLE_ARCH="/data/oracle/archivelog"
ORACLE_FRA="/data/oracle/fast_recovery"
ORACLE_BACKUP="/backup/oracle"

# ===== 数据库参数 =====
CHARSET="AL32UTF8"
NLS_LANG="AMERICAN_AMERICA.AL32UTF8"
PROCESSES="1500"
OPEN_CURSORS="1000"
REDO_SIZE_MB="2048"
FRA_SIZE_MB="40960"
FRA_SIZE_MB_MIN="20480"

# ===== Data Guard =====
ENABLE_DG="false"
PRIMARY_IP="192.168.0.108"
STANDBY_IP="192.168.0.110"

# ===== 备份策略 =====
BACKUP_RETENTION_DAYS="30"
BACKUP_COMPRESSION="ALL"
BACKUP_PARALLEL="4"

# ===== 清理策略 =====
LOG_RETENTION_DAYS="7"
AUDIT_RETENTION_DAYS="30"
TRACE_RETENTION_DAYS="7"

# ===== SQL 脚本目录 =====
# SQL_INIT_DIR="${OMF_HOME}/sql/init"
# SQL_UPGRADE_DIR="${OMF_HOME}/sql/upgrade"
# SQL_PATCH_DIR="${OMF_HOME}/sql/patch"
# SQL_CUSTOM_DIR="${OMF_HOME}/sql/custom"
EOF

    log_info "配置文件已创建: $config_file"
    echo ""
    echo "请根据实际环境修改配置后执行: omf config validate"
}
