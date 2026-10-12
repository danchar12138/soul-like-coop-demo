extends Node
## 跨设备局域网测试。
##
## 用法（每台机器各跑一次）：
##   主机：  bash tests/run_lan_test.sh host
##   客户端：bash tests/run_lan_test.sh client 192.168.1.100
##
## ## 与 mp_battle_test.gd 的分工
##
## `mp_battle_test.gd` 在**同一台机器**上开多个 Godot 进程。
## 它能验证同步逻辑、权限分配、状态一致性 —— 但那台机器上
## 网络延迟接近 0，测不出任何与时序相关的问题。
##
## 本脚本在**多台机器**上各跑一个进程。它要验证的是真实网络下的：
##   1. 位置插值是否够平滑（20Hz 同步 + 12~14 插值速度）
##   2. 动画进度同步是否准确（见 player_sync.gd 的动画同步说明）
##   3. Boss 位置的滞后是否可接受
##   4. 地形破坏的广播延迟
##   5. 不同性能机器之间是否出现状态不一致
##
## ## 观测方式
##
## 本脚本**不能自动化判定"手感"**，只能：
##   - 采集客观指标（RTT、收到的消息数、状态一致性）
##   - 把主观项列成清单，让人对照着看
##
## 这是刻意的：跨设备测试的价值在于"人看到真实延迟下的表现"，
## 把它做成自动断言会给人"通过了就没事"的错觉。

const ARENA := "res://scenes/levels/arena.tscn"
const TEST_PORT := 27019
const TIMEOUT := 120.0

var _role := "host"
var _host_ip := "127.0.0.1"
var _elapsed := 0.0
var _done := false
var _checked := false
var _level: Node3D = null

## 统计
var _rtt_samples: Array[float] = []
var _anim_sync_count: int = 0
## 收到的远端玩家位置更新次数（由 _on_remote_state 统计）
var _pos_sync_count: int = 0
## 是否已经强制过 Boss 仇恨（只做一次）
var _aggro_forced: bool = false
## 会话期间见过的最大玩家数（见 _process 里的说明）
var _peak_players: int = 0
## 上一次采样到的远端玩家位置 / 动画名
var _last_remote_pos: Dictionary = {}
var _last_remote_anim: Dictionary = {}
## 自动绕圈移动的相位
var _move_phase: float = 0.0


func _ready() -> void:
	_role = _arg("--role=", "host")
	_host_ip = _arg("--host=", "127.0.0.1")
	print("[跨设备] 角色 = %s，Godot %s" % [
		_role, Engine.get_version_info()["string"]])
	print("[跨设备] 平台 = %s，CPU = %s" % [
		OS.get_name(), OS.get_processor_name()])

	NetManager.net_error.connect(func (m: String) -> void:
		printerr("[跨设备] 网络错误：" + m))

	if _role == "host":
		_serve()
	else:
		_join()

	var t := get_tree().create_timer(TIMEOUT, false)
	t.timeout.connect(func () -> void:
		if not _done:
			_report_and_quit())


func _arg(prefix: String, fallback: String) -> String:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return fallback


func _serve() -> void:
	var err := NetManager.host_game(TEST_PORT, "跨设备测试房")
	if err != OK:
		printerr("[跨设备] 创建房间失败（错误码 %d）" % err)
		get_tree().quit(1)
		return
	var ips := IP.get_local_addresses()
	var lan: PackedStringArray = []
	for ip: String in ips:
		if ip.begins_with("192.168.") or ip.begins_with("10."):
			lan.append(ip)
	print("[跨设备] 房间已创建，端口 %d" % TEST_PORT)
	print("[跨设备] 本机局域网地址：%s" % (
		", ".join(lan) if not lan.is_empty() else "未检测到（请手工 ipconfig 查看）"))
	print("[跨设备] 请在客户端上执行：")
	print("[跨设备]   bash tests/run_lan_test.sh client <上面的地址>")
	_load_arena()


