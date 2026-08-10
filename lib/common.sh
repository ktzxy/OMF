#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF 公共函数库 v2
# 变更: TTY 颜色自适应 / 集中日志 / 通知 / 锁 / oracle 兼容执行 / 内存预检
#===============================================================================

# ---- 颜色 (仅在 TTY 输出带颜色, 写入日志文件自动去色) ----
if [ -t 1 ]; then
    # 用 ANSI-C 引号 ($'...') 存真正的 ESC 字节, 这样 printf %s 与 echo -e 都能正确渲染
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
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

# 自动清理 OMF 自身运行日志, 防止长期运行撑满磁盘
#   策略: 仅删 ${OMF_HOME}/logs 一级的 omf_*.log; 保留期优先 LOG_RETENTION_DAYS, 否则 30 天.
#   不影响子目录(awr / monitor_history 等, 它们有各自生命周期); 本次新建的日志是当天, 不会被误删.
omf_prune_own_logs() {
    local dir="${OMF_HOME}/logs"
    [ -d "$dir" ] || return 0
    local days="${OMF_CONFIG[LOG_RETENTION_DAYS]:-30}"
    [ "$days" -lt 1 ] 2>/dev/null && days=30
    find "$dir" -maxdepth 1 -name 'omf_*.log' -mtime "+$((days-1))" -delete 2>/dev/null || true
}

# 初始化本次运行的集中日志
log_init() {
    local cmd="$1"
    mkdir -p "${OMF_HOME}/logs"
    OMF_RUN_LOG="${OMF_HOME}/logs/omf_${cmd}_$(date +%Y%m%d_%H%M%S).log"
    export OMF_RUN_LOG
    # 每次运行顺手清理过期 OMF 日志 (无副作用, 失败忽略)
    omf_prune_own_logs
    log_debug "运行日志: $OMF_RUN_LOG"
}

# ---- 通知 (可选) ----
# 渠道 (可叠加):
#   1) 可执行钩子 conf/notify.sh (优先级最高, 可对接任意自定义: 邮件/钉钉/企微/alertmanager)
#   2) 通用 webhook: OMF_NOTIFY_WEBHOOK 设 URL 即启用, OMF_NOTIFY_WEBHOOK_FMT 指定
#      raw(默认, {"title","content"}) / dingtalk(text) / wechat(markdown) —— 兼容 alertmanager/钉钉/企微
#   3) 邮件兜底: OMF_NOTIFY_MAIL 设收件人且系统有 mail
send_notification() {
    local subject="$1"; local body="$2"
    local hook="${OMF_HOME}/conf/notify.sh"
    if [ -x "$hook" ]; then
        "$hook" "$subject" "$body" &>/dev/null &
    fi
    # 通用 webhook 渠道
    local wh="${OMF_NOTIFY_WEBHOOK:-}"
    if [ -n "$wh" ] && command -v curl &>/dev/null; then
        local fmt="${OMF_NOTIFY_WEBHOOK_FMT:-raw}"
        # JSON 转义: 反斜杠/双引号/换行
        local s; s="${subject//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"
        local b; b="${body//\\/\\\\}"; b="${b//\"/\\\"}"; b="${b//$'\n'/\\n}"
        local payload
        case "$fmt" in
            dingtalk) payload="{\"msgtype\":\"text\",\"text\":{\"content\":\"${s}\n${b}\"}}";;
            wechat)   payload="{\"msgtype\":\"markdown\",\"markdown\":{\"content\":\"**${s}**\n${b}\"}}";;
            *)        payload="{\"title\":\"${s}\",\"content\":\"${b}\"}";;
        esac
        curl -s -m 10 -H 'Content-Type: application/json' -X POST -d "$payload" "$wh" &>/dev/null &
    fi
    if command -v mail &>/dev/null && [ -n "${OMF_NOTIFY_MAIL:-}" ]; then
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
# 语义: 
#   - --yes: 自动通过 (return 0)
#   - 交互 + yes: 通过 (return 0); 交互 + 其它: 用户主动取消, 视为正常结束 (exit 0)
#   - 非交互(如 cron)且无 --yes: 默认拒绝。此时调用方无法"主动取消", 只能"默认拒绝";
#     返回非0让调用链(cron 判障)能感知"未执行", 而非误以为已成功 (与 confirm_danger 一致)。
confirm() {
    local msg="${1:-确认继续?}"
    [ "${OMF_ASSUME_YES:-false}" = "true" ] && return 0
    # 非交互环境(如 cron)且无 --yes, 默认拒绝以避免危险操作
    [ -t 0 ] || { log_warn "非交互环境, 未指定 --yes, 已取消: $msg"; return 1; }
    local ans
    read -r -p "$msg (yes/no): " ans
    case "$ans" in
        yes|y|Y) return 0;;
        *) log_warn "用户取消"; exit 0;;
    esac
}

