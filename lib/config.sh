#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF 配置管理 v2
# 加载优先级: 命令行参数 > 环境变量 > conf/omf.conf > 默认值
# 新增: FRA_SIZE_MB 修正 / OS 探测 / set_config 落盘 / 更严格校验
#===============================================================================

declare -A OMF_CONFIG

load_config() {
    # ---------- 默认值 ----------
    OMF_CONFIG[ORACLE_USER]="oracle"
    OMF_CONFIG[ORACLE_GROUP]="oinstall"
    OMF_CONFIG[ORACLE_BASE]="/u01/app/oracle"
    # Oracle 主版本 (仅支持 CDB 系列: 18 / 19 / 21 / 23), 用于推导默认安装包名/Home/CVU 假名
    OMF_CONFIG[ORACLE_VERSION]="${ORACLE_VERSION:-19}"
    # ORACLE_HOME 留空则按 ORACLE_VERSION 自动推导 (如 19 -> /u01/app/oracle/product/19.3.0/dbhome_1)
    # 如需自定义安装路径, 在 conf/omf.conf 中显式指定 ORACLE_HOME 即可覆盖
    OMF_CONFIG[ORACLE_HOME]=""
    # 安装包路径 (留空则按 ORACLE_VERSION 推导默认名, 见 install.sh 的 oracle_default_zip)
    OMF_CONFIG[ORACLE_ZIP]="${ORACLE_ZIP:-}"
    # 内存规划比例 (用于 SGA/HugePages 估算, 可在 conf 中调整)
    #   ORACLE_MEM_RATIO: Oracle 内存占物理内存 %
    #   SGA_RATIO:        SGA 占 Oracle 内存 %
    #   HUGEPAGES_RESERVE_FREE_MB: 预留大页后至少给 OS 留的空闲(MB), 防止小内存机器被吃满
    #   HUGEPAGES_DEFER: true 时大页推迟到 omf db create 前再预留(避免安装器内存不足)
    OMF_CONFIG[ORACLE_MEM_RATIO]="${ORACLE_MEM_RATIO:-80}"
    OMF_CONFIG[SGA_RATIO]="${SGA_RATIO:-75}"
    OMF_CONFIG[HUGEPAGES_RESERVE_FREE_MB]="${HUGEPAGES_RESERVE_FREE_MB:-2048}"
    OMF_CONFIG[HUGEPAGES_DEFER]="${HUGEPAGES_DEFER:-false}"
    OMF_CONFIG[ORACLE_SID]="ARTERY"
    OMF_CONFIG[PDB_NAME]="ARTERYPDB"
    OMF_CONFIG[ORACLE_DATA_BASE]="/data/oracle"
    OMF_CONFIG[ORACLE_DATA]="/data/oracle/oradata"
    OMF_CONFIG[ORACLE_ARCH]="/data/oracle/archivelog"
    OMF_CONFIG[ORACLE_FRA]="/data/oracle/fast_recovery"
    OMF_CONFIG[ORACLE_BACKUP]="/backup/oracle"
    OMF_CONFIG[ORACLE_DUMP_DIR]="${ORACLE_DUMP_DIR:-/data/oracle/oracle_dumps}"
    OMF_CONFIG[LISTENER_PORT]="${LISTENER_PORT:-1521}"
    OMF_CONFIG[CHARSET]="AL32UTF8"
    OMF_CONFIG[NLS_LANG]="AMERICAN_AMERICA.AL32UTF8"

    OMF_CONFIG[ORACLE_PASSWORD]="${ORACLE_PASSWORD:-Qiyuan!960#123}"
    OMF_CONFIG[SYSTEM_PASSWORD]="${SYSTEM_PASSWORD:-Qiyuan!960#123}"
    OMF_CONFIG[PDB_PASSWORD]="${PDB_PASSWORD:-Qiyuan!960#123}"
    OMF_CONFIG[APP_USER]="${APP_USER:-dherp}"
    OMF_CONFIG[APP_PASSWORD]="${APP_PASSWORD:-dherp_skzy}"
    OMF_CONFIG[APP_TABLESPACE]="${APP_TABLESPACE:-dherp}"
    # 多模式(多库)列表: 空格分隔, 如 "dherp lsdherp miserp"; 留空 = 仅 APP_USER 单模式
    OMF_CONFIG[APP_SCHEMAS]="${APP_SCHEMAS:-}"

    OMF_CONFIG[PROCESSES]="1500"
    OMF_CONFIG[OPEN_CURSORS]="1000"
    OMF_CONFIG[REDO_SIZE_MB]="2048"
    OMF_CONFIG[FRA_SIZE_MB]="${FRA_SIZE_MB:-40960}"        # 修正: 原 FRA_SIZE_MB_MIN 未被读取
    OMF_CONFIG[FRA_SIZE_MB_MIN]="20480"

    OMF_CONFIG[ENABLE_DG]="false"
    OMF_CONFIG[DB_UNIQUE_NAME_PRIMARY]="${OMF_CONFIG[ORACLE_SID]}_PRIMARY"
    OMF_CONFIG[DB_UNIQUE_NAME_STANDBY]="${OMF_CONFIG[ORACLE_SID]}_STANDBY"
    OMF_CONFIG[STANDBY_SID]="${STANDBY_SID:-${OMF_CONFIG[ORACLE_SID]}}"
    OMF_CONFIG[PRIMARY_IP]="${PRIMARY_IP:-192.168.0.108}"
    OMF_CONFIG[STANDBY_IP]="${STANDBY_IP:-192.168.0.110}"

    # 备份策略 (逻辑/物理/两者, 全量/增量 由 BACKUP_MODE 控制)
    OMF_CONFIG[BACKUP_MODE]="${BACKUP_MODE:-both}"   # logical | physical | both
    OMF_CONFIG[BACKUP_RETENTION_DAYS]="30"
    OMF_CONFIG[BACKUP_WARN_DAYS]=""   # 即将过期高亮阈值(天); 留空=保留期的1/5(钳制2~7天)
    OMF_CONFIG[BACKUP_COMPRESSION]="ALL"
    OMF_CONFIG[BACKUP_PARALLEL]="4"

    OMF_CONFIG[LOG_RETENTION_DAYS]="7"
    OMF_CONFIG[AUDIT_RETENTION_DAYS]="30"
    OMF_CONFIG[TRACE_RETENTION_DAYS]="7"

    # 框架自更新 (omf self-update 使用的 tar.gz 地址, 留空则报错提示)
    OMF_CONFIG[OMF_UPDATE_URL]="${OMF_UPDATE_URL:-}"

    OMF_CONFIG[SQL_INIT_DIR]="${OMF_HOME}/sql/init"
    OMF_CONFIG[SQL_UPGRADE_DIR]="${OMF_HOME}/sql/upgrade"
    OMF_CONFIG[SQL_PATCH_DIR]="${OMF_HOME}/sql/patch"
    OMF_CONFIG[SQL_CUSTOM_DIR]="${OMF_HOME}/sql/custom"

    # ---------- 加载配置文件 ----------
    # 配置文件是用户可控文本, 语法错误/未定义变量在 set -e 下会静默中断整个 OMF 且难定位。
    # 故用 set +e 包裹 source 并捕获返回码: 失败时给出明确错误与文件路径, 而非静默中止。
    # 注意: 必须在【当前 shell】source (不能用子 shell, 否则配置里的变量赋值丢失)。
    local config_file="${OMF_CONFIG_FILE:-${OMF_HOME}/conf/omf.conf}"
    if [ -f "$config_file" ]; then
        log_debug "加载配置文件: $config_file"
        local _src_rc=0
        set +e
        source "$config_file"
        _src_rc=$?
        set -e
        if [ "$_src_rc" -ne 0 ]; then
            log_error "配置文件加载失败(语法或执行错误): $config_file"
        fi
        unset _src_rc
    fi

    # ---------- 加载敏感口令文件 conf/.omf.secret (独立于 omf.conf, 权限 600) ----------
    # 由 `omf config password` 生成, 存放 ORACLE_PASSWORD/SYSTEM_PASSWORD/PDB_PASSWORD/APP_PASSWORD
    # 及每个模式的 <大写名>_PASSWORD。优先级: 环境变量 > .omf.secret > omf.conf > 出厂默认。
    # 与 omf.conf 分离使真实口令可独立收紧权限(600), 且不随 omf.conf 的出厂弱口令兜底被覆盖。
    local secret_file="${OMF_CONFIG_FILE:+$(dirname "$OMF_CONFIG_FILE")}/.omf.secret"
    [ -z "$OMF_CONFIG_FILE" ] && secret_file="${OMF_HOME}/conf/.omf.secret"
    if [ -f "$secret_file" ]; then
        log_debug "加载敏感口令文件: $secret_file"
        # 仅提取 *_PASSWORD 键, 避免任意内容注入; 权限过松时警告(不阻断)。
        local _spm; _spm="$(stat -c '%a' "$secret_file" 2>/dev/null || echo 644)"
        if [ "${_spm#???}" != "" ] || [ "${_spm:0:1}" != "6" ] && [ "${_spm:0:1}" != "4" ] && [ "${_spm:0:1}" != "0" ]; then
            log_warn ".omf.secret 权限为 ${_spm} (建议 600), 请 chmod 600 收紧"
        fi
        local _k _v _in_env
        while IFS='=' read -r _k _v; do
            case "$_k" in
                *_PASSWORD)
                    # 优先级: 环境变量 > secret。若该键已在环境中(用户显式 export),
                    # 则不覆盖; 否则用 secret 覆盖 omf.conf。
                    if env | grep -q "^${_k}="; then
                        log_debug "环境变量 ${_k} 优先, 忽略 secret 中的同名口令"
                        continue
                    fi
                    _v="${_v%\"}"; _v="${_v#\"}"
                    export "$_k=$_v"
                    ;;
            esac
        done < <(grep -E '^[A-Za-z0-9_]+_PASSWORD=' "$secret_file" 2>/dev/null)
        unset _spm _k _v _in_env
    fi

    # 关键修复: source 后配置项只是【全局变量】, 必须同步回 OMF_CONFIG 数组,
    # 否则下面的导出循环会用数组默认值覆盖掉配置文件中的覆盖值
    # (此前 HUGEPAGES_DEFER 等覆盖项不生效的根因)
    for key in "${!OMF_CONFIG[@]}"; do
        if [ -n "${!key:-}" ]; then
            OMF_CONFIG[$key]="${!key}"
        fi
    done

    # ORACLE_HOME 联动推导: 未显式设置(为空)时, 按 ORACLE_VERSION 生成默认路径
    # 兼容旧配置/自定义路径: conf 中已写 ORACLE_HOME 则保留
    if [ -z "${OMF_CONFIG[ORACLE_HOME]}" ]; then
        OMF_CONFIG[ORACLE_HOME]="/u01/app/oracle/product/${OMF_CONFIG[ORACLE_VERSION]}.3.0/dbhome_1"
        log_debug "ORACLE_HOME 由 ORACLE_VERSION=${OMF_CONFIG[ORACLE_VERSION]} 推导: ${OMF_CONFIG[ORACLE_HOME]}"
    fi

    # ---------- 导出为环境变量 ----------
    for key in "${!OMF_CONFIG[@]}"; do
        export "${key}"="${OMF_CONFIG[$key]}"
    done
    log_debug "配置加载完成"
}