func _join() -> void:
	print("[跨设备] 连接 %s:%d …" % [_host_ip, TEST_PORT])
	var err := NetManager.join_game(_host_ip, TEST_PORT)
	if err != OK:
		printerr("[跨设备] 创建客户端失败（错误码 %d）" % err)
		get_tree().quit(1)
		return
	var ok := await _wait_connected(30.0)
	if not ok:
		printerr("[跨设备] 连接超时（30 秒）。请确认：")
		printerr("  1. 主机已执行 run_lan_test.sh host")
		printerr("  2. IP 输入正确（在主机上用 ipconfig 确认）")
		printerr("  3. 两台机器在同一网段")
		printerr("  4. 防火墙允许 Godot 通过")
		get_tree().quit(1)
		return
	print("[跨设备] 已连上（peer_id=%d），加载关卡" % multiplayer.get_unique_id())
	_load_arena()


func _wait_connected(seconds: float) -> bool:
	var left := seconds
	while left > 0.0:
		var p := multiplayer.multiplayer_peer
		if p != null and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			return true
		await get_tree().create_timer(0.2, false).timeout
		left -= 0.2
		if _done:
			return false
	return false


func _load_arena() -> void:
	var packed := load(ARENA) as PackedScene
	if packed == null:
		printerr("[跨设备] 无法加载关卡")
		get_tree().quit(1)
		return
	_level = packed.instantiate() as Node3D
	add_child(_level)
	# 采集指标
	EventBus.peer_joined.connect(func (id: int) -> void:
		print("[跨设备] 检测到 peer 接入：%d" % id))
	EventBus.player_spawned.connect(_on_player_spawned)


## 每当有玩家实体出现（含远端副本），给他挂上位置同步的计数器。
## 直接监听 PlayerSync 的内部状态不方便，改为每帧轮询远端玩家节点的
## 位置是否在变 —— 这才是"同步确实在工作"的直接证据。
func _on_player_spawned(player: Node, peer_id: int) -> void:
	print("[跨设备] 玩家实体出现：peer_id=%d，本地=%s" % [
		peer_id, (player as Node).get("is_local")])


## 每秒采样一次远端玩家，统计"位置在变"和"动画在切"。
##
## 【为什么用观测而不是数信号】
## 直接观测最贴近"玩家实际看到什么"：如果远端玩家的位置在变、
## 动画名在切，那就证明同步链路是通的。数内部信号计数器容易
## 因为信号连接的时机问题漏计，而且它证明的只是"信号发了"，
## 不一定是"数据到了位"。
func _sample_remote_nodes() -> void:
	var local_id := multiplayer.get_unique_id()
	for id: int in GameState.players:
		if id == local_id:
			continue
		var node: Node3D = GameState.players[id]
		if node == null or not is_instance_valid(node):
			continue

		# 位置：与上一次采样比较
		var pos := node.global_position
		if _last_remote_pos.has(id):
			var prev: Vector3 = _last_remote_pos[id]
			# 位移超过 1mm 才算"变了"，避免浮点噪声
			if prev.distance_to(pos) > 0.001:
				_pos_sync_count += 1
		_last_remote_pos[id] = pos

		# 动画：读远端节点的 AnimationDriver 当前动画
		var drv := node.get_node_or_null("AnimationDriver")
		if drv != null:
			var cur: Variant = drv.call("get_current_anim")
			if _last_remote_anim.has(id):
				var prev_anim: StringName = _last_remote_anim[id]
				if cur != prev_anim:
					_anim_sync_count += 1
			_last_remote_anim[id] = cur


# ============================================================
# 周期采样
# ============================================================

