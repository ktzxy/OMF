#!/bin/bash
#===============================================================================
# OMF 公共函数库 v2
# 变更: TTY 颜色自适应 / 集中日志 / 通知 / 锁 / oracle 兼容执行 / 内存预检
#===============================================================================

# ---- 颜色 (仅在 TTY 输出带颜色, 写入日志文件自动去色) ----
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
fi

# 集中运行日志路径 (由 omf.sh 的 log_init 设置)
OMF_RUN_LOG=""

# ---- 日志核心 ----
_log() {
    local level="$1"; shift
    local ts="$(date '+%F %T')"
    local out
    case "$level" in
        INFO)  out="${GREEN}[INFO]${NC}  $ts - $*";;
        WARN)  out="${YELLOW}[WARN]${NC}  $ts - $*";;
        STEP)  out="${CYAN}[STEP]${NC}  $ts - $*";;
        DEBUG) [ "${OMF_DEBUG:-false}" = "true" ] || return 0
                out="${BLUE}[DEBUG]${NC} $ts - $*";;
        *)     out="[$level] $ts - $*";;
    esac
    echo -e "$out"
    [ -n "$OMF_RUN_LOG" ] && echo "[$level] $ts - $*" >> "$OMF_RUN_LOG"
}

log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_step()  { _log STEP  "$@"; }
log_debug() { _log DEBUG "$@"; }

# 错误: 写日志 + 通知 + 退出
log_error() {
    local ts="$(date '+%F %T')"
    echo -e "${RED}[ERROR]${NC} $ts - $*" >&2
    [ -n "$OMF_RUN_LOG" ] && echo "[ERROR] $ts - $*" >> "$OMF_RUN_LOG"
    send_notification "OMF 执行失败 [$(basename "$0")]" "$*"
    exit 1
}

# 初始化本次运行的集中日志
log_init() {
    local cmd="$1"
    mkdir -p "${OMF_HOME}/logs"
    OMF_RUN_LOG="${OMF_HOME}/logs/omf_${cmd}_$(date +%Y%m%d_%H%M%S).log"
    export OMF_RUN_LOG
    log_debug "运行日志: $OMF_RUN_LOG"
}

# ---- 通知 (可选) ----
# 1) 若存在可执行钩子 conf/notify.sh, 调用它 (可对接邮件/钉钉/企业微信)
# 2) 否则若配置了 OMF_NOTIFY_MAIL 且系统有 mail, 发邮件
send_notification() {
    local subject="$1"; local body="$2"
    local hook="${OMF_HOME}/conf/notify.sh"
    if [ -x "$hook" ]; then
        "$hook" "$subject" "$body" &>/dev/null &
    elif command -v mail &>/dev/null && [ -n "${OMF_NOTIFY_MAIL:-}" ]; then
        echo "$body" | mail -s "[OMF] $subject" "${OMF_NOTIFY_MAIL}" &>/dev/null &
    fi
}

# ---- 权限 ----
require_root() {
    [ "$(id -u)" -eq 0 ] || log_error "此操作需要 root 权限执行"
}
# 数据库/备份/SQL 类操作: root 或 oracle 均可 (cron 以 oracle 运行)
require_db_user() {
    local u; u="$(whoami)"
    [ "$u" = "oracle" ] || [ "$(id -u)" -eq 0 ] || \
        log_error "需要 root 或 oracle 用户执行此操作"
}

# ---- 确认 (非交互 / --yes 时自动通过) ----
confirm() {
    local msg="${1:-确认继续?}"
    [ "${OMF_ASSUME_YES:-false}" = "true" ] && return 0
    # 非交互环境(如 cron)且无 --yes, 默认拒绝以避免危险操作
    [ -t 0 ] || { log_warn "非交互环境, 未指定 --yes, 已取消: $msg"; exit 0; }
    local ans
    read -r -p "$msg (yes/no): " ans
    case "$ans" in
        yes|y|Y) return 0;;
        *) log_warn "用户取消"; exit 0;;
    esac
}

check_cmd() {
    command -v "$1" &>/dev/null || log_error "命令不存在: $1"
}

