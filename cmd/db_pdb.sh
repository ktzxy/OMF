#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF - PDB 管理 (从 db.sh 拆分)
# 注意: db_pdb 的 status 分支调用 db_status (定义于 cmd/db.sh), 依赖主文件先加载.
#===============================================================================
#===============================================================================
# PDB 管理
#===============================================================================
db_pdb() {
    local action="${1:-status}"
    local pdb="${2:-${OMF_CONFIG[PDB_NAME]}}"

    case "$action" in
        open)
            oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -s / as sysdba <<'SQL'
ALTER PLUGGABLE DATABASE ${pdb} OPEN;
EXIT;
SQL
"
            log_info "PDB $pdb 已打开"
            ;;
        close)
            # CLOSE IMMEDIATE 会回滚未提交事务并断开该 PDB 上所有会话, 业务立即中断 (可逆: pdb open 恢复)
            log_warn "此操作将关闭 PDB ${pdb} (CLOSE IMMEDIATE), 该 PDB 上的业务会话将被中断"
            confirm "确认关闭 PDB ${pdb}?"
            oracle_su "
export ORACLE_SID=${OMF_CONFIG[ORACLE_SID]}
export ORACLE_HOME=${OMF_CONFIG[ORACLE_HOME]}
export PATH=\$ORACLE_HOME/bin:\$PATH
sqlplus -s / as sysdba <<'SQL'
ALTER PLUGGABLE DATABASE ${pdb} CLOSE IMMEDIATE;
EXIT;
SQL
"
            log_info "PDB $pdb 已关闭"
            ;;
        status|*)
            db_status
            ;;
    esac
}