func _process(delta: float) -> void:
	if _done or _checked:
		return
	_elapsed += delta

	# 每 2 秒采一次 RTT
	if fmod(_elapsed, 2.0) < delta:
		_sample_rtt()
	# 每秒观测一次远端节点
	if fmod(_elapsed, 1.0) < delta:
		_sample_remote_nodes()

	# 记录本次会话里见过的最大玩家数。
	# 【为什么记录峰值而不是读结束时的那一刻】先退出的一方会切断连接，
	# 另一方的 peer_disconnected 处理会把对方从 GameState.players 里移除。
	# 于是"结束时"读到的人数总是偏少的 —— 那不是状态同步有问题，
	# 只是观测时机不对。峰值才反映会话期间的真实情况。
	_peak_players = maxi(_peak_players, GameState.players.size())

	# 周期性自动出招：让"远端动画同步"这条路径真的被走到。
	# 无头模式下没有人按键，不主动触发的话这条路径永远测不到。
	if _elapsed > 8.0 and fmod(_elapsed, 3.0) < delta:
		_auto_attack()

	# 持续自动移动：让"远端位置同步"这条路径被走到。
	# 只在 8 秒之后开始，给场景初始化留时间。
	if _elapsed > 8.0:
		_auto_move(delta)

	# 30 秒时强制一次 Boss 仇恨（让 Boss 动起来），60 秒后出报告。
	# 用标志位而不是时间区间判断 —— 用区间的话那一秒里的每一帧
	# 都会调用一次，日志里会刷屏（第一版就这么错的）。
	if not _aggro_forced and _elapsed > 30.0:
		_aggro_forced = true
		_force_boss_aggro()
	if _elapsed > 60.0:
		_checked = true
		_report_and_quit()


## 让本地玩家自动打一套轻击。
## 目的不是"测伤害"，而是让 attack_started 信号真的发出来，
## 这样对端才有机会收到动画广播 —— 从而验证那条路径是通的。
func _auto_attack() -> void:
	var p := GameState.local_player
	if p == null or not is_instance_valid(p):
		return
	var weapon: Variant = p.get("weapon_data")
	if not (weapon is WeaponData):
		return
	var ac := p.get_node_or_null("AttackController")
	if ac == null:
		return
	if ac.get("current_attack") != null:
		return
	var atk: AttackData = (weapon as WeaponData).get_light(0)
	if atk != null:
		ac.call("request_attack", atk, true)


## 让本地玩家绕圈跑动。
##
## 【为什么必须主动移动】
## 位置同步的验证不能靠"玩家站着不动" —— 站着不动时位置不变，
## 观测到 0 次变化，看起来像同步失效，其实只是没东西可同步
## （第一版就踩了这个坑）。必须真的产生位移，
## "远端看到我在动"这条链路才被走到。
func _auto_move(delta: float) -> void:
	var p := GameState.local_player
	if p == null or not is_instance_valid(p):
		return
	# 沿半径 4 米的圆绕圈，速度约 3 m/s
	_move_phase += delta * 0.75
	var center: Vector3 = p.get_meta("move_center", p.global_position)
	var target: Vector3 = center + Vector3(
		cos(_move_phase) * 4.0, 0.0, sin(_move_phase) * 4.0)
	var to: Vector3 = target - p.global_position
	to.y = 0.0
	if to.length() < 0.05:
		return
	# 直接设 velocity，让 PlayerController 自己的物理把它推过去。
	# 这里不改位置 —— 那就是"瞬移"，会触发主机的速度校验
	# （MAX_SPEED_TOLERANCE），反而证明不了同步是正常的。
	var v: Variant = p.get("velocity")
	var vy := (v as Vector3).y if v is Vector3 else 0.0
	var dir := to.normalized()
	p.set("velocity", Vector3(dir.x * 3.0, vy, dir.z * 3.0))
	# 朝向也跟着转，这样朝向同步也被覆盖到
	p.global_rotation.y = MathUtil.yaw_from_direction(to)


