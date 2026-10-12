class_name PlayerSync
extends Node
## 玩家状态同步（手动 RPC 式，不依赖 MultiplayerSynchronizer）。
##
## 为什么手动而不用 MultiplayerSynchronizer：
##   MultiplayerSynchronizer 需要一份 SceneReplicationConfig 资源，
##   在代码里构造它很别扭，且它的插值策略不适合"每个客户端权威自己的
##   角色"这种模式。手动 RPC 只有 40 行，行为完全可预期、可调试。
##
## 同步模型（详见 docs/架构说明.md）：
##   1. 每个客户端对自己角色的**位置**有权威（避免橡皮筋），
##      并以 20Hz 上报给主机。
##   2. 主机做基本校验（速度上限、位置合理性），然后转发给所有人。
##   3. 其他人以 20Hz 收到的数据做插值，得到平滑的远端角色。
##   4. **战斗结果（伤害、Boss 血量、地形破坏）不走这里**，
##      一律由主机结算后广播，杜绝"各端显示不同结果"。
##
## 表现层同步：攻击动作（attack_id + 播放进度）也会广播，
## 让远端玩家能看到队友在挥刀。远端不重算伤害。

## 上报频率（每秒）
const REPORT_RATE := 20.0
## 远端插值速度（越大越跟手，越小越平滑）
const INTERP_SPEED := 14.0
## 位置校验：单帧最大允许位移（超过判定为作弊/瞬移）
const MAX_SPEED_TOLERANCE := 24.0

var player: PlayerController
var _report_accum: float = 0.0
var _report_interval: float = 0.05

## 远端位置插值目标
var _net_position: Vector3 = Vector3.ZERO
var _net_yaw: float = 0.0
var _has_net_state: bool = false

## 远端正在播放的动画名与它开始的时间戳。
##
## 【为什么动画进度也要同步，而不是各端各播一遍】
## 玩家的位置是**客户端权威**（见 TD-008），主机不知道也不会去猜
## 客户端此刻在播什么动画。如果各端只看"状态枚举"自己决定播什么，
## 那么：队友按下的攻击时刻不同步 —— A 端可能在挥刀，B 端还在待机；
## 而且位置是 20Hz 插值的，动画进度与插值位置会对不上，
## 看起来就是"滑步"。
##
## 所以攻击开始时由该玩家广播 (动画名, 开始时刻)，其他端按
## "已过去多久"跳到对应进度播放。位置插值照常进行，两者独立，
## 但因为都源自同一个真实时刻，视觉上就同步了。
##
## 注意动画不是"应用到本节点"，而是应用到**发送方那个玩家的副本**上
## —— 见 _rpc_play_anim 的说明。

## 最近一次收到的远端状态（调试显示）
var last_rtt_report_time: float = 0.0

# ---------------------------------------------------------------
# 诊断计数
#
# 同步出问题时，"消息走到哪一步断了"比"哪个断言失败"有用得多。
# 这三个计数把链路切成四段：
#   send_count  本机发出了多少次（0 = 本机根本没在报）
#   recv_count  收到了多少次原始消息（0 = 网络上没到）
#   apply_count 成功写入了插值目标（0 = 到了但被校验挡掉）
# 配上 _hist_pos / _hist_time 还能看出"最后一条消息是多久以前的"。
# 见 tests/sync_debug.gd。
# ---------------------------------------------------------------
var send_count: int = 0
var recv_count: int = 0
var apply_count: int = 0
## 最后一次收到的原始位置与收到时刻
var _hist_pos: Vector3 = Vector3.ZERO
var _hist_time: float = -999.0


func _ready() -> void:
	player = get_parent() as PlayerController
	if player == null:
		push_error("PlayerSync 必须挂在 PlayerController 节点下")
		return
	_report_interval = 1.0 / REPORT_RATE
	_net_position = player.global_position
	_net_yaw = player.global_rotation.y

	# 状态变化时立即上报一次（让队友立刻看到"他在攻击/他死了"）
	var sm := player.get_node_or_null("StateMachine")
	if sm != null:
		sm.state_changed.connect(_on_state_changed)
	EventBus.player_died.connect(_on_player_died)
	EventBus.player_respawned.connect(_on_player_respawned)

	# 攻击开始时广播动画名，让远端能看到队友在挥刀（而不是滑步）
	EventBus.attack_started.connect(_on_attack_started)

	if is_local() and NetManager.is_session_active():
		# 稍等一下再开始上报，等场景稳定
		var t := get_tree().create_timer(0.5, false)
		t.timeout.connect(func () -> void: _send_state(true))


func is_local() -> bool:
	return player != null and player.is_local


func _physics_process(delta: float) -> void:
	if player == null:
		return
	if not NetManager.is_session_active():
		return

	if is_local():
		_report_accum += delta
		if _report_accum >= _report_interval:
			_report_accum = 0.0
			_send_state(false)
	else:
		_interpolate_remote(delta)


