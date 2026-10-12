extends Node
## 地形破坏管理器（Autoload 单例）。
##
## 职责：
##   1. 注册场景中所有可破坏结构，维护「结构 -> 若干 Piece」的映射
##   2. 提供统一的破坏入口，并按权限分流（权威端结算 / 客户端上报）
##   3. 结构整体摧毁后触发玩法事件（打开通路、崩塌改变地形）
##   4. 记录破坏状态，供联机同步与检查点恢复
##
## 联机权限（任务要求 6 的技术限制）：
##   权威端确认破坏结果，客户端不得自行决定某一地形是否已摧毁。
##   客户端调用 request_damage() -> RPC 到主机 -> 主机结算 -> 广播。
##   主机自己直接调用 apply_damage_authoritative()。
##
## 数据结构（任务要求"地形破坏需要有独立的数据结构"）：
##   _structures: structure_id -> {
##       pieces: Array[DestructiblePiece],
##       destroyed_pieces: Dictionary[piece_uid] -> true,
##       fully_destroyed: bool,
##       checkpoint_state: Dictionary  # 检查点时的快照，用于重置
##   }

signal structure_progress_changed(structure_id: String, remaining: int, total: int)
signal structure_destroyed(structure_id: String, world_position: Vector3)
## 通路打开 —— 供关卡脚本订阅（例如"击碎石柱后出现隐藏通道"）
signal path_opened(path_id: String)

var _structures: Dictionary = {}
## 已完全摧毁的结构 ID 集合（重启关卡时清空）
var _destroyed_structures: Dictionary = {}

## 阈值：结构剩余 Piece 比例低于该值算"整体摧毁"
const STRUCTURE_DESTROY_RATIO := 0.0

## 本机是否为权威端
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 注意：这里**不**在会话建立时重放状态。
	# 会话刚建立时关卡还没加载，_structures 是空的，重放无意义；
	# 而且此时对端节点也不存在，RPC 会被丢弃。
	# 正确的时机是主机收到客户端的 `_rpc_client_ready` 之后，
	# 由 LevelManager 调用 replay_state_to(peer_id)。


# ============================================================
# 注册
# ============================================================

## 场景初始化时调用：扫描所有 DestructiblePiece 并按 structure_id 分组
func register_scene(root: Node) -> void:
	_structures.clear()
	_destroyed_structures.clear()

	var pieces := _collect_pieces(root)
	for piece: DestructiblePiece in pieces:
		_register_piece(piece)

	for id: String in _structures:
		var info: Dictionary = _structures[id]
		print("[地形] 注册结构 %s（%d 块，总耐久 %.0f）" % [
			id, (info["pieces"] as Array).size(), info["total_durability"]
		])


func _collect_pieces(root: Node) -> Array[DestructiblePiece]:
	var out: Array[DestructiblePiece] = []
	for node in root.get_tree().get_nodes_in_group(&"destructibles"):
		var p := node as DestructiblePiece
		if p != null and not p.is_destroyed:
			out.append(p)
	return out


func _register_piece(piece: DestructiblePiece) -> void:
	var id := piece.structure_id
	if not _structures.has(id):
		_structures[id] = {
			"pieces": [] as Array,
			"total": 0,
			"remaining": 0,
			"total_durability": 0.0,
			"fully_destroyed": false,
			"world_position": piece.global_position,
		}
	var info: Dictionary = _structures[id]
	(info["pieces"] as Array).append(piece)
	info["total"] = (info["pieces"] as Array).size()
	info["remaining"] = (info["pieces"] as Array).size()
	info["total_durability"] += piece.max_durability

	piece.piece_destroyed.connect(_on_piece_destroyed)
	piece.piece_damaged.connect(_on_piece_damaged)


# ============================================================
# 破坏入口
# ============================================================

## 权威端：结算一次地形伤害。返回是否导致了 Piece 碎裂。
func apply_damage_authoritative(piece: DestructiblePiece, amount: float, weight: int, impact: Vector3) -> bool:
	if piece == null or not is_instance_valid(piece) or piece.is_destroyed:
		return false

	var broke := piece.apply_destruction_damage(amount, weight, impact)
	# 广播给客户端（客户端不重算，只播放）
	if broke and NetManager != null and NetManager.is_session_active():
		_rpc_piece_destroyed.rpc(piece.piece_uid, impact)
	return broke


## 客户端：请求权威端结算
func request_damage(piece: DestructiblePiece, amount: float, weight: int, impact: Vector3) -> void:
	if piece == null or not is_instance_valid(piece):
		return
	if NetManager == null or not NetManager.is_session_active():
		apply_damage_authoritative(piece, amount, weight, impact)
		return
	# 本地先给一点即时反馈（闪一下），但不改变耐久
	piece._flash()
	_rpc_request_damage.rpc_id(1, piece.piece_uid, amount, weight, impact)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_request_damage(uid: String, amount: float, weight: int, impact: Vector3) -> void:
	if not is_authority_here():
		return
	var sender := multiplayer.get_remote_sender_id()
	# 校验：请求者必须是真实存在的玩家的攻击（首版做基本范围校验防作弊）
	var piece := find_piece_by_uid(uid)
	if piece == null:
		return
	# 拒绝明显异常的超大伤害请求
	if amount > 500.0:
		push_warning("[地形] 拒绝来自 %d 的可疑破坏请求（伤害 %.1f）" % [sender, amount])
		return
	apply_damage_authoritative(piece, amount, weight, impact)


