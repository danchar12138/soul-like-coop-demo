class_name EnemySync
extends Node
## 敌人与 Boss 的状态同步。
##
## 与 PlayerSync 的区别（关键）：
##   PlayerSync 是"客户端权威"——玩家自己的机器算位置（为了手感）。
##   EnemySync 是"主机权威"——敌人 AI 只在主机上跑，位置由主机
##   广播给客户端。客户端纯粹做插值显示。
##
## 为什么敌人必须主机权威：
##   1. 敌人 AI 要读所有玩家的状态来做决策，客户端没有完整视野
##   2. 如果各端各跑一份 AI，敌人位置会迅速分叉，出现"我这边 Boss
##      在左边、你那边在右边"，攻击判定也就无从对齐
##   3. Boss 的招式选择（加权随机）必须是同一个结果，否则各端看到的
##      攻击都不一样，没法配合闪避
##
## 同步内容：
##   - 位置与朝向（20 Hz，unreliable_ordered）
##   - 生命值 / 架势（事件驱动，reliable）
##   - 动作状态（状态变化时立即发，reliable）
##
## 添加方式：把本脚本挂在敌人根节点下，命名为 "EnemySync"。
## `EnemyBase` 与 `BossGreatsword` 会自动发现它。

const REPORT_RATE := 20.0
const INTERP_SPEED := 12.0

var enemy: Node3D
var health: HealthComponent
var poise: PoiseComponent
var state_machine: CharacterStateMachine

var _report_accum: float = 0.0
var _report_interval: float = 0.05
var _net_position: Vector3 = Vector3.ZERO
var _net_yaw: float = 0.0
var _has_state: bool = false
## 客户端的插值是否启用（首次收到 snap 之前不插值，避免从原点滑过来）
var _interp_enabled: bool = false

## 最近一次收到同步的时间（调试用）
var last_sync_time: float = 0.0


func _ready() -> void:
	enemy = get_parent() as Node3D
	if enemy == null:
		push_error("EnemySync 必须挂在敌人根节点下")
		return
	_report_interval = 1.0 / REPORT_RATE
	_net_position = enemy.global_position
	_net_yaw = enemy.global_rotation.y

	health = enemy.get_node_or_null("Health") as HealthComponent
	poise = enemy.get_node_or_null("Poise") as PoiseComponent
	state_machine = enemy.get_node_or_null("StateMachine") as CharacterStateMachine

	if health != null:
		health.damaged.connect(_on_health_changed)
		health.died.connect(_on_died)
	if poise != null:
		poise.poise_changed.connect(_on_poise_changed)
	if state_machine != null:
		state_machine.state_changed.connect(_on_state_changed)


## 主机是否应该驱动这个敌人
func is_authority() -> bool:
	return NetManager == null or not NetManager.is_session_active() or multiplayer.is_server()


func _physics_process(delta: float) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	if NetManager == null or not NetManager.is_session_active():
		return

	if is_authority():
		# 主机：把 AI 跑出来的位置定期广播。
		#
		# 【为什么必须先检查有没有客户端就绪】
		# RPC 是按**节点路径**寻址的（例如 /root/Arena/BossGreatsword/EnemySync）。
		# 客户端还没加载完关卡时，对端不存在这个路径，主机的消息会在
		# 对端报 "Node not found ... Requested node was not found" 并被丢弃。
		# 这不致命（对端忽略即可），但会刷满日志、埋掉真正的问题，
		# 而且新玩家会看到一个静止的 Boss。
		# 所以没人能听的时候就不发。
		if NetManager == null or not NetManager.has_ready_clients():
			_report_accum = 0.0
			return
		_report_accum += delta
		if _report_accum >= _report_interval:
			_report_accum = 0.0
			_broadcast_transform(false)
		return

	# 客户端：插值到收到的位置
	_interpolate(delta)


# ============================================================
# 主机 → 广播
# ============================================================

