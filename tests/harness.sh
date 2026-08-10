#!/bin/bash
#===============================================================================
# OMF - 危险路径行为回归测试 (tests/harness.sh)
# 用法:
#   bash tests/harness.sh            # 运行全部危险路径断言
#   OMF_HOME=... bash tests/harness.sh  # 指定框架根目录 (默认取脚本所在目录上级)
#
# 设计:
#   本脚本不依赖真实 Oracle 环境, 仅验证 OMF 防护逻辑的【行为】:
#     1) confirm        非交互 + 无 --yes        -> 返回非0 (拒绝执行, 调用方可感知)
#     2) confirm        非交互 +  --yes / -y      -> 返回0   (自动通过)
#     3) confirm_danger 非交互 (即使 --yes)       -> 返回非0 (中止, 防自动化误执行)
#     4) confirm_danger OMF_ALLOW_DANGEROUS=1     -> 返回0   (显式放行)
#     5) set_config     非法键名 / 含换行值        -> 拒绝 (不落盘)
#     6) set_config     合法键值                   -> 成功持久化
#   对应 v1.32 起加固的危险操作防护, 防止未来改动破坏"执行前拦截"语义.
#   全部用例在子进程/临时目录中运行, 不改动真实 conf, 可安全接入 CI.
#===============================================================================

# ---- 定位 OMF 根目录 ----
if [ -z "${OMF_HOME:-}" ]; then
    OMF_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
fi
export OMF_HOME

# ---- 测试框架 ----
PASS=0; FAIL=0
t() { # t <描述> <命令...>
    local desc="$1"; shift
    if "$@"; then PASS=$((PASS+1)); echo "  ✓ $desc"
    else FAIL=$((FAIL+1)); echo "  ✗ $desc"; fi
}

# 在子进程中加载 lib/common.sh (仅依赖空 OMF_CONFIG 数组, 无副作用)
load_common() {
    bash -c "
        declare -A OMF_CONFIG
        . '${OMF_HOME}/lib/common.sh'
        $1
    "
}

