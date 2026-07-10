#!/bin/bash
#===============================================================================
# OMF - 环境准备命令 v2
# 修复: env_profile 使用配置变量(不再写死 ARTERY); 依赖包按 OS 自适应
#===============================================================================

cmd_env() {
    local subcmd="${1:-prepare}"
    shift || true
    case "$subcmd" in
        prepare) env_prepare "$@";;
        check)   env_check "$@";;
        user)    env_user "$@";;
        kernel)  env_kernel "$@";;
        packages) env_packages "$@";;
        profile) env_profile "$@";;
        *) echo "用法: omf env {prepare|check|user|kernel|packages|profile}"; exit 1;;
    esac
}

env_prepare() {
    require_root
    log_step "========== Oracle 19c 环境准备 =========="
    local steps=(env_user env_kernel env_packages env_dirs env_profile env_firewall)
    local i=1
    for s in "${steps[@]}"; do
        log_step "[$i/${#steps[@]}] $s"
        $s
        i=$((i+1))
    done
    log_info "环境准备完成！建议执行: omf check preflight"
}

env_user() {
    local uid="${1:-54321}"
    for grp in oinstall dba oper backupdba dgdba kmdba racdba; do
        if ! getent group "$grp" &>/dev/null; then
            groupadd -g "$uid" "$grp" 2>/dev/null && log_info "创建组: $grp (GID=$uid)"
            uid=$((uid+1))
        fi
    done
    if ! id oracle &>/dev/null; then
        useradd -u 54321 -g oinstall -G dba,oper,backupdba,dgdba,kmdba,racdba \
            -d /home/oracle -m -s /bin/bash oracle
        echo "${ORACLE_PASSWORD}" | passwd --stdin oracle 2>/dev/null || \
            echo "oracle:${ORACLE_PASSWORD}" | chpasswd
        log_info "创建 oracle 用户 (UID=54321)"
    else
        log_info "oracle 用户已存在"
    fi

    # 确保 oracle 家目录归属正确 (若目录已被 root 预先 mkdir 创建, 否则 oracle 写不进 .bash_profile)
    local ohome; ohome=$(getent passwd oracle 2>/dev/null | cut -d: -f6)
    if [ -n "$ohome" ] && [ -d "$ohome" ]; then
        chown -R oracle:oinstall "$ohome" 2>/dev/null || true
    fi
}

env_kernel() {
    local sysctl_file="/etc/sysctl.d/99-oracle.conf"
    local total_mem; total_mem=$(get_total_memory_mb)
    local shmmax=$((total_mem * 1024 * 1024 / 2))
    local shmall=$((shmmax / 4096))

    # HugePages 估算 (按 SGA 估算, 页大小 2MB):
    #   oracle 内存 ≈ 物理内存 80%, SGA ≈ 其中 75%
    local oracle_mb=$((total_mem * 80 / 100))
    [ "$oracle_mb" -lt 2048 ] && oracle_mb=2048
    local sga_mb=$((oracle_mb * 75 / 100))
    local hp=$(( (sga_mb + 2048 - 1) / 2 + 1 ))

    cat > "$sysctl_file" << EOF
# Oracle 19c 内核参数 (由 OMF 生成)
fs.file-max = 6815744
fs.aio-max-nr = 1048576
kernel.shmall = ${shmall}
kernel.shmmax = ${shmmax}
kernel.shmmni = 4096
kernel.sem = 250 32000 100 128
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_default = 262144
net.core.wmem_max = 1048576
net.ipv4.ip_local_port_range = 9000 65500
vm.swappiness = 10
vm.dirty_background_ratio = 3
vm.dirty_ratio = 15
vm.min_free_kbytes = 524288
# HugePages (页大小 2MB, 覆盖 SGA ${sga_mb}MB, 需在数据库启动前生效)
vm.nr_hugepages = ${hp}
EOF
    sysctl -p "$sysctl_file" &>/dev/null || sysctl -p "$sysctl_file"
    log_info "内核参数已配置 (SHMMAX=${shmmax})"

    cat > /etc/security/limits.d/99-oracle.conf << 'EOF'
oracle   soft   nofile    65536
oracle   hard   nofile    65536
oracle   soft   nproc     65536
oracle   hard   nproc     65536
oracle   soft   stack     65536
oracle   hard   stack     65536
oracle   soft   memlock   unlimited
oracle   hard   memlock   unlimited
EOF
    log_info "用户资源限制已配置"

    if [ -d /sys/kernel/mm/transparent_hugepage ]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
        echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
        log_info "已禁用透明大页 (THP)"
    fi
}

