extends Node
## 联机同步调试工具（无头运行）。
##
## 用法：
##   godot --headless res://tests/sync_debug.tscn -- --role=host
##   godot --headless res://tests/sync_debug.tscn -- --role=client --host=127.0.0.1
##
## 用途：定位"远端玩家位置/动画不同步"这类问题。
## 它不做断言，只**尽可能多地把链路各环节的实际数值打出来** ——
## 定位同步问题时，最缺的从来不是"哪个断言失败了"，
## 而是"消息到底走到哪一步断了"。
##
## 测试的六个环节（对应 PlayerSync 的完整链路）：
##   ① 本机是否在建会话、是否在报告状态
##   ② 主机的 _rpc_report_state 是否收到并转发了
##   ③ 各端的 _rpc_apply_state 是否收到
##   ④ receive_state 是否写入了插值目标
##   ⑤ 插值是否在推进远端节点的位置
##   ⑥ 远端节点在观测方看到的实际位移

const ARENA := "res://scenes/levels/arena.tscn"
const TEST_PORT := 27020

var _role := "host"
var _host_ip := "127.0.0.1"
var _elapsed := 0.0
var _done := false
var _level: Node3D = null
var _report_tick := 0


func _ready() -> void:
	_role = _arg("--role=", "host")
	_host_ip = _arg("--host=", "127.0.0.1")
	print("[同步诊断] 角色 = %s" % _role)

	if _role == "host":
		NetManager.host_game(TEST_PORT, "同步诊断房")
		print("[同步诊断] 已建房间，端口 %d" % TEST_PORT)
		_load_arena()
	else:
		await get_tree().create_timer(2.0, false).timeout
		NetManager.join_game(_host_ip, TEST_PORT)
		var ok := await _wait_connected(20.0)
		if not ok:
			printerr("[同步诊断] 连接超时")
			get_tree().quit(1)
			return
		print("[同步诊断] 已连接（peer_id=%d）" % multiplayer.get_unique_id())
		_load_arena()

	var t := get_tree().create_timer(40.0, false)
	t.timeout.connect(func () -> void:
		if not _done:
			_finish())


func _arg(prefix: String, fallback: String) -> String:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return fallback


func _wait_connected(seconds: float) -> bool:
	var left := seconds
	while left > 0.0:
		var p := multiplayer.multiplayer_peer
		if p != null and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			return true
		await get_tree().create_timer(0.2, false).timeout
		left -= 0.2
	return false


func _load_arena() -> void:
	var packed := load(ARENA) as PackedScene
	_level = packed.instantiate() as Node3D
	add_child(_level)


func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta

	# 8 秒后开始让本地玩家动起来（位置同步需要真的产生位移）
	if _elapsed > 8.0:
		_auto_move(delta)

	# 每 4 秒打一份链路快照
	if _elapsed > 6.0 and int(_elapsed / 4.0) > _report_tick:
		_report_tick = int(_elapsed / 4.0)
		_dump()

	if _elapsed > 30.0:
		_finish()


func _auto_move(delta: float) -> void:
	var p := GameState.local_player
	if p == null or not is_instance_valid(p):
		return
	_move_phase += delta * 0.35
	var center: Vector3 = p.get_meta("move_center", p.global_position)
	var target: Vector3 = center + Vector3(
		cos(_move_phase) * 3.0, 0.0, sin(_move_phase) * 3.0)
	var to: Vector3 = target - p.global_position
	to.y = 0.0
	if to.length() < 0.05:
		return
	var v: Variant = p.get("velocity")
	var vy := (v as Vector3).y if v is Vector3 else 0.0
	var dir := to.normalized()
	p.set("velocity", Vector3(dir.x * 2.0, vy, dir.z * 2.0))

var _move_phase: float = 0.0


## 打印链路各环节的实际状态
func _dump() -> void:
	var my_id := multiplayer.get_unique_id()
	print("\n[同步诊断] ── t=%.1fs 链路快照（本机 peer_id=%d）──" % [_elapsed, my_id])

	# ① 会话与网络
	var peer := multiplayer.multiplayer_peer
	print("[同步诊断] ① 会话：active=%s，peers=%s" % [
		NetManager.is_session_active(), str(multiplayer.get_peers())])

	# ② 已注册的玩家
	var ids: Array = GameState.players.keys()
	ids.sort()
	print("[同步诊断] ② GameState.players = %s（本机 = %d）" % [str(ids), my_id])

	# ③ 逐节点：本地/远端、权威、插值状态、位置
	for id: int in ids:
		var raw: Variant = GameState.players[id]
		if not is_instance_valid(raw):
			print("[同步诊断]    peer %d：节点已失效" % id)
			continue
		var node := raw as Node3D
		if node == null:
			continue
		var is_local: Variant = node.get("is_local")
		var auth := node.get_multiplayer_authority()
		var sync := node.get_node_or_null("PlayerSync")
		var line := "[同步诊断]    peer %-10d 本地=%-5s 权威=%-10d 位置=%s" % [
			id, str(is_local), auth, _fmt(node.global_position)]
		if sync != null:
			var has: Variant = sync.get("_has_net_state")
			var npos: Variant = sync.get("_net_position")
			var hist: Variant = sync.get("_hist_pos")
			var hist_t: Variant = sync.get("_hist_time")
			line += "\n[同步诊断]                 插值: has=%s net_pos=%s" % [
				str(has), _fmt(npos as Vector3) if npos is Vector3 else "—"]
			line += "\n[同步诊断]                 最后收到: %s 距离现在 %.2fs，当时位置 %s" % [
				"有" if hist is Vector3 else "无",
				_elapsed - (hist_t as float) if hist is float else -1.0,
				_fmt(hist as Vector3) if hist is Vector3 else "—"]
			# 差值：远端节点当前位置 vs 收到的目标位置
			if npos is Vector3:
				var d := node.global_position.distance_to(npos as Vector3)
				line += "（当前位置与目标相差 %.3f m）" % d
		print(line)

	# ④ 逐个 PlayerSync 的自报统计
	print("[同步诊断] ④ 各 PlayerSync 的上报计数：")
	for id: int in ids:
		var raw: Variant = GameState.players[id]
		if not is_instance_valid(raw):
			continue
		var sync := (raw as Node).get_node_or_null("PlayerSync")
		if sync == null:
			continue
		print("[同步诊断]    peer %-10d 发送=%d 接收=%d 应用=%d" % [
			id, int(sync.get("send_count")), int(sync.get("recv_count")),
			int(sync.get("apply_count"))])


func _fmt(v: Vector3) -> String:
	return "(%.2f,%.2f,%.2f)" % [v.x, v.y, v.z]


func _finish() -> void:
	if _done:
		return
	_done = true
	NetManager.leave_session()
	print("\n[同步诊断] 结束")
	get_tree().quit(0)
