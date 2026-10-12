class_name LevelManager
extends Node3D
## 关卡管理器：挂载在战斗场景根节点，负责整个关卡的编排。
##
## 职责：
##   1. 生成/管理所有玩家（离线单人或联机多人）
##   2. 注册地形破坏物
##   3. 设置检查点
##   4. 监听 Boss 击败 / 玩家死亡等事件，推进关卡状态
##   5. 提供重开关卡的能力（F5）
##
## 这是"关卡编排"层，不含战斗逻辑 —— 战斗逻辑都在各自的组件里。
## 这样换一个关卡（换个 .tscn）就能复用全部战斗系统。

signal level_ready()
signal all_players_defeated()
signal boss_victory()

@export_group("场景引用")
## 玩家场景
@export var player_scene: PackedScene
## 生成玩家的位置（单个）
@export var spawn_position: Vector3 = Vector3(0.0, 1.2, 6.0)
## 玩家生成点列表（多人按顺序使用）
@export var spawn_points: Array[Vector3] = []
## 玩家容器节点路径
@export var players_root_path: NodePath = ^"Players"
## 检查点位置
@export var checkpoint_position: Vector3 = Vector3(0.0, 1.2, 6.0)
@export var checkpoint_yaw: float = 0.0

@export_group("关卡配置")
## 是否在加载后自动扫描并注册可破坏地形
@export var auto_register_terrain: bool = true
## 玩家死亡后是否自动复活（首版 true；联机救援机制见文档）
@export var auto_respawn: bool = true

var players_root: Node3D
## peer_id -> PlayerController
var _spawned_players: Dictionary = {}
var _next_spawn_index: int = 0


func _ready() -> void:
	players_root = get_node_or_null(players_root_path) as Node3D
	if players_root == null:
		players_root = Node3D.new()
		players_root.name = "Players"
		add_child(players_root)

	GameState.set_checkpoint(checkpoint_position, checkpoint_yaw)
	GameState.phase = GameState.Phase.PLAYING

	if auto_register_terrain:
		# 延后一帧：等所有子节点（含地形）都进入场景树
		call_deferred("_register_terrain")

	EventBus.peer_joined.connect(_on_peer_joined)
	EventBus.peer_left.connect(_on_peer_left)
	EventBus.boss_defeated.connect(_on_boss_defeated)

	call_deferred("_spawn_initial_players")

	# 客户端加载完关卡后要告诉主机"我准备好了"。
	# 延迟 1.5 秒是为了等对手节点（Boss、木桩、地形）都进入场景树 ——
	# 主机会在收到通知后立刻推状态，如果对端还没建好节点，那些
	# RPC 会因路径不存在而被丢弃。
	if NetManager.is_session_active() and not NetManager.is_host:
		var t := get_tree().create_timer(1.5, false)
		t.timeout.connect(func () -> void:
			if is_instance_valid(self):
				notify_client_ready()
		)


func _register_terrain() -> void:
	var terrain := get_node_or_null("Terrain")
	TerrainManager.register_scene(terrain if terrain != null else self)
	TerrainManager.path_opened.connect(_on_path_opened)
	TerrainManager.structure_progress_changed.connect(_on_structure_progress)


# ============================================================
# 玩家生成
# ============================================================

func _spawn_initial_players() -> void:
	if player_scene == null:
		push_error("LevelManager 未设置 player_scene，无法生成玩家")
		return

	# 离线：只生成一个本地玩家
	if not NetManager.is_session_active():
		_spawn_player(1, false)
		level_ready.emit()
		return

	# 【联机】只有主机负责"决定谁在场"，然后把决定广播给所有客户端。
	#
	# 为什么必须同步生成而不是各端自己生成：
	#   玩家的权威是"该玩家自己的客户端"（见 TD-008），但**谁在场**
	#   是主机说了算。如果各端各自决定，加入顺序稍有差异就会出现
	#   "A 端有 3 个人、B 端只有 2 个人"，按下攻击时目标根本对不上。
	#
	# 还有一个更隐蔽的问题：PlayerSync 的 RPC 是按**节点路径**寻址的
	# （/root/.../Player_1234/PlayerSync）。如果两端的节点路径不一致，
	# 同步消息就会报 "Node not found" 而被丢弃。用同一份 player_scene、
	# 同一套命名规则（"Player_<peer_id>"）、同一个父节点，路径必然一致。
	if NetManager.is_host:
		for id: int in NetManager.get_sorted_peer_ids():
			_spawn_player(id, true)
		# 广播给所有客户端；此时可能还没有客户端连接，rpc 会静默失败，
		# 之后 _on_peer_joined 会补发一次（见那里的说明）。
		_broadcast_spawn_all()
	else:
		# 客户端：等主机的 RPC。这里不生成任何东西 —— 否则会出现
		# "客户端自己造了一个 id 不匹配的玩家"。
		print("[关卡] 客户端等待主机分配玩家实体…")

	level_ready.emit()


