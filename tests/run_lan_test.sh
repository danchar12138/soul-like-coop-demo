#!/usr/bin/env bash
# 跨设备联机测试辅助脚本。
#
# 用法：
#     # 在主机上：
#     bash tests/run_lan_test.sh host
#
#     # 在每台客户端上（把 IP 换成主机显示的地址）：
#     bash tests/run_lan_test.sh client 192.168.1.100
#
# 与 run_mp_battle_test.sh 的区别：
#   那个脚本在**同一台机器**上开多个进程（验证同步逻辑是否正确）。
#   这个脚本在**多台机器**上各开一个进程（验证真实网络下的表现）。
#
# 两者是互补的，不能互相替代：
#   - 多进程测试能验证逻辑，但网络延迟接近 0，测不出时序问题
#   - 跨设备测试能暴露延迟、丢包、时钟不同步，但环境难以自动化
#
# 【跨设备测试会暴露什么】
#   1. 位置插值是否够平滑（20Hz 同步 + 插值，延迟高时会看出"飘"）
#   2. 动画进度同步是否准确（用了引擎时间而非系统时间，见 player_sync.gd）
#   3. Boss 位置同步的滞后是否可接受
#   4. 地形破坏的广播是否有明显延迟
#   5. 不同性能的机器之间是否会出现"我先看到它碎了"这类不一致
#
# 【已知会表现不佳的项】（提前说明，避免误判为 bug）
#   - Boss 的位置是 20Hz 同步 + 客户端插值，快速移动时能看到轻微滞后。
#     这是设计取舍（只广播位置不广播速度），不是缺陷。
#   - 玩家位置同样是 20Hz。局域网下延迟通常 <5ms，肉眼看不出。

set -u

ROLE="${1:-}"
HOST_IP="${2:-127.0.0.1}"

GODOT="${GODOT:-/c/Users/60459/Tools/godot/Godot_v4.7.1-stable_mono_win64/Godot_v4.7.1-stable_mono_win64.exe}"
SCENE="res://tests/lan_test.tscn"
LOG="tests/_lan_${ROLE}.log"

if [ -z "$ROLE" ]; then
    echo "用法："
    echo "  主机：  bash tests/run_lan_test.sh host"
    echo "  客户端：bash tests/run_lan_test.sh client <主机IP>"
    exit 1
fi

echo "=== 角色：$ROLE ==="
if [ "$ROLE" = "client" ]; then
    echo "=== 目标主机：$HOST_IP ==="
fi
echo "=== 日志：$LOG ==="

"$GODOT" --headless "$SCENE" -- --role="$ROLE" --host="$HOST_IP" 2>&1 | tee "$LOG"

echo
echo "=== 摘要 ==="
grep -E "^\[跨设备\]|\[通过\]|\[失败\]" "$LOG" | tail -30
