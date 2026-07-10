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
    local steps=(env_user env_kernel env_packages env_lib64 env_dirs env_profile env_firewall)
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
        log_info "创建 oracle 用户 (UID=54321)"
    else
        log_info "oracle 用户已存在"
    fi

    # 设置/解锁 oracle 密码
    # Ubuntu 不支持 'passwd --stdin', 统一用 chpasswd; 未配置 ORACLE_PASSWORD 时给兜底默认密码
    # 关键: useradd 默认锁定账户(shadow 为 '!'), 必须 passwd -u 解锁,
    #       否则 root 执行 'su - oracle' 会在 account/auth 阶段报 Authentication failure
    local opw="${ORACLE_PASSWORD:-Qiyuan!960#123}"
    if echo "oracle:${opw}" | chpasswd 2>/dev/null; then
        log_info "已设置 oracle 密码"
    else
        log_warn "chpasswd 设置 oracle 密码失败, 尝试 passwd 兜底"
        # 兜底: 用 openssl 生成散列再写入 (避免某些镜像 chpasswd 行为异常)
        local hp; hp=$(openssl passwd -6 "$opw" 2>/dev/null)
        if [ -n "$hp" ]; then
            usermod -p "$hp" oracle 2>/dev/null && log_info "已用散列兜底设置 oracle 密码" || log_warn "oracle 密码兜底设置失败"
        fi
    fi
    # 解锁账户 (即使已设密码, 仍确保非锁定态; -u 对未锁定账户无害)
    if passwd -u oracle >/dev/null 2>&1; then
        log_info "已解锁 oracle 账户 (root 可 su - oracle)"
    fi
    # 校验: 若仍为锁定态(L), 报警提示手动处理
    local ostate; ostate=$(passwd -S oracle 2>/dev/null | awk '{print $2}')
    if [ "$ostate" = "L" ]; then
        log_warn "oracle 账户仍为锁定态(L), 请手动执行: passwd -u oracle"
    else
        log_info "oracle 账户状态: $ostate (非锁定, root 可 su - oracle)"
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

    # HugePages / SGA 估算 (比例可配置, 见 conf)
    local sga_mb; sga_mb=$(omf_sga_mb)
    local hp; hp=$(omf_hugepages_count)

    # 延迟预留: 持久化文件直接写 0 (避免重启又把内存占满), 运行时也清零, 待 omf db create 前再预留
    local hp_line="vm.nr_hugepages = ${hp}"
    if [ "${HUGEPAGES_DEFER:-false}" = "true" ]; then
        hp_line="vm.nr_hugepages = 0"
    fi

    cat > "$sysctl_file" << EOF
# Oracle 内核参数 (由 OMF 生成)
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
${hp_line}
EOF
    sysctl -p "$sysctl_file" &>/dev/null || sysctl -p "$sysctl_file"

    if [ "${HUGEPAGES_DEFER:-false}" = "true" ]; then
        # 立即把运行时大页清零(释放内存给安装器), 待 omf db create 前再预留
        sysctl -w vm.nr_hugepages=0 >/dev/null 2>&1 || true
        local cur_hp; cur_hp=$(awk '/HugePages_Total/{print $2}' /proc/meminfo 2>/dev/null)
        log_info "内核参数已配置 (SHMMAX=${shmmax}); 大页预留推迟到 omf db create 前 (当前 HugePages_Total=${cur_hp:-0}, 内存已释放给安装器)"
    else
        log_info "内核参数已配置 (SHMMAX=${shmmax}); 大页已预留 ${hp} 个 (约 $((hp*2))MB, 覆盖 SGA ${sga_mb}MB)"
    fi

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
            # 各版本差异主要在 libcrypt 包名:
            #   Ubuntu 22.04+/Debian 11+ : libcrypt1  (提供 libcrypt.so.1)
            #   Ubuntu 18.04/20.04       : libxcrypt1 (旧包名)
            #   Ubuntu 24.04+ 因 time_t 64 位改造: libaio1 -> libaio1t64
            local crypt_pkg="libxcrypt1"
            case "$ver" in
                22.04*|22*|23.04*|23.10*|23*|24.04*|24*|25*|26*|27*|28*|29*|3*) crypt_pkg="libcrypt1";;
            esac
            case "$ver" in
                24.04*|24*|25*|26*|27*|28*|29*|3*)
                    pkgs=(
                        binutils gcc g++ ksh make sysstat unzip
                        libaio1t64 libaio-dev
                        libstdc++6
                        libelf1 libelf-dev
                        libc6 libc6-dev
                        libnsl2 libtirpc3 libtirpc-dev
                        "$crypt_pkg"
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
                        "$crypt_pkg"
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

        # 关键运行库校验: Oracle 二进制依赖 libcrypt.so.1 (Ubuntu22.04 由 libxcrypt1 提供, 24.04 由 libcrypt1 提供)
        # 缺失会导致 runInstaller/sqlplus 报 'error while loading shared libraries: libcrypt.so.1'
        if ! omf_lib_present "libcrypt.so.1"; then
            log_warn "未检测到 libcrypt.so.1, Oracle 运行/安装将失败, 尝试补装..."
            local crypt_pkg="libxcrypt1"
            case "$distro" in
                ubuntu) case "$ver" in
                    22.04*|22*|23.04*|23.10*|23*|24.04*|24*|25*|26*|27*|28*|29*|3*) crypt_pkg="libcrypt1";;
                esac ;;
            esac
            apt-get install -y "$crypt_pkg" 2>&1 | tail -5
            ldconfig
            if omf_lib_present "libcrypt.so.1"; then
                log_info "libcrypt.so.1 已补装 (包: $crypt_pkg)"
            else
                log_error "libcrypt.so.1 仍缺失, 请手动安装: $crypt_pkg (Ubuntu22.04+=libcrypt1 / 20.04=libxcrypt1)"
            fi
        fi
    fi

    log_info "依赖包安装完成"
}

