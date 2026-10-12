class_name HitReactor
extends Node3D
## 受击表现反应器：把"受到了什么伤害"翻译成"看起来/听起来像什么"。
##
## 与 HealthComponent 的分工：
##   HealthComponent = 数值（扣了多少血，死了没）
##   HitReactor      = 表现（闪白、后退、播哪个受击动画、播哪个音效）
##
## 这样拆分是为了联机时能明确区分：数值必须权威，表现可以各端自己播。

## 受击闪白：用材质 overrides 临时提高自发光
@export var flash_color: Color = Color(1.0, 0.85, 0.85)
@export var flash_time: float = 0.09
## 是否自动闪白（需要模型有 MeshInstance3D 子节点）
@export var enable_flash: bool = true

## 击退是否作用到角色身上（由角色控制器读取）
var pending_knockback: Vector3 = Vector3.ZERO
var knockback_timer: float = 0.0

signal heavy_hit_received(info: DamageInfo)
signal light_hit_received(info: DamageInfo)

var _flash_timer: float = 0.0
var _meshes: Array[MeshInstance3D] = []
var _orig_overrides: Array = []


func _ready() -> void:
	_collect_meshes()


func _process(delta: float) -> void:
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_clear_flash()
	if knockback_timer > 0.0:
		knockback_timer -= delta
		if knockback_timer <= 0.0:
			pending_knockback = Vector3.ZERO


func _collect_meshes() -> void:
	_meshes.clear()
	_orig_overrides.clear()
	var host := get_parent()
	_gather(host if host != null else self)


func _gather(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			_meshes.append(child as MeshInstance3D)
		_gather(child)


## 由 Damageable / Hitbox 命中流程调用（只做表现，不改数值）
func react_to_hit(info: DamageInfo) -> void:
	if info == null:
		return

	# 1. 闪白 + 自发光脉冲
	if enable_flash:
		_start_flash(info.is_heavy)

	# 2. 击退（短促推力，由角色控制器在移动时叠加上去）
	var kb := info.knockback
	if kb <= 0.0 and GameConfig != null:
		kb = GameConfig.KNOCKBACK_HEAVY if info.is_heavy else GameConfig.KNOCKBACK_LIGHT
	pending_knockback = info.hit_direction * kb
	pending_knockback.y = 0.0
	knockback_timer = 0.18 if not info.is_heavy else 0.32

	# 3. 事件分流，供动画状态机订阅
	if info.is_heavy:
		heavy_hit_received.emit(info)
	else:
		light_hit_received.emit(info)


func _start_flash(heavy: bool) -> void:
	# 关键：在**第一次闪白时**才记录原始材质。
	# 因为 HitReactor 是子节点，_ready 会比父节点（会给自己染色）先执行，
	# 如果在 _ready 里缓存，会把父节点的染色当成"原始状态"覆盖掉。
	if _orig_overrides.size() != _meshes.size():
		_orig_overrides.clear()
		for m: MeshInstance3D in _meshes:
			_orig_overrides.append(m.material_override if is_instance_valid(m) else null)

	_flash_timer = flash_time * (1.6 if heavy else 1.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = flash_color
	mat.emission_enabled = true
	mat.emission = flash_color
	mat.emission_energy_multiplier = 2.4 if heavy else 1.2
	for m: MeshInstance3D in _meshes:
		if is_instance_valid(m):
			m.material_override = mat


func _clear_flash() -> void:
	for i in _meshes.size():
		var m := _meshes[i]
		if is_instance_valid(m):
			m.material_override = _orig_overrides[i] if i < _orig_overrides.size() else null


## 消费一次击退（角色控制器每帧调用一次，取走后清零）
func consume_knockback() -> Vector3:
	if knockback_timer > 0.0:
		return pending_knockback
	return Vector3.ZERO
