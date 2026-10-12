class_name WeaponData
extends Resource
## 一套武器的定义：模型、攻击表、伤害倍率、握持点。
##
## 一个武器包含多条攻击（轻1/轻2/轻3/重击/蓄力/闪避攻击）。
## 战斗系统只认 AttackData，不认武器类型，所以新增武器 = 新增 .tres。

@export_group("标识")
## 唯一 ID，例如 &"greatsword"
@export var weapon_id: StringName = &"unnamed_weapon"
@export var display_name: String = "未命名武器"
@export_multiline var description: String = ""

@export_group("攻击表")
## 三段轻攻击连招（按顺序）
@export var light_combo: Array[AttackData] = []
## 重攻击（可蓄力）
@export var heavy_attack: AttackData
## 蓄力满后的强化重击（留空则用 heavy_attack 的倍率）
@export var charged_attack: AttackData
## 闪避/冲刺中按攻击触发的突进攻击
@export var dodge_attack: AttackData
## 架势打破后的处决攻击
@export var execution_attack: AttackData
## 跳跃攻击（可选）
@export var jump_attack: AttackData

@export_group("属性")
## 全局伤害倍率（武器本身的力量）
@export var damage_multiplier: float = 1.0
## 全局精力消耗倍率
@export var stamina_multiplier: float = 1.0
## 重量：影响角色移动速度与闪避距离（重武器更慢）
@export_range(0.0, 2.0) var weight_class: float = 1.0

@export_group("表现与握持")
## 武器模型场景路径（.glb 或 .tscn）
@export var model_scene: String = ""
## 右手握持点相对手臂骨骼的局部变换
@export var grip_offset: Vector3 = Vector3.ZERO
@export var grip_rotation_deg: Vector3 = Vector3.ZERO
@export var grip_scale: float = 1.0
## 武器碰撞/静态体的半长度，用于收招时避免穿模（预留）
@export var weapon_length: float = 1.0


## 按序号取轻攻击（从 0 开始）。越界返回最后一段（连招循环）。
func get_light(index: int) -> AttackData:
	if light_combo.is_empty():
		return null
	return light_combo[clampi(index, 0, light_combo.size() - 1)]


func get_light_count() -> int:
	return light_combo.size()


## 按攻击 ID 查找任意一条攻击配置
func find_attack(id: StringName) -> AttackData:
	for a: AttackData in light_combo:
		if a != null and a.attack_id == id:
			return a
	for a: AttackData in [heavy_attack, charged_attack, dodge_attack, execution_attack, jump_attack]:
		if a != null and a.attack_id == id:
			return a
	return null


## 返回武器所有攻击，用于批量处理（例如注册到网络哈希表）
func get_all_attacks() -> Array[AttackData]:
	var out: Array[AttackData] = []
	for a: AttackData in light_combo:
		if a != null:
			out.append(a)
	for a: AttackData in [heavy_attack, charged_attack, dodge_attack, execution_attack, jump_attack]:
		if a != null:
			out.append(a)
	return out


func _to_string() -> String:
	return "[WeaponData %s 轻x%d]" % [weapon_id, light_combo.size()]
