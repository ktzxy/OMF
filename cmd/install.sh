#!/bin/bash
#===============================================================================
# OMF - Oracle 软件安装命令
# 用法: omf install <subcommand> [options]
#===============================================================================

cmd_install() {
    local subcmd="${1:-software}"
    shift || true

    case "$subcmd" in
        software)
            install_software "$@"
            ;;
        listener)
            install_listener "$@"
            ;;
        check)
            install_check "$@"
            ;;
        *)
            echo "用法: omf install {software|listener|check}"
            exit 1
            ;;
    esac
}

#===============================================================================
# 按 ORACLE_VERSION 推导默认安装包名 (仅 CDB 系列: 18 / 19 / 21 / 23)
# 官方 db_home zip 命名规律: LINUX.X64_<五/六位版本>_db_home.zip
#===============================================================================
oracle_default_zip() {
    local ver="${OMF_CONFIG[ORACLE_VERSION]:-19}"
    local name
    case "$ver" in
        18)      name="LINUX.X64_180000_db_home.zip" ;;
        19)      name="LINUX.X64_193000_db_home.zip" ;;
        21)      name="LINUX.X64_213000_db_home.zip" ;;
        23|23ai) name="LINUX.X64_2340000_db_home.zip" ;;
        *)       name="LINUX.X64_193000_db_home.zip" ;;
    esac
    echo "/home/oracle/${name}"
}

#===============================================================================
# 按 ORACLE_VERSION 推导 CVU 兼容性假名 (让安装器绕过 OS 预检)
# 仅 CDB 系列: 18/19 在 OL8/9 上需声明为 OEL7.6; 21/23 声明为 OEL8.x
#===============================================================================
oracle_cvu_distid() {
    case "${OMF_CONFIG[ORACLE_VERSION]:-19}" in
        18|19)   echo "OEL7.6" ;;
        21)      echo "OEL8.6" ;;
        23|23ai) echo "OEL8.6" ;;
        *)       echo "OEL7.6" ;;
    esac
}

