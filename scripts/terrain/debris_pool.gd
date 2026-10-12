extends Node
## 碎片池（Autoload 单例）：全局管理破坏产生的刚体碎片。
##
## 存在的理由（任务要求 6 的性能约束）：
##   "碎片物理模拟应有数量和持续时间限制，避免大量刚体导致性能下降"
##
## 策略：
##   1. 全局上限 MAX_DEBRIS_RIGIDBODIES（默认 60）。超出时回收最老的。
##   2. 每个碎片有生命周期，到期淡出并归还。
##   3. 离玩家太远的直接回收（看不见的物理没意义）。
##   4. 用对象池复用 RigidBody3D 节点，避免频繁 new/free 造成卡顿。
##
## 重要：碎片是**纯表现**，不参与战斗判定，因此不需要网络同步。
## 各客户端可以各自模拟自己的碎片，不影响战斗结果一致性。

## 当前活跃碎片
var _active: Array[DebrisPiece] = []
## 空闲对象池
var _pool: Array[DebrisPiece] = []

## 碎片容器（首次使用时创建在场景根下）
var _container: Node3D


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func _process(delta: float) -> void:
	_tick_active(delta)


## 从一块可破坏结构件生成碎片
static func spawn_from_piece(piece: DestructiblePiece, impact_position: Vector3) -> void:
	var mgr := _instance()
	if mgr == null:
		return
	# 以中心点为基础，按半径散布生成点
	var center := impact_position
	if piece.global_position.distance_to(impact_position) > 6.0:
		center = piece.global_position
	mgr._spawn(piece, center)


## 通用生成入口（脚本触发、调试用）
static func spawn_at(position: Vector3, count: int, color: Color, size: float = 0.28) -> void:
	var mgr := _instance()
	if mgr == null:
		return
	for i in count:
		var p: DebrisPiece = mgr._acquire()
		if p == null:
			return
		var offset := Vector3(
			randf_range(-0.5, 0.5), randf_range(0.0, 0.6), randf_range(-0.5, 0.5)
		) * size * 3.0
		p.launch(position + offset, size, color, _random_velocity())


## 取得本 Autoload 单例。脚本已注册为 autoload 名为 DebrisPool。
static func _instance() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("DebrisPool")


func _get_container() -> Node3D:
	if _container == null or not is_instance_valid(_container):
		var tree := get_tree()
		if tree == null or tree.current_scene == null:
			return null
		_container = Node3D.new()
		_container.name = "DebrisContainer"
		tree.current_scene.add_child(_container)
	return _container


func _spawn(piece: DestructiblePiece, center: Vector3) -> void:
	var count := piece.debris_count
	var color := _extract_color(piece)
	var radius := _estimate_radius(piece) * piece.debris_scale

	for i in count:
		var p := _acquire()
		if p == null:
			return
		var dir := Vector3(randf_range(-1, 1), randf_range(0.3, 1.0), randf_range(-1, 1)).normalized()
		var pos := center + dir * radius * randf_range(0.3, 1.0)
		p.launch(pos, radius * randf_range(0.35, 0.6), color, dir * randf_range(2.0, 5.5))


## 从 Piece 的网格材质里取一个颜色给碎片，保持视觉一致
func _extract_color(piece: DestructiblePiece) -> Color:
	var mesh := piece.get_node_or_null("Mesh") as MeshInstance3D
	if mesh == null:
		return Color(0.55, 0.56, 0.6)
	var mat := mesh.material_override
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).albedo_color
	if mesh.mesh != null and mesh.mesh.get_surface_count() > 0:
		var m := mesh.mesh.surface_get_material(0)
		if m is StandardMaterial3D:
			return (m as StandardMaterial3D).albedo_color
	return Color(0.55, 0.56, 0.6)


func _estimate_radius(piece: DestructiblePiece) -> float:
	var shape_node := piece.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape_node != null and shape_node.shape != null:
		var sh := shape_node.shape
		if sh is BoxShape3D:
			var b := sh as BoxShape3D
			return maxf(maxf(b.size.x, b.size.y), b.size.z) * 0.5
		if sh is CylinderShape3D:
			return (sh as CylinderShape3D).radius
		if sh is SphereShape3D:
			return (sh as SphereShape3D).radius
	return 0.5


static func _random_velocity() -> Vector3:
	return Vector3(randf_range(-1, 1), randf_range(0.4, 1.0), randf_range(-1, 1)).normalized() * randf_range(2.0, 5.0)


## 取得一个碎片实例（优先复用）
func _acquire() -> DebrisPiece:
	_enforce_limit()
	var p: DebrisPiece
	if not _pool.is_empty():
		p = _pool.pop_back()
	else:
		var container := _get_container()
		if container == null:
			return null
		p = DebrisPiece.new()
		p.name = "Debris"
		container.add_child(p)
	p.activate()
	if not _active.has(p):
		_active.append(p)
	return p


## 回收一个碎片
func recycle(p: DebrisPiece) -> void:
	var idx := _active.find(p)
	if idx >= 0:
		_active.remove_at(idx)
	p.deactivate()
	if not _pool.has(p):
		_pool.append(p)


func _tick_active(delta: float) -> void:
	if _active.is_empty():
		return
	var cam_pos := _camera_position()
	var to_recycle: Array[DebrisPiece] = []
	for p: DebrisPiece in _active:
		if not is_instance_valid(p):
			to_recycle.append(p)
			continue
		var expired := p.tick(delta)
		if expired:
			to_recycle.append(p)
			continue
		# 距离剔除
		if cam_pos != Vector3.ZERO and p.global_position.distance_to(cam_pos) > GameConfig.DEBRIS_CULL_DISTANCE:
			to_recycle.append(p)
	for p: DebrisPiece in to_recycle:
		if is_instance_valid(p):
			recycle(p)


func _camera_position() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		return cam.global_position
	return Vector3.ZERO


## 超过上限时，回收最老的碎片（保持最新鲜的破坏效果）
func _enforce_limit() -> void:
	var limit := GameConfig.MAX_DEBRIS_RIGIDBODIES
	while _active.size() >= limit:
		var oldest: DebrisPiece = _active[0]
		_active.remove_at(0)
		if is_instance_valid(oldest):
			recycle(oldest)
		else:
			break


## 清空所有碎片（切换关卡、复活重置用）
func clear_all() -> void:
	for p: DebrisPiece in _active:
		if is_instance_valid(p):
			p.deactivate()
			if not _pool.has(p):
				_pool.append(p)
	_active.clear()


func get_active_count() -> int:
	return _active.size()
