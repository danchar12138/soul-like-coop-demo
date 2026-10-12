#!/usr/bin/env bash
# 一键跑全部测试。
#
# 用法（项目根目录）：
#     bash tests/run_all_tests.sh
#
# 会依次执行 7 个测试套件，最后汇总结果。
# 任何一项失败都会在汇总里标出来，但**不会中断** ——
# 一次跑完看到全部问题，比修一个跑一次快得多。

set -u
cd "$(dirname "$0")/.."

GODOT="${GODOT:-/c/Users/60459/Tools/godot/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe}"

PASS=0
FAIL=0
declare -a RESULTS=()

run_godot() {
    local name="$1"; shift
    local scene="$1"; shift
    echo ""
    echo "════════ $name ════════"
    local out
    out=$("$GODOT" --headless "$scene" "$@" 2>&1)
    local line
    line=$(echo "$out" | grep -E "^结果：" | head -1)
    if echo "$out" | grep -qE "^结果：.*失败 0"; then
        PASS=$((PASS+1))
        RESULTS+=("  [通过] $name    $line")
        echo "$line"
    else
        FAIL=$((FAIL+1))
        RESULTS+=("  [失败] $name    $line")
        echo "$line"
        echo "$out" | grep -E "\[失败\]" | head -10
    fi
}

# 「报告型」测试：它不判通过/失败，只输出数据。
# 只要正常跑完（不崩溃）就算通过。
run_report() {
    local name="$1"; shift
    local scene="$1"; shift
    echo ""
    echo "════════ $name ════════"
    local out
    out=$("$GODOT" --headless "$scene" "$@" 2>&1)
    local rc=$?
    if [ "$rc" -eq 0 ] && echo "$out" | grep -q "结果已写入"; then
        PASS=$((PASS+1))
        RESULTS+=("  [通过] $name    （报告型：数据已写入）")
        echo "$out" | grep -E "结果已写入" | head -1
    else
        FAIL=$((FAIL+1))
        RESULTS+=("  [失败] $name")
        echo "$out" | tail -5
    fi
}

run_shell() {
    local name="$1"; shift
    echo ""
    echo "════════ $name ════════"
    if bash "$@" > /tmp/_run_all_test.log 2>&1; then
        PASS=$((PASS+1))
        RESULTS+=("  [通过] $name")
        tail -2 /tmp/_run_all_test.log
    else
        FAIL=$((FAIL+1))
        RESULTS+=("  [失败] $name")
        tail -5 /tmp/_run_all_test.log
    fi
}

echo "╔══════════════════════════════════════════╗"
echo "║   低多边形类魂合作 Demo —— 全部测试       ║"
echo "╚══════════════════════════════════════════╝"

run_godot "战斗系统集成测试" "res://tests/test_runner.tscn"
run_godot "骨骼动画校验"     "res://tests/animation_test.tscn"
run_godot "音效资源校验"     "res://tests/audio_test.tscn"
run_godot "模型资源校验"     "res://tests/test_models.tscn"
# 性能测试是"报告型"：它生成性能数据而不做通过/失败判定。
# 用 run_report 而不是 run_godot —— 后者靠解析"结果：通过 X"来判断，
# 而性能测试根本不输出那行。
run_report "性能测试"         "res://tests/perf_test.tscn"

run_shell "双进程联机连接"   "tests/run_net_test.sh"
run_shell "四人多人战斗"     "tests/run_mp_battle_test.sh" 4

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║                汇总                       ║"
echo "╚══════════════════════════════════════════╝"
for r in "${RESULTS[@]}"; do echo "$r"; done
echo ""
echo "通过 $PASS 项 / 失败 $FAIL 项"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