#===============================================================================
# 安装 Oracle 软件（集成自 02_install_oracle_software.sh）
#===============================================================================
install_software() {
    require_root

    local ver="${OMF_CONFIG[ORACLE_VERSION]:-19}"
    # 仅支持 CDB 系列版本, 非法版本给出明确提示
    case "$ver" in
        18|19|21|23|23ai) ;;
        *) log_error "不支持的 ORACLE_VERSION='${ver}' (仅支持 CDB 系列: 18 / 19 / 21 / 23)" ;;
    esac

    # 参数解析: 支持 --force/-f 强制重装; 其余按位置: <zip路径> [安装模式]
    local force=false
    local pos=()
    local a
    for a in "$@"; do
        case "$a" in
            -f|--force) force=true ;;
            *) pos+=("$a") ;;
        esac
    done

    # 安装包优先级: 命令行参数 > 配置 ORACLE_ZIP > 按版本推导默认名
    local zip_file="${pos[0]:-${OMF_CONFIG[ORACLE_ZIP]:-$(oracle_default_zip)}}"
    local install_mode="${pos[1]:-EE}"  # EE 或 SE

    log_step "========== Oracle ${ver}c 软件安装 =========="

    # 0. 环境就绪自检: oracle 用户/核心依赖缺失, 或 Ubuntu 下 /usr/lib64 软链未建
    #    (Oracle 链接前提), 自动执行环境准备 (含 env_lib64 建链 与 oracle 账户解锁)
    if ! id oracle &>/dev/null || ! ldconfig -p 2>/dev/null | grep -q "libaio.so.1" || [ ! -e /usr/lib64 ]; then
        log_warn "检测到环境未就绪, 自动执行 omf env prepare ..."
        source "${OMF_HOME}/cmd/env.sh"
        env_prepare
    fi

    # 1. 检查安装包
    if [ ! -f "$zip_file" ]; then
        log_error "安装包不存在: $zip_file (请将 Oracle ${ver}c 的 db_home zip 放到该路径, 或显式传入: omf install software <zip路径>, 或配置 ORACLE_ZIP)"
    fi
    log_info "安装包: $zip_file"

    # 1.1 自动接管安装包归属, 免去手动 chown (需 root, install_software 已 require_root)
    chown oracle:oinstall "$zip_file" 2>/dev/null || true
    chmod 644 "$zip_file" 2>/dev/null || true

    # 2. 安装运行时依赖
    log_step "[1/5] 安装运行时依赖"
    install_runtime_deps

    # 3. 准备 Inventory
    log_step "[2/5] 准备 Oracle Inventory"
    prepare_inventory

    # 3.5 幂等检查 / 强制重装
    # 仅当 sqlplus 存在 且 非 --force 时, 才判定为已完成并跳过;
    # 上一次若链接阶段失败, sqlplus 可能已存在但安装残缺 -> 必须 --force 重装
    if [ -x "${OMF_CONFIG[ORACLE_HOME]}/bin/sqlplus" ] && [ "$force" != "true" ]; then
        log_warn "检测到 ORACLE_HOME 已安装 Oracle 软件, 跳过解压与安装"
        install_listener
        log_info "Oracle 软件安装完成 (已存在, 跳过)!"
        return 0
    fi
    if [ "$force" = "true" ]; then
        log_warn "强制重装: 清理 ORACLE_HOME 与 inventory 锁后重新安装..."
        rm -rf "${OMF_CONFIG[ORACLE_HOME]}"
        rm -rf "${OMF_CONFIG[ORACLE_BASE]}/oraInventory/locks" 2>/dev/null || true
        prepare_inventory
    fi

    # 3.6 清理失败残余: 若 ORACLE_HOME 已存在但软件未安装成功 (sqlplus 不存在),
    #     说明上一次安装失败/中断, 残留文件会导致 runInstaller 报
    #     INS-32026 (Software Location 非空). 清理后再重装, 无需手动回滚.
    if [ -d "${OMF_CONFIG[ORACLE_HOME]}" ] && [ ! -x "${OMF_CONFIG[ORACLE_HOME]}/bin/sqlplus" ]; then
        # 安全护栏: 仅当 ORACLE_HOME 是 ORACLE_BASE 的子目录时才清理, 避免误删
        case "${OMF_CONFIG[ORACLE_HOME]}" in
            "${OMF_CONFIG[ORACLE_BASE]}"/*)
                log_warn "检测到 ORACLE_HOME 非空的失败/残留安装, 清理后重新安装..."
                rm -rf "${OMF_CONFIG[ORACLE_HOME]}"
                # 清理 OUI 可能遗留的 inventory 锁, 避免重跑时 'Central Inventory is locked'
                rm -rf "${OMF_CONFIG[ORACLE_BASE]}/oraInventory/locks" 2>/dev/null || true
                # 重新清理 inventory.xml 中残留的 HOME 记录 (prepare_inventory 已在步骤2处理过)
                prepare_inventory
                ;;
            *)
                log_error "ORACLE_HOME 不在 ORACLE_BASE 下, 拒绝自动清理以防误删: ${OMF_CONFIG[ORACLE_HOME]}"
                ;;
        esac
    fi

    # 4. 解压安装包
    log_step "[3/5] 解压安装包到 ${OMF_CONFIG[ORACLE_HOME]}"
    mkdir -p "${OMF_CONFIG[ORACLE_HOME]}"
    chown oracle:oinstall "${OMF_CONFIG[ORACLE_HOME]}"
    su - oracle -c "unzip -o $zip_file -d ${OMF_CONFIG[ORACLE_HOME]}" 2>&1 | tail -5

    # 5. 生成响应文件
    log_step "[4/5] 生成静默安装响应文件"
    generate_response "$install_mode"

    # 6. 执行安装
    log_step "[5/5] 执行 Oracle 软件安装（可能需要 15-30 分钟）"
    run_installer

    # 7. 执行 root 脚本
    execute_root_scripts

    # 8. 配置监听器
    install_listener

    log_info "Oracle 软件安装完成！"
}

#===============================================================================
# 运行时依赖
#===============================================================================
install_runtime_deps() {
    # 必须的依赖
    if ! ldconfig -p | grep -q libnsl; then
        log_warn "libnsl 缺失，正在安装..."
        yum install -y libnsl libnsl2 2>/dev/null || \
        dnf install -y libnsl libnsl2 2>/dev/null || true
    fi

    # 非致命依赖
    for lib in libtirpc libxcrypt; do
        if ! ldconfig -p | grep -q "$lib"; then
            yum install -y "$lib" "${lib}-devel" 2>/dev/null || \
            dnf install -y "$lib" "${lib}-devel" 2>/dev/null || true
        fi
    done

    log_info "运行时依赖检查完成"
}

#===============================================================================
# Inventory 准备
#===============================================================================
prepare_inventory() {
    local inv_file="${OMF_CONFIG[ORACLE_BASE]}/oraInventory/ContentsXML/inventory.xml"
    local ora_home="${OMF_CONFIG[ORACLE_HOME]}"

    if [ -f "$inv_file" ]; then
        if grep -q "$ora_home" "$inv_file"; then
            log_warn "检测到残留 ORACLE_HOME 记录，正在清理..."
            sed -i "/$(echo "$ora_home" | sed 's/\//\\\//g')/,/<\/HOME>/d" "$inv_file"
        fi
    fi
}

#===============================================================================
# 响应文件
#===============================================================================
generate_response() {
    local mode="$1"
    local resp_file="${OMF_CONFIG[ORACLE_BASE]}/oracle_install.rsp"
    # 写前清理: 避免上一次失败残留的 oracle 属主文件导致 root 重定向覆盖被拒 (Permission denied)
    rm -f "$resp_file" 2>/dev/null || true

    # 响应文件版本需与安装器匹配 (否则 INS-10105 报响应文件无效)
    local rsp_ver
    case "${OMF_CONFIG[ORACLE_VERSION]:-19}" in
        18)      rsp_ver="18.0.0" ;;
        19)      rsp_ver="19.3.0" ;;
        21)      rsp_ver="21.0.0" ;;
        23|23ai) rsp_ver="23.0.0" ;;
        *)        rsp_ver="19.3.0" ;;
    esac

    cat > "$resp_file" << EOF
oracle.install.responseFileVersion=$rsp_ver
oracle.install.option=INSTALL_DB_SWONLY
UNIX_GROUP_NAME=oinstall
INVENTORY_LOCATION=${OMF_CONFIG[ORACLE_BASE]}/oraInventory
ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
ORACLE_BASE=${OMF_CONFIG[ORACLE_BASE]}
oracle.install.db.InstallEdition=${mode}
oracle.install.db.OSDBA_GROUP=dba
oracle.install.db.OSOPER_GROUP=oper
oracle.install.db.OSBACKUPDBA_GROUP=backupdba
oracle.install.db.OSDGDBA_GROUP=dgdba
oracle.install.db.OSKMDBA_GROUP=kmdba
oracle.install.db.OSRACDBA_GROUP=racdba
oracle.install.db.rootconfig.executeRootScript=false
SECURITY_UPDATES_VIA_MYORACLESUPPORT=false
DECLINE_SECURITY_UPDATES=true
EOF

    chown oracle:oinstall "$resp_file" 2>/dev/null || true
    chmod 644 "$resp_file" 2>/dev/null || true
    log_info "响应文件已生成: $resp_file"
}

#===============================================================================
# 执行安装
#===============================================================================
run_installer() {
    # 关键: 关闭 set -e 和 pipefail
    set +e
    set +o pipefail

    # 重定向 TMPDIR 到大盘 (避免默认 /tmp 空间不足导致安装器解压/链接失败)
    local omf_tmp="${OMF_CONFIG[ORACLE_BASE]}/tmp"
    mkdir -p "$omf_tmp"
    chown oracle:oinstall "$omf_tmp" 2>/dev/null || true

    # OL8/9 中 libnsl 由 libnsl/libnsl2 包提供, 路径可能不同 (不再是 /usr/lib64/libnsl.so.1)。
    # 仅当 libnsl.so.1 实际存在时才设置 LD_PRELOAD, 否则跳过, 避免写死路径导致安装器加载失败。
    local libn=""
    libn=$(ldconfig -p 2>/dev/null | awk '/libnsl\.so\.1/{print $NF; exit}')
    [ -n "$libn" ] && libn="export LD_PRELOAD=${libn}"

    su - oracle -c "
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export ORACLE_BASE=${OMF_CONFIG[ORACLE_BASE]}
export TMPDIR=${omf_tmp}
export CV_ASSUME_DISTID=$(oracle_cvu_distid)
${libn}

cd ${OMF_CONFIG[ORACLE_HOME]}
./runInstaller -silent -ignorePrereqFailure -responseFile ${OMF_CONFIG[ORACLE_BASE]}/oracle_install.rsp 2>&1
" | tee -a "$OMF_RUN_LOG"
    local ret=${PIPESTATUS[0]}

    set -e
    set -o pipefail

    if [ "$ret" -eq 0 ] && grep -qi "Successfully Setup Software" "$OMF_RUN_LOG"; then
        log_info "Oracle 软件安装成功"
    else
        log_error "Oracle 软件安装失败 (exit=$ret), 请检查日志: $OMF_RUN_LOG"
    fi
}

#===============================================================================
# 执行 root 脚本
#===============================================================================
execute_root_scripts() {
    log_info "执行 root 配置脚本..."

    local ora_inv="${OMF_CONFIG[ORACLE_BASE]}/oraInventory"
    [ -f "${ora_inv}/orainstRoot.sh" ] && "${ora_inv}/orainstRoot.sh"

    [ -f "${OMF_CONFIG[ORACLE_HOME]}/root.sh" ] && "${OMF_CONFIG[ORACLE_HOME]}/root.sh"

    log_info "root 脚本执行完成"
}

#===============================================================================
# 配置监听器
#===============================================================================
install_listener() {
    log_info "配置 Oracle 监听器..."

    set +e
    set +o pipefail

    su - oracle -c "
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
netca -silent -responseFile \$ORACLE_HOME/assistants/netca/netca.rsp 2>&1
" | tee -a "$OMF_RUN_LOG"

    set -e
    set -o pipefail

    log_info "监听器配置完成"
}

#===============================================================================
# 安装检查
#===============================================================================
install_check() {
    log_step "Oracle 软件安装状态检查"

    echo ""
    if [ -x "${OMF_CONFIG[ORACLE_HOME]}/bin/sqlplus" ]; then
        echo "✓ sqlplus 可用"
    else
        echo "✗ sqlplus 不可用"
    fi

    if su - oracle -c "${OMF_CONFIG[ORACLE_HOME]}/bin/lsnrctl status" 2>/dev/null | grep -q "Uptime"; then
        echo "✓ 监听器运行中"
    else
        echo "✗ 监听器未运行"
    fi

    if [ -f /etc/oratab ]; then
        echo "✓ /etc/oratab 存在"
        grep -v "^#" /etc/oratab | grep -v "^$"
    else
        echo "✗ /etc/oratab 不存在"
    fi
}