# Debian/Ubuntu 系: Oracle 的链接脚本(env_rdbms.mk 等)写死 RHEL 路径 /usr/lib64/,
# 但 Ubuntu 的静态库/链接库实际在 /usr/lib/x86_64-linux-gnu/。缺 /usr/lib64 会导致
# 安装链接阶段报 'cannot find /usr/lib64/libc_nonshared.a' 而 FATAL 失败。
# 修复: 建立 /usr/lib64 -> /usr/lib/x86_64-linux-gnu 的软链, 覆盖 Oracle 链接所需全部库。
env_lib64() {
    case "$(detect_os)" in
        ubuntu*|debian*|linuxmint*|kali*|pop*) ;;
        *) return 0;;   # 非 Debian 系(RHEL 等)无需处理
    esac

    local src="/usr/lib/x86_64-linux-gnu"
    if [ ! -d "$src" ]; then
        log_warn "未找到 $src, 跳过 /usr/lib64 软链"
        return 0
    fi

    # 若 /usr/lib64 已是正确软链, 跳过
    if [ -L /usr/lib64 ] && [ "$(readlink -f /usr/lib64)" = "$(readlink -f "$src")" ]; then
        log_debug "/usr/lib64 软链已存在, 跳过"
        return 0
    fi

    # 若 /usr/lib64 是真实目录(非软链), 不破坏, 仅补齐 Oracle 链接常用的 .a 软链
    if [ -d /usr/lib64 ] && [ ! -L /usr/lib64 ]; then
        log_warn "/usr/lib64 已是真实目录, 仅补齐 Oracle 链接常用静态库软链"
        for f in libc_nonshared.a libpthread_nonshared.a libc.a libpthread.a \
                 libnsl.a libtirpc.a libstdc++.a libgcc_s.a; do
            [ -e "$src/$f" ] && ln -sf "$src/$f" "/usr/lib64/$f" 2>/dev/null || true
        done
        ldconfig 2>/dev/null || true
        return 0
    fi

    # 移除失效软链, 重建为指向 Ubuntu 库目录
    rm -f /usr/lib64 2>/dev/null || true
    ln -s "$src" /usr/lib64
    ldconfig 2>/dev/null || true
    log_info "已建立 /usr/lib64 -> $src 软链 (修复 Oracle 链接期 cannot find /usr/lib64/...)"
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
        if omf_lib_present "$lib"; then
            echo "✓ $lib"
        else
            echo "✗ $lib (缺失)"
        fi
    done
    echo ""; echo "=== 磁盘空间 ==="; df -h / /data /backup 2>/dev/null
    echo ""; echo "=== 透明大页 ==="
    [ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo "THP: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
}
