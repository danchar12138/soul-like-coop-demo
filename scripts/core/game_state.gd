extends Node
## 全局游戏状态（Autoload 单例）。
##
## 职责边界（重要）：
##   本脚本只保存**本地表现层与 UI 需要的会话状态**，
##   权威战斗数据始终保存在各个角色节点自己的组件里。
##   这样做是为了避免"全局单例成了隐藏的联机状态源"，
##   导致客户端各自维护一份不同的 Boss 血量。

enum Phase { BOOT, MAIN_MENU, PLAYING, BOSS_FIGHT, VICTORY, DEFEAT }

## 当前游戏阶段
var phase: Phase = Phase.BOOT

## 本地玩家节点（当前客户端操控的角色）
var local_player: Node3D

## 所有已注册玩家：peer_id -> 节点
var players: Dictionary = {}

## 当前锁定的目标
var locked_target: Node3D

## 当前 Boss
var boss: Node3D

## 检查点位置（玩家死亡后复活点）
var checkpoint_position: Vector3 = Vector3.ZERO
var checkpoint_rotation: float = 0.0

## 战斗统计（供结算界面与调试）
var stats := {
	"deaths": 0,
	"boss_attempts": 0,
	"damage_dealt": 0.0,
	"elapsed_time": 0.0,
}

## 调试 HUD 是否显示
var debug_enabled: bool = true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	if phase in [Phase.PLAYING, Phase.BOSS_FIGHT]:
		stats["elapsed_time"] += delta


func reset() -> void:
	players.clear()
	local_player = null
	locked_target = null
	boss = null
	phase = Phase.BOOT
	stats = {"deaths": 0, "boss_attempts": 0, "damage_dealt": 0.0, "elapsed_time": 0.0}


func register_player(peer_id: int, node: Node3D) -> void:
	players[peer_id] = node


func unregister_player(peer_id: int) -> void:
	players.erase(peer_id)


func get_player(peer_id: int) -> Node3D:
	return players.get(peer_id)


func get_player_count() -> int:
	return players.size()


## 返回所有存活玩家，Boss AI 用它决定攻击目标
func get_alive_players() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for id: int in players:
		# 【必须先取成 Variant 再判有效，不能直接赋给类型化变量】
		# `players` 里可能残留已经释放的节点（玩家断线时
		# LevelManager 会 queue_free，但释放推迟到帧末）。
		# 对一个**已释放**的对象赋值给 `Node3D` 类型的变量会抛
		# "Trying to assign invalid previously freed instance" ——
		# 而不是像预期那样得到 null。
		# Boss 每次攻击结束都会经由 _maybe_retarget() 走到这里，
		# 所以这条错误日志会在联机断线后持续刷屏。
		var raw: Variant = players[id]
		if not is_instance_valid(raw):
			continue
		var p := raw as Node3D
		if p == null:
			continue
		var h := p.get_node_or_null("Health") as HealthComponent
		if h != null and not h.is_dead:
			out.append(p)
	return out


func set_checkpoint(pos: Vector3, yaw_deg: float = 0.0) -> void:
	checkpoint_position = pos
	checkpoint_rotation = yaw_deg


func is_multiplayer() -> bool:
	return NetManager != null and NetManager.is_session_active()


func phase_name() -> String:
	match phase:
		Phase.BOOT: return "启动"
		Phase.MAIN_MENU: return "主菜单"
		Phase.PLAYING: return "探索"
		Phase.BOSS_FIGHT: return "Boss 战"
		Phase.VICTORY: return "胜利"
		Phase.DEFEAT: return "失败"
	return "未知"