func _broadcast_transform(snap: bool) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	var st := 0
	if state_machine != null:
		st = int(state_machine.get_state())
	_rpc_apply_transform.rpc(enemy.global_position, enemy.global_rotation.y, st, snap)


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_apply_transform(pos: Vector3, yaw: float, state: int, snap: bool) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	last_sync_time = Time.get_ticks_msec() / 1000.0

	if snap or not _has_state:
		enemy.global_position = pos
		enemy.global_rotation.y = yaw
		_interp_enabled = true
		_has_state = true
	else:
		_net_position = pos
		_net_yaw = yaw

	# 状态同步：客户端的敌人状态机不跑 AI，但需要显示正确的状态
	# （例如"正在挥刀"要能看到挥刀表现）
	if state_machine != null:
		var cur := int(state_machine.get_state())
		if cur != state and CombatState.can_take_damage(state):
			state_machine.force_state(state)


func _interpolate(delta: float) -> void:
	if not _interp_enabled or not _has_state:
		return
	var w := clampf(INTERP_SPEED * delta, 0.0, 1.0)
	enemy.global_position = enemy.global_position.lerp(_net_position, w)
	var diff := wrapf(_net_yaw - enemy.global_rotation.y, -PI, PI)
	enemy.global_rotation.y += diff * w


# ============================================================
# 数值同步（事件驱动，reliable）
# ============================================================

func _on_health_changed(_info: DamageInfo, remaining: float) -> void:
	if not is_authority() or NetManager == null or not NetManager.is_session_active():
		return
	var dead := health != null and health.is_dead
	_rpc_apply_health.rpc(remaining, dead)


@rpc("authority", "call_remote", "reliable")
func _rpc_apply_health(remaining: float, dead: bool) -> void:
	if health == null:
		return
	# 直接用权威数值覆盖，不触发伤害逻辑 —— 这是防止
	# "各端显示不同血量"的关键（见 docs/架构说明.md 5.3）
	health.set_health_authoritative(remaining, dead)


func _on_poise_changed(current: float, maximum: float) -> void:
	if not is_authority() or NetManager == null or not NetManager.is_session_active():
		return
	_rpc_apply_poise.rpc(current, poise.is_broken if poise != null else false)


@rpc("authority", "call_remote", "reliable")
func _rpc_apply_poise(current: float, broken: bool) -> void:
	if poise == null:
		return
	poise.set_poise_authoritative(current, broken)


func _on_state_changed(_from: int, to: int) -> void:
	# 状态变化立刻广播（不等到下一个周期），让客户端及时看到"它要出招了"
	if not is_authority() or NetManager == null or not NetManager.is_session_active():
		return
	_broadcast_transform(true)
	# 破防是关键时刻，用 reliable 单独发一次
	if to == CombatState.State.POISE_BREAK:
		_rpc_notify_poise_break.rpc()


@rpc("authority", "call_remote", "reliable")
func _rpc_notify_poise_break() -> void:
	# 客户端只播表现；实际的破防判定已经在主机上做完了
	if poise != null:
		poise.set_poise_authoritative(0.0, true)


func _on_died(_killer: Node) -> void:
	if not is_authority() or NetManager == null or not NetManager.is_session_active():
		return
	_rpc_apply_health.rpc(0.0, true)
	_broadcast_transform(true)


## 新玩家加入时，主机主动把当前状态推一次（否则新客户端会看到
## 满血的 Boss 站在原地）。
##
## 调用时机很重要：必须等客户端**已经加载完关卡、节点路径存在**
## 之后才能发。`LevelManager` 在生成玩家时会延迟调用它（见
## level_manager.gd 的 `_on_peer_joined`），延迟就是为此留的。
func push_full_state() -> void:
	if not is_authority():
		return
	if NetManager != null and not NetManager.has_ready_clients():
		return
	if health != null:
		_rpc_apply_health.rpc(health.health, health.is_dead)
	if poise != null:
		_rpc_apply_poise.rpc(poise.current, poise.is_broken)
	_broadcast_transform(true)
