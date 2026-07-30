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
    echo "--- 命令分发一致性 (omf.sh 分发 <-> cmd/*.sh 实现) ---"
    local line sf fn
    # 正向: omf.sh 里分发的每个命令, 其引用的 cmd/<x>.sh 应存在且定义了被调用的 cmd_<x> 函数
    while IFS= read -r line; do
        sf=$(printf '%s' "$line" | grep -oE 'cmd/[a-zA-Z_]+\.sh')
        fn=$(printf '%s' "$line" | grep -oE 'cmd_[a-zA-Z_]+')
        [ -z "$sf" ] && continue
        if [ ! -f "${OMF_HOME}/${sf}" ]; then
            echo "  ✗ 分发引用 ${sf} 但文件不存在"; fail=$((fail+1)); continue
        fi
        if grep -qE "^[[:space:]]*${fn}[[:space:]]*\(\)|^[[:space:]]*${fn}[[:space:]]*\([[:space:]]*\)" "${OMF_HOME}/${sf}"; then
            echo "  ✓ ${sf} -> ${fn}"
            pass=$((pass+1))
        else
            echo "  ✗ ${sf} 未定义分发所调用的函数 ${fn}"
            fail=$((fail+1))
        fi
    done < <(grep 'source "${OMF_HOME}/cmd/' "${OMF_HOME}/omf.sh")
    # 反向: cmd/ 下每个脚本都应在 omf.sh 中分发, 否则成了死代码
    for f in "${OMF_HOME}/cmd"/*.sh; do
        [ -f "$f" ] || continue
        if ! grep -q "cmd/$(basename "$f")" "${OMF_HOME}/omf.sh"; then
            echo "  ⚠ $(basename "$f") 存在但未在 omf.sh 中分发 (疑似死代码)"
        fi
    done

    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "自检结果: ✓ $pass 通过  ✗ $fail 失败"
    echo "══════════════════════════════════════════════════════════"
    [ "$fail" -gt 0 ] && return 1
    return 0
}