## 主机：把"当前所有玩家"广播一遍。客户端收到后按同样的规则实例化。
## 幂等 —— 已经存在的 peer_id 会被 _spawn_player 跳过。
func _broadcast_spawn_all() -> void:
	if not NetManager.is_host:
		return
	var ids := NetManager.get_sorted_peer_ids()
	for id: int in ids:
		_rpc_spawn_player.rpc(id)


@rpc("authority", "call_remote", "reliable")
func _rpc_spawn_player(peer_id: int) -> void:
	_spawn_player(peer_id, true)


func _spawn_player(peer_id: int, networked: bool) -> PlayerController:
	if _spawned_players.has(peer_id):
		var existing: PlayerController = _spawned_players[peer_id]
		if is_instance_valid(existing):
			return existing

	var p := player_scene.instantiate() as PlayerController
	if p == null:
		push_error("player_scene 的根节点不是 PlayerController")
		return null

	# 【节点名必须两端完全一致】
	# PlayerSync 的 RPC 按节点路径寻址，名字不同会导致同步消息
	# 在另一端找不到目标节点而静默失败。所以这里用确定性命名。
	p.name = "Player_%d" % peer_id
	p.peer_id = peer_id
	p.display_name = NetManager.get_peer_display_name(peer_id) if networked else "玩家"
	p.player_color = _color_for_peer(peer_id)

	if networked:
		# 【authority 必须在 add_child 之前设置】
		# PlayerController._ready() 会在 add_child 的瞬间执行，并在其中
		# 用 is_multiplayer_authority() 判断"我是不是本机的角色"。
		# 如果先 add_child 再设 authority，客户端上所有玩家节点的
		# authority 都还是默认的 1，于是没有任何一个被认成自己的角色，
		# GameState.local_player 会是 null，输入完全没反应。
		#
		# 每个客户端对自己角色有权威 —— 这是避免"操作橡皮筋"的关键
		# （见 docs/技术决策.md TD-008）。
		p.set_multiplayer_authority(peer_id)

	players_root.add_child(p)
	p.global_position = get_spawn_position_for(peer_id)

	if networked:
		# add_child 之后再确认一次（两道保险，见 apply_network_role 的说明）
		p.apply_network_role()
	else:
		p.is_local = true
		GameState.local_player = p

	_spawned_players[peer_id] = p
	print("[关卡] 生成玩家 %d（%s）于 %s" % [
		peer_id, "本地" if p.is_local else "远端", str(p.global_position)
	])
	return p


## 玩家配色：四个人彼此可分
func _color_for_peer(peer_id: int) -> Color:
	match peer_id:
		1: return Color(0.82, 0.85, 0.92)   # 主机：白灰
		2: return Color(0.45, 0.72, 1.0)    # 蓝
		3: return Color(1.0, 0.72, 0.38)    # 橙
		4: return Color(0.62, 0.95, 0.55)   # 绿
	return Color(0.9, 0.6, 0.9)


func get_spawn_position_for(peer_id: int) -> Vector3:
	if spawn_points.is_empty():
		# 没有配置多点时按 peer 序号错开，避免叠在一起
		var offset := Vector3(0.0, 0.0, float(peer_id - 1) * 1.6)
		return spawn_position + offset
	var ids := NetManager.get_sorted_peer_ids()
	var idx := ids.find(peer_id)
	if idx < 0:
		idx = _next_spawn_index
		_next_spawn_index += 1
	return spawn_points[idx % spawn_points.size()]


# ============================================================
# 网络事件
# ============================================================