# 探测 OS (用于依赖包选择)
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "${ID:-linux} ${VERSION_ID:-}"
    else
        echo "linux unknown"
    fi
}

show_config() {
    echo ""
    echo "╔═══════════════════════════════════════════════╗"
    echo "║           OMF 当前配置                         ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo ""
    echo "[数据库配置]"
    echo "  ORACLE_VERSION: ${OMF_CONFIG[ORACLE_VERSION]}c (CDB)"
    echo "  ORACLE_SID:     ${OMF_CONFIG[ORACLE_SID]}"
    echo "  PDB_NAME:       ${OMF_CONFIG[PDB_NAME]}"
    echo "  CHARSET:        ${OMF_CONFIG[CHARSET]}"
    echo "  APP_USER:       ${OMF_CONFIG[APP_USER]}  (主模式)"
    echo "  APP_TABLESPACE: ${OMF_CONFIG[APP_TABLESPACE]}"
    echo "  APP_SCHEMAS:   ${OMF_CONFIG[APP_SCHEMAS]:-(仅 ${OMF_CONFIG[APP_USER]})}"
    local _s _u _ts _dd
    for _s in $(omf_schema_list); do
        _u=$(omf_schema_user "$_s"); _ts=$(omf_schema_tablespace "$_s"); _dd=$(omf_schema_datadir "$_s")
        echo "    └ 模式[${_s}] -> 用户=${_u} 表空间=${_ts} 数据目录=${_dd}"
    done
    echo ""
    echo "[路径配置]"
    echo "  ORACLE_BASE:    ${OMF_CONFIG[ORACLE_BASE]}"
    echo "  ORACLE_HOME:    ${OMF_CONFIG[ORACLE_HOME]}"
    echo "  DATA:           ${OMF_CONFIG[ORACLE_DATA]}"
    echo "  ARCHIVE:        ${OMF_CONFIG[ORACLE_ARCH]}"
    echo "  FRA:            ${OMF_CONFIG[ORACLE_FRA]} (${OMF_CONFIG[FRA_SIZE_MB]}MB)"
    echo "  BACKUP:         ${OMF_CONFIG[ORACLE_BACKUP]}"
    echo "  DUMP_DIR:       ${OMF_CONFIG[ORACLE_DUMP_DIR]} (数据泵导入目录)"
    echo ""
    echo "[数据库参数]"
    echo "  PROCESSES:      ${OMF_CONFIG[PROCESSES]}"
    echo "  OPEN_CURSORS:   ${OMF_CONFIG[OPEN_CURSORS]}"
    echo "  REDO_SIZE_MB:   ${OMF_CONFIG[REDO_SIZE_MB]}"
    echo ""
    echo "[备份策略]"
    echo "  BACKUP_MODE:           ${OMF_CONFIG[BACKUP_MODE]}"
    echo "  BACKUP_RETENTION_DAYS: ${OMF_CONFIG[BACKUP_RETENTION_DAYS]} 天"
    echo "  BACKUP_COMPRESSION:    ${OMF_CONFIG[BACKUP_COMPRESSION]}"
    echo "  BACKUP_PARALLEL:       ${OMF_CONFIG[BACKUP_PARALLEL]}"
    echo ""
    echo "[清理策略]"
    echo "  LOG_RETENTION_DAYS:   ${OMF_CONFIG[LOG_RETENTION_DAYS]} 天"
    echo "  AUDIT_RETENTION_DAYS: ${OMF_CONFIG[AUDIT_RETENTION_DAYS]} 天"
    echo "  TRACE_RETENTION_DAYS:  ${OMF_CONFIG[TRACE_RETENTION_DAYS]} 天"
    echo ""
    echo "[Data Guard]"
    echo "  ENABLED:        ${OMF_CONFIG[ENABLE_DG]}"
    echo "  PRIMARY_IP:     ${OMF_CONFIG[PRIMARY_IP]}"
    echo "  STANDBY_IP:     ${OMF_CONFIG[STANDBY_IP]}"
    echo ""
}