@rpc("authority", "call_remote", "reliable")
func _rpc_piece_destroyed(uid: String, impact: Vector3) -> void:
	# 客户端收到权威结果：直接销毁，不重算
	var piece := find_piece_by_uid(uid)
	if piece == null:
		return
	piece.force_destroy_from_network()
	_notify_structure_progress(piece.structure_id)


# ============================================================
# 查询
# ============================================================

func find_piece_by_uid(uid: String) -> DestructiblePiece:
	for id: String in _structures:
		var info: Dictionary = _structures[id]
		for obj: Variant in (info["pieces"] as Array):
			# 注意：不能写成 `for p: DestructiblePiece in ...`。
			# 数组里可能残留已被 queue_free 并真正释放的实例，
			# 那时把元素赋给类型化变量会抛
			# "Trying to assign invalid previously freed instance"。
			# 先用 is_instance_valid 过滤，再做类型转换。
			if not is_instance_valid(obj):
				continue
			var p := obj as DestructiblePiece
			if p != null and p.piece_uid == uid and not p.is_destroyed:
				return p
	return null


func get_structure_info(structure_id: String) -> Dictionary:
	return _structures.get(structure_id, {})


func is_structure_destroyed(structure_id: String) -> bool:
	return _destroyed_structures.has(structure_id)


func get_all_destroyed_uids() -> Array[String]:
	var out: Array[String] = []
	for id: String in _structures:
		var info: Dictionary = _structures[id]
		for obj: Variant in (info["pieces"] as Array):
			if not is_instance_valid(obj):
				continue
			var p := obj as DestructiblePiece
			if p != null and p.is_destroyed:
				out.append(p.piece_uid)
	return out


# ============================================================
# 内部
# ============================================================

func _on_piece_damaged(piece: DestructiblePiece, current: float, maximum: float) -> void:
	EventBus.destructible_damaged.emit(piece, current, maximum)
	_notify_structure_progress(piece.structure_id)


func _on_piece_destroyed(piece: DestructiblePiece) -> void:
	_notify_structure_progress(piece.structure_id)


func _notify_structure_progress(structure_id: String) -> void:
	if not _structures.has(structure_id):
		return
	var info: Dictionary = _structures[structure_id]
	var remaining := 0
	for obj: Variant in (info["pieces"] as Array):
		# 同 find_piece_by_uid：必须先 is_instance_valid 再转型，
		# 否则已释放的实例会抛 "assign invalid previously freed instance"。
		if not is_instance_valid(obj):
			continue
		var p := obj as DestructiblePiece
		if p != null and not p.is_destroyed:
			remaining += 1
	info["remaining"] = remaining
	structure_progress_changed.emit(structure_id, remaining, int(info["total"]))

	if remaining <= 0 and not info["fully_destroyed"]:
		_complete_structure(structure_id, info)


func _complete_structure(structure_id: String, info: Dictionary) -> void:
	info["fully_destroyed"] = true
	_destroyed_structures[structure_id] = true
	var pos: Vector3 = info.get("world_position", Vector3.ZERO)
	structure_destroyed.emit(structure_id, pos)
	EventBus.destructible_destroyed.emit(structure_id, pos, int(info["total"]))
	print("[地形] 结构「%s」已完全摧毁 —— 通路打开" % structure_id)

	# 让关卡脚本可以据此打开新路线
	path_opened.emit(structure_id)


func is_authority_here() -> bool:
	return NetManager == null or NetManager.is_authority()


# ============================================================
# 网络状态重放（新玩家加入时同步已破坏的部分）
# ============================================================

## 向指定玩家（或所有客户端）重放"哪些地形件已经被破坏"。
##
## 调用时机：主机收到新客户端的 `_rpc_client_ready` 之后。
## 早于这个时机会失败 —— 对端的地形节点还没建好，RPC 会因为
## 路径不存在被丢弃。
func replay_state_to(peer_id: int = 0) -> void:
	var destroyed := get_all_destroyed_uids()
	if destroyed.is_empty():
		return
	if peer_id > 0:
		_rpc_replay_destruction.rpc_id(peer_id, destroyed)
	else:
		_rpc_replay_destruction.rpc(destroyed)
	print("[地形] 向玩家 %s 同步 %d 个已被破坏的结构件" % [
		str(peer_id) if peer_id > 0 else "全体", destroyed.size()])


@rpc("authority", "call_remote", "reliable")
func _rpc_replay_destruction(uids: Array) -> void:
	for uid: String in uids:
		var piece := find_piece_by_uid(uid)
		if piece != null:
			piece.force_destroy_from_network()
	print("[地形] 已同步 %d 个已被破坏的结构件" % uids.size())


# ============================================================
# 检查点重置
# ============================================================

## 玩家死亡重生时，默认**不重置**地形。
## 理由：刚破坏出的通路立刻恢复会让玩家迷惑，且破坏是"有意义的进展"。
## 如果需要重置（例如整关卡重开），调用本方法。
func reset_all() -> void:
	_structures.clear()
	_destroyed_structures.clear()
	DebrisPool.clear_all()


func _to_string() -> String:
	return "[地形管理器 %d 个结构，%d 个已摧毁]" % [_structures.size(), _destroyed_structures.size()]