func _on_peer_joined(peer_id: int) -> void:
	# 只有主机负责生成新人
	if not NetManager.is_host:
		return
	# 【这里不再直接生成玩家，而是等对方说"我准备好了"】
	#
	# 原因：RPC 按节点路径寻址。如果主机在对方还没加载关卡时就开始
	# 生成玩家、广播 Boss 位置，对端会刷出大量
	# "Node not found ... Requested node was not found" 并丢弃这些消息。
	# 新玩家会看到一个静止的 Boss 和几个不动的队友。
	#
	# 正确流程：客户端加载完关卡后主动上报 `_rpc_client_ready`，
	# 主机收到才开始分发状态。
	print("[关卡] 玩家 %d 已接入，等待其加载完成…" % peer_id)


## 客户端加载完关卡后调用（由 _ready 的延迟调用链触发）
func notify_client_ready() -> void:
	if NetManager.is_host or not NetManager.is_session_active():
		return
	_rpc_client_ready.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_ready() -> void:
	if not NetManager.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	print("[关卡] 玩家 %d 已加载完成，开始分发世界状态" % sender)
	NetManager.mark_client_ready(sender)

	# 1) 生成所有玩家（含新来的），并把名单广播出去
	for id: int in NetManager.get_sorted_peer_ids():
		_spawn_player(id, true)
	_broadcast_spawn_all()

	# 2) 把敌人的当前状态推一遍（否则新客户端看到满血站桩的 Boss）
	for node in get_tree().get_nodes_in_group(&"lockon_targets"):
		var sync := node.get_node_or_null("EnemySync")
		if sync != null and sync.has_method("push_full_state"):
			sync.call("push_full_state")

	# 3) 把已被破坏的地形状态重放一遍（否则新客户端看到完整的墙）
	TerrainManager.replay_state_to(sender)


func _on_peer_left(peer_id: int) -> void:
	_spawned_players.erase(peer_id)


# ============================================================
# 关卡事件
# ============================================================

func _on_boss_defeated(_boss: Node) -> void:
	GameState.phase = GameState.Phase.VICTORY
	boss_victory.emit()
	print("[关卡] ★ Boss 已击败，关卡完成。用时 %.1f 秒，死亡 %d 次" % [
		GameState.stats["elapsed_time"], GameState.stats["deaths"]
	])


func _on_path_opened(structure_id: String) -> void:
	# 结构摧毁 -> 打开通路。具体行为由关卡脚本按 ID 处理。
	print("[关卡] 通路事件：%s" % structure_id)
	match structure_id:
		"pillar_east":
			_open_east_flank()
		"wall_center":
			_open_center_breach()
		_:
			pass


## 击碎东侧石柱 -> 露出侧翼路线
func _open_east_flank() -> void:
	var gate := get_node_or_null("Gates/EastFlankBlocker") as Node3D
	if gate != null:
		gate.visible = false
		for c in gate.get_children():
			if c is CollisionObject3D:
				(c as CollisionObject3D).process_mode = Node.PROCESS_MODE_DISABLED
				(c as CollisionObject3D).set_collision_layer_value(1, false)
	print("[关卡] ★ 东侧石柱崩落，侧翼路线已打通")


## 击碎中央墙体 -> 战场中央出现新的移动空间
func _open_center_breach() -> void:
	var wall := get_node_or_null("Terrain/CenterWall") as Node3D
	if wall != null:
		# 墙体已经逐块碎了，这里做一点额外表现
		DebrisPool.spawn_at(wall.global_position + Vector3.UP * 0.6, 10,
			Color(0.45, 0.43, 0.42), 0.45)
	print("[关卡] ★ 中央墙体已破，战场中央通道打开")


func _on_structure_progress(structure_id: String, remaining: int, total: int) -> void:
	if remaining > 0 and remaining < total:
		print("[地形] %s 剩余 %d/%d 块" % [structure_id, remaining, total])


# ============================================================
# 玩家死亡处理
# ============================================================

func _check_all_defeated() -> void:
	if GameState.get_alive_players().is_empty() and not GameState.players.is_empty():
		all_players_defeated.emit()


func get_players() -> Array:
	return _spawned_players.values()


func count_alive_players() -> int:
	var n := 0
	for p: Node3D in _spawned_players.values():
		if not is_instance_valid(p):
			continue
		var h := p.get_node_or_null("Health") as HealthComponent
		if h != null and not h.is_dead:
			n += 1
	return n
