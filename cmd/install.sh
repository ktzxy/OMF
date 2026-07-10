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
# 安装 Oracle 软件（集成自 02_install_oracle_software.sh）
#===============================================================================
install_software() {
    require_root

    local zip_file="${1:-/home/oracle/LINUX.X64_193000_db_home.zip}"
    local install_mode="${2:-EE}"  # EE 或 SE

    log_step "========== Oracle 19c 软件安装 =========="

    # 0. 全新环境自检: 若 oracle 用户或核心依赖缺失, 自动执行环境准备 (无需手动先跑 env prepare)
    if ! id oracle &>/dev/null || ! ldconfig -p 2>/dev/null | grep -q "libaio.so.1"; then
        log_warn "检测到全新环境, 自动执行 omf env prepare ..."
        source "${OMF_HOME}/cmd/env.sh"
        env_prepare
    fi

    # 1. 检查安装包
    if [ ! -f "$zip_file" ]; then
        log_error "安装包不存在: $zip_file (请将 LINUX.X64_193000_db_home.zip 放到该路径, 或显式传入: omf install software <zip路径>)"
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

    # 3.5 幂等检查: 若 ORACLE_HOME 已安装软件, 跳过解压与安装 (避免重复执行覆盖/报错)
    if [ -x "${OMF_CONFIG[ORACLE_HOME]}/bin/sqlplus" ]; then
        log_warn "检测到 ORACLE_HOME 已安装 Oracle 软件, 跳过解压与安装"
        install_listener
        log_info "Oracle 软件安装完成 (已存在, 跳过)!"
        return 0
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
    local resp_file="/tmp/oracle_install.rsp"
    local groups="oinstall,dba,oper,backupdba,dgdba,kmdba,racdba"

    cat > "$resp_file" << EOF
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
EOF

    chown oracle:oinstall "$resp_file"
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
export CV_ASSUME_DISTID=OEL7.6
${libn}

cd ${OMF_CONFIG[ORACLE_HOME]}
./runInstaller -silent -ignorePrereqFailure -responseFile /tmp/oracle_install.rsp 2>&1
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
