#!/usr/bin/env bash
# 多进程多人战斗测试：1 个主机 + N 个客户端，全部进入战斗关卡。
#
# 用法（项目根目录）：
#     bash tests/run_mp_battle_test.sh           # 两人（默认）
#     bash tests/run_mp_battle_test.sh 4         # 四人
#
# 验证内容：
#   - 每个进程都注册了 N 个玩家实体（含本地与远端）
#   - 每个进程都生成了 Boss
#   - 客户端收到了 Boss 的位置同步
#   - 地形破坏物数量在所有进程一致
#
# 【关于四人测试的诚实说明】
#   本脚本启动的是 4 个**独立 Godot 进程**（不是 4 台机器）。
#   这能验证同步逻辑、权限分配、状态一致性，
#   但**不能**验证真实网络延迟、丢包、NAT 穿透这些只有跨设备才暴露的问题。
#   跨设备的测试步骤见 docs/测试记录.md。

set -u

PLAYERS="${1:-2}"
GODOT="${GODOT:-/c/Users/60459/Tools/godot/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe}"
SCENE="res://tests/mp_battle_test.tscn"
LOG_DIR="tests/_mp_logs"

rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

PIDS=()
ROLES=()

echo "=== 启动主机进程（期望 $PLAYERS 人）==="
"$GODOT" --headless "$SCENE" -- --role=host --players="$PLAYERS" \
    > "$LOG_DIR/host.log" 2>&1 &
PIDS+=($!)
ROLES+=("host")

# 主机需要一点时间把房间建起来
sleep 4

for i in $(seq 1 $((PLAYERS - 1))); do
    echo "=== 启动客户端进程 $i ==="
    "$GODOT" --headless "$SCENE" -- --role=client --players="$PLAYERS" \
        > "$LOG_DIR/client$i.log" 2>&1 &
    PIDS+=($!)
    ROLES+=("client$i")
    # 客户端之间错开启动，避免同时握手造成端口/缓存竞争
    sleep 2
done

echo
echo "=== 等待所有进程结束（最多 90 秒）==="
FAILED=0
for idx in "${!PIDS[@]}"; do
    pid="${PIDS[$idx]}"
    role="${ROLES[$idx]}"
    if ! wait "$pid"; then
        echo "  [$role] 退出码非 0"
        FAILED=1
    fi
done

echo
for f in "$LOG_DIR"/*.log; do
    name=$(basename "$f" .log)
    echo "--- $name ---"
    grep -E "\[通过\]|\[失败\]|=====" "$f" | tail -12
    echo
done

if [ "$FAILED" -eq 0 ]; then
    echo "=== ${PLAYERS} 人战斗测试通过 ==="
    exit 0
else
    echo "=== ${PLAYERS} 人战斗测试失败 ==="
    exit 1
fi
