extends Node
## 联机管理器（Autoload 单例）—— 主机/客户端模型。
##
## 架构决策（详见 docs/架构说明.md）：
##   使用 Godot 原生高层多人 API（ENetMultiplayerPeer + MultiplayerSpawner
##   + MultiplayerSynchronizer），不引入第三方框架。
##
## 权限模型：
##   - 主机 = peer_id 1 = 权威端。所有伤害结算、Boss 状态、地形破坏
##     都由主机决定，然后广播。
##   - 客户端对自己的角色有输入权限（set_multiplayer_authority(peer_id)），
##     位置由客户端上报、主机校验，避免"瞬移作弊"和橡皮筋。
##   - 客户端**不**自行扣 Boss 血。它只发送"我打中了"的请求，
##     由主机验证后再广播结果。这样杜绝重复伤害与各自显示不同结果。
##
## 首版范围：局域网创建/加入房间，最多 4 人。不做公网匹配。

const PORT := 27015
const MAX_PLAYERS := 4
const PROTOCOL_VERSION := 1

## 会话状态
var is_host: bool = false
var session_active: bool = false
## 房间名（主机设置）
var room_name: String = "本地测试房"
## 本机玩家名
var player_name: String = "玩家"

## 已连接玩家信息：peer_id -> {name: String, ready: bool}
##
## `ready` 的含义是"该玩家已经加载完关卡、可以接收世界状态了"。
## 主机在分发 Boss/地形状态前必须等所有相关玩家 ready，否则 RPC 会
## 因对端节点路径还不存在而被丢弃（刷一堆 "Node not found"）。
var peer_info: Dictionary = {}

## 出生点（主机分配，避免全部叠在一点）
const SPAWN_POINTS := [
	Vector3(-2.0, 1.0, 4.0),
	Vector3(2.0, 1.0, 4.0),
	Vector3(-2.0, 1.0, 6.0),
	Vector3(2.0, 1.0, 6.0),
]

signal session_started(is_host: bool)
signal session_ended()
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal net_error(message: String)
signal info_updated()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	# 玩家名：默认取系统用户名，避免四台机器同名分不清
	player_name = OS.get_environment("USERNAME")
	if player_name.is_empty():
		player_name = "玩家"


# ============================================================
# 会话控制
# ============================================================

## 主机：创建房间
func host_game(port: int = PORT, name: String = "本地测试房") -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		var msg := "创建房间失败（端口 %d 可能被占用），错误码 %d" % [port, err]
		net_error.emit(msg)
		EventBus.net_error.emit(msg)
		return err

	multiplayer.multiplayer_peer = peer
	is_host = true
	session_active = true
	room_name = name
	peer_info[1] = {"name": player_name, "ready": true}

	_emit_session_started()
	return OK