# 依赖包: 按发行版自适应 (支持 RHEL 系 / Debian 系)
env_packages() {
    local os_info; os_info=$(detect_os)
    local distro="${os_info%% *}"
    local ver="${os_info##* }"
    log_info "检测到 OS: $os_info"

    local pm=""
    local -a pkgs=()

    case "$distro" in
        # ---------- Debian / Ubuntu 系 (apt) ----------
        ubuntu|debian|linuxmint|kali|pop)
            pm="apt"
            # Ubuntu 24.04 (noble) 起因 time_t 64 位改造, 包名变化:
            #   libaio1    -> libaio1t64
            #   libxcrypt* -> libcrypt* (libcrypt1 / libcrypt-dev)
            case "$ver" in
                24.04*|24*|25*|26*|27*|28*|29*|3*)
                    pkgs=(
                        binutils gcc g++ ksh make sysstat unzip
                        libaio1t64 libaio-dev
                        libstdc++6
                        libelf1 libelf-dev
                        libc6 libc6-dev
                        libnsl2 libtirpc3 libtirpc-dev
                        libcrypt1 libcrypt-dev
                        smartmontools nfs-common
                    )
                    ;;
                *)
                    pkgs=(
                        binutils gcc g++ ksh make sysstat unzip
                        libaio1 libaio-dev
                        libstdc++6
                        libelf1 libelf-dev
                        libc6 libc6-dev
                        libnsl2 libtirpc3 libtirpc-dev
                        libxcrypt1 libxcrypt-dev
                        smartmontools nfs-common
                    )
                    ;;
            esac
            ;;
        # ---------- RHEL / CentOS / OL / Rocky / Alma 系 (dnf/yum) ----------
        ol|rhel|centos|rocky|almalinux|fedora|anolis|openanolis|tencentos)
            pm="rpm"
            pkgs=(
                binutils gcc gcc-c++ ksh make sysstat unzip
                libaio libaio-devel libstdc++ libstdc++-devel
                elfutils-libelf elfutils-libelf-devel
                glibc glibc-devel glibc-headers
                libnsl libnsl2 libtirpc libtirpc-devel libxcrypt libxcrypt-devel
                smartmontools nfs-utils
            )
            # OL8/9 / RHEL8/9 / Fedora 已移除 compat-libstdc++-33 与 compat-libcap1
            case "$ver" in
                8*|9*|fedora*) ;;
                *) pkgs+=(compat-libcap1 compat-libstdc++-33);;
            esac
            ;;
        *)
            log_error "不支持的发行版: $distro ($os_info)。目前支持: Ubuntu/Debian, CentOS/RHEL/Oracle Linux/Rocky/Alma/Fedora"
            return 1
            ;;
    esac

    # ---------- 执行安装 ----------
    case "$pm" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y 2>&1 | tail -3
            # 逐个安装: 单个包缺失/改名不阻断其余 (Ubuntu 各版本包名差异大)
            local failed=""
            for p in "${pkgs[@]}"; do
                if apt-get install -y "$p" >/dev/null 2>&1; then
                    log_debug "已安装: $p"
                else
                    log_warn "包安装失败(若非必需可忽略): $p"
                    failed="$failed $p"
                fi
            done
            [ -n "$failed" ] && log_warn "以下包未安装:$failed"
            ;;
        rpm)
            if command -v dnf &>/dev/null; then
                dnf install -y "${pkgs[@]}" 2>&1 | tail -5
            elif command -v yum &>/dev/null; then
                yum install -y "${pkgs[@]}" 2>&1 | tail -5
            elif command -v microdnf &>/dev/null; then
                microdnf install -y "${pkgs[@]}" 2>&1 | tail -5
            else
                log_error "未找到 dnf/yum/microdnf 包管理器"
                return 1
            fi
            ;;
    esac

    # Debian/Ubuntu: 系统默认仅 libnsl.so.2, Oracle 19c 运行/安装需要 libnsl.so.1
    # 从 libnsl2 提供的 libnsl.so.2 软链一个 libnsl.so.1, 使 install.sh 的 LD_PRELOAD 探测生效
    if [ "$pm" = "apt" ]; then
        local nsl2
        nsl2=$(ldconfig -p 2>/dev/null | awk '/libnsl\.so\.2/{print $NF; exit}')
        if [ -n "$nsl2" ] && [ ! -e "${nsl2%/*}/libnsl.so.1" ]; then
            ln -sf "$nsl2" "${nsl2%/*}/libnsl.so.1"
            ldconfig
            log_info "已创建 libnsl.so.1 软链 (Oracle 19c 需要): ${nsl2%/*}/libnsl.so.1 -> $nsl2"
        fi
    fi

    log_info "依赖包安装完成"
}