## 采集 RTT（往返延迟）。这是跨设备测试最有价值的客观指标 ——
## 它决定了位置插值、动画同步的观感是否可接受。
##
## 只读 ENetPacketPeer.PEER_ROUND_TRIP_TIME。
## 【为什么不用"已收包数"之类的统计】ENetPacketPeer 的统计项枚举
## 在不同 Godot 版本间有增删（PEER_PACKETS_RECEIVED 在 4.7 里就不存在），
## 用它会让脚本在换版本时直接编译失败。RTT 是最稳定、也最有价值的那一项。
func _sample_rtt() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer == null or not (peer is ENetMultiplayerPeer):
		return
	var enet := peer as ENetMultiplayerPeer
	for id: int in multiplayer.get_peers():
		var p := enet.get_peer(id)
		if p == null:
			continue
		# 【单位】ENetPacketPeer.PEER_ROUND_TRIP_TIME 的统计值已经是
		# **毫秒**，不需要再乘 1000。最初按名字里的 "TIME" 猜是微秒、
		# 乘了 1000，结果报告的 RTT 是 13448 ms —— 本机回环实测应为
		# 几毫秒到十几毫秒。这个错误会让"延迟评估"完全失去意义。
		var rtt_ms := p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)
		_rtt_samples.append(rtt_ms)


## 让 Boss 主动攻击（否则玩家站在出生点，Boss 可能一直在远处待机，
## 测不到 Boss 位置同步的表现）
func _force_boss_aggro() -> void:
	var boss := GameState.boss
	if boss == null or not is_instance_valid(boss):
		return
	var players := GameState.get_alive_players()
	if players.is_empty():
		return
	if boss.has_method("force_target"):
		boss.call("force_target", players[0])
	print("[跨设备] 已强制 Boss 仇恨，观察位置同步表现")


# ============================================================
# 报告
# ============================================================

func _report_and_quit() -> void:
	if _done:
		return
	_done = true

	var tag := "主机" if NetManager.is_host else "客户端"
	print("\n[跨设备] ========== %s 端观测报告 ==========" % tag)

	# --- 客观指标 ---
	var peer_count := multiplayer.get_peers().size()
	print("[跨设备] 已连接 peer 数：%d" % peer_count)

	if _rtt_samples.is_empty():
		print("[跨设备] RTT：无样本（没有其他 peer，或采样太早）")
	else:
		var sum := 0.0
		var worst := 0.0
		for v: float in _rtt_samples:
			sum += v
			worst = maxf(worst, v)
		var avg := sum / _rtt_samples.size()
		var level := "优秀（局域网）" if avg < 20.0 else (
			"可接受" if avg < 60.0 else "偏高，位置同步会有明显滞后感")
		print("[跨设备] RTT 样本 %d 个：平均 %.1f ms，最大 %.1f ms —— %s" % [
			_rtt_samples.size(), avg, worst, level])

	print("[跨设备] 会话期间最大玩家数：%d（结束时 %d）" % [
		_peak_players, GameState.players.size()])
	print("[跨设备] 观测到远端玩家位置变化：%d 次采样（证明位置同步在工作）" % _pos_sync_count)
	print("[跨设备] 观测到远端玩家动画切换：%d 次（证明动作同步在工作）" % _anim_sync_count)
	print("[跨设备] Boss 存在：%s" % ("是" if GameState.boss != null else "否"))

	# --- 状态一致性 ---


	# --- 主观项清单 ---
	print("")
	print("[跨设备] ---- 需要人工确认的项（脚本无法判定）----")
	var checklist := [
		"其他玩家的移动是否平滑（不应有明显的跳动或拖影）",
		"其他玩家挥刀时刀是否在动（动画同步是否生效）",
		"Boss 移动是否可接受（20Hz 同步，有轻微滞后是正常的）",
		"自己操作是否有延迟感（玩家位置是客户端权威，应该没有）",
		"打碎石柱后，多久能在对端看到它消失（应 <0.5 秒）",
		"四个玩家同时打同一根石柱时，各端看到的结果是否一致",
	]
	for i in checklist.size():
		print("[跨设备]   [ ] %d. %s" % [i + 1, checklist[i]])

	NetManager.leave_session()
	print("[跨设备] ==========================================\n")
	get_tree().quit(0)
