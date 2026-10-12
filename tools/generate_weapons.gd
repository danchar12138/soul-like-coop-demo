extends SceneTree
## 武器数据生成工具。
##
## 用法（在项目根目录执行）：
##   godot --headless --script tools/generate_weapons.gd
##
## 为什么不手写 .tres：AttackData 有 40 多个字段，手写极易漏字段或
## 写错类型导致静默使用默认值（这会让"调参"变成假象）。
## 用代码构造 + Godot 自己序列化，保证 .tres 与脚本字段严格一致。
##
## 改数值只需要改这里，然后重新跑一次生成。生成后可以在 Godot
## 编辑器里直接编辑 .tres，但下次重跑生成会覆盖——请以本文件为准。

const ATTACK_OUT := "res://resources/weapons/attacks/"
const WEAPON_OUT := "res://resources/weapons/"


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ATTACK_OUT))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WEAPON_OUT))

	_generate_katana()

	print("\n武器数据生成完成。")
	quit()


# ============================================================
# 太刀（首个 Demo 的标志武器）
#
# 设计意图：见 docs/技术决策.md TD-001。核心是「有节奏的三段连招 +
# 居合蓄力」，攻击距离中等偏长，鼓励进退拉锯。
#
# 三段轻攻击的节奏设计（这是手感的关键，不是随便填的）：
#   第一段 0.30s 起手 —— 可以被玩家"随手按"就出，建立反应速度感
#   第二段 0.26s 起手 —— 略快，让连招有"加速"的感觉
#   第三段 0.42s 起手 —— 明显变慢且收招长，形成"这一下是终结技"的心理预期
# 如果三段一样快，连招就没有节奏，只剩下按键次数。
# ============================================================
func _generate_katana() -> void:
	var weapon := WeaponData.new()
	weapon.weapon_id = &"katana"
	weapon.display_name = "太刀"
	weapon.description = "中距离、以横向斩击为主的标准武器。三段轻攻击节奏由快转重，\n重攻击可蓄力为「居合」，蓄力满后突进距离与伤害大幅提升。"
	weapon.damage_multiplier = 1.0
	weapon.stamina_multiplier = 1.0
	weapon.weight_class = 0.7
	weapon.model_scene = "res://assets/models/katana.glb"
	weapon.weapon_length = 1.05

	# ---- 轻攻击 1：右上向左下横斩 ----
	var l1 := _base_attack(&"katana_light_1", "轻击·一之太刀", &"katana")
	l1.windup = 0.30
	l1.active = 0.10
	l1.recovery = 0.34
	l1.damage = 18.0
	l1.poise_damage = 10.0
	l1.weight = 0
	l1.stamina_cost = 16.0
	l1.shape_type = "Capsule"
	l1.hit_offset = Vector3(0.0, 1.15, -1.30)
	l1.hit_offset_end = Vector3(0.0, 1.05, -1.55)
	l1.hit_half_length = 0.95
	l1.hit_radius = 0.50
	l1.hit_rotation_deg = Vector3(0.0, 0.0, 12.0)
	l1.lunge_speed = 1.6
	l1.combo_window_open = 0.34
	l1.combo_window_close = 0.80
	l1.dodge_cancel_progress = 0.60
	l1.attack_cancel_progress = 0.70
	l1.sfx_swing = &"swing_light"
	l1.sfx_hit = &"hit_light"

	# ---- 轻攻击 2：左向右反手斩 ----
	var l2 := _base_attack(&"katana_light_2", "轻击·二之太刀", &"katana")
	l2.windup = 0.26
	l2.active = 0.10
	l2.recovery = 0.36
	l2.damage = 21.0
	l2.poise_damage = 12.0
	l2.weight = 0
	l2.stamina_cost = 17.0
	l2.shape_type = "Capsule"
	l2.hit_offset = Vector3(0.0, 1.10, -1.35)
	l2.hit_offset_end = Vector3(0.0, 1.15, -1.60)
	l2.hit_half_length = 1.00
	l2.hit_radius = 0.52
	l2.hit_rotation_deg = Vector3(0.0, 0.0, -14.0)
	l2.lunge_speed = 2.0
	l2.combo_window_open = 0.32
	l2.combo_window_close = 0.82
	l2.dodge_cancel_progress = 0.60
	l2.attack_cancel_progress = 0.70
	l2.sfx_swing = &"swing_light"
	l2.sfx_hit = &"hit_light"

	# ---- 轻攻击 3：回旋上挑（终结技，明显更重更慢）----
	var l3 := _base_attack(&"katana_light_3", "轻击·三之太刀（终结）", &"katana")
	l3.windup = 0.42
	l3.active = 0.14
	l3.recovery = 0.52
	l3.damage = 30.0
	l3.poise_damage = 20.0
	l3.weight = 1
	l3.stamina_cost = 24.0
	l3.shape_type = "Capsule"
	l3.hit_offset = Vector3(0.0, 1.20, -1.40)
	l3.hit_offset_end = Vector3(0.0, 1.30, -1.70)
	l3.hit_half_length = 1.25
	l3.hit_radius = 0.72
	l3.hit_rotation_deg = Vector3(0.0, 0.0, 0.0)
	l3.lunge_speed = 2.4
	l3.combo_window_open = 0.0
	l3.combo_window_close = 0.0
	# 终结技收招更长，给敌人反击窗口 —— 这是"高风险高回报"的落点
	l3.dodge_cancel_progress = 0.85
	l3.attack_cancel_progress = 1.0
	l3.sfx_swing = &"swing_medium"
	l3.sfx_hit = &"hit_medium"
	l3.vfx_hit = "res://scenes/fx/hit_spark_medium.tscn"

	# ---- 重攻击：蓄力斩 ----
	var heavy := _base_attack(&"katana_heavy", "重击·蓄力斩", &"katana")
	heavy.windup = 0.55
	heavy.active = 0.14
	heavy.recovery = 0.60
	heavy.damage = 45.0
	heavy.poise_damage = 34.0
	heavy.weight = 2
	heavy.stamina_cost = 32.0
	heavy.shape_type = "Capsule"
	heavy.hit_offset = Vector3(0.0, 1.30, -1.55)
	heavy.hit_offset_end = Vector3(0.0, 0.90, -1.75)
	heavy.hit_half_length = 1.15
	heavy.hit_radius = 0.68
	heavy.hit_rotation_deg = Vector3(35.0, 0.0, 0.0)
	heavy.lunge_speed = 2.2
	# 蓄力期间允许微调走位，这是重武器的战术价值
	heavy.allow_movement = true
	heavy.chargeable = true
	heavy.max_charge = 0.85
	heavy.charge_damage_mult = 2.2
	heavy.dodge_cancel_progress = 0.90
	heavy.attack_cancel_progress = 1.0
	heavy.sfx_swing = &"swing_heavy"
	heavy.sfx_hit = &"hit_heavy"
	heavy.vfx_hit = "res://scenes/fx/hit_spark_heavy.tscn"

	# ---- 蓄力满：居合（突进斩）----
	# 这是一个"高投入高回报"的动作：起手极短（因为刀已经在鞘上蓄满），
	# 但有长位移和长收招，打空就是大破绽。
	var iai := _base_attack(&"katana_iai", "重击·居合斩（蓄力满）", &"katana")
	iai.windup = 0.22
	iai.active = 0.16
	iai.recovery = 0.74
	iai.damage = 80.0
	iai.poise_damage = 50.0
	iai.weight = 2
	iai.stamina_cost = 32.0
	iai.shape_type = "Capsule"
	iai.hit_offset = Vector3(0.0, 1.20, -1.60)
	iai.hit_offset_end = Vector3(0.0, 1.10, -2.30)
	iai.hit_half_length = 1.35
	iai.hit_radius = 0.62
	iai.lunge_speed = 9.0
	iai.dodge_cancel_progress = 1.0
	iai.attack_cancel_progress = 1.0
	iai.sfx_swing = &"swing_iai"
	iai.sfx_hit = &"hit_heavy"
	iai.vfx_hit = "res://scenes/fx/hit_spark_heavy.tscn"

	# ---- 闪避攻击：突进斩 ----
	var dodge_atk := _base_attack(&"katana_dodge_attack", "闪避攻击·突进斩", &"katana")
	dodge_atk.windup = 0.20
	dodge_atk.active = 0.10
	dodge_atk.recovery = 0.46
	dodge_atk.damage = 24.0
	dodge_atk.poise_damage = 14.0
	dodge_atk.weight = 0
	dodge_atk.stamina_cost = 20.0
	dodge_atk.shape_type = "Capsule"
	dodge_atk.hit_offset = Vector3(0.0, 1.10, -1.45)
	dodge_atk.hit_offset_end = Vector3(0.0, 1.05, -1.85)
	dodge_atk.hit_half_length = 1.05
	dodge_atk.hit_radius = 0.50
	dodge_atk.lunge_speed = 5.0
	dodge_atk.sfx_swing = &"swing_light"
	dodge_atk.sfx_hit = &"hit_light"

	# ---- 处决（架势破除后）----
	var exec := _base_attack(&"katana_execution", "处决·一閃", &"katana")
	exec.windup = 0.50
	exec.active = 0.10
	exec.recovery = 0.75
	exec.damage = 260.0
	exec.poise_damage = 999.0
	exec.weight = 2
	exec.stamina_cost = 0.0
	exec.is_execution = true
	exec.shape_type = "Sphere"
	exec.hit_offset = Vector3(0.0, 1.10, -1.30)
	exec.hit_radius = 1.30
	exec.allow_movement = false
	exec.sfx_swing = &"swing_iai"
	exec.sfx_hit = &"hit_execution"
	exec.vfx_hit = "res://scenes/fx/hit_spark_heavy.tscn"

	weapon.light_combo = [l1, l2, l3] as Array[AttackData]
	weapon.heavy_attack = heavy
	weapon.charged_attack = iai
	weapon.dodge_attack = dodge_atk
	weapon.execution_attack = exec

	for a: AttackData in weapon.get_all_attacks():
		_save_attack(a)

	_save_resource(weapon, WEAPON_OUT + "katana.tres")
	print("  已生成 太刀（%d 段轻攻击 + 重击 + 居合 + 闪避攻击 + 处决）" % weapon.light_combo.size())


# ============================================================
# 辅助
# ============================================================

## 建立一个攻击的基础框架，只填必须的字段，其余留默认。
## 这样每段攻击的差异一眼可见，方便对比调参。
func _base_attack(id: StringName, display: String, weapon_id: StringName) -> AttackData:
	var a := AttackData.new()
	a.attack_id = id
	a.display_name = display
	a.weapon_id = weapon_id
	a.lock_facing = true
	a.follow_facing = true
	return a


func _save_attack(a: AttackData) -> void:
	_save_resource(a, ATTACK_OUT + "%s.tres" % a.attack_id)


func _save_resource(res: Resource, path: String) -> void:
	var err := ResourceSaver.save(res, path)
	if err != OK:
		push_error("保存失败 %s（错误码 %d）" % [path, err])
	else:
		print("  -> %s" % path)
