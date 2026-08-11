#!/bin/bash
# OMF - 每日备份/健康 HTML 报表 (report)
# 用法: omf report {daily|list|clean}
# 内部自洽, 依赖 lib/common.sh (as_oracle/send_notification) 与 lib/sql.sh (复用查询).
# 作用: 汇总当日备份结果 + 健康指标, 生成一份人类可读的 HTML 报表, 落盘 logs/reports/,
#       可随 webhook 推送, 供运营/交接汇报 (纯 shell 生成, 无 JS 依赖).
#===============================================================================

# 报表目录
report_dir() { echo "${OMF_HOME}/logs/reports"; }

# HTML 转义 (防止指标值含 <>& 破坏页面)
_htmlesc() {
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
    printf '%s' "$s"
}

# 采集当前健康指标 (复用 check_monitor 的采集, 输出到全局 _RP_*)
_rp_collect() {
    _RP_DB_UP="-"; _RP_MEM="-"; _RP_ORA="-"; _RP_INVAL="-"; _RP_TS="-"; _RP_BKAGE="-"
    _RP_DG="-"; _RP_ARCH="-"; _RP_CPU="-"; _RP_ACT="-"; _RP_REDO="-"; _RP_STATUS="-"
    if command -v check_monitor >/dev/null 2>&1; then
        local j
        # set -e 下子进程非0会中断, 用 || true 容错; 无 Oracle 环境时指标留 "-"
        j=$(OMF_HOME="${OMF_HOME}" bash "${OMF_HOME}/omf.sh" check monitor json 2>/dev/null) || true
        [ -n "$j" ] || return 0
        _RP_DB_UP=$(echo "$j" | grep -o '"db_up": *[0-9]*' | grep -o '[0-9]*$')
        _RP_MEM=$(echo "$j" | grep -o '"mem_free_pct": *[0-9]*' | grep -o '[0-9]*$')
        _RP_ORA=$(echo "$j" | grep -o '"alert_ora_errors": *[0-9]*' | grep -o '[0-9]*$')
        _RP_INVAL=$(echo "$j" | grep -o '"invalid_objects": *[0-9]*' | grep -o '[0-9]*$')
        _RP_TS=$(echo "$j" | grep -o '"tbs_max_pct": *[0-9.]*' | grep -o '[0-9.]*$')
        _RP_BKAGE=$(echo "$j" | grep -o '"backup_age_days": *[0-9-]*' | grep -o '[0-9-]*$')
        _RP_DG=$(echo "$j" | grep -o '"dg_lag_sec": *[0-9-]*' | grep -o '[0-9-]*$')
        _RP_ARCH=$(echo "$j" | grep -o '"arch_used_pct": *[0-9.]*' | grep -o '[0-9.]*$')
        _RP_CPU=$(echo "$j" | grep -o '"cpu_pct": *[0-9]*' | grep -o '[0-9]*$')
        _RP_ACT=$(echo "$j" | grep -o '"active_sessions": *[0-9]*' | grep -o '[0-9]*$')
        _RP_REDO=$(echo "$j" | grep -o '"redo_mbps": *[0-9.]*' | grep -o '[0-9.]*$')
        _RP_STATUS=$(echo "$j" | grep -o '"status": *"[^"]*"' | sed 's/.*"status": *"//;s/"//')
    fi
}

