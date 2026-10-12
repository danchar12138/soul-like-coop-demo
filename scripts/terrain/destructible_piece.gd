class_name DestructiblePiece
extends StaticBody3D
## 可破坏结构件：地形破坏的最小单位。
##
## 设计（详见 docs/架构说明.md「地形破坏」）：
##   一个大型结构（石柱、墙体）由若干 Piece 组成。每个 Piece 有独立
##   耐久度，被打坏后消失并生成碎片。当所有 Piece 都坏了，结构整体
##   判定为"已摧毁"，并可以让出通路。
##
## 为什么按 Piece 而不是整块一起碎：
##   1. 可以表现"逐步损坏"—— 打掉一根石柱的下半截，上半截还立着
##   2. 破坏过程有层次，不是一刀秒变成空气
##   3. 碎片数量可控（每个 Piece 生成固定数量碎片）
##
## 网络（任务要求 6 / 12）：
##   - 破坏结果由权威端确认，客户端只播放表现
##   - Piece 有稳定的 piece_id（父结构ID + 序号），保证各端一致
##   - 摧毁时广播 piece_id；客户端收到后播放同样的碎片效果

signal piece_damaged(piece: DestructiblePiece, current: float, maximum: float)
signal piece_destroyed(piece: DestructiblePiece)

## 所属结构的 ID（例如 "pillar_a"）
@export var structure_id: String = ""
## 本 Piece 在结构中的序号（决定碎片数量等）
@export var piece_index: int = 0
## 耐久度
@export var max_durability: float = 60.0
@export var durability: float = 60.0
## 需要达到多少重量等级的伤害才能破坏（0 = 任何攻击都能打）
@export var required_weight: int = 0
## 破坏时生成的碎片数量
@export var debris_count: int = 6
## 碎片模型（用自身网格的材质）
@export var debris_scale: float = 1.0
## 记录：本 Piece 是否已摧毁（网络同步用）
@export var is_destroyed: bool = false

## 边框告示（可破坏物被打时闪一下）
var _flash_mat: StandardMaterial3D
var _orig_mat: Material
var _flash_timer: float = 0.0
var _mesh: MeshInstance3D

## 全局唯一标识：structure_id + index。联机同步靠它。
var piece_uid: String = ""


func _ready() -> void:
	if structure_id.is_empty():
		structure_id = name
	piece_uid = "%s#%d" % [structure_id, piece_index]

	_mesh = get_node_or_null("Mesh") as MeshInstance3D
	if _mesh == null:
		for c in get_children():
			if c is MeshInstance3D:
				_mesh = c as MeshInstance3D
				break

	durability = clampf(durability, 0.0, max_durability)
	add_to_group(&"destructibles")

	if _mesh != null:
		_orig_mat = _mesh.material_override
		_flash_mat = StandardMaterial3D.new()
		_flash_mat.albedo_color = Color(1.0, 0.95, 0.8)
		_flash_mat.emission_enabled = true
		_flash_mat.emission = Color(0.8, 0.7, 0.5)
		_flash_mat.emission_energy_multiplier = 1.5

	# 碰撞层：
	#   1 = world —— 玩家/敌人的移动碰撞要能撞到它（否则角色会穿柱而过）
	#   6 = destructible —— 攻击判定用它来识别"这是可破坏物"
	set_collision_layer_value(1, true)
	set_collision_layer_value(6, true)


func _process(delta: float) -> void:
	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0 and _mesh != null:
			_mesh.material_override = _orig_mat


## 权威端调用：结算一次攻击对地形的伤害。
## 返回本次是否把这块打碎。
func apply_destruction_damage(amount: float, weight: int, impact_position: Vector3) -> bool:
	if is_destroyed:
		return false
	if weight < required_weight:
		# 攻击太轻，打不动（例如轻击打不碎大石柱）
		# 但仍然闪一下，让玩家明白"打到了但打不动"
		_flash_weaker()
		return false

	durability = maxf(0.0, durability - amount)
	_flash()
	piece_damaged.emit(self, durability, max_durability)

	# 血量低时表现更破败（简单做法：略微缩放 + 变暗）
	_update_damaged_look()

	if durability <= 0.0:
		break_piece(impact_position)
		return true
	return false


## 碎裂。权威端决定，所有端执行表现。
##
## 【注意：这里用的是 queue_free，不是 free】
## queue_free 把释放推迟到帧末。这意味着 break_piece() 返回之后、
## 帧末之前，piece 对象仍然有效（is_instance_valid == true），
## 但已经 is_destroyed == true。
##
## 所以任何遍历"结构里还有哪些件"的代码都**不能只判断
## is_instance_valid**，必须同时判断 is_destroyed，否则会把已碎裂的
## 件重新算成存活，导致"整根石柱都碎了但通路事件永远不触发"。
## TerrainManager._notify_structure_progress 两个条件都查了。
func break_piece(impact_position: Vector3, spawn_debris: bool = true) -> void:
	if is_destroyed:
		return
	is_destroyed = true
	piece_destroyed.emit(self)

	if spawn_debris:
		DebrisPool.spawn_from_piece(self, impact_position)

	# 碰撞立即消失，让通路打开
	set_collision_layer_value(6, false)
	visible = false
	# 延迟移除，避免同一帧还在被其他判定引用
	queue_free()


## 非权威端：直接按权威结果销毁（不重新计算伤害）
func force_destroy_from_network() -> void:
	if is_destroyed:
		return
	is_destroyed = true
	set_collision_layer_value(6, false)
	DebrisPool.spawn_from_piece(self, global_position)
	visible = false
	queue_free()


func get_ratio() -> float:
	return durability / max_durability if max_durability > 0.0 else 0.0


func _flash() -> void:
	if _mesh == null:
		return
	_mesh.material_override = _flash_mat
	_flash_timer = 0.08


func _flash_weaker() -> void:
	if _mesh == null:
		return
	_mesh.material_override = _flash_mat
	_flash_timer = 0.05


## 受损外观：越破越暗、越小
func _update_damaged_look() -> void:
	if _mesh == null:
		return
	var r := get_ratio()
	_flash_timer = 0.0
	var mat := StandardMaterial3D.new()
	# 从正常颜色逐渐变暗变红
	var base := Color(0.55, 0.56, 0.6)
	var damaged := Color(0.32, 0.26, 0.24)
	mat.albedo_color = base.lerp(damaged, 1.0 - r)
	mat.roughness = 0.9
	# 出现裂纹感：用略微的下沉表示受损
	_mesh.material_override = mat
	var s := lerpf(0.86, 1.0, r)
	_mesh.scale = Vector3(s, lerpf(0.94, 1.0, r), s)


func _to_string() -> String:
	return "[地形 %s 耐久 %.0f/%.0f%s]" % [
		piece_uid, durability, max_durability, " 已摧毁" if is_destroyed else ""
	]
