#!/usr/bin/env bash
# 多人联机性能测试：1 个主机 + N 个客户端，每个进程各测自己的物理帧时间。
#
# 用法（项目根目录）：
#     bash tests/run_mp_perf_test.sh        # 默认 4 人
#     bash tests/run_mp_perf_test.sh 2      # 2 人
#
# 【诚实说明】这是同一台机器上的 N 个进程，不是 N 台机器。
#   它测的是"主机在多人负载下的 CPU 主循环余量"，不是真实网络表现。
#   跨设备步骤见 docs/测试记录.md 第五节。
#
# 结果：tests/_mp_perf/<role>.txt，由各进程自己写，本脚本只负责汇总打印。

set -u

PLAYERS="${1:-4}"
GODOT="${GODOT:-/c/Users/60459/Tools/godot/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe}"
SCENE="res://tests/mp_perf_test.tscn"
OUT_DIR="tests/_mp_perf"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

PIDS=()
ROLES=()

echo "=== 启动主机进程（期望 $PLAYERS 人）==="
"$GODOT" --headless "$SCENE" -- --role=host --players="$PLAYERS" \
    > "$OUT_DIR/host.log" 2>&1 &
PIDS+=($!)
ROLES+=("host")

sleep 4

for i in $(seq 1 $((PLAYERS - 1))); do
    echo "=== 启动客户端进程 $i ==="
    "$GODOT" --headless "$SCENE" -- --role=client --players="$PLAYERS" \
        > "$OUT_DIR/client$i.log" 2>&1 &
    PIDS+=($!)
    ROLES+=("client$i")
    sleep 2
done

echo
echo "=== 等待所有进程结束（最多 150 秒）==="
FAILED=0
for idx in "${!PIDS[@]}"; do
    if ! wait "${PIDS[$idx]}"; then
        echo "  [${ROLES[$idx]}] 退出码非 0"
        FAILED=1
    fi
done

echo
echo "================ 各进程实测结果 ================"
for f in "$OUT_DIR"/*.txt; do
    [ -f "$f" ] || continue
    echo "--- $(basename "$f" .txt) ---"
    cat "$f"
    echo
done

if [ "$FAILED" -eq 0 ]; then
    echo "=== ${PLAYERS} 人性能测试完成 ==="
    exit 0
else
    echo "=== ${PLAYERS} 人性能测试有进程失败（详见 $OUT_DIR/*.log）==="
    exit 1
fi
