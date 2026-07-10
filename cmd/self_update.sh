#!/bin/bash
#===============================================================================
# OMF - 框架自更新命令
# 用法: omf self-update [version|force]
# 依赖 conf/omf.conf 中的 OMF_UPDATE_URL (指向 omf.tar.gz)
# 可选 OMF_UPDATE_SHA256 (压缩包 sha256, 用于完整性校验)
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

    # 完整性校验: 若配置了期望的 SHA256, 则校验 (防止下载到损坏或被篡改的包)
    if [ -n "${OMF_UPDATE_SHA256:-}" ]; then
        local actual
        actual=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')
        if [ "$actual" != "$OMF_UPDATE_SHA256" ]; then
            rm -f "$tmp"
            log_error "完整性校验失败: 期望 ${OMF_UPDATE_SHA256}, 实际 ${actual}"
        fi
        log_info "SHA256 校验通过: $actual"
    fi

    # 解压
    local exdir="/tmp/omf_extract_$$"
    mkdir -p "$exdir"
    if ! tar xzf "$tmp" -C "$exdir"; then
        rm -rf "$exdir" "$tmp"
        log_error "解压失败, 更新中止 (旧版本仍在)"
    fi

    # 定位压缩包内的 omf 根目录
    local src
    src=$(find "$exdir" -maxdepth 3 -name omf.sh -exec dirname {} \; | head -1)
    [ -z "$src" ] && { rm -rf "$exdir" "$tmp"; log_error "压缩包内未找到 omf.sh, 更新中止"; }

    # 版本比较: 提取包内版本号, 与本地比较
    local new_ver
    new_ver=$(grep -m1 '^export OMF_VERSION=' "$src/omf.sh" 2>/dev/null | sed 's/.*=//; s/"//g')
    new_ver="${new_ver:-unknown}"
    log_info "本地版本: ${OMF_VERSION}  远程版本: ${new_ver}"
    if [ "$new_ver" != "unknown" ] && [ "$new_ver" = "$OMF_VERSION" ] && [ "$ver" != "force" ]; then
        log_warn "远程版本与本地一致 (${new_ver}), 无需更新 (如需强制更新请加 force)"
        rm -rf "$exdir" "$tmp"
        return 0
    fi

    confirm "确认用下载包覆盖更新当前 OMF (${OMF_HOME})? 现有脚本将先备份, 用户配置(conf/sql/logs)不会被覆盖"

    # 备份当前版本脚本/入口 (不备份用户数据: conf/sql/logs)
    local bak="${OMF_HOME}/.backup/omf_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$bak"
    cp -r "${OMF_HOME}/cmd" "${OMF_HOME}/lib" "${OMF_HOME}/omf.sh" "${OMF_HOME}/setup.sh" "$bak/" 2>/dev/null || true
    log_info "已备份当前版本到: $bak"

    # 覆盖 (保留 conf/sql/logs/用户数据)
    _omf_apply_update() {
        cp -r "$src/cmd" "$OMF_HOME/" 2>/dev/null && \
        cp -r "$src/lib" "$OMF_HOME/" 2>/dev/null && \
        cp "$src/omf.sh" "$src/setup.sh" "$OMF_HOME/" 2>/dev/null
    }

    # 覆盖失败: 先回滚再报错退出 (log_error 会 exit, 故回滚须在其之前)
    if ! _omf_apply_update; then
        cp -r "${bak}/cmd" "${bak}/lib" "$OMF_HOME/" 2>/dev/null || true
        cp "${bak}/omf.sh" "${bak}/setup.sh" "$OMF_HOME/" 2>/dev/null || true
        rm -rf "$exdir" "$tmp"
        log_error "文件覆盖失败, 已回滚到更新前版本"
    fi
    chmod +x "${OMF_HOME}/omf.sh" "${OMF_HOME}/setup.sh" 2>/dev/null || true

    # 更新后完整性校验: 关键文件必须存在
    local ok=true
    for f in omf.sh setup.sh cmd/env.sh lib/common.sh; do
        [ -f "${OMF_HOME}/$f" ] || { ok=false; break; }
    done
    if [ "$ok" != "true" ]; then
        cp -r "${bak}/cmd" "${bak}/lib" "$OMF_HOME/" 2>/dev/null || true
        cp "${bak}/omf.sh" "${bak}/setup.sh" "$OMF_HOME/" 2>/dev/null || true
        rm -rf "$exdir" "$tmp"
        log_error "更新后完整性校验失败, 已回滚到更新前版本"
    fi

    rm -rf "$exdir" "$tmp"
    log_info "OMF 已更新至 ${new_ver} (之前 ${OMF_VERSION})"
}