## 客户端：加入房间
func join_game(address: String, port: int = PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		var msg := "连接失败：无法创建客户端（地址 %s:%d，错误码 %d）" % [address, port, err]
		net_error.emit(msg)
		EventBus.net_error.emit(msg)
		return err

	multiplayer.multiplayer_peer = peer
	is_host = false
	session_active = true
	return OK


## 退出会话，回到离线模式
func leave_session() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	is_host = false
	session_active = false
	peer_info.clear()
	session_ended.emit()
	EventBus.session_ended.emit()
	info_updated.emit()


func is_session_active() -> bool:
	return session_active and multiplayer.multiplayer_peer != null


## 本地玩家对应的 peer id（离线时为 1）
func get_local_peer_id() -> int:
	if not is_session_active():
		return 1
	return multiplayer.get_unique_id()


## 判断某个节点是否由本机控制
func has_authority_over(node: Node) -> bool:
	if not is_session_active():
		return true
	return node.is_multiplayer_authority()


## 是否为权威端（离线时视为权威）
func is_authority() -> bool:
	if not is_session_active():
		return true
	return multiplayer.is_server()


## 取该 peer 的出生点
func get_spawn_position(peer_id: int) -> Vector3:
	var ids := get_sorted_peer_ids()
	var idx := ids.find(peer_id)
	if idx < 0:
		idx = 0
	return SPAWN_POINTS[idx % SPAWN_POINTS.size()]


func get_sorted_peer_ids() -> Array[int]:
	var ids: Array[int] = []
	for id: int in peer_info:
		ids.append(id)
	ids.sort()
	if ids.is_empty():
		ids.append(1)
	return ids


func get_peer_display_name(peer_id: int) -> String:
	var info: Dictionary = peer_info.get(peer_id, {})
	return info.get("name", "玩家%d" % peer_id)


# ============================================================
# 玩家状态中转
# ============================================================
#
# ## 为什么转发 RPC 挂在 NetManager 上，而不是挂在玩家自己的 PlayerSync 上
#
# 这是一个真实踩过的架构错误，值得说明白。
#
# Godot 的 RPC 是**按节点路径寻址**的：`some_node.rpc(...)` 会在**每一个**
# 对端上找到**同一条路径**的那个节点，然后只在那一个节点上执行。
#
# 最初 `_rpc_apply_state` 定义在 `PlayerSync` 上，路径是
# `/root/.../Players/Player_1/PlayerSync`。于是主机转发 A 玩家的位置时，
# 消息只会在各端的 **Player_1/PlayerSync** 上执行；而这个函数的第一句是
# `if node == player: return`（"不要处理自己"），结果**每一条消息都被
# 自己拒绝掉了** —— 位置同步完全失效，而且不报任何错。
#
# 正确做法：中转 RPC 挂在一个**全局唯一、路径两端完全一致**的节点上，
# 用参数里的 `peer_id` 说明"这条消息是关于谁的"，再由它分发到
# 对应的玩家节点。`NetManager` 是 Autoload，路径恒为 `/root/NetManager`，
# 正是合适的载体。

## 客户端上报自己的状态（主机是唯一的接收者）
@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_client_state(pos: Vector3, yaw: float, state: int, snap: bool) -> void:
	if OS.get_environment("SYNC_TRACE") == "1":
		print("[链路] 本机=%d 收到客户端上报 from=%d" % [
			multiplayer.get_unique_id(), multiplayer.get_remote_sender_id()])
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var node := GameState.get_player(sender)
	if node == null or not is_instance_valid(node):
		return

	# 位置校验：防止瞬移作弊（宽松阈值，宁可漏报不要误报 ——
	# 误报会让正常玩家的位置同步被反复打断）
	var prev: Vector3 = node.get_meta("net_pos", node.global_position)
	var allowed := PlayerSync.MAX_SPEED_TOLERANCE * 0.05 * 8.0
	if not snap and prev.distance_to(pos) > allowed:
		push_warning("[同步] 玩家 %d 位置跳变过大（%.1fm > %.1fm），已忽略" % [
			sender, prev.distance_to(pos), allowed])
		return
	node.set_meta("net_pos", pos)

	_broadcast_player_state(sender, pos, yaw, state, snap)


## 主机广播所有玩家的状态。主机自己的状态也走这里 ——
## 主机对自己调用 `rpc()` 时，Godot 会因为方法标了 `call_remote`
## 而跳过本机，所以它天然只发给客户端，不需要额外排除。
func broadcast_local_player_state(peer_id: int, pos: Vector3, yaw: float,
		state: int, snap: bool) -> void:
	if not multiplayer.is_server():
		return
	_broadcast_player_state(peer_id, pos, yaw, state, snap)


func _broadcast_player_state(peer_id: int, pos: Vector3, yaw: float,
		state: int, snap: bool) -> void:
	if OS.get_environment("SYNC_TRACE") == "1":
		print("[链路] 本机=%d 广播 player=%d 给 peers=%s" % [
			multiplayer.get_unique_id(), peer_id, str(multiplayer.get_peers())])
	_rpc_apply_player_state.rpc(peer_id, pos, yaw, state, snap)


## 应用到对应的玩家节点（所有端都要执行，**包括主机自己**）
##
## 【为什么是 `call_local` 而不是 `call_remote`】
## 主机既是转发者，也是玩家之一 —— 它的 AI 需要知道别人的实际位置，
## 而且它自己的画面上也要能看到队友在动。
##
## 用 `call_remote`（不含本机）的后果：主机把客户端的位置转发给了
## 所有客户端，**唯独没有更新自己那份副本**。症状很隐蔽 ——
## 客户端能看到主机在动，但主机看到的客户端永远停在出生点，
## 而且 Boss 会一直对着一个"幽灵位置"追。
##
## `call_local` 让主机自己也在收到广播时执行一次。本机角色由
## 函数内部 `node.is_local` 的判断挡住，不会被覆盖。
@rpc("authority", "call_local", "unreliable_ordered")
func _rpc_apply_player_state(peer_id: int, pos: Vector3, yaw: float,
		state: int, snap: bool) -> void:
	if OS.get_environment("SYNC_TRACE") == "1":
		print("[链路] 本机=%d 收到转发 player=%d from=%d" % [
			multiplayer.get_unique_id(), peer_id,
			multiplayer.get_remote_sender_id()])
	# 取节点时先经过 Variant，避免对已释放对象做类型化赋值时报错
	# （与 game_state.gd 的 get_alive_players 同理）
	var raw: Variant = GameState.players.get(peer_id)
	if not is_instance_valid(raw):
		return
	var node := raw as Node3D
	if node == null:
		return
	var sync := node.get_node_or_null("PlayerSync")
	if sync == null:
		return
	# 【必须调方法，不能 get("is_local")】
	# `is_local` 在 PlayerSync 上是**方法**（`func is_local()`），
	# 不是属性。`Object.get("is_local")` 在找不到同名属性时会返回
	# 一个方法引用（打印出来是 `Node(PlayerSync)::is_local`），
	# 它 `== true` 恒为 false —— 于是这个"不处理自己"的保护**完全失效**，
	# 本机角色会被远端数据反复覆盖。
	#
	# 真正的 `is_local` 属性在 PlayerController 上（`var is_local: bool`），
	# 所以这里也可以直接读 `node.is_local`。两者等价，读 Controller 的
	# 那个更直观。
	if node.get("is_local") == true:
		return
	sync.set("recv_count", int(sync.get("recv_count")) + 1)
	sync.set("_hist_pos", pos)
	sync.set("_hist_time", Time.get_ticks_msec() / 1000.0)
	sync.call("receive_state", pos, yaw, state, snap)
	sync.set("apply_count", int(sync.get("apply_count")) + 1)


## 客户端上报动画（与位置同理，也走 NetManager 中转）
@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_anim(attack_id: StringName, started_at: float) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	_rpc_apply_player_anim.rpc(sender, attack_id, started_at)


func broadcast_local_player_anim(peer_id: int, attack_id: StringName,
		started_at: float) -> void:
	if not multiplayer.is_server():
		return
	_rpc_apply_player_anim.rpc(peer_id, attack_id, started_at)


## 同 _rpc_apply_player_state：用 call_local，让主机也能看到
## 远端玩家的动作（否则主机画面上队友永远在滑步）
@rpc("authority", "call_local", "reliable")
func _rpc_apply_player_anim(peer_id: int, attack_id: StringName, started_at: float) -> void:
	var node := GameState.get_player(peer_id)
	if node == null or not is_instance_valid(node):
		return
	var sync := node.get_node_or_null("PlayerSync")
	if sync == null:
		return
	sync.call("_apply_remote_anim", attack_id, started_at)


## 标记某个玩家已加载完关卡、可以接收世界状态。
## 由 LevelManager._rpc_client_ready 调用。
func mark_client_ready(peer_id: int) -> void:
	if not peer_info.has(peer_id):
		peer_info[peer_id] = {"name": "玩家%d" % peer_id, "ready": true}
	else:
		(peer_info[peer_id] as Dictionary)["ready"] = true
	info_updated.emit()


## 是否至少有一个客户端已经加载完关卡。
##
## 【用途】主机在发世界状态（敌人位置、Boss 数值、地形破坏）之前
## 必须先查这个。否则 RPC 会因为对端还没有对应节点而报
## "Node not found ... Requested node was not found"，
## 消息被丢弃 —— 新玩家会看到一个不动的 Boss。更糟的是日志会被
## 刷满，真正的问题被埋掉。
func has_ready_clients() -> bool:
	for id: int in peer_info:
		if id == 1:
			continue
		if (peer_info[id] as Dictionary).get("ready", false):
			return true
	return false


## 已就绪的客户端 id 列表
func get_ready_client_ids() -> Array[int]:
	var out: Array[int] = []
	for id: int in peer_info:
		if id == 1:
			continue
		if (peer_info[id] as Dictionary).get("ready", false):
			out.append(id)
	out.sort()
	return out


# ============================================================
# 网络事件
# ============================================================

func _on_peer_connected(id: int) -> void:
	if is_host:
		# 主机侧：登记新玩家并广播完整名单
		peer_info[id] = {"name": "玩家%d" % id, "ready": false}
		_broadcast_peer_list()
	peer_joined.emit(id)
	EventBus.peer_joined.emit(id)
	info_updated.emit()


func _on_peer_disconnected(id: int) -> void:
	peer_info.erase(id)
	if is_host:
		_broadcast_peer_list()
	peer_left.emit(id)
	EventBus.peer_left.emit(id)
	# 清掉该玩家的场景节点
	var p: Node = GameState.players.get(id)
	if p != null and is_instance_valid(p):
		p.queue_free()
	GameState.unregister_player(id)
	info_updated.emit()


func _on_connected_to_server() -> void:
	_emit_session_started()
	# 客户端连上后把自己的名字报给主机
	_rpc_register_player.rpc_id(1, player_name)
	info_updated.emit()


func _on_connection_failed() -> void:
	session_active = false
	var msg := "连接失败：请确认主机 IP 与端口，且主机已开启房间。"
	net_error.emit(msg)
	EventBus.net_error.emit(msg)


func _on_server_disconnected() -> void:
	session_active = false
	multiplayer.multiplayer_peer = null
	var msg := "与主机断开连接。"
	net_error.emit(msg)
	EventBus.net_error.emit(msg)
	session_ended.emit()
	EventBus.session_ended.emit()


func _emit_session_started() -> void:
	session_started.emit(is_host)
	EventBus.session_started.emit(is_host)
	info_updated.emit()


# ============================================================
# RPC
# ============================================================

@rpc("any_peer", "call_remote", "reliable")
func _rpc_register_player(p_name: String) -> void:
	if not is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	peer_info[sender] = {"name": p_name, "ready": true}
	_broadcast_peer_list()


func _broadcast_peer_list() -> void:
	if not is_host:
		return
	_rpc_sync_peer_list.rpc(peer_info)


@rpc("authority", "call_remote", "reliable")
func _rpc_sync_peer_list(list: Dictionary) -> void:
	peer_info = list
	info_updated.emit()


func _to_string() -> String:
	if not is_session_active():
		return "[NetManager 离线]"
	if is_host:
		return "[NetManager 主机 %d 人]" % peer_info.size()
	return "[NetManager 客户端 -> 主机]"
