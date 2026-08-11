#!/bin/bash
# OMF - DBA 知识库 SQL 查询收敛层 (lib/sql.sh)
# 将散落在各 cmd 模块的常用 Oracle 查询收敛为独立函数, 统一经 as_oracle 执行并净化输出。
# 收益:
#   1) 消除重复拼接 (v$datafile / v$dataguard_stats / v$rman_backup_job_details 等)
#   2) 单点维护: 改一处查询, 全框架生效
#   3) 每函数带注释说明视图语义, 供 DBA 审计/复核
# 约定:
#   - 所有函数返回"净化后的单值" (去空白/去标题), 失败返回空串
#   - 仅依赖 lib/common.sh 的 as_oracle
# 注意: 若查询失败(库不可连), 统一返回空串, 由调用方自行处理回退。
#===============================================================================

# 数据库数据文件总大小(字节, 不含 TEMP): 用于备份空间估算最坏情况
# 视图: v$datafile 所有永久数据文件
omf_sql_datafile_bytes() {
    as_oracle "echo \"set pagesize 0 feedback off heading off SELECT SUM(bytes) FROM v\\\$datafile;\" | sqlplus -s / as sysdba" 2>/dev/null \
        | tr -d ' ' | grep -E '^[0-9]+$' | head -1
}

# 最近一次成功全量物理备份时间 (RPO 信号): 无则返回空
# 视图: v$rman_backup_job_details WHERE input_type='DB FULL' AND status='COMPLETED'
omf_sql_last_full_backup() {
    as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT TO_CHAR(MAX(start_time),'YYYY-MM-DD HH24:MI:SS') FROM v\\\$rman_backup_job_details
WHERE input_type='DB FULL' AND status='COMPLETED';\" | sqlplus -s / as sysdba" 2>/dev/null \
        | tr -d ' ' | grep -v '^$' | head -1
}

# FRA(快速恢复区)使用率(%): 满仓会阻塞归档/备份; 未配置 FRA 时返回空
# 视图: v$recovery_area_usage 的 PERCENT_SPACE_USED 求和
omf_sql_fra_usage_pct() {
    as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT ROUND(SUM(PERCENT_SPACE_USED),1) FROM v\\\$recovery_area_usage;\" | sqlplus -s / as sysdba" 2>/dev/null \
        | tr -d ' ' | grep -E '^[0-9.]+$' | head -1
}

# DG 应用延迟(秒): 仅备库有值; 返回空表示未启用/无值
# 视图: v$dataguard_stats name='apply lag' (格式 +DD HH:MM:SS 已解析为秒)
omf_sql_dg_apply_lag_sec() {
    local raw
    # 注意: 不能 tr -d ' ', 因为 +DD HH:MM:SS 中"天数与时间"靠空格分隔; 删掉空格会破坏解析
    raw=$(as_oracle "echo \"set pagesize 0 feedback off heading off
SELECT NVL(MAX(value),'-') FROM v\\\$dataguard_stats WHERE name='apply lag';\" | sqlplus -s / as sysdba" 2>/dev/null \
        | head -1)
    [ -z "$raw" ] || [ "$raw" = "-" ] && return 0
    local dd hhmmss d h m s mmss
    dd="${raw%% *}"; dd="${dd#+}"
    hhmmss="${raw#* }"
    h="${hhmmss%%:*}"; mmss="${hhmmss#*:}"; m="${mmss%%:*}"; s="${mmss#*:}"
    # 10# 强制十进制, 避免前导零(如 08/09)被当八进制报错
    echo $(( 10#${dd:-0}*86400 + 10#${h:-0}*3600 + 10#${m:-0}*60 + 10#${s:-0} ))
}

# 归档模式 (ARCHIVELOG / NOARCHIVELOG): 无法连接返回空
# 视图: v$database LOG_MODE
# 注: 数据库角色查询见 common.sh 的 omf_db_role (权威实现, 返回 PRIMARY|STANDBY), 不在此重复
omf_sql_log_mode() {
    as_oracle "echo \"set pagesize 0 feedback off heading off SELECT log_mode FROM v\\\$database;\" | sqlplus -s / as sysdba" 2>/dev/null \
        | tr -d ' ' | grep -v '^$' | head -1
}
