#!/bin/bash
#===============================================================================
# OMF - 框架自更新命令
# 用法: omf self-update [version]
# 依赖 conf/omf.conf 中的 OMF_UPDATE_URL (指向 omf.tar.gz)
#===============================================================================

cmd_self_update() {
    local url="${OMF_UPDATE_URL:-}"
    local ver="${1:-latest}"

    if [ -z "$url" ]; then
        log_error "未配置 OMF_UPDATE_URL, 请在 conf/omf.conf 设置, 例如: OMF_UPDATE_URL=\"http://your-host/omf/omf.tar.gz\""
    fi

    log_step "检查更新 (${ver}): $url"

    local tmp="/tmp/omf_update_$$.tar.gz"
    if ! wget -q -O "$tmp" "$url"; then
        rm -f "$tmp"
        log_error "下载失败: $url"
    fi
    log_info "已下载: $tmp ($(du -h "$tmp" | cut -f1))"

    confirm "确认用下载包覆盖更新当前 OMF (${OMF_HOME})? 现有脚本将先备份, 用户配置(conf/sql/logs)不会被覆盖"

    # 备份当前版本脚本/入口 (不备份用户数据: conf/sql/logs)
    local bak="${OMF_HOME}/.backup/omf_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$bak"
    cp -r "${OMF_HOME}/cmd" "${OMF_HOME}/lib" "${OMF_HOME}/omf.sh" "${OMF_HOME}/setup.sh" "$bak/" 2>/dev/null || true
    log_info "已备份当前版本到: $bak"

    # 解压并同步 (保留 conf/sql/logs/用户数据)
    local exdir="/tmp/omf_extract_$$"
    mkdir -p "$exdir"
    if ! tar xzf "$tmp" -C "$exdir"; then
        rm -rf "$exdir" "$tmp"
        log_error "解压失败, 更新中止 (旧版本仍在)"
    fi

    # 定位压缩包内的 omf 根目录
    local src
    src=$(find "$exdir" -maxdepth 3 -name omf.sh -exec dirname {} \; | head -1)
    [ -z "$src" ] && src="$exdir"

    cp -r "$src/cmd" "$OMF_HOME/" 2>/dev/null || true
    cp -r "$src/lib" "$OMF_HOME/" 2>/dev/null || true
    cp "$src/omf.sh" "$src/setup.sh" "$OMF_HOME/" 2>/dev/null || true
    chmod +x "${OMF_HOME}/omf.sh" "${OMF_HOME}/setup.sh" 2>/dev/null || true

    rm -rf "$exdir" "$tmp"
    log_info "OMF 已更新至 ${ver}. 当前版本常量: ${OMF_VERSION} (如版本号未变, 请检查压缩包内容)"
    log_info "提示: 若 OMF_VERSION 未随更新变化, 请确认压缩包内 omf.sh 的 OMF_VERSION 已更新"
}
