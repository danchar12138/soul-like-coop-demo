class_name CameraRig
extends Node3D
## 第三人称跟随相机（相当于把整个支架套在玩家身上）。
##
## 结构（在场景里的形式）：
##   Player (CharacterBody3D)
##     └ CameraRig (Node3D)          <- 本脚本，"髋部"位置
##         └ PitchPivot (Node3D)     <- 俯仰旋转
##             └ SpringArm3D         <- 做碰撞收缩
##                 └ Camera3D
##
## 为什么不直接用 SpringArm3D 挂在玩家上：
##   锁定时相机需要绕着目标旋转（玩家和目标之间的构图），
##   自由时需要相机朝向与移动解耦。有一个独立的 rig 更好控制。
##
## 相机碰撞：使用 SpringArm3D，它会自动把相机推近，避免穿墙。

@export_group("跟随")
## 相机系在角色身上的高度偏移
@export var pivot_height: float = 1.55
## 相机与角色的水平距离
@export var distance: float = 5.2
## 相机俯仰限制
@export var min_pitch_deg: float = -55.0
@export var max_pitch_deg: float = 62.0
## 跟随平滑（位置）。越大越跟手。
@export var position_smooth: float = 14.0

@export_group("鼠标")
@export var mouse_sensitivity: float = 0.0022
@export var invert_y: bool = false
## 是否捕获鼠标（游戏内应为 true）
@export var capture_mouse: bool = true

@export_group("锁定")
## 锁定状态下相机距离
@export var lock_distance: float = 4.4
## 锁定状态下角色在画面中的水平偏移（0 = 正中，正数把角色推向左侧）
@export var lock_side_offset: float = 0.55
## 锁定状态下的跟随速度
@export var lock_follow_speed: float = 8.0

@export_group("镜头反馈")
## 是否启用抖动与冲击
@export var enable_shake: bool = true

@export_group("节点引用")
@export var pitch_pivot_path: NodePath = ^"PitchPivot"
@export var spring_arm_path: NodePath = ^"PitchPivot/SpringArm3D"
@export var camera_path: NodePath = ^"PitchPivot/SpringArm3D/Camera3D"

# ------ 内部状态 ------
var yaw: float = 0.0
var pitch: float = -0.12
var _pitch_pivot: Node3D
var _spring_arm: SpringArm3D
var _camera: Camera3D

var _is_active: bool = true
## 目标 FOV（用于锁定时的轻微推近）
var _base_fov: float = 75.0
var _target_fov: float = 75.0

# 镜头冲击
var _shake_strength: float = 0.0
var _shake_offset: Vector3 = Vector3.ZERO
var _punch_offset: Vector3 = Vector3.ZERO
var _punch_velocity: Vector3 = Vector3.ZERO

## 锁定目标（与 GameState.locked_target 同步）
var _lock_target: Node3D

## 上一帧的锁定目标位置，用于计算目标移动速度做预测
var _last_target_pos: Vector3 = Vector3.ZERO


func _ready() -> void:
	# 关键：top_level = true 让相机支架**不继承父节点的变换**。
	# 因为玩家角色会旋转（朝向移动/锁定目标），如果相机跟着转，
	# 鼠标控制就会和角色朝向叠加，镜头会乱甩。
	# 设为 top_level 后，支架的位置/旋转完全由本脚本控制，
	# 同时仍然作为玩家的子节点参与场景树管理（跟随生成/销毁）。
	top_level = true

	_pitch_pivot = get_node_or_null(pitch_pivot_path) as Node3D
	_spring_arm = get_node_or_null(spring_arm_path) as SpringArm3D
	_camera = get_node_or_null(camera_path) as Camera3D

	if _spring_arm != null:
		_spring_arm.spring_length = distance
		# 相机碰撞：只被世界几何体遮挡
		_spring_arm.collision_mask = 1 | 4
	if _camera != null:
		_base_fov = _camera.fov
		_target_fov = _base_fov
		if not _is_active:
			_camera.current = false

	apply_pivot_height()

	if capture_mouse and _is_active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# 相机应始终跟随，即使玩家在受击硬直（此时玩家脚本仍在 physics_process）
	set_process(true)
	set_physics_process(true)

	EventBus.lock_on_changed.connect(_on_lock_changed)


func apply_pivot_height() -> void:
	position = Vector3(0.0, pivot_height, 0.0)


func set_active(active: bool) -> void:
	_is_active = active
	if _camera != null:
		_camera.current = active
	if active and capture_mouse:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func is_active() -> bool:
	return _is_active


# ============================================================
# 输入
# ============================================================

func _unhandled_input(event: InputEvent) -> void:
	if not _is_active:
		return

	if event is InputEventMouseMotion:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			return
		var mm := event as InputEventMouseMotion
		yaw -= mm.relative.x * mouse_sensitivity
		# 鼠标向下移 => relative.y 为正 => pitch 减小 => 视线向下。
		# invert_y = true 时反转。
		var dy := mm.relative.y * mouse_sensitivity
		pitch += dy if invert_y else -dy
		pitch = clampf(pitch, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))

	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and k.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# ============================================================
