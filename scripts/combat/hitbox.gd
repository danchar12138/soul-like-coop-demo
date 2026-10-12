class_name Hitbox
extends Area3D
## 攻击判定盒：出手的那一侧。
##
## 由 AttackController 在攻击的 [windup, windup+active) 窗口内开启。
## 只有开启期间检测到的受击盒才生效，从根本上杜绝"隔空伤害"和
## "收招时还在扣血"这两类手感灾难。
##
## 两个关键设计：
##   1. **判定体积随攻击变化**。每次 activate() 都按 AttackData 重建
##      CollisionShape3D，所以横扫是长的、突刺是短的、跳劈是圆的。
##      任务要求"根据攻击动作变化的判定范围"就落在这里。
##   2. **每次挥击对同一目标只结算一次**。否则 60fps 下 6 帧的有效窗口
##      会把一次攻击算成 6 次伤害。

## 本次挥击已经命中的目标（避免重复结算）。每次攻击开始时清空。
var _hit_this_swing: Dictionary = {}
## 是否处于有效判定状态
var is_active: bool = false
## 当前攻击数据
var current_attack: AttackData
## 攻击者（角色根节点）
var attacker: Node

## 判定形状节点（由 _apply_shape 动态替换 shape）
var _shape_node: CollisionShape3D
var _cap := CapsuleShape3D.new()
var _sph := SphereShape3D.new()
var _box := BoxShape3D.new()

## 玩家攻击的默认 mask：敌人身体(3) + 可破坏地形(6)
const MASK_VS_ENEMY := (1 << 2) | (1 << 5)      # 4 + 32 = 36
## 敌人攻击的默认 mask：玩家身体(2) + 可破坏地形(6)
const MASK_VS_PLAYER := (1 << 1) | (1 << 5)     # 2 + 32 = 34


## 便捷设置：让本判定盒去打敌人（玩家用）
func target_enemies() -> void:
	attack_layer = 4
	target_layers = MASK_VS_ENEMY
	_refresh_collision()


## 便捷设置：让本判定盒去打玩家（敌人用）
func target_players() -> void:
	attack_layer = 5
	target_layers = MASK_VS_PLAYER
	_refresh_collision()


func _refresh_collision() -> void:
	collision_layer = 1 << (attack_layer - 1)
	collision_mask = target_layers

@export_group("碰撞层")
## 攻击方属于哪一层（4 = 玩家攻击，5 = 敌人攻击）。
## 分开是为了实现"玩家只打敌人、敌人只打玩家"这条规则。
@export var attack_layer: int = 4
## 能打到哪些层（位掩码，层号从 1 开始）。
## 默认 = 敌人身体(3) + 可破坏地形(6) = 1<<2 | 1<<5 = 36。
## 敌人攻击应设为 player_body(2) + destructible(6) = 1<<1 | 1<<5 = 34。
##
## 【为什么必须按阵营分开，不能两边共用一套 mask】
## 曾把敌人受击盒同时挂在 player_body 和 enemy_body 上，结果敌人
## 攻击的 mask 命中了**另一个敌人的受击盒** —— 两个训练木桩会互相
## 砍。测试里表现为"玩家一次挥击扣了 30 血"（自己 18 + 隔壁木桩 12）。
## 现在阵营由碰撞层一地决定，代码里不用写任何 if。
@export var target_layers: int = 36

signal hit_registered(damageable: Damageable, info: DamageInfo)
## 命中可破坏地形
signal destructible_hit(piece: DestructiblePiece, amount: float, weight: int, position: Vector3)


func _ready() -> void:
	# 攻击判定本身就是个 Area3D：
	#   - 自己属于 attack_layer（player_attack / enemy_attack），用于统计与过滤
	#   - 检测 target_layers（对方阵营的身体 + 可破坏地形）
	#   - monitoring 默认关，由 AttackController 在有效帧打开
	_refresh_collision()
	monitoring = false
	monitorable = false
	_shape_node = _find_shape_node()
	_build_shape()
	set_physics_process(false)


func setup(p_attacker: Node) -> void:
	attacker = p_attacker


