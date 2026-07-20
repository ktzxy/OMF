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

# 命令锁文件路径 (由 acquire_lock 设置, 由 omf.sh 的退出 trap 统一清理)
OMF_LOCK_FILE=""

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

# ---- 依赖库探测 (跨发行版, 不依赖 rpm) ----
# 优先 ldconfig 缓存; 若 ldconfig 不可用/缓存未刷新 (或 set -o pipefail 下
# grep -q 提前退出导致 ldconfig 收到 SIGPIPE 误判), 回退到标准库目录文件探测.
# 返回 0=存在, 1=缺失
omf_lib_present() {
    local lib="$1"
    # 方式1: ldconfig 缓存 (优先 /sbin/ldconfig, 避免 PATH 不含 /sbin 时漏检)
    local lc=""
    if command -v ldconfig >/dev/null 2>&1; then lc="ldconfig"
    elif [ -x /sbin/ldconfig ]; then lc="/sbin/ldconfig"; fi
    if [ -n "$lc" ] && $lc -p 2>/dev/null | grep -q -- "$lib"; then
        return 0
    fi
    # 方式2: 直接查找常见库目录 (兜底, 解决 ldconfig 缓存未刷新/不可用的假阳性)
    local d
    for d in /lib /lib64 /usr/lib /usr/lib64 \
             /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu \
             /lib/i386-linux-gnu /usr/lib/i386-linux-gnu; do
        [ -e "$d/$lib" ] && return 0
    done
    return 1
}

# libtirpc 在不同发行版 soname 不同: RHEL/CentOS7 为 libtirpc.so.1, Ubuntu/OL8 为 libtirpc.so.3
# Oracle 19c 在各平台分别链接对应 soname, 任一存在即满足依赖 (避免 CentOS7 上误报缺失)
omf_lib_tirpc_present() {
    omf_lib_present "libtirpc.so.3" || omf_lib_present "libtirpc.so.1"
}

# ---- 以 oracle 用户执行命令 (兼容 root 调用与 oracle 直接调用) ----
# 优先 runuser: root 切换免密码认证, 规避 su 在 Linux-PAM 1.4+ 下
#   (Ubuntu 的 root 账户本身锁定, 导致 pam_rootok 对 root->oracle 也走认证并报
#    Authentication failure) 的问题. 回退 su - oracle (老系统无 runuser 时).
oracle_su() {
    local cmd="$1"
    if [ "$(id -u)" -eq 0 ]; then
        if command -v runuser >/dev/null 2>&1; then
            runuser -l oracle -c "$cmd"
        else
            su - oracle -c "$cmd"
        fi
    elif [ "$(whoami)" = "oracle" ]; then
        eval "$cmd"
    else
        log_error "需要 root 或 oracle 用户执行"
    fi
}

as_oracle() {
    local script="$1"
    if [ "$(id -u)" -eq 0 ]; then
        oracle_su "export ORACLE_SID=${ORACLE_SID:-ARTERY}; \
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
    OMF_LOCK_FILE="/tmp/omf_${lock_name}.lock"
    exec 200>"$OMF_LOCK_FILE"
    flock -n 200 || log_error "另一个 OMF 进程正在运行 (lock: $OMF_LOCK_FILE)"
}

# ---- 系统内存(MB) ----
get_total_memory_mb() {
    awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
}

# ---- Oracle 内存规划 (比例可配置, 见 conf: ORACLE_MEM_RATIO / SGA_RATIO / HUGEPAGES_RESERVE_FREE_MB) ----
# 分配给 Oracle 的总内存(MB): 物理内存 * ORACLE_MEM_RATIO%, 下限 2048
omf_oracle_mem_mb() {
    local total_mem; total_mem=$(get_total_memory_mb)
    local oracle_mb=$(( total_mem * ${OMF_CONFIG[ORACLE_MEM_RATIO]:-80} / 100 ))
    [ "$oracle_mb" -lt 2048 ] && oracle_mb=2048
    echo "$oracle_mb"
}

# SGA 目标(MB): Oracle 内存 * SGA_RATIO%, 并钳制为不超过 (物理内存 - 给OS预留)
# 这样小内存机器不会把内存全锁成大页, 给 OS/安装器留余量
omf_sga_mb() {
    local total_mem; total_mem=$(get_total_memory_mb)
    local oracle_mb; oracle_mb=$(omf_oracle_mem_mb)
    local sga_mb=$(( oracle_mb * ${OMF_CONFIG[SGA_RATIO]:-75} / 100 ))
    local max_reservable=$(( total_mem - ${OMF_CONFIG[HUGEPAGES_RESERVE_FREE_MB]:-2048} ))
    [ "$max_reservable" -lt 2048 ] && max_reservable=2048
    if [ "$sga_mb" -gt "$max_reservable" ]; then
        sga_mb=$max_reservable
    fi
    echo "$sga_mb"
}

# HugePages 数量 (2MB/页): 向上取整覆盖 SGA
omf_hugepages_count() {
    local sga_mb; sga_mb=$(omf_sga_mb)
    local hp=$(( (sga_mb + 2048 - 1) / 2 + 1 ))
    echo "$hp"
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

    # SGA+PGA 默认占 ORACLE_MEM_RATIO%, 单实例不应超过物理内存
    local oracle_mb; oracle_mb=$(omf_oracle_mem_mb)
    log_info "计划分配给 Oracle: ${oracle_mb}MB (约 $((oracle_mb/1024))GB, 比例 ${OMF_CONFIG[ORACLE_MEM_RATIO]:-80}%)"

    # HugePages 推荐值 (按 SGA 估算, 页大小 2MB)
    local sga_mb; sga_mb=$(omf_sga_mb)
    local raw_sga=$(( oracle_mb * ${OMF_CONFIG[SGA_RATIO]:-75} / 100 ))
    local max_reservable=$(( total_mem - ${OMF_CONFIG[HUGEPAGES_RESERVE_FREE_MB]:-2048} ))
    [ "$max_reservable" -lt 2048 ] && max_reservable=2048
    if [ "$raw_sga" -gt "$max_reservable" ]; then
        log_warn "SGA 已钳制为 ${sga_mb}MB (为给 OS 保留 ${OMF_CONFIG[HUGEPAGES_RESERVE_FREE_MB]:-2048}MB, 避免大页吃满内存)"
    fi
    local hp; hp=$(omf_hugepages_count)
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
