class_name DebrisPiece
extends RigidBody3D
## 单个碎片。由 DebrisPool 池化复用，不要直接 new。
##
## 性能注意：
##   - 使用 BoxMesh（最低多边形）而不是复杂网格
##   - 睡眠阈值调低，静止后尽快进入 sleep 停止物理计算
##   - 到期后淡出并回池，节点不销毁（避免 GC 抖动）

## 剩余生命
var _life: float = 0.0
## 是否活跃
var _active: bool = false
## 材质（复用，避免每次新建）
var _mat: StandardMaterial3D
var _mesh: MeshInstance3D
var _shape: CollisionShape3D


func _init() -> void:
	# 物理属性：碎片要有点分量但不能太重，否则会推飞玩家
	mass = 0.35
	gravity_scale = 1.0
	linear_damp = 0.42
	angular_damp = 1.1
	# 睡眠：静止后停止模拟
	can_sleep = true
	sleeping = true
	# 碰撞层：第 1 层（世界）+ 第 6 层（可破坏），不参与角色碰撞
	collision_layer = 0
	set_collision_layer_value(1, true)
	# 不与角色/敌人碰撞，避免碎片把玩家顶飞
	collision_mask = 1
	continuous_cd = false
	max_contacts_reported = 0


func _ready() -> void:
	_build_visuals()
	set_physics_process(true)
	visible = false


func _build_visuals() -> void:
	if _mesh != null:
		return
	_mat = StandardMaterial3D.new()
	_mat.roughness = 0.92
	_mat.metallic = 0.0

	_mesh = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	_mesh.mesh = box
	_mesh.material_override = _mat
	add_child(_mesh)

	_shape = CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3.ONE
	_shape.shape = bs
	add_child(_shape)


## 发射一个碎片
func launch(world_position: Vector3, size: float, color: Color, velocity: Vector3) -> void:
	if not _active:
		activate()
	_build_visuals()
	if _mat == null or _mesh == null:
		return
	global_position = world_position
	scale = Vector3.ONE * maxf(size, 0.05)
	# 稍微压扁，看起来更像碎块而不是骰子
	scale.y *= randf_range(0.6, 1.0)
	_mat.albedo_color = color
	linear_velocity = velocity
	angular_velocity = Vector3(
		randf_range(-8, 8), randf_range(-8, 8), randf_range(-8, 8)
	)
	sleeping = false
	_life = GameConfig.DEBRIS_LIFETIME if GameConfig != null else 6.0
	modulate_a(1.0)


func modulate_a(a: float) -> void:
	if _mat != null:
		# 用 albedo alpha 做淡出（需要开启 transparent）
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if a < 0.999 else BaseMaterial3D.TRANSPARENCY_DISABLED
		var c := _mat.albedo_color
		_mat.albedo_color = Color(c.r, c.g, c.b, a)


func activate() -> void:
	_active = true
	visible = true
	set_physics_process(true)
	freeze = false


func deactivate() -> void:
	_active = false
	visible = false
	freeze = true
	sleeping = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	# 移出视野，避免残留碰撞
	global_position = Vector3(0.0, -500.0, 0.0)


func is_active_piece() -> bool:
	return _active


## 每帧推进。返回 true 表示该回收。
func tick(delta: float) -> bool:
	if not _active:
		return true
	_life -= delta
	if _life <= 0.0:
		return true

	# 最后一段时间淡出
	var fade := GameConfig.DEBRIS_FADE_TIME
	if _life < fade:
		modulate_a(clampf(_life / fade, 0.0, 1.0))

	# 掉出世界
	if global_position.y < -20.0:
		return true
	return false
