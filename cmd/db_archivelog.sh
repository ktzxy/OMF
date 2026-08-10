#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF - 归档模式管理 (从 db.sh 拆分)
#===============================================================================
db_archivelog() {
    local action="${1:-status}"
    local sid="${OMF_CONFIG[ORACLE_SID]}"
    local home="${OMF_CONFIG[ORACLE_HOME]}"

    case "$action" in
        status)
            require_db_user
            log_step "查询归档模式"
            oracle_su "
export ORACLE_SID=${sid}
export ORACLE_HOME=${home}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -S / as sysdba <<'SQL'
SET PAGESIZE 0 FEEDBACK OFF
SELECT 'log_mode=' || log_mode FROM v\$database;
ARCHIVE LOG LIST;
EXIT;
SQL
"
            ;;
        enable)
            require_db_user
            log_step "开启归档模式 (ARCHIVELOG)"
            log_warn "此操作将重启数据库 (SHUTDOWN IMMEDIATE -> MOUNT -> OPEN), 期间数据库短暂不可用"
            confirm "确认开启归档模式?"

            local arch_dir="${OMF_CONFIG[ORACLE_ARCH]}"
            # 确保归档目录存在 (以 oracle 用户创建, 保证属主正确)
            oracle_su "mkdir -p '${arch_dir}'" 2>/dev/null || true

            set +e
            oracle_su "
export ORACLE_SID=${sid}
export ORACLE_HOME=${home}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -S / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SYSTEM SET log_archive_dest_1='LOCATION=${arch_dir}' SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ARCHIVE LOG LIST;
EXIT;
SQL
"
            local rc=$?
            set -e
            if [ "$rc" -eq 0 ]; then
                log_info "归档模式已开启, 归档目录: ${arch_dir}"
                log_info "现在可执行 RMAN 备份: omf backup physical"
            else
                log_error "开启归档模式失败 (sqlplus rc=${rc}), 请检查 alert 日志: omf log view alert"
            fi
            ;;
        disable)
            require_db_user
            log_step "关闭归档模式 (NOARCHIVELOG)"
            log_warn "关闭归档后将无法进行 RMAN 在线备份与时间点恢复; 此操作将重启数据库"
            confirm_danger "确认关闭归档模式? (关闭后将无法 RMAN 在线备份与时间点恢复)" || return 1

            set +e
            oracle_su "
export ORACLE_SID=${sid}
export ORACLE_HOME=${home}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -S / as sysdba <<'SQL'
WHENEVER SQLERROR EXIT SQL.SQLCODE
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE NOARCHIVELOG;
ALTER DATABASE OPEN;
ARCHIVE LOG LIST;
EXIT;
SQL
"
            local rc=$?
            set -e
            [ "$rc" -eq 0 ] && log_info "归档模式已关闭" || \
                log_error "关闭归档模式失败 (sqlplus rc=${rc}), 请检查 alert 日志"
            ;;
        *)
            echo "用法: omf db archivelog {status|enable|disable}"
            exit 1
            ;;
    esac
}

