#!/usr/bin/env bash
# 双进程联机测试：一个主机、一个客户端。
#
# 用法（项目根目录）：
#     bash tests/run_net_test.sh
#
# 两个进程都返回 0 才算通过。
# 之所以要两个进程：Godot 的 multiplayer 单例每个 SceneTree 只有一份，
# 单进程内无法同时扮演主机与客户端。

set -u

GODOT="${GODOT:-/c/Users/60459/Tools/godot/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe}"
SCENE="res://tests/net_test.tscn"
LOG_HOST="tests/_net_host.log"
LOG_CLIENT="tests/_net_client.log"

echo "=== 启动主机进程 ==="
"$GODOT" --headless "$SCENE" -- --role=host > "$LOG_HOST" 2>&1 &
HOST_PID=$!

sleep 3

echo "=== 启动客户端进程 ==="
"$GODOT" --headless "$SCENE" -- --role=client > "$LOG_CLIENT" 2>&1 &
CLIENT_PID=$!

wait $CLIENT_PID
CLIENT_RC=$?
wait $HOST_PID
HOST_RC=$?

echo
echo "--- 主机输出 ---"
grep -E "联机测试" "$LOG_HOST" | head -20
echo "--- 客户端输出 ---"
grep -E "联机测试" "$LOG_CLIENT" | head -20

echo
if [ "$HOST_RC" -eq 0 ] && [ "$CLIENT_RC" -eq 0 ]; then
    echo "=== 联机测试通过（两端退出码均为 0）==="
    exit 0
else
    echo "=== 联机测试失败（主机 $HOST_RC / 客户端 $CLIENT_RC）==="
    exit 1
fi