# 生成每日 HTML 报表
#   $1 = 日期 (YYYY-MM-DD, 默认今天)
#   $2 = 是否推送通知 (--push)
report_daily() {
    local date_arg="${1:-$(date '+%Y-%m-%d')}" push=0
    [ "$2" = "--push" ] && push=1
    local dir; dir=$(report_dir)
    mkdir -p "$dir" 2>/dev/null || true

    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    local sid="${OMF_CONFIG[ORACLE_SID]}"
    local role; role=$(omf_db_role 2>/dev/null); [ -z "$role" ] && role="(不可连接)"
    local logmode; logmode=$(omf_sql_log_mode); [ -z "$logmode" ] && logmode="(不可连接)"
    local retention="${BACKUP_RETENTION_DAYS:-30}"
    local host="$(hostname 2>/dev/null)"
    local host_ip; host_ip=$(hostname -I 2>/dev/null | awk '{print $1}'); [ -z "$host_ip" ] && host_ip="-"

    # 备份信息
    local last_full; last_full=$(omf_sql_last_full_backup); [ -z "$last_full" ] && last_full="(尚无完整物理备份)"
    local bk_sz; bk_sz=$(du -sh "${ORACLE_BACKUP}" 2>/dev/null | cut -f1); [ -z "$bk_sz" ] && bk_sz="(空)"
    local dmp_cnt; dmp_cnt=$(ls -1 "${ORACLE_BACKUP}/dump/"*.dmp 2>/dev/null | wc -l); [ -z "$dmp_cnt" ] && dmp_cnt=0
    local bk_days; bk_days=$(omf_sql_last_full_backup)
    local bk_age="-"
    if [ -n "$bk_days" ] && [ "$bk_days" != "-" ]; then
        local bt; bt=$(date -d "$bk_days" +%s 2>/dev/null)
        [ -n "$bt" ] && bk_age=$(( ( $(date +%s) - bt ) / 86400 ))
    fi

    # 健康指标
    _rp_collect
    local db_up_txt="不可用"
    [ "$_RP_DB_UP" = "1" ] && db_up_txt="存活"
    [ "$_RP_DB_UP" = "0" ] && db_up_txt="宕机"
    local status_bg="#e0f7e9" status_txt="正常"
    if [ "$_RP_STATUS" = "err" ]; then status_bg="#ffd9d9"; status_txt="异常 (err)";
    elif [ "$_RP_STATUS" = "warn" ]; then status_bg="#fff3d6"; status_txt="警告 (warn)"; fi

    local file="${dir}/daily_${date_arg}.html"
    {
        echo "<!DOCTYPE html><html lang=\"zh\"><head><meta charset=\"utf-8\">"
        echo "<title>OMF 每日健康报表 ${date_arg}</title>"
        echo "<style>body{font-family:sans-serif;margin:20px;color:#333}h1{color:#1a6;font-size:22px}h2{color:#156;font-size:16px;border-bottom:1px solid #ddd;padding-bottom:4px}table{border-collapse:collapse;margin:8px 0;width:100%}th,td{border:1px solid #ddd;padding:6px 10px;text-align:left}th{background:#f5f5f5}tr:nth-child(even){background:#fafafa}.badge{padding:2px 8px;border-radius:3px;color:#fff;font-size:12px}.ok{background:#4caf50}.warn{background:#ff9800}.err{background:#f44336}.muted{color:#999;font-size:12px}</style></head><body>"
        echo "<h1>OMF 每日健康报表 - $( _htmlesc "$date_arg" )</h1>"
        echo "<p class=\"muted\">生成时间: $( _htmlesc "$ts" )  |  主机: $( _htmlesc "$host" ) ($( _htmlesc "$host_ip" ))  |  框架 v${OMF_VERSION}</p>"

        # 总览
        echo "<h2>总览</h2>"
        echo "<p>健康状态: <span class=\"badge\" style=\"background:${status_bg};color:#333\">$( _htmlesc "$status_txt" )</span>  数据库: <span class=\"badge ${_RP_DB_UP:+ok}\">$( _htmlesc "$db_up_txt" )</span></p>"

        # 实例信息
        echo "<h2>实例信息</h2><table><tr><th>项</th><th>值</th></tr>"
        echo "<tr><td>实例 (SID)</td><td>$( _htmlesc "$sid" )</td></tr>"
        echo "<tr><td>PDB</td><td>$( _htmlesc "${PDB_NAME}" )</td></tr>"
        echo "<tr><td>库角色</td><td>$( _htmlesc "$role" )</td></tr>"
        echo "<tr><td>归档模式</td><td>$( _htmlesc "$logmode" )</td></tr>"
        echo "<tr><td>备份保留</td><td>${retention} 天</td></tr>"
        echo "</table>"

        # 备份概况
        echo "<h2>备份概况</h2><table><tr><th>项</th><th>值</th></tr>"
        echo "<tr><td>最近全量备份</td><td>$( _htmlesc "$last_full" )</td></tr>"
        echo "<tr><td>最近全量距今天数</td><td>${bk_age}</td></tr>"
        echo "<tr><td>备份目录占用</td><td>$( _htmlesc "$bk_sz" )</td></tr>"
        echo "<tr><td>逻辑备份(dump)数</td><td>${dmp_cnt}</td></tr>"
        echo "</table>"

        # 健康指标
        echo "<h2>健康指标</h2><table><tr><th>指标</th><th>值</th></tr>"
        echo "<tr><td>CPU 使用率</td><td>${_RP_CPU:-"-"} %</td></tr>"
        echo "<tr><td>可用内存</td><td>${_RP_MEM:-"-"} %</td></tr>"
        echo "<tr><td>活动会话数</td><td>${_RP_ACT:-"-"}</td></tr>"
        echo "<tr><td>无效对象数</td><td>${_RP_INVAL:-"-"}</td></tr>"
        echo "<tr><td>表空间最大使用率</td><td>${_RP_TS:-"-"} %</td></tr>"
        echo "<tr><td>FRA 使用率</td><td>${_RP_ARCH:-"-"} %</td></tr>"
        echo "<tr><td>Redo 速率</td><td>${_RP_REDO:-"-"} MB/s</td></tr>"
        echo "<tr><td>DG 应用延迟</td><td>${_RP_DG:-"-"} 秒</td></tr>"
        echo "<tr><td>Alert 日志 ORA- 错误</td><td>${_RP_ORA:-"-"}</td></tr>"
        echo "</table>"

        echo "<p class=\"muted\">明细查询: omf status / omf backup list / omf log audit / omf check monitor</p>"
        echo "</body></html>"
    } > "$file"

    log_info "每日健康报表已生成: $file"
    if [ "$push" -eq 1 ]; then
        local summary="SID=${sid} 状态=${status_txt} 库=${db_up_txt} 最近全量=${last_full}(${bk_age}天前) 表空间=${_RP_TS:-?}% FRA=${_RP_ARCH:-?}% DG延迟=${_RP_DG:-?}s 无效对象=${_RP_INVAL:-?}"
        send_notification "OMF 每日健康报表 (${date_arg})" "$summary"
    fi
}

