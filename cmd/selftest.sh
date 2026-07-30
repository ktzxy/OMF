#!/bin/bash
# OMF - Oracle Management Framework (c) 2026 ktzxy. Apache-2.0; 见 LICENSE/NOTICE. 仅编排 Oracle 自带命令, 可安全审计.
#===============================================================================
# OMF - 自检测试 (语法 / 基本健全性)
# 用法: omf selftest
#   纯静态检查, 不依赖 Oracle 环境, 可在任意装有 bash 的主机运行, 适合
#   CI / 批量部署前快速发现框架自身的脚本语法或结构问题.
#===============================================================================

cmd_selftest() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          OMF 自检测试 (语法 / 健全性)                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    local fail=0 pass=0
    local -a files=()
    files+=("${OMF_HOME}/omf.sh")
    local f
    for f in "${OMF_HOME}/lib"/*.sh; do [ -f "$f" ] && files+=("$f"); done
    for f in "${OMF_HOME}/cmd"/*.sh; do [ -f "$f" ] && files+=("$f"); done

    echo "--- Shell 语法检查 (bash -n) ---"
    local err_tmp
    err_tmp="$(mktemp 2>/dev/null || echo /tmp/omf_selftest_err)"
    for f in "${files[@]}"; do
        if bash -n "$f" 2>"$err_tmp"; then
            echo "  ✓ $(basename "$f")"
            pass=$((pass+1))
        else
            echo "  ✗ $(basename "$f") 语法错误:"
            sed 's/^/      /' "$err_tmp"
            fail=$((fail+1))
        fi
    done
    rm -f "$err_tmp" 2>/dev/null || true

    echo ""
    echo "--- shebang 检查 (首行应为 #!/bin/bash) ---"
    for f in "${files[@]}"; do
        if ! head -1 "$f" | grep -q '^#!.*bash'; then
            echo "  ⚠ $(basename "$f") 首行非 bash shebang, 可能无法被 sh 正确解析"
        fi
    done

    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "自检结果: ✓ $pass 通过  ✗ $fail 失败"
    echo "══════════════════════════════════════════════════════════"
    [ "$fail" -gt 0 ] && return 1
    return 0
}
