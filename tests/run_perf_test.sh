#!/usr/bin/env bash
# 一键运行性能测试（无头）。对应已知问题 K-09。
#
# 用法（项目根目录）：
#     bash tests/run_perf_test.sh                  # 主测试 + 两个探针
#     bash tests/run_perf_test.sh --main-only      # 只跑主测试（更快）
#
# 结果文件（均由 Godot 脚本生成，不允许手改）：
#     tests/性能结果.txt         主测试的 8 个场景
#     tests/性能上限探针.txt     碎片数量 -> 物理耗时 的拐点
#     tests/性能最坏情况探针.txt  60 个碎片全程飞行（限内理论最坏）
#
# 【为什么用 --headless】
#   无渲染依赖，任何机器都能跑，适合放进 CI。
#   代价是测不到渲染/GPU 耗时，报告里对这一点有明确说明。
#
# 退出码：0 = 主测试至少跑出了一个场景；非 0 = 脚本自身失败。

set -u

GODOT="${GODOT:-/c/Users/60459/Tools/godot/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe}"
RESULT="tests/性能结果.txt"

# 过滤掉引擎退出时的心跳噪音（这些都发生在 quit() 之后，与测试结果无关）
NOISE="Leaked|at: ~|ObjectDB|resources still|Pages in use|RID alloc|cleanup|utilities.cpp|clear \("

MAIN_ONLY=0
[ "${1:-}" = "--main-only" ] && MAIN_ONLY=1

echo "=== [1/3] 主性能测试（8 个场景，约 35 秒）==="
"$GODOT" --headless res://tests/perf_test.tscn 2>&1 | grep -vE "$NOISE"
RC=${PIPESTATUS[0]}

if [ "$MAIN_ONLY" -eq 0 ]; then
    echo
    echo "=== [2/3] 上限探针：碎片数量 -> 物理耗时（约 28 秒）==="
    "$GODOT" --headless res://tests/perf_limit_probe.tscn 2>&1 | grep -vE "$NOISE"

    echo
    echo "=== [3/3] 最坏情况探针：60 个碎片全程飞行（约 10 秒）==="
    "$GODOT" --headless res://tests/perf_worst_probe.tscn 2>&1 | grep -vE "$NOISE"
fi

echo
if [ -f "$RESULT" ]; then
    echo "=== 结果文件 ==="
    ls -1 tests/性能*.txt 2>/dev/null | sed 's/^/    /'
else
    echo "=== 未生成 $RESULT，主测试可能中途失败 ==="
fi

exit "$RC"