# 列出已生成的报表
report_list() {
    local dir; dir=$(report_dir)
    echo ""
    echo "──── OMF 每日健康报表 (logs/reports/) ────"
    if [ -d "$dir" ] && [ -n "$(ls -1 "$dir"/*.html 2>/dev/null)" ]; then
        ls -1th "$dir"/*.html 2>/dev/null | while read -r f; do
            printf "  %-60s %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
        done
    else
        echo "  (暂无报表, 执行 omf report daily)"
    fi
    echo ""
}

# 清理 N 天前报表 (默认保留 30 天)
report_clean() {
    local days="${1:-30}"
    local dir; dir=$(report_dir)
    [ -d "$dir" ] || return 0
    find "$dir" -name "*.html" -mtime "+$((days-1))" -delete 2>/dev/null || true
    log_info "已清理 ${days} 天前的健康报表"
}

cmd_report() {
    local subcmd="${1:-daily}"
    shift || true
    log_set_subcmd "$subcmd"
    case "$subcmd" in
        daily)
            # 生成类操作: set -o pipefail 下查询管道(grep 无匹配等)可能返回非0, 报表生成不应因此中断。
            # 用 set +e 包裹, 只要报表文件生成了即视为成功 (指标缺失以 "-" 显示)。
            local rc_report
            set +e
            report_daily "$@"
            rc_report=$?
            set -e
            return "$rc_report"
            ;;
        list)  report_list "$@";;
        clean) report_clean "$@";;
        *)
            echo "用法: omf report {daily|list|clean}"
            echo "  daily [日期] [--push]  生成每日备份/健康 HTML 报表 (默认今天)"
            echo "  list                   列出已生成的报表"
            echo "  clean [天数]           清理 N 天前报表 (默认 30)"
            ;;
    esac
}