func _find_shape_node() -> CollisionShape3D:
	for c in get_children():
		if c is CollisionShape3D:
			return c as CollisionShape3D
	var n := CollisionShape3D.new()
	n.name = "CollisionShape3D"
	add_child(n)
	return n


func _build_shape() -> void:
	if _shape_node != null and _shape_node.shape == null:
		_shape_node.shape = _cap


## 按攻击数据重建判定体积。
## 形状语义：
##   Capsule -> 横向展开的胶囊，用于横扫。长度 = 2*hit_half_length
##   Sphere  -> 球，用于突刺 / 圆形 AoE
##   Box     -> 盒，用于下劈 / 直线判定
func _apply_shape(atk: AttackData) -> void:
	if _shape_node == null:
		return
	match atk.shape_type:
		"Sphere":
			_sph.radius = maxf(atk.hit_radius, 0.05)
			_shape_node.shape = _sph
			_shape_node.rotation = Vector3.ZERO
		"Box":
			_box.size = Vector3(
				maxf(atk.hit_half_length * 2.0, 0.1),
				maxf(atk.hit_half_height * 2.0, 0.1),
				maxf(atk.hit_radius * 2.0, 0.1)
			)
			_shape_node.shape = _box
			_shape_node.rotation = Vector3.ZERO
		_:
			# 胶囊默认沿 Y 轴，旋转 90 度让它沿 X 轴横着展开
			_cap.radius = maxf(atk.hit_radius, 0.05)
			_cap.height = maxf(atk.hit_half_length * 2.0, _cap.radius * 2.0 + 0.02)
			_shape_node.shape = _cap
			_shape_node.rotation = Vector3(0.0, 0.0, PI * 0.5)


## 开启判定。重置已命中列表。
func activate(data: AttackData) -> void:
	current_attack = data
	_hit_this_swing.clear()
	_apply_shape(data)
	is_active = true
	monitoring = true
	# 让 Godot 立即刷新一次重叠检测，避免开启当帧漏判
	set_physics_process(true)
	_check_overlaps()


## 关闭判定。
func deactivate() -> void:
	is_active = false
	monitoring = false
	set_physics_process(false)


func _physics_process(_delta: float) -> void:
	if is_active:
		_check_overlaps()


func _check_overlaps() -> void:
	if current_attack == null:
		return

	# 1) 角色/敌人的受击盒（Area3D）
	for area: Area3D in get_overlapping_areas():
		var dmg := area as Damageable
		if dmg == null or dmg.is_dead():
			continue
		if _is_already_hit(dmg):
			continue
		# 不打自己人
		if dmg.damage_owner == attacker:
			continue
		_hit_this_swing[_target_key(dmg)] = true
		_register_hit(dmg)

	# 2) 可破坏地形（StaticBody3D）
	#    地形不通过 HealthComponent 结算（它有独立的耐久度），
	#    所以单独走一条路径。攻击管线对两者的入口仍然只有这里一个。
	for body: Node3D in get_overlapping_bodies():
		var piece := body as DestructiblePiece
		if piece == null or piece.is_destroyed:
			continue
		var key := piece.get_instance_id()
		if _hit_this_swing.has(key):
			continue
		_hit_this_swing[key] = true
		_register_destructible_hit(piece)


func _target_key(dmg: Damageable) -> int:
	return dmg.get_instance_id()


func _is_already_hit(dmg: Damageable) -> bool:
	return _hit_this_swing.has(_target_key(dmg))


func _register_hit(dmg: Damageable) -> void:
	var info := DamageInfo.create(attacker, current_attack, dmg.global_position)
	info.damage *= dmg.damage_multiplier
	hit_registered.emit(dmg, info)


func _register_destructible_hit(piece: DestructiblePiece) -> void:
	# 地形伤害用攻击的基础伤害值。地形的 durability 就是按这个量级配的
	# （石柱 260 耐久 = 约 6 下重击或 14 下轻击，是一个"值得投入"的量）。
	var impact := piece.global_position
	if attacker is Node3D:
		var origin: Vector3 = (attacker as Node3D).global_position + Vector3.UP * 1.1
		impact = origin.lerp(piece.global_position, 0.86)
	destructible_hit.emit(piece, current_attack.damage, current_attack.weight, impact)
