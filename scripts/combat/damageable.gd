class_name Damageable
extends Area3D
## 受击盒（Hurtbox）：被打的那一侧。
##
## 放在角色的受击部位（身体、头部）。攻击判定（Hitbox）检测到它，
## 再通过 damage_owner 找到真正挂载 HealthComponent 的角色根节点。
##
## 为什么用 Area3D + 单独节点而不是直接检测角色刚体：
##   1. 可以做部位倍率（打头伤害更高）—— 首版预留
##   2. 判定体积可以独立于物理碰撞体，调参更自由
##   3. 攻击判定只需要检测一个碰撞层，不必枚举角色类型

## 部位伤害倍率（1.0 = 无加成）。首版全为 1.0，预留头部弱点。
@export var damage_multiplier: float = 1.0
## 部位名称（调试显示用）
@export var part_name: String = "身体"

## 实际承载 HealthComponent 的节点。留空则向上查找。
@export var damage_owner_path: NodePath

var damage_owner: Node


func _ready() -> void:
	if damage_owner_path != NodePath():
		damage_owner = get_node_or_null(damage_owner_path)
	if damage_owner == null:
		damage_owner = _find_owner_with_health(get_parent())

	# 受击盒本身不产生物理碰撞
	monitoring = false
	monitorable = true


func _find_owner_with_health(from: Node) -> Node:
	var n := from
	while n != null:
		if n.has_node("Health"):
			return n
		n = n.get_parent()
	return from


func get_health() -> HealthComponent:
	if damage_owner == null:
		return null
	return damage_owner.get_node_or_null("Health") as HealthComponent


func get_poise() -> PoiseComponent:
	if damage_owner == null:
		return null
	return damage_owner.get_node_or_null("Poise") as PoiseComponent


## 该部位是否已被摧毁（死亡）
func is_dead() -> bool:
	var h := get_health()
	return h == null or h.is_dead
