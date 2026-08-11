#!/bin/bash
# OMF - 实例清单 / 多实例批量管理 (fleet)
# 用法: omf fleet {list|run|status|check|add|remove}
# 内部自洽, 依赖 lib/common.sh (log_*).
# 作用: 让运维在一台管理机上批量对多台 Oracle 主机执行 OMF 命令, 从"单机工具"走向"运维平台"。
# 清单文件: ${OMF_HOME}/conf/fleet.conf (每行 <实例名> <目标> [--omf <路径>], 见 fleet.conf.example)
#===============================================================================

FLEET_CONF="${OMF_HOME}/conf/fleet.conf"

# 解析 fleet.conf, 输出到全局数组 _FLEET_NAME/_FLEET_TARGET/_FLEET_OMF
# 跳过空行/注释; 兼容 --omf 可选参数
_fleet_load() {
    _FLEET_NAME=(); _FLEET_TARGET=(); _FLEET_OMF=()
    [ -f "$FLEET_CONF" ] || { log_error "实例清单不存在: $FLEET_CONF (cp conf/fleet.conf.example conf/fleet.conf)"; }
    local line name target omf extra
    while IFS= read -r line; do
        # 去除行尾注释 (# 后) 与首尾空白
        line="${line%%#*}"
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        # read 最后一个变量会拿到剩余全部 token, 故用 extra 捕获 --omf 后的路径
        read -r name target omf extra <<< "$line"
        [ -z "$name" ] && continue
        [ -z "$target" ] && continue
        _FLEET_NAME+=("$name")
        _FLEET_TARGET+=("$target")
        # 解析 --omf 值: 第3字段可能是 "--omf"(此时第4字段 extra 是路径) 或直接是路径
        local omf_path="/opt/omf/omf.sh"
        if [ "$omf" = "--omf" ]; then
            [ -n "$extra" ] && omf_path="$extra"
        elif [ -n "$omf" ] && [ "$omf" != "--omf" ]; then
            omf_path="$omf"
        fi
        _FLEET_OMF+=("$omf_path")
    done < "$FLEET_CONF"
    if [ "${#_FLEET_NAME[@]}" -eq 0 ]; then
        log_error "实例清单为空: $FLEET_CONF"
    fi
    return 0
}

# 对单个实例执行命令: 本地直接跑, 远程经 SSH
#   $1=实例名  $2=目标(local|user@host)  $3=远程omf路径  $4..=omf 命令参数
# 输出前缀 [实例名] 便于区分; 返回 0=成功 1=失败
_fleet_exec() {
    local name="$1" target="$2" omf="$3"; shift 3
    local cmdline; cmdline="$*"
    local rc
    if [ "$target" = "local" ]; then
        # 本机: 直接调用本 OMF (注意: fleet 本身也是 omf, 用 bash omf.sh 避免递归锁问题)
        bash "${OMF_HOME}/omf.sh" -y $cmdline > /tmp/omf_fleet_${name}.out 2>&1
        rc=$?
    else
        # 远程: SSH 调用目标机的 omf
        if ! command -v ssh &>/dev/null; then
            log_warn "[${name}] 本机无 ssh 命令, 跳过"
            return 1
        fi
        ssh -o ConnectTimeout=10 -o BatchMode=yes "$target" "'$omf' -y $cmdline" > /tmp/omf_fleet_${name}.out 2>&1
        rc=$?
    fi
    return "$rc"
}

