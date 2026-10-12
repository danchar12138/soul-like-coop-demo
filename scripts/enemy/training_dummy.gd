extends EnemyBase
## 训练木桩：用于战斗调试的简化普通敌人。
##
## 定位（严格限定，不扩展成怪物图鉴）：
##   - 一个会缓慢追人、有单一挥击的稻草人
##   - 存在的唯一目的是让玩家在 Boss 之前先验证：
##     连招能否接上、闪避无敌是否生效、精力是否够用、伤害数字是否合理
##   - 它比 Boss 简单得多，方便反复试招不死
##
## 行为：
##   距离 > 4m  -> 走近
##   距离 2~4m  -> 停下，蓄力 0.6s 后挥击（起手长，给玩家充分反应时间）
##   距离 < 2m  -> 后退一点（避免贴脸）

@export var attack_data: AttackData

## 挥击的攻击配置（如果没在编辑器里指定就运行时构造）
func _setup_stats() -> void:
	super()
	if health != null:
		health.max_health = 80.0
		health.health = 80.0
	if poise != null:
		poise.max_poise = 40.0
		poise.current = 40.0
	if attack_data == null:
		attack_data = _build_default_attack()


## 木桩的挥击：起手 0.65 秒（非常长），让玩家有充分时间练习闪避。
## 伤害低（12），因为它不是来杀人的，是来当靶子的。
func _build_default_attack() -> AttackData:
	var a := AttackData.new()
	a.attack_id = &"dummy_swing"
	a.display_name = "木桩挥击"
	a.weapon_id = &"dummy"
	a.windup = 0.65
	a.active = 0.12
	a.recovery = 0.70
	a.damage = 12.0
	a.poise_damage = 18.0
	a.weight = 1
	a.stamina_cost = 0.0
	a.shape_type = "Capsule"
	a.hit_offset = Vector3(0.0, 1.05, -1.25)
	a.hit_half_length = 0.85
	a.hit_radius = 0.45
	a.follow_facing = true
	a.lock_facing = true
	a.sfx_swing = &"swing_medium"
	a.sfx_hit = &"hit_medium"
	return a


func _get_preferred_attack_range() -> float:
	return 2.6


func _pick_attack(dist: float) -> AttackData:
	# 只在合适的距离出招，太近太远都不打（避免贴脸空挥）
	if dist < 1.6 or dist > 3.4:
		return null
	return attack_data


func _ai_think(delta: float) -> void:
	if target == null:
		_idle_brake(delta)
		return

	var dist := _horizontal_distance_to(target)

	# 贴太近就后退
	if dist < 1.5:
		var away := global_position - target.global_position
		away.y = 0.0
		if away.length_squared() > 0.01:
			var d := away.normalized()
			velocity.x = move_toward(velocity.x, d.x * move_speed * 0.6, 16.0 * delta)
			velocity.z = move_toward(velocity.z, d.z * move_speed * 0.6, 16.0 * delta)
			_face_target(delta)
		return

	if dist > _get_preferred_attack_range():
		_move_toward(target, delta, 0.85)
	else:
		_idle_brake(delta)
		_face_target(delta)
		_try_attack(dist)


func _setup_attack_controller() -> void:
	pass


func _ready() -> void:
	super()
	# 木桩攻速慢一点，让战斗节奏更适合练习
	attack_cooldown = 2.0