# 设置配置项并持久化到配置文件
set_config() {
    local key="$1"; local value="$2"
    [ -z "$key" ] && log_error "用法: omf config set <KEY> <VALUE>"
    [ -z "$value" ] && log_error "用法: omf config set <KEY> <VALUE>"

    # 键名白名单: 仅允许大/小写字母、数字、下划线; 防止注入 OMF_CONFIG["..."] 数组语法
    # (如 key 含 ']' 会闭合数组下标、含 '=' 会破坏赋值) 或注入额外配置行。
    if ! [[ "$key" =~ ^[A-Za-z0-9_]+$ ]]; then
        log_error "非法配置键名: $key (仅允许字母/数字/下划线)"
    fi
    # 拒绝含换行的值, 防止 sed 追加/替换时注入多条配置行
    if [[ "$value" == *$'\n'* ]] || [[ "$value" == *$'\r'* ]]; then
        log_error "配置值不能包含换行符: $key"
    fi

    OMF_CONFIG["$key"]="$value"
    export "${key}"="$value"

    local config_file="${OMF_CONFIG_FILE:-${OMF_HOME}/conf/omf.conf}"
    [ -f "$config_file" ] || log_error "配置文件不存在: $config_file"

    # 已存在则替换, 否则追加
    if grep -q "^${key}=" "$config_file" 2>/dev/null; then
        # 转义 sed 替换串中的特殊字符: & 表示整段匹配, | 为分隔符, \ 为转义符
        local safe_value="${value//\\/\\\\}"
        safe_value="${safe_value//&/\\&}"
        safe_value="${safe_value//|/\\|}"
        sed -i "s|^${key}=.*|${key}=\"${safe_value}\"|" "$config_file"
    else
        echo "${key}=\"${value}\"" >> "$config_file"
    fi
    log_info "配置已更新并持久化: $key = $value"
}