# ---- 以 oracle 用户执行命令 (兼容 root 调用与 oracle 直接调用) ----
as_oracle() {
    local script="$1"
    if [ "$(id -u)" -eq 0 ]; then
        su - oracle -c "export ORACLE_SID=${ORACLE_SID:-ARTERY}; \
export ORACLE_HOME=${ORACLE_HOME}; \
export ORACLE_BASE=${ORACLE_BASE}; \
export PATH=\$ORACLE_HOME/bin:\$PATH; \
export NLS_LANG=${NLS_LANG:-AMERICAN_AMERICA.AL32UTF8}; \
$script"
    elif [ "$(whoami)" = "oracle" ]; then
        export ORACLE_SID="${ORACLE_SID:-ARTERY}"
        export ORACLE_HOME="${ORACLE_HOME}"
        export ORACLE_BASE="${ORACLE_BASE}"
        export PATH="$ORACLE_HOME/bin:$PATH"
        export NLS_LANG="${NLS_LANG:-AMERICAN_AMERICA.AL32UTF8}"
        eval "$script"
    else
        log_error "需要 root 或 oracle 用户执行"
    fi
}

# ---- 文件锁, 防止并发执行 ----
acquire_lock() {
    local lock_name="${1:-omf}"
    local lock_file="/tmp/omf_${lock_name}.lock"
    exec 200>"$lock_file"
    flock -n 200 || log_error "另一个 OMF 进程正在运行 (lock: $lock_file)"
    trap "rm -f '$lock_file'" EXIT
}

# ---- 系统内存(MB) ----
get_total_memory_mb() {
    awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
}

# ---- 磁盘剩余(MB) / 使用率(%) ----
get_disk_free_mb() {
    local path="${1:-/}"
    df -m "$path" 2>/dev/null | awk 'NR==2 {print $4}'
}
get_disk_usage_pct() {
    local path="${1:-/}"
    df "$path" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%'
}

# ---- 内存前置检查 (安装/建库前调用) ----
# 校验: 内存下限 / SGA 不超过物理内存 / 推荐 HugePages
# $1 (可选, 忽略)  $2=fatal: true(默认, 不足即退出) / false(仅返回1, 供预检汇总)
check_memory_prereq() {
    local fatal="${2:-true}"
    local total_mem; total_mem=$(get_total_memory_mb)
    local min_mem=4096
    log_step "内存前置检查 (物理内存 ${total_mem}MB)"

    if [ "$total_mem" -lt "$min_mem" ]; then
        if [ "$fatal" = "true" ]; then
            log_error "物理内存 ${total_mem}MB 低于 Oracle 19c 推荐最小值 ${min_mem}MB"
        else
            log_warn "物理内存 ${total_mem}MB 低于 Oracle 19c 推荐最小值 ${min_mem}MB"
            return 1
        fi
    fi

    # SGA+PGA 默认占 80%, 单实例不应超过 80% 物理内存
    local oracle_mb=$((total_mem * 80 / 100))
    [ "$oracle_mb" -lt 2048 ] && oracle_mb=2048
    log_info "计划分配给 Oracle: ${oracle_mb}MB (约 $((oracle_mb/1024))GB)"

    # HugePages 推荐值 (按 SGA 估算, 页大小 2MB)
    local sga_mb=$((oracle_mb * 75 / 100))
    local hp=$(( (sga_mb + 2048 - 1) / 2 + 1 ))
    log_info "建议 HugePages 数量: ${hp} (页大小 2MB, 覆盖 SGA ${sga_mb}MB)"
    log_info "可将以下参数加入 env kernel 配置:"
    echo "    vm.nr_hugepages = ${hp}"
    return 0
}

# ---- 创建备份目录结构 ----
ensure_backup_dirs() {
    local base="${ORACLE_BACKUP:-/backup/oracle}"
    mkdir -p "${base}/full" "${base}/incremental" "${base}/archive" \
             "${base}/controlfile" "${base}/spfile" "${base}/dump"
    chown -R oracle:oinstall "$base" 2>/dev/null || true
}