# ---- 危险操作确认 (不受全局 -y 影响) ----
# 用于不可逆 / 影响可恢复性的操作 (如全量清理归档日志、关闭归档模式).
# 与 confirm() 不同: 即使 OMF_ASSUME_YES=true (全局 --yes), 也强制二次确认,
#   防止自动化 / cron / 误用 -y 时静默执行破坏:
#     - 交互环境:  必须显式输入 YES 才放行;
#     - 非交互环境 (管道 / cron): 默认中止并返回非0, 打印提示 (避免静默误删).
#   确需脚本化的危险操作: 显式导出 OMF_ALLOW_DANGEROUS=1 才跳过确认.
confirm_danger() {
    local prompt="${1:-危险操作, 确认继续?}"
    if [ "${OMF_ALLOW_DANGEROUS:-0}" = "1" ]; then
        log_warn "OMF_ALLOW_DANGEROUS=1 已设, 放行危险操作: ${prompt}"
        return 0
    fi
    echo -e "${RED}════════ 危险操作 ════════${NC}"
    echo -e "  ${prompt}"
    echo -e "${YELLOW}此操作不可逆或影响可恢复性. 即使已使用 -y, 仍需显式确认.${NC}"
    if [ -t 0 ]; then
        local ans
        read -r -p "  输入 YES 继续, 其它任意键中止: " ans
        if [ "$ans" = "YES" ]; then
            return 0
        fi
        echo "已取消"
        return 1
    else
        log_warn "危险操作在非交互环境中被自动中止 (防止自动化误执行): ${prompt} —— 如需执行请交互运行, 或设 OMF_ALLOW_DANGEROUS=1"
        return 1
    fi
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
    # 环境变量为空时回退到 OMF_CONFIG (omf.sh 入口不会把 ORACLE_HOME 等注入 shell,
    # 在全新终端直接跑 omf tune apply/awr 时环境变量为空, 否则 sqlplus 找不到导致静默失败)
    local sid="${ORACLE_SID:-${OMF_CONFIG[ORACLE_SID]:-ARTERY}}"
    local home="${ORACLE_HOME:-${OMF_CONFIG[ORACLE_HOME]}}"
    local base="${ORACLE_BASE:-${OMF_CONFIG[ORACLE_BASE]}}"
    local nls="${NLS_LANG:-AMERICAN_AMERICA.AL32UTF8}"
    if [ "$(id -u)" -eq 0 ]; then
        oracle_su "export ORACLE_SID=${sid}; \
export ORACLE_HOME=${home}; \
export ORACLE_BASE=${base}; \
export PATH=\$ORACLE_HOME/bin:\$PATH; \
export NLS_LANG=${nls}; \
$script"
    elif [ "$(whoami)" = "oracle" ]; then
        export ORACLE_SID="${sid}"
        export ORACLE_HOME="${home}"
        export ORACLE_BASE="${base}"
        export PATH="$home/bin:$PATH"
        export NLS_LANG="${nls}"
        eval "$script"
    else
        log_error "需要 root 或 oracle 用户执行"
    fi
}