# 跟随
# ============================================================

func _physics_process(delta: float) -> void:
	if not _is_active:
		return
	_update_shake(delta)

	_lock_target = GameState.locked_target

	if _lock_target != null and is_instance_valid(_lock_target):
		_follow_locked(delta)
	else:
		_follow_free(delta)

	_apply_rotation()
	_update_spring(delta)
	_update_fov(delta)


## 自由模式：相机朝向完全由鼠标控制
func _follow_free(delta: float) -> void:
	var desired := global_position
	# 位置平滑（避免角色急停时相机猛拉）
	var target := get_parent() as Node3D
	if target != null:
		desired = target.global_position + Vector3.UP * pivot_height
	global_position = global_position.lerp(desired, clampf(position_smooth * delta, 0.0, 1.0))
	_pitch_pivot.rotation.x = pitch
	_pitch_pivot.rotation.y = 0.0
	rotation.y = yaw
	rotation.x = 0.0


## 锁定模式：相机自动朝向"玩家与目标的中点方向"
func _follow_locked(delta: float) -> void:
	var target := get_parent() as Node3D
	if target == null:
		return

	var my_pos := target.global_position
	var tgt_pos := _lock_target.global_position

	# 相机位置：略偏向玩家的侧后方，让玩家和 Boss 都在画面内
	var to_target := tgt_pos - my_pos
	to_target.y = 0.0
	var dist := to_target.length()
	var dir_to_target := to_target.normalized() if dist > 0.01 else Vector3.FORWARD

	# 期望 yaw：从相机看向"玩家 + 朝目标方向的偏移点"
	var look_point := my_pos + dir_to_target * minf(dist * 0.42, 6.0) + Vector3.UP * 1.1
	var desired_yaw := atan2(my_pos.x - look_point.x, my_pos.z - look_point.z)
	# 侧向偏移：把角色略推到画面一侧，给 Boss 留出观察空间
	var side := Vector3(dir_to_target.z, 0.0, -dir_to_target.x)
	look_point += side * lock_side_offset

	# 平滑旋转到期望朝向
	yaw = _lerp_angle_fast(yaw, desired_yaw, lock_follow_speed * delta)

	# 位置跟随
	var desired_pos := my_pos + Vector3.UP * pivot_height
	global_position = global_position.lerp(desired_pos, clampf(position_smooth * delta, 0.0, 1.0))
	rotation.y = yaw
	rotation.x = 0.0

	# 锁定时的俯仰：稍微抬高看 Boss 上半身
	var height_diff := (tgt_pos.y + 1.0) - (my_pos.y + pivot_height)
	var desired_pitch := clampf(atan2(height_diff, maxf(dist, 1.0)), deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
	pitch = lerpf(pitch, desired_pitch, clampf(delta * 4.0, 0.0, 1.0))
	_pitch_pivot.rotation.x = pitch

	# 处理锁定目标切换输入
	_handle_lock_switch()


func _lerp_angle_fast(from: float, to: float, weight: float) -> float:
	var diff := wrapf(to - from, -PI, PI)
	return from + diff * clampf(weight, 0.0, 1.0)


## 在多个敌人之间切换锁定目标。
##
## 【为什么用鼠标滚轮而不是方向键】
## 最初的写法是用 A/D（`move_left` / `move_right`）来切换目标。
## 这是一个真实的手感 bug：锁定状态下 A/D 本来就是**横向绕圈走位**
## 最常用的按键，于是每次横移都会触发目标切换 —— Boss 和小怪之间
## 疯狂跳目标，镜头跟着乱甩，完全没法打。
##
## 正确做法是用一个**不与移动冲突**的独立输入。
## 鼠标滚轮是最自然的（类魂游戏普遍用它切目标），
## 且不需要额外占用键盘键位。
func _handle_lock_switch() -> void:
	if not _is_active:
		return

	var dir := 0
	if Input.is_action_just_pressed(&"lock_switch_next"):
		dir = 1
	elif Input.is_action_just_pressed(&"lock_switch_prev"):
		dir = -1
	if dir == 0:
		return

	var current := _lock_target
	var candidates: Array[Node3D] = []
	for node in get_tree().get_nodes_in_group(&"lockon_targets"):
		var n := node as Node3D
		if n == null or not is_instance_valid(n) or n == current:
			continue
		var h := n.get_node_or_null("Health") as HealthComponent
		if h == null or not h.is_dead:
			candidates.append(n)
	if candidates.is_empty():
		return

	# 按"离当前目标的方位角"排序，而不是单纯按距离 ——
	# 这样连续滚动的切换顺序是环绕式的，不会在两个目标之间来回跳。
	if current != null and is_instance_valid(current):
		var cam_pos := current.global_position
		var cam_forward := -global_transform.basis.z
		var base_angle := atan2(cam_forward.x, cam_forward.z)
		candidates.sort_custom(func (a: Node3D, b: Node3D) -> bool:
			var da := _relative_angle(a.global_position - cam_pos, base_angle)
			var db := _relative_angle(b.global_position - cam_pos, base_angle)
			return da < db
		)
		if dir > 0:
			GameState.locked_target = candidates[0]
		else:
			GameState.locked_target = candidates.back()
	else:
		candidates.sort_custom(func (a: Node3D, b: Node3D) -> bool:
			return a.global_position.distance_squared_to(global_position) \
				< b.global_position.distance_squared_to(global_position)
		)
		GameState.locked_target = candidates[0]


## 相对基准方向的水平夹角（0~TAU），用于环绕式排序
func _relative_angle(offset: Vector3, base_angle: float) -> float:
	var a := atan2(offset.x, offset.z)
	return fposmod(a - base_angle, TAU)


func _apply_rotation() -> void:
	# 抖动与冲击叠加在旋转之后，作为纯表现偏移
	if not enable_shake:
		return
	var total := _shake_offset + _punch_offset
	_pitch_pivot.rotation.y = total.x
	_pitch_pivot.rotation.x = pitch + total.y


func _update_spring(delta: float) -> void:
	if _spring_arm == null:
		return
	var want := lock_distance if (_lock_target != null and is_instance_valid(_lock_target)) else distance
	_spring_arm.spring_length = lerpf(_spring_arm.spring_length, want, clampf(delta * 8.0, 0.0, 1.0))


func _update_fov(delta: float) -> void:
	if _camera == null:
		return
	# 冲刺/锁定时的轻微 FOV 变化，增加速度感
	var owner_body := get_parent() as CharacterBody3D
	var want := _base_fov
	if owner_body != null and GameState.locked_target == null:
		var spd := Vector2(owner_body.velocity.x, owner_body.velocity.z).length()
		want = _base_fov + clampf((spd - GameConfig.MOVE_SPEED) * 1.4, 0.0, 6.0)
	_target_fov = want
	_camera.fov = lerpf(_camera.fov, _target_fov, clampf(delta * 6.0, 0.0, 1.0))


# ============================================================
# 镜头反馈（供 CombatResolver / 玩家脚本调用）
# ============================================================

## 请求一次镜头抖动
func add_shake(strength: float) -> void:
	if not enable_shake:
		return
	_shake_strength = maxf(_shake_strength, strength)


## 请求一次镜头冲击（沿视线方向的推拉）
func add_punch(amount: float) -> void:
	if not enable_shake:
		return
	_punch_velocity.y -= amount * 6.0


func _update_shake(delta: float) -> void:
	if _shake_strength > 0.0:
		_shake_strength = maxf(0.0, _shake_strength - GameConfig.SHAKE_DECAY * delta * _shake_strength * 3.0)
		if _shake_strength < 0.0005:
			_shake_strength = 0.0
		var t := Time.get_ticks_msec() / 1000.0
		# 用两个不同频率的正弦伪随机，避免看起来像规律震动
		_shake_offset.x = sin(t * 47.0) * _shake_strength * 0.32
		_shake_offset.y = sin(t * 61.0 + 1.7) * _shake_strength * 0.32
	else:
		_shake_offset = _shake_offset.lerp(Vector3.ZERO, clampf(delta * 12.0, 0.0, 1.0))

	# 冲击用弹簧回正
	_punch_offset += _punch_velocity * delta
	_punch_velocity = _punch_velocity.lerp(Vector3.ZERO, clampf(delta * 9.0, 0.0, 1.0))
	_punch_offset = _punch_offset.lerp(Vector3.ZERO, clampf(delta * 9.0, 0.0, 1.0))


func _on_lock_changed(_player: Node, target: Node) -> void:
	_lock_target = target as Node3D
	if _lock_target != null:
		# 立即调整到合适角度，避免锁定瞬间相机猛甩
		var t := get_parent() as Node3D
		if t != null:
			var d := _lock_target.global_position - t.global_position
			d.y = 0.0
			if d.length_squared() > 0.01:
				yaw = atan2(-d.x, -d.z)


## 尽可能在角色死亡时保持相机
func on_owner_died() -> void:
	if _lock_target != null:
		GameState.locked_target = null


# ============================================================
# 供 PlayerController 查询的接口
# ============================================================

## 移动方向基准（相机水平朝向）
func get_movement_basis() -> Basis:
	var y := rotation.y
	return Basis(Vector3.UP, y)


func get_camera_global_position() -> Vector3:
	if _camera != null:
		return _camera.global_position
	return global_position


func get_camera_forward() -> Vector3:
	if _camera != null:
		return -_camera.global_transform.basis.z
	return -global_transform.basis.z