# 批量执行命令 (fleet run <omf 命令...>)
fleet_run() {
    [ $# -eq 0 ] && { echo "用法: omf fleet run <omf 命令及参数>  例: omf fleet run status / omf fleet run check monitor --alert"; return 1; }
    _fleet_load
    local cmdline="$*"
    log_step "批量执行 ${#_FLEET_NAME[@]} 个实例: omf $cmdline"
    local ok=0 fail=0 i name target omf
    for (( i=0; i<${#_FLEET_NAME[@]}; i++ )); do
        name="${_FLEET_NAME[$i]}"; target="${_FLEET_TARGET[$i]}"; omf="${_FLEET_OMF[$i]}"
        echo "──────────────────────────────────────────"
        echo "▶ [${name}] (${target})  omf ${cmdline}"
        if _fleet_exec "$name" "$target" "$omf" $cmdline; then
            echo "  ✓ [${name}] 成功"
            ok=$((ok+1))
        else
            echo "  ✗ [${name}] 失败 (rc=$?)"
            fail=$((fail+1))
        fi
        # 显示该实例输出 (缩进)
        sed 's/^/    /' /tmp/omf_fleet_${name}.out 2>/dev/null
        rm -f /tmp/omf_fleet_${name}.out
    done
    echo ""
    echo "══════════════════════════════════════════"
    echo "批量执行汇总: 成功 ${ok}  失败 ${fail}  共 ${#_FLEET_NAME[@]}"
    [ "$fail" -gt 0 ] && return 1
    return 0
}

# 批量状态 (fleet status)
fleet_status() {
    fleet_run status
}

# 批量健康检查 (fleet check)
fleet_check() {
    fleet_run check monitor --alert
}

# 列出实例
fleet_list() {
    _fleet_load
    echo ""
    echo "════════ OMF 实例清单 (fleet.conf) ════════"
    printf "  %-16s %-28s %s\n" "实例名" "目标" "远程OMF"
    local i
    for (( i=0; i<${#_FLEET_NAME[@]}; i++ )); do
        printf "  %-16s %-28s %s\n" "${_FLEET_NAME[$i]}" "${_FLEET_TARGET[$i]}" "${_FLEET_OMF[$i]}"
    done
    echo "════════════════════════════════════════════"
}

# 添加实例 (fleet add <name> <target> [--omf <path>])
fleet_add() {
    local name="$1" target="$2"; shift 2
    [ -z "$name" ] || [ -z "$target" ] && { echo "用法: omf fleet add <实例名> <local|user@host> [--omf <远程omf路径>]"; return 1; }
    _fleet_load
    local i
    for (( i=0; i<${#_FLEET_NAME[@]}; i++ )); do
        [ "${_FLEET_NAME[$i]}" = "$name" ] && log_error "实例已存在: $name"
    done
    local omf_path="/opt/omf/omf.sh"
    if [ "$1" = "--omf" ] && [ -n "$2" ]; then omf_path="$2"; fi
    echo "${name} ${target} --omf ${omf_path}" >> "$FLEET_CONF"
    log_info "已添加实例: ${name} -> ${target} (--omf ${omf_path})"
    fleet_list
}

# 移除实例 (fleet remove <name>)
fleet_remove() {
    local name="$1"
    [ -z "$name" ] && { echo "用法: omf fleet remove <实例名>"; return 1; }
    [ -f "$FLEET_CONF" ] || log_error "实例清单不存在: $FLEET_CONF"
    confirm "确认从清单移除实例 ${name}? (仅移除清单条目, 不影响远程数据库)"
    grep -v "^[[:space:]]*${name}[[:space:]]" "$FLEET_CONF" > "${FLEET_CONF}.tmp" 2>/dev/null
    mv "${FLEET_CONF}.tmp" "$FLEET_CONF"
    log_info "已移除实例: ${name}"
    fleet_list
}

cmd_fleet() {
    local subcmd="${1:-list}"
    shift || true
    log_set_subcmd "$subcmd"
    case "$subcmd" in
        list)   fleet_list "$@";;
        run)    fleet_run "$@";;
        status) fleet_status "$@";;
        check)  fleet_check "$@";;
        add)    fleet_add "$@";;
        remove) fleet_remove "$@";;
        *)
            echo "用法: omf fleet {list|run|status|check|add|remove}"
            echo "  list     列出所有实例"
            echo "  run <cmd> 对全部实例批量执行 omf <cmd>  例: omf fleet run status"
            echo "  status   批量状态 (≡ fleet run status)"
            echo "  check    批量健康检查+告警 (≡ fleet run check monitor --alert)"
            echo "  add/remove 增删实例 (编辑 conf/fleet.conf)"
            ;;
    esac
}