env_dirs() {
    mkdir -p "${ORACLE_BASE}" "${ORACLE_HOME}" "${ORACLE_DATA_BASE}" \
             "${ORACLE_DATA}" "${ORACLE_ARCH}" "${ORACLE_FRA}" "${ORACLE_BACKUP}" \
             "${ORACLE_BASE}/admin/${ORACLE_SID}/adump" \
             "${ORACLE_BASE}/admin/${ORACLE_SID}/dpdump" \
             "${ORACLE_BASE}/admin/${ORACLE_SID}/pfile"
    chown -R oracle:oinstall "${ORACLE_BASE}" "${ORACLE_DATA_BASE}" "${ORACLE_BACKUP}" 2>/dev/null || true
    log_info "目录结构创建完成"
}

# 使用配置变量生成 .bash_profile (不再写死 ARTERY)
env_profile() {
    local pf="/home/oracle/.bash_profile"
    cat > "$pf" << PROFILEEOF
# Oracle 19c 环境变量 (由 OMF 生成, 与 conf/omf.conf 保持一致)
export ORACLE_BASE=${ORACLE_BASE}
export ORACLE_HOME=${ORACLE_HOME}
export ORACLE_SID=${ORACLE_SID}
export PATH=\$ORACLE_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:\$LD_LIBRARY_PATH
export NLS_LANG=${NLS_LANG}
export CV_ASSUME_DISTID=OEL7.6

alias dbs='sqlplus / as sysdba'
alias lsnr='lsnrctl status'
PROFILEEOF
    chown oracle:oinstall "$pf"
    log_info "oracle 用户环境变量已配置: $pf"
}

env_firewall() {
    # RHEL 系: firewalld
    if command -v firewall-cmd &>/dev/null && systemctl is-active firewalld &>/dev/null; then
        firewall-cmd --add-port=1521/tcp --permanent 2>/dev/null
        firewall-cmd --add-port=5500/tcp --permanent 2>/dev/null
        firewall-cmd --reload 2>/dev/null
        log_info "防火墙已配置 (1521, 5500, firewalld)"
        return
    fi
    # Debian/Ubuntu 系: ufw
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 1521/tcp 2>/dev/null
        ufw allow 5500/tcp 2>/dev/null
        log_info "防火墙已配置 (1521, 5500, ufw)"
        return
    fi
    log_debug "未检测到启用的防火墙 (firewalld/ufw), 跳过"
}

env_check() {
    log_step "环境检查"
    echo ""; echo "=== 系统信息 ==="
    echo "操作系统: $(. /etc/os-release 2>/dev/null; echo $PRETTY_NAME)"
    echo "内核版本: $(uname -r)"
    echo "内存: $(free -h | awk '/Mem:/{print $2}')"
    echo "CPU: $(nproc) 核"
    echo ""; echo "=== 用户 ==="; id oracle &>/dev/null && echo "✓ oracle 用户" || echo "✗ oracle 用户不存在"
    echo ""; echo "=== 内核参数 ==="
    echo "SHMMAX: $(sysctl -n kernel.shmmax 2>/dev/null)"
    echo "SHMALL: $(sysctl -n kernel.shmall 2>/dev/null)"
    echo "FILE-MAX: $(sysctl -n fs.file-max 2>/dev/null)"
    echo ""; echo "=== 依赖库 (ldconfig) ==="
    for lib in libaio.so.1 libnsl.so.1 libtirpc.so.3 libc.so.6 libstdc++.so.6 libelf.so.1; do
        if ldconfig -p 2>/dev/null | grep -q "$lib"; then
            echo "✓ $lib"
        else
            echo "✗ $lib (缺失)"
        fi
    done
    echo ""; echo "=== 磁盘空间 ==="; df -h / /data /backup 2>/dev/null
    echo ""; echo "=== 透明大页 ==="
    [ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo "THP: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
}