# ---- Data Guard 助手 ----
# 返回当前数据库角色 (PRIMARY / PHYSICAL STANDBY / LOGICAL STANDBY / SNAPSHOT STANDBY)
#   数据库未起/不可连时返回空
omf_db_role() {
    as_oracle "echo \"select database_role from v\\\$database;\" | sqlplus -s / as sysdba" 2>/dev/null \
        | grep -iE 'PRIMARY|STANDBY' | head -1
}
# 配置是否启用 DG (conf 中 ENABLE_DG=true)
omf_dg_enabled() {
    [ "${ENABLE_DG:-false}" = "true" ]
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

# HugePages 数量 (2MB/页): 覆盖 SGA, 仅留少量余量(约256MB+2页)
# 注: 余量过大(如旧版 +1GB)会在小内存机器上过度预留, 挤占 PGA/OS 常规内存导致 OOM
omf_hugepages_count() {
    local sga_mb; sga_mb=$(omf_sga_mb)
    local hp=$(( (sga_mb + 256) / 2 + 2 ))
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

# ---- 字节数转人类可读 (B/K/M/G) ----
human_size() {
    local bytes="${1:-0}"
    [ -z "${bytes}" ] && bytes=0
    awk -v b="$bytes" 'BEGIN{
        if(b<1024) printf "%.0fB", b;
        else if(b<1048576) printf "%.1fK", b/1024;
        else if(b<1073741824) printf "%.1fM", b/1048576;
        else printf "%.1fG", b/1073741824;
    }'
}

# ---- 分钟数转人类可读时长 (Xd Yh Zm / Yh Zm / Zm) ----
fmt_duration() {
    local mins="${1:-}"
    if [ -z "$mins" ] || [ "$mins" -lt 0 ] 2>/dev/null; then
        echo "N/A"; return
    fi
    local d=$((mins/1440)) h=$(((mins%1440)/60)) m=$((mins%60))
    if [ "$d" -gt 0 ]; then echo "${d}天${h}时${m}分"
    elif [ "$h" -gt 0 ]; then echo "${h}时${m}分"
    else echo "${m}分"; fi
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

# ---- 查找 Alert 日志路径 (兼容 19c 文本/XML 及大小写变体) ----
get_alert_log() {
    local sid="${OMF_CONFIG[ORACLE_SID]}"
    local base="${OMF_CONFIG[ORACLE_BASE]}"
    local f
    # 1) 常见文本 alert 日志
    f="${base}/diag/rdbms/${sid}/${sid}/trace/alert_${sid}.log"
    [ -f "$f" ] && { echo "$f"; return; }
    # 2) 大小写/变体: 动态查找文本 alert 日志
    f=$(find "${base}/diag/rdbms" -type f -name "alert_${sid}.log" 2>/dev/null | head -1)
    [ -n "$f" ] && { echo "$f"; return; }
    # 3) XML 格式 alert (19c 默认)
    f=$(find "${base}/diag/rdbms" -type f -name "log.xml" -path "*alert*" 2>/dev/null | head -1)
    [ -n "$f" ] && { echo "$f"; return; }
    # 4) 回退原始假设路径
    echo "${base}/diag/rdbms/${sid}/${sid}/trace/alert_${sid}.log"
}

#===============================================================================
# 备份清理 (被 omf backup cleanup 与 omf clean backup 共用)
# 两种模式:
#   --all        删除【全部】备份 (RMAN 备份集/镜像副本 + 所有 dump/物理文件), 需确认
#   -d N         删除 N 天前完成的备份 (默认 BACKUP_RETENTION_DAYS, 回退 30)
# 注: "-d N" 这里的 N 天前 = 当前日期往前 N 天 (find -mtime +N / RMAN SYSDATE-N)
#===============================================================================
backup_cleanup() {
    local all="false" days="" dry_run="false" yes="false" scope="both"
    # 1) 继承 cmd_clean 注入的全局变量 (omf clean backup 路径)
    [ -n "${CLEAN_DAYS:-}" ] && days="$CLEAN_DAYS"
    [ "${CLEAN_ALL:-false}" = "true" ] && all="true"
    [ "${CLEAN_PREVIEW:-false}" = "true" ] && dry_run="true"
    [ "${CLEAN_YES:-false}" = "true" ] && yes="true"
    # 2) 解析本次传入参数 (omf backup cleanup 路径, 可覆盖全局)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "用法: omf backup cleanup [--logical|--physical] [-d 天数 | --all] [-p|--dry-run|list] [-y]"
                echo "  --logical   仅清理逻辑备份(dump)      --physical  仅清理物理备份(RMAN)"
                echo "  -d N        清理 N 天前的 (默认 30)    --all       清理全部(忽略天数)"
                echo "  -p|list     仅预览, 不删除            -y          跳过确认直接执行"
                exit 0;;
            -p|--preview|--dry-run|list) dry_run="true"; shift;;
            --logical)  scope="logical";  shift;;
            --physical) scope="physical"; shift;;
            -d|--days) days="$2"; shift 2;;
            --all|-a|--force) all="true"; shift;;
            -y|--yes) yes="true"; shift;;
            *) log_error "未知参数: $1 (用法: omf backup cleanup [--logical|--physical] [-d 天数 | --all] [-p|--dry-run|list] [-y])"; exit 1;;
        esac
    done
    [ -z "$days" ] && days="${OMF_CONFIG[BACKUP_RETENTION_DAYS]:-30}"
    # -y 真正免交互: 设置 confirm() 读取的环境变量, 否则 -y 只是被吞掉仍弹确认
    [ "$yes" = "true" ] && export OMF_ASSUME_YES=true

    local base="${ORACLE_BACKUP:-/backup/oracle}"
    local sid="${OMF_CONFIG[ORACLE_SID]:-ARTERY}"
    local scope_desc
    if [ "$all" = "true" ]; then scope_desc="【全部】${scope}备份"; else scope_desc="${days} 天前的 ${scope}备份"; fi

    if [ "$dry_run" = "true" ]; then
        echo "========== [DRY-RUN] 仅预览将要删除的对象, 不实际删除 =========="
        echo "清理范围: ${scope_desc}"
    elif [ "$yes" != "true" ]; then
        if [ "$all" = "true" ]; then
            confirm "确认清理【全部】${scope}备份? 此操作不可恢复!"
        else
            confirm "确认清理 ${days} 天前的 ${scope}备份?"
        fi
    fi

    # 删除执行器: dry_run 时仅打印待删对象, 否则真正删除
    _cleanup_find() {
        if [ "$dry_run" = "true" ]; then
            find "$@" -print 2>/dev/null | sed 's/^/  [将删除] /'
        else
            find "$@" -delete 2>/dev/null || true
        fi
    }

    # --- 1) 逻辑备份 (dump) ---
    if [ "$scope" = "both" ] || [ "$scope" = "logical" ]; then
        if [ "$all" = "true" ]; then
            log_step "清理全部 dump 文件: ${base}/dump"
            _cleanup_find "${base}/dump" -name "*.dmp"
            _cleanup_find "${base}/dump" -name "*.log"
        else
            # 注意: find -mtime +N 实际删 (N+1) 天前, 故用 +(days-1) 实现"保留 days 天"
            log_step "清理 ${days} 天前的 dump 文件: ${base}/dump"
            _cleanup_find "${base}/dump" -name "*.dmp" -mtime "+$((days-1))"
            _cleanup_find "${base}/dump" -name "*.log" -mtime "+$((days-1))"
        fi
    fi

    # --- 2) 物理备份 (RMAN 备份集 + 物理目录) ---
    if [ "$scope" = "both" ] || [ "$scope" = "physical" ]; then
        if [ "$dry_run" = "true" ]; then
            echo "  [DRY-RUN] 将执行 RMAN 清理: ${scope_desc} (此处不实际连接数据库)"
            log_info "备份清理预览完成 (DRY-RUN, 未做任何删除)"
            return 0
        fi

        # 物理目录兜底清理 (RMAN 已删的不会重复; 仅清孤儿文件)
        for d in full incremental controlfile spfile; do
            [ -d "${base}/${d}" ] || continue
            if [ "$all" = "true" ]; then
                log_step "清理全部物理文件: ${base}/${d}"
                _cleanup_find "${base}/${d}" -type f
            else
                log_step "清理 ${days} 天前的物理文件: ${base}/${d}"
                _cleanup_find "${base}/${d}" -type f -mtime "+$((days-1))"
            fi
        done

        # 3) RMAN 元数据清理 (需数据库运行且归档模式)
        local arch_on
    arch_on=$(oracle_su "
export ORACLE_SID=${sid}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
echo \"select log_mode from v\\\$database;\" | sqlplus -s / as sysdba | grep -i 'ARCHIVELOG'
" 2>/dev/null)

    if [ -n "$arch_on" ]; then
        if [ "$all" = "true" ]; then
            log_step "RMAN: 删除全部备份集与镜像副本, 并清理孤立(文件已失)的过期记录"
            # 注: 先 CROSSCHECK+DELETE EXPIRED 清理孤儿记录(文件已被 find 删/丢失的 EXPIRED 备份),
            #      DELETE NOPROMPT BACKUP 只删 AVAILABLE 的, 不碰 EXPIRED, 故孤儿必须单独清
            oracle_su "
export ORACLE_SID=${sid}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
rman target / <<RMANEOF
CROSSCHECK BACKUP;
CROSSCHECK COPY;
DELETE NOPROMPT EXPIRED BACKUP;
DELETE NOPROMPT EXPIRED COPY;
DELETE NOPROMPT BACKUP;
DELETE NOPROMPT COPY;
RMANEOF
" 2>&1 | tail -40
        else
            log_step "RMAN: 删除 ${days} 天前完成的备份集, 并清理孤立(文件已失)的过期记录"
            oracle_su "
export ORACLE_SID=${sid}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
rman target / <<RMANEOF
CROSSCHECK BACKUP;
CROSSCHECK COPY;
DELETE NOPROMPT EXPIRED BACKUP;
DELETE NOPROMPT EXPIRED COPY;
DELETE NOPROMPT BACKUP COMPLETED BEFORE 'SYSDATE-${days}';
RMANEOF
" 2>&1 | tail -40
        fi
    else
        log_warn "数据库未运行或非归档模式, 跳过 RMAN 元数据清理 (仅清理磁盘文件)"
    fi
    fi   # 闭合 [scope=both|physical] 物理范围块

    log_info "备份清理完成"
}