#===============================================================================
# 多模式(多库)支持: APP_SCHEMAS 列表 + 每个模式的派生配置
#   配置示例 (conf/omf.conf):
#     APP_SCHEMAS="dherp lsdherp miserp"     # 空格分隔, 想加第 N 个直接追加
#     LSDHERP_PASSWORD="ls_pwd"                # 每个模式的个别覆盖 (键名 = 大写模式名 + 后缀)
#     LSDHERP_TABLESPACE="ls_ts"              #   缺省: 用户名/表空间=模式名, 密码=全局 APP_PASSWORD
#     MISERP_DATA_DIR="/data/oracle/oradata/ARTERY/miserp"
#   区分逻辑: 列表里的"名字"即模式的逻辑键(也是默认 Oracle 用户名/表空间名);
#             每个模式可经 <大写名>_USER / _TABLESPACE / _PASSWORD / _DATA_DIR 个别覆盖.
#===============================================================================
omf_schema_list() {
    local s="${APP_SCHEMAS:-${OMF_CONFIG[APP_SCHEMAS]:-}}"
    if [ -z "$s" ]; then
        # 单模式: 回退到主模式 APP_USER
        s="${APP_USER:-${OMF_CONFIG[APP_USER]:-dherp}}"
    else
        # 多模式: 自动把主模式 APP_USER 纳入列表, 避免"配了 APP_SCHEMAS 却漏写主模式"
        # 导致主库不被创建 (omf sql init 只遍历列表). 顺序: 主模式在前.
        local au="${APP_USER:-${OMF_CONFIG[APP_USER]:-}}"
        local found=0
        for _x in $s; do [ "$_x" = "$au" ] && found=1; done
        [ "$found" -eq 0 ] && s="$au $s"
    fi
    echo "$s"
}

# 给定逻辑名, 返回覆盖键 lookup (大写), 兼容小写/大写书写的模式名
_omf_schema_key() { echo "$1" | tr '[:lower:]' '[:upper:]'; }

omf_schema_user() {
    local key; key="$(_omf_schema_key "$1")_USER"
    echo "${!key:-$1}"
}
omf_schema_tablespace() {
    local key; key="$(_omf_schema_key "$1")_TABLESPACE"
    echo "${!key:-$1}"
}
omf_schema_password() {
    local key; key="$(_omf_schema_key "$1")_PASSWORD"
    echo "${!key:-${APP_PASSWORD:-${OMF_CONFIG[APP_PASSWORD]:-}}}"
}
omf_schema_datadir() {
    local key; key="$(_omf_schema_key "$1")_DATA_DIR"
    echo "${!key:-${ORACLE_DATA}/${ORACLE_SID}/$1}"
}

# 自动加载
load_config