## 本地权威：把自己的状态发出去。
##
## 【主机与客户端走**两条不同的路径**，这一点很容易搞错】
##
## 客户端：`rpc_id(1, ...)` 上报给主机，主机校验后再转发给其他人。
##         这是"客户端权威位置 + 主机校验"模型（见 TD-008）。
##
## 主机：  **不能**用 `rpc_id(1, ...)` —— 那是在对自己调用，
##         而 `_rpc_report_state` 标了 `call_remote`，Godot 会直接拒绝：
##             RPC '_rpc_report_state' on yourself is not allowed
##         实测主机每秒钟发出 20 条、全部被丢弃（日志刷了几百行），
##         结果是**主机的角色位置从来没有同步给任何客户端** ——
##         客户端看到主机的角色永远停在出生点。
##
##         正确做法：主机跳过"上报给自己再转发"这一步，
##         直接把状态广播给所有客户端。主机本来就不需要校验自己。
func _send_state(force: bool) -> void:
	if player == null or not is_instance_valid(player):
		return
	# 离线时没有会话，直接返回。否则 rpc 会在自己身上执行并报错。
	if not NetManager.is_session_active():
		return

	var sm := player.get_node_or_null("StateMachine")
	var state := 0
	if sm != null:
		state = int(sm.call("get_state"))
	send_count += 1

	if multiplayer.is_server():
		# 主机：直接广播自己。不走"上报给自己再转发"那条路 ——
		# 那会触发 "RPC on yourself is not allowed"（实测每秒 20 条全被拒）。
		_hist_pos = player.global_position
		_hist_time = Time.get_ticks_msec() / 1000.0
		NetManager.broadcast_local_player_state(player.peer_id,
			player.global_position, player.global_rotation.y, state, force)
	else:
		# 客户端：上报给主机（主机是 peer 1）
		NetManager._rpc_client_state.rpc_id(1, player.global_position,
			player.global_rotation.y, state, force)


## 收到远端状态：写入插值目标
func receive_state(pos: Vector3, yaw: float, state: int, snap: bool) -> void:
	if snap or not _has_net_state:
		_net_position = pos
		_net_yaw = yaw
		if player != null:
			player.global_position = pos
			player.global_rotation.y = yaw
		_has_net_state = true
		return
	_net_position = pos
	_net_yaw = yaw
	last_rtt_report_time = Time.get_ticks_msec() / 1000.0

	# 远端角色的动画状态也同步过来（表现层）
	var sm := player.get_node_or_null("StateMachine")
	if sm != null:
		var cur: int = sm.call("get_state")
		if cur != int(state):
			# 用 force_state：远端状态是"事实"，不做优先级判断
			sm.call("force_state", state)


func _interpolate_remote(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	if not _has_net_state:
		return
	var w := clampf(INTERP_SPEED * delta, 0.0, 1.0)
	# 位置用 lerp，朝向用最短角度插值
	player.global_position = player.global_position.lerp(_net_position, w)
	var diff := wrapf(_net_yaw - player.global_rotation.y, -PI, PI)
	player.global_rotation.y += diff * w


func _find_player_node(peer_id: int) -> Node3D:
	return GameState.get_player(peer_id)


func _on_state_changed(_from: int, _to: int) -> void:
	# 状态切换立刻上报，不等到下一个周期 —— 这能让队友的攻击动作
	# 及时出现，而不是延迟 50ms 才看到
	if is_local() and NetManager.is_session_active():
		_send_state(true)


func _on_player_died(p: Node) -> void:
	if p == player and is_local():
		_send_state(true)


func _on_player_respawned(p: Node) -> void:
	if p != player:
		return
	# 复活后位置是突变的，用 snap 上报，让各端直接跳过去而不是滑过去
	if is_local() and NetManager.is_session_active():
		_send_snap()


## 发送一次"位置突变"快照（复活、传送用）。
## 各端收到后直接跳过去，不做插值 —— 否则角色会从旧位置"飘"到新位置。
func _send_snap() -> void:
	if player == null or not is_instance_valid(player):
		return
	if not NetManager.is_session_active():
		return
	var state := int(CombatState.State.IDLE)
	var sm := player.get_node_or_null("StateMachine")
	if sm != null:
		state = int(sm.call("get_state"))
	send_count += 1
	if multiplayer.is_server():
		NetManager.broadcast_local_player_state(player.peer_id,
			player.global_position, player.global_rotation.y, state, true)
	else:
		NetManager._rpc_client_state.rpc_id(1, player.global_position,
			player.global_rotation.y, state, true)


# ============================================================
# 动画表现同步
# ============================================================

## 本地玩家开始一个动作（攻击 / 闪避）时，把他的动画名广播出去。
##
## 只发"动画名 + 开始时刻"，不发进度 —— 收到方按自己的时钟算出
## 应该播到哪一帧。这样带宽是常量（每次动作一条消息），
## 且不受网络抖动影响（晚到的消息会直接跳到正确进度，
## 而不是从头开始播）。
func _on_attack_started(attacker: Node, attack_id: StringName) -> void:
	if not is_local() or attacker != player:
		return
	if not NetManager.is_session_active():
		return
	# 动画广播走 NetManager 中转 —— 原因见 net_manager.gd 里
	# "为什么转发 RPC 挂在 NetManager 上"那段说明
	if multiplayer.is_server():
		NetManager.broadcast_local_player_anim(player.peer_id, attack_id, _now())
	else:
		NetManager._rpc_client_anim.rpc_id(1, attack_id, _now())


## 把远端动画播放到"此刻应该处于的进度"。
## 由 PlayerSync._rpc_play_anim 在**对应的那个远端节点**上调用。
func _apply_remote_anim(anim: StringName, started_at: float) -> void:
	if anim.is_empty():
		return
	var drv := player.get_node_or_null("AnimationDriver")
	if drv == null:
		return
	# 已经过去多久
	var elapsed := _now() - started_at
	if elapsed < 0.0:
		elapsed = 0.0
	drv.call("play_at", anim, elapsed)


## 本地时钟（秒）。用引擎时间而不是系统时间 ——
## 后者在网络两端可能相差几秒，会导致动画进度完全错乱。
func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