# 在子进程中加载 config.sh 的 set_config 函数 (剥离自动加载 load_config 副作用)
#   config.sh 末行裸调用 load_config 会 source 真实 omf.conf; 这里拷到 tmp 去掉末行再 source,
#   得到干净的 set_config 定义; log_error stub 为退出非0, 使"拒绝路径"能被捕获.
load_set_config() {
    local tmp; tmp="$(mktemp)"
    grep -v '^load_config$' "${OMF_HOME}/lib/config.sh" > "$tmp"
    bash -c "
        declare -A OMF_CONFIG
        export OMF_CONFIG_FILE='$OMF_CONFIG_FILE'
        log_error() { echo \"log_error: \$*\" >&2; exit 9; }
        log_info()  { :; }
        . '$tmp'
        $1
    "
    rm -f "$tmp"
}

# ---- 用例 ----
echo "=== OMF 危险路径回归测试 ==="

# 1) confirm: 非交互 + 无 --yes -> 返回非0 (拒绝执行)
t "confirm 非交互无 --yes 拒绝执行 (返回非0)" \
    load_common "unset OMF_ASSUME_YES; confirm '测试确认?' && exit 1 || exit 0"

# 2) confirm: 非交互 + --yes -> 返回0 (自动通过)
t "confirm 非交互 --yes 自动通过 (返回0)" \
    load_common "export OMF_ASSUME_YES=true; confirm '测试确认?'"

# 3) confirm_danger: 非交互 + --yes -> 返回非0 (中止, 防自动化误执行)
t "confirm_danger 非交互即使 --yes 也中止 (返回非0)" \
    load_common "export OMF_ASSUME_YES=true; confirm_danger '测试危险操作?' 2>/dev/null && exit 1 || exit 0"

# 4) confirm_danger: OMF_ALLOW_DANGEROUS=1 -> 返回0 (显式放行)
t "confirm_danger OMF_ALLOW_DANGEROUS=1 放行 (返回0)" \
    load_common "export OMF_ALLOW_DANGEROUS=1 OMF_ASSUME_YES=true; confirm_danger '测试危险操作?' >/dev/null 2>&1"

# 5) set_config: 非法键名被拒绝 (返回非0, 不落盘)
t "set_config 非法键名被拒绝" \
    load_set_config "OMF_CONFIG_FILE=\$(mktemp); echo 'X=1' > \$OMF_CONFIG_FILE; set_config 'A]X=1;touch /tmp/omf_pwned' v 2>/dev/null && exit 1 || exit 0"

# 6) set_config: 含换行值被拒绝 (返回非0, 不落盘)
t "set_config 含换行值被拒绝" \
    load_set_config "OMF_CONFIG_FILE=\$(mktemp); echo 'X=1' > \$OMF_CONFIG_FILE; set_config FOO \$'a\nb' 2>/dev/null && exit 1 || exit 0"

# 7) set_config: 合法键值成功持久化
t "set_config 合法键值成功持久化" \
    load_set_config "OMF_CONFIG_FILE=\$(mktemp); echo 'X=1' > \$OMF_CONFIG_FILE; set_config FOO bar; grep -q '^FOO=\"bar\"' \$OMF_CONFIG_FILE"

# ---- 8-9) 敏感口令文件 conf/.omf.secret 加载优先级 ----
# 8) secret 文件覆盖 omf.conf 中的口令默认值
t "secret 文件口令覆盖 omf.conf" \
    bash -c "
        tmpd=\$(mktemp -d)
        printf 'ORACLE_PASSWORD=\"sec123456\"\nAPP_PASSWORD=\"app7890\"\n' > \$tmpd/.omf.secret
        chmod 600 \$tmpd/.omf.secret
        : > \$tmpd/omf.conf
        export OMF_CONFIG_FILE=\$tmpd/omf.conf
        OMF_HOME='${OMF_HOME}' bash -c 'source lib/common.sh; source lib/config.sh; [ \"\$ORACLE_PASSWORD\" = sec123456 ] && [ \"\$APP_PASSWORD\" = app7890 ]'
        rc=\$?; rm -rf \$tmpd; exit \$rc
    "

# 9) 环境变量优先于 secret
t "环境变量口令优先于 secret" \
    bash -c "
        tmpd=\$(mktemp -d)
        printf 'ORACLE_PASSWORD=\"sec123456\"\n' > \$tmpd/.omf.secret
        chmod 600 \$tmpd/.omf.secret
        : > \$tmpd/omf.conf
        export OMF_CONFIG_FILE=\$tmpd/omf.conf ORACLE_PASSWORD=envpw789
        OMF_HOME='${OMF_HOME}' bash -c 'source lib/common.sh; source lib/config.sh; [ \"\$ORACLE_PASSWORD\" = envpw789 ]'
        rc=\$?; rm -rf \$tmpd; exit \$rc
    "

# 10) 语法错误配置应被明确拒绝 (set +e 保护), 而非静默中断
t "load_config 语法错误配置被明确拒绝" \
    bash -c "
        tmpd=\$(mktemp -d)
        printf 'ORACLE_SID=\"BROKEN\nTHIS IS NOT VALID\n' > \$tmpd/omf.conf
        : > \$tmpd/.omf.secret
        export OMF_CONFIG_FILE=\$tmpd/omf.conf
        out=\$(OMF_HOME='${OMF_HOME}' bash -c 'source lib/common.sh; source lib/config.sh' 2>&1)
        rc=\$?
        echo \"\$out\" | grep -q '配置文件加载失败' && [ \$rc -ne 0 ]
        r2=\$?; rm -rf \$tmpd; exit \$r2
    "

# ---- 11-12) 结构化日志 (cmd/subcmd 字段, 文本 + JSON) ----
# 11) 默认文本模式: 日志行含 [cmd=...][sub=...]
t "结构化日志文本模式含 cmd/sub 字段" \
    load_common "
        export OMF_CMD=testcmd OMF_HOME='${OMF_HOME}'
        log_init testcmd; log_set_subcmd build
        log_info hello
        grep -q '\[cmd=testcmd\]\[sub=build\]' \"\$OMF_RUN_LOG\"
    "

# 12) JSON 模式: OMF_LOG_STRUCTURED=true 输出 JSON Lines
t "结构化日志 JSON 模式输出合法 JSON" \
    load_common "
        export OMF_CMD=testcmd OMF_HOME='${OMF_HOME}' OMF_LOG_STRUCTURED=true
        log_init testcmd; log_set_subcmd run
        log_info jsonmode
        head -1 \"\$OMF_RUN_LOG\" | grep -q '\"cmd\":\"testcmd\"' && head -1 \"\$OMF_RUN_LOG\" | grep -q '\"sub\":\"run\"' && head -1 \"\$OMF_RUN_LOG\" | grep -q '\"msg\":\"jsonmode\"'
    "

echo ""
echo "═══════════════════════════════════════"
echo "回归结果: ✓ $PASS 通过  ✗ $FAIL 失败"
echo "═══════════════════════════════════════"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
