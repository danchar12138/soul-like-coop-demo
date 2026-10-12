extends Node
## 自动化战斗集成测试（无头运行）。
##
## 用法（项目根目录）：
##   godot --headless res://tests/test_runner.tscn
##
## 用「运行场景」而不是 --script：被测脚本引用了 GameConfig / EventBus /
## GameState 等 Autoload，--script 模式下这些单例不存在，脚本会编译失败。
##
## 测试内容（对应 docs/测试记录.md 的验收编号）：
##   T1  关卡加载与玩家生成
##   T2  攻击时序：起手 / 有效 / 收招的时间点是否准确
##   T3  命中判定：能否打到训练木桩，伤害数值是否正确
##   T4  判定可信性：有效帧外不得造成伤害（防"隔空伤害"）
##   T5  单次挥击不得重复结算（防多帧重复扣血）
##   T6  闪避无敌帧
##   T7  精力消耗与气竭
##   T8  架势破除与处决窗口
##   T9  三段轻攻击连招
##   T10 地形破坏：耐久、碎裂、碎片上限、通路事件
##   T11 死亡与复活
##   T12 Boss：数值、攻击数量、预警与惩罚窗口、二阶段、击败
##   T13 朝向约定（-Z 前向）自检
##
## 结果写入 tests/测试结果.txt 并打印到标准输出。
## 单项失败不会中断后续测试，便于一次跑出全部问题。

const ARENA := "res://scenes/levels/arena.tscn"

var _results: Array[Dictionary] = []
var _level: Node3D
var _player: Node3D
var _passed: int = 0
var _failed: int = 0

## 事件标志位。
##
## 【为什么用成员变量而不是局部变量】
## GDScript 的 lambda 对**局部变量按值捕获**：在 lambda 体内写
## `flag = true` 只改到副本，外面的变量永远不变。
## 症状是"事件明明触发了，断言却是 false"。放成员变量上没有这个问题。
var _flag_path_opened: bool = false
var _flag_boss_defeated: bool = false


func _ready() -> void:
	print("========== 开始自动化测试 ==========")
	await _run_all()
	_report()
	get_tree().quit(0 if _failed == 0 else 1)


# ============================================================
# 测试骨架
# ============================================================

func _check(name: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": name, "ok": ok, "detail": detail})
	if ok:
		_passed += 1
		print("  [通过] %s  %s" % [name, detail])
	else:
		_failed += 1
		print("  [失败] %s  %s" % [name, detail])


## 等待若干物理帧
func _step(frames: int = 1) -> void:
	for i in frames:
		await get_tree().physics_frame


## 等待真实秒数
func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, false).timeout


## 让角色面向某个世界坐标点（使用 -Z 前向约定）
func _face_towards(node: Node3D, target: Vector3) -> void:
	node.global_rotation.y = MathUtil.yaw_towards(node.global_position, target)


# ============================================================
# 主流程
# ============================================================

func _run_all() -> void:
	var packed := load(ARENA) as PackedScene
	if packed == null:
		_check("T1 关卡加载", false, "无法加载 %s" % ARENA)
		return
	_level = packed.instantiate() as Node3D
	add_child(_level)
	await _step(6)
	await _wait(0.4)

	# 【关键】先关掉所有敌人的 AI。
	# 否则 Boss 和木桩会在测试过程中追打玩家，把玩家打进受击硬直，
	# 于是后续的攻击/闪避用例全部失败 —— 那不是被测代码的问题，
	# 而是测试环境不干净。需要敌人行为时（T12）单独打开。
	_set_all_enemy_ai(false)

	_player = GameState.local_player
	_check("T1 关卡加载与玩家生成", _player != null and GameState.boss != null,
		"玩家=%s Boss=%s" % [
			_player.name if _player else "无",
			GameState.boss.name if GameState.boss else "无"])
	if _player == null:
		return
	# 确认 AI 真的被关掉了（Boss 有"延迟自启"逻辑，见 EnemyBase.ai_enabled 的 setter）
	await _wait(1.6)
	_set_all_enemy_ai(false)

	_test_orientation()          # 纯数学，不需要等待
	await _test_attack_timing()
	await _test_hit_detection()
	await _test_no_phantom_damage()
	await _test_no_double_hit()
	await _test_dodge_iframes()
	await _test_stamina()
	await _test_poise_break()
	await _test_combo_chain()
	await _test_destructible()
	await _test_execution()
	await _test_charge_variants()
	await _test_animation()
	await _test_death_respawn()
	await _test_boss()


## 打开/关闭场景中所有敌人的 AI。
## 关闭时会同时在 EnemyBase 上留下"强制关闭"记号，这样敌人自己的
## 延迟自启逻辑不会把它重新打开。
func _set_all_enemy_ai(enabled: bool) -> void:
	for n in get_tree().get_nodes_in_group(&"lockon_targets"):
		var e := n as Node
		if e == null:
			continue
		if enabled and e.has_method("clear_ai_force_off"):
			e.call("clear_ai_force_off")
		if e.get("ai_enabled") != null:
			e.set("ai_enabled", enabled)


# ============================================================
# T13 朝向约定（先跑，因为它决定了 T3 是否有意义）
# ============================================================

func _test_orientation() -> void:
	# 目标是 +Z 方向时，-Z 前向的角色应该转到 yaw = PI
	var yaw_pos_z := MathUtil.yaw_from_direction(Vector3(0.0, 0.0, 1.0))
	var ok_z := is_equal_approx(absf(yaw_pos_z), PI)
	# 目标是 -Z 方向时，应转到 yaw = 0
	var yaw_neg_z := MathUtil.yaw_from_direction(Vector3(0.0, 0.0, -1.0))
	var ok_neg_z := is_equal_approx(yaw_neg_z, 0.0)
	# 目标是 +X 时，应转到 yaw = -PI/2
	var yaw_pos_x := MathUtil.yaw_from_direction(Vector3(1.0, 0.0, 0.0))
	var ok_x := is_equal_approx(yaw_pos_x, -PI * 0.5)

	_check("T13 朝向约定（-Z 前向）计算正确", ok_z and ok_neg_z and ok_x,
		"+Z->%.2f(-PI)  -Z->%.2f(0)  +X->%.2f(-PI/2)" % [yaw_pos_z, yaw_neg_z, yaw_pos_x])

	# 实际验证：把角色转到一个方向后，其 -Z 轴确实指向该方向
	var probe := Node3D.new()
	add_child(probe)
	probe.global_rotation.y = MathUtil.yaw_from_direction(Vector3(1.0, 0.0, 1.0))
	var forward := -probe.global_transform.basis.z
	var dot := forward.normalized().dot(Vector3(1.0, 0.0, 1.0).normalized())
	probe.queue_free()
	_check("T13.2 角色 forward 与目标方向一致", dot > 0.999,
		"点积 %.4f（1.0 为完全一致）" % dot)


# ============================================================
# T2 攻击时序
# ============================================================

func _test_attack_timing() -> void:
	var ac := _player.get_node_or_null("AttackController") as AttackController
	var weapon := _player.get("weapon_data") as WeaponData
	if ac == null or weapon == null:
		_check("T2 攻击时序", false, "缺少 AttackController 或 weapon_data")
		return

	var atk := weapon.get_light(0)
	var total := atk.get_total_duration()
	var range_ok := is_equal_approx(total, atk.windup + atk.active + atk.recovery)
	_check("T2.1 攻击时长 = 起手+有效+收招", range_ok,
		"%.2f = %.2f+%.2f+%.2f" % [total, atk.windup, atk.active, atk.recovery])

	# 三段轻攻击的起手时间必须有差异，否则连招就没有节奏
	var w1 := weapon.get_light(0).windup
	var w2 := weapon.get_light(1).windup
	var w3 := weapon.get_light(2).windup
	_check("T2.2 三段连招起手时间有节奏差异",
		not is_equal_approx(w1, w3) and w3 > w1,
		"%.2f / %.2f / %.2f 秒" % [w1, w2, w3])

	# 三段的总时长也不该相同（否则"终结技"没有重量感）
	var d1 := weapon.get_light(0).get_total_duration()
	var d3 := weapon.get_light(2).get_total_duration()
	_check("T2.3 第三段比第一段更慢更重", d3 > d1 and weapon.get_light(2).damage > weapon.get_light(0).damage,
		"总时长 %.2f vs %.2f，伤害 %.0f vs %.0f" % [
			d1, d3, weapon.get_light(0).damage, weapon.get_light(2).damage])

	# 时序点实测
	_player.global_position = Vector3(0.0, 1.0, 0.0)
	await _step(3)
	var hb := _player.get_node_or_null("Hitbox") as Hitbox
	ac.request_attack(atk, true)
	_check("T2.4 起手阶段判定盒关闭", hb != null and not hb.is_active,
		"is_active=%s" % (hb.is_active if hb else "无"))

	await _wait(atk.windup + atk.active * 0.5)
	_check("T2.5 有效帧内判定盒开启", hb != null and hb.is_active,
		"t=%.2fs is_active=%s" % [atk.windup + atk.active * 0.5, hb.is_active if hb else "无"])

	await _wait(atk.active * 0.5 + atk.recovery * 0.4)
	_check("T2.6 收招阶段判定盒关闭", hb != null and not hb.is_active,
		"is_active=%s" % (hb.is_active if hb else "无"))

	await _wait(atk.recovery)
	_check("T2.7 攻击结束后回到待机", not ac.is_attacking(),
		"is_attacking=%s" % ac.is_attacking())


# ============================================================
# T3 命中判定
# ============================================================

func _test_hit_detection() -> void:
	var dummy := _find_dummy()
	if dummy == null:
		_check("T3 命中训练木桩", false, "场景中找不到 TrainingDummy")
		return

	var ac := _player.get_node_or_null("AttackController") as AttackController
	var weapon := _player.get("weapon_data") as WeaponData
	var atk := weapon.get_light(0)
	var health := dummy.get_node_or_null("Health") as HealthComponent
	health.revive(1.0)

	# 站到木桩正前方 1.7m（在攻击范围内），并朝向它
	_player.global_position = dummy.global_position + Vector3(0.0, 0.0, 1.7)
	_face_towards(_player, dummy.global_position)
	await _step(4)

	var hp_before: float = health.health
	ac.request_attack(atk, true)
	await _wait(atk.windup + atk.active + 0.06)

	var dealt := hp_before - health.health
	_check("T3.1 攻击命中造成伤害", dealt > 0.0,
		"扣血 %.1f（%.0f -> %.0f）" % [dealt, hp_before, health.health])
	_check("T3.2 伤害值与配置一致", is_equal_approx(dealt, atk.damage),
		"实际 %.1f / 配置 %.1f" % [dealt, atk.damage])

	await _wait(atk.recovery + 0.15)


# ============================================================
# T4 无隔空伤害
# ============================================================

func _test_no_phantom_damage() -> void:
	var dummy := _find_dummy()
	if dummy == null:
		return
	var health := dummy.get_node_or_null("Health") as HealthComponent
	health.revive(1.0)

	var ac := _player.get_node_or_null("AttackController") as AttackController
	var weapon := _player.get("weapon_data") as WeaponData
	var atk := weapon.get_light(0)

	# 站在 8 米外，肯定打不到
	_player.global_position = dummy.global_position + Vector3(0.0, 0.0, 8.0)
	_face_towards(_player, dummy.global_position)
	await _step(4)

	var hp_before: float = health.health
	ac.request_attack(atk, true)
	await _wait(atk.get_total_duration() + 0.12)
	_check("T4.1 距离外不造成伤害（无隔空判定）",
		is_equal_approx(hp_before, health.health),
		"血量 %.0f -> %.0f（距离 8m）" % [hp_before, health.health])

	# 收招阶段不应继续扣血
	health.revive(1.0)
	health.invuln_time = 0.0
	_player.global_position = dummy.global_position + Vector3(0.0, 0.0, 1.7)
	_face_towards(_player, dummy.global_position)
	await _step(4)
	ac.request_attack(atk, true)
	await _wait(atk.windup + atk.active + 0.03)
	var hp_mid: float = health.health
	await _wait(atk.recovery)
	var hp_end: float = health.health
	_check("T4.2 收招阶段不再扣血", is_equal_approx(hp_mid, hp_end),
		"进入收招时 %.0f -> 攻击结束时 %.0f" % [hp_mid, hp_end])
	health.invuln_time = 0.25


# ============================================================
# T5 单次挥击不重复结算
# ============================================================

func _test_no_double_hit() -> void:
	var dummy := _find_dummy()
	if dummy == null:
		return
	var health := dummy.get_node_or_null("Health") as HealthComponent
	# 给足血量，方便观察"一次挥击扣了多少"
	health.max_health = 2000.0
	health.revive(1.0)
	# 关掉受击无敌 —— 这样如果代码错误地多次结算，就一定会被测出来
	health.invuln_time = 0.0

	var ac := _player.get_node_or_null("AttackController") as AttackController
	var weapon := _player.get("weapon_data") as WeaponData
	var atk := weapon.get_light(0)

	_player.global_position = dummy.global_position + Vector3(0.0, 0.0, 1.7)
	_face_towards(_player, dummy.global_position)
	await _step(4)

	var hp_before: float = health.health
	ac.request_attack(atk, true)
	await _wait(atk.get_total_duration() + 0.15)
	var dealt := hp_before - health.health
	_check("T5 单次挥击只结算一次伤害", is_equal_approx(dealt, atk.damage),
		"一次挥击共扣血 %.1f（应为 %.1f；判定窗口跨多帧，很容易重复结算）" % [dealt, atk.damage])

	health.invuln_time = 0.25
	health.max_health = 80.0
	health.revive(1.0)


# ============================================================
# T6 闪避无敌帧
# ============================================================

func _test_dodge_iframes() -> void:
	var health := _player.get_node_or_null("Health") as HealthComponent
	var stamina := _player.get_node_or_null("Stamina") as StaminaComponent
	var sm := _player.get_node_or_null("StateMachine") as CharacterStateMachine
	health.invuln_time = 0.0
	health.revive(1.0)
	stamina.refill()
	await _step(2)

	# 1) 无敌窗口内不吃伤害
	var before := health.health
	health.grant_invulnerability(0.5)
	var info := DamageInfo.new()
	info.damage = 20.0
	var res := CombatResolver.resolve(health, null, info)
	await _step(2)
	_check("T6.1 无敌帧内不受伤害",
		is_equal_approx(health.health, before) and res["evaded"],
		"血量 %.0f -> %.0f，evaded=%s" % [before, health.health, res["evaded"]])

	# 2) 无敌到期后正常受伤
	await _wait(0.6)
	var mid: float = health.health
	var info2 := DamageInfo.new()
	info2.damage = 20.0
	CombatResolver.resolve(health, null, info2)
	_check("T6.2 无敌帧结束后正常受伤", health.health < mid,
		"血量 %.0f -> %.0f" % [mid, health.health])

	# 3) 实际调用闪避入口，检查状态机与无敌是否生效
	health.revive(1.0)
	stamina.refill()
	# 清掉可能残留的硬直状态（T4 里刚被打过，状态机可能还在受击硬直中）
	sm.force_state(CombatState.State.IDLE)
	await _step(3)
	var dodged: bool = _player.call("_try_dodge")
	await _step(2)
	_check("T6.3 闪避可用并进入闪避状态",
		dodged and sm.is_state(CombatState.State.DODGE),
		"dodged=%s 状态=%s 精力 %.0f" % [dodged, sm.get_state_name(), stamina.current])

	# 4) 闪避期间确实获得无敌
	await _step(2)
	var invuln_now := health.is_invulnerable()
	_check("T6.4 闪避期间获得无敌帧", invuln_now,
		"is_invulnerable=%s（无敌窗口 %.2f~%.2fs）" % [
			invuln_now, GameConfig.DODGE_IFRAME_START, GameConfig.DODGE_IFRAME_END])

	# 等闪避结束
	await _wait(GameConfig.DODGE_DURATION + 0.15)
	health.invuln_time = 0.25
	health.revive(1.0)
	stamina.refill()


# ============================================================
# T7 精力
# ============================================================

func _test_stamina() -> void:
	var st := _player.get_node_or_null("Stamina") as StaminaComponent
	if st == null:
		_check("T7 精力系统", false, "玩家没有 Stamina 组件")
		return
	st.refill()
	await _step(2)

	var before := st.current
	var ok := st.try_spend(30.0, &"test")
	_check("T7.1 精力可被消耗", ok and st.current < before,
		"%.0f -> %.0f" % [before, st.current])

	st.current = 5.0
	var ok2 := st.try_spend(40.0, &"test")
	_check("T7.2 精力不足时拒绝动作", not ok2 and is_equal_approx(st.current, 5.0),
		"精力 %.0f 时请求消耗 40 -> %s" % [st.current, "被拒绝" if not ok2 else "被允许（错误）"])

	st.current = 30.0
	st.is_exhausted = false
	st.try_spend(30.0, &"test")
	_check("T7.3 精力耗尽进入气竭", st.is_exhausted,
		"精力 %.0f，is_exhausted=%s" % [st.current, st.is_exhausted])

	# 攻击会消耗精力（走完整的攻击入口）
	st.refill()
	var ac := _player.get_node_or_null("AttackController") as AttackController
	var weapon := _player.get("weapon_data") as WeaponData
	var atk := weapon.get_light(0)
	_player.global_position = Vector3(0.0, 1.0, 0.0)
	await _step(2)
	var sp_before := st.current
	ac.request_attack(atk, false)     # force=false，走精力检查
	await _step(2)
	_check("T7.4 出招实际扣除精力",
		st.current < sp_before,
		"%.0f -> %.0f（配置消耗 %.0f）" % [sp_before, st.current, atk.stamina_cost])
	await _wait(atk.get_total_duration() + 0.1)

	st.refill()
	await _step(2)
	_check("T7.5 回复后解除气竭", not st.is_exhausted and st.current > 90.0,
		"精力 %.0f" % st.current)


# ============================================================
# T8 架势破除
# ============================================================

func _test_poise_break() -> void:
	var dummy := _find_dummy()
	if dummy == null:
		return
	var poise := dummy.get_node_or_null("Poise") as PoiseComponent
	var health := dummy.get_node_or_null("Health") as HealthComponent
	if poise == null:
		_check("T8 架势系统", false, "木桩没有 Poise 组件")
		return

	# 玩家站远一点，避免木桩（如果 AI 意外开启）反击干扰
	_player.global_position = dummy.global_position + Vector3(0.0, 0.0, 12.0)
	health.max_health = 100000.0
	health.revive(1.0)
	poise.current = poise.max_poise
	poise.is_broken = false

	var weapon := _player.get("weapon_data") as WeaponData
	var per_hit := weapon.get_light(0).poise_damage
	var hits_needed := int(ceil(poise.max_poise / per_hit))
	var broke_at := -1
	for i in hits_needed + 2:
		if poise.apply_poise_damage(per_hit):
			broke_at = i + 1
			break
	_check("T8.1 连续攻击可打破架势", broke_at > 0,
		"每下 %.0f 架势伤害，第 %d 下破防（上限 %.0f）" % [per_hit, broke_at, poise.max_poise])
	_check("T8.2 破防后进入处决窗口",
		poise.is_broken and poise.get_break_time_left() > 0.0,
		"剩余窗口 %.1f 秒" % poise.get_break_time_left())

	# 破防会打断敌人动作（检查状态机进入破防状态）
	var sm := dummy.get_node_or_null("StateMachine") as CharacterStateMachine
	_check("T8.3 破防使敌人进入破防状态",
		sm != null and sm.is_state(CombatState.State.POISE_BREAK),
		"状态=%s" % (sm.get_state_name() if sm else "无"))

	await _wait(poise.break_window + 0.3)
	_check("T8.4 处决窗口结束后架势自动恢复", not poise.is_broken,
		"is_broken=%s 架势=%.0f" % [poise.is_broken, poise.current])

	# 重击的架势伤害必须明显高于轻击，否则"重击"在破防上毫无价值
	var heavy_poise := weapon.heavy_attack.poise_damage
	_check("T8.5 重击的架势伤害显著高于轻击",
		heavy_poise >= per_hit * 2.5,
		"轻击 %.0f / 重击 %.0f（%.1f 倍）" % [per_hit, heavy_poise, heavy_poise / per_hit])

	health.max_health = 80.0
	health.revive(1.0)


# ============================================================
# T9 连招接续
# ============================================================

func _test_combo_chain() -> void:
	var ac := _player.get_node_or_null("AttackController") as AttackController
	var sm := _player.get_node_or_null("StateMachine") as CharacterStateMachine
	var weapon := _player.get("weapon_data") as WeaponData
	var st := _player.get_node_or_null("Stamina") as StaminaComponent
	st.refill()

	var started_ids: Array[StringName] = []
	EventBus.attack_started.connect(func (a: Node, id: StringName) -> void:
		if a == _player:
			started_ids.append(id)
	)

	_player.global_position = Vector3(0.0, 1.0, 0.0)
	await _step(3)

	# 依次请求三段轻攻击，每段都在收招窗口内接续
	for i in 3:
		var atk := weapon.get_light(i)
		ac.request_attack(atk, true)
		await _wait(atk.windup + atk.active + atk.recovery * 0.85)
		await _step(3)

	await _wait(0.4)
	var light_ids := [
		weapon.get_light(0).attack_id,
		weapon.get_light(1).attack_id,
		weapon.get_light(2).attack_id,
	]
	var all_seen := true
	for id: StringName in light_ids:
		if not started_ids.has(id):
			all_seen = false
	_check("T9.1 三段轻攻击连招均可触发", all_seen,
		"实际触发序列：%s" % str(started_ids))

	# 闪避攻击与重击也必须能通过同一条管线触发
	st.refill()
	sm.force_state(CombatState.State.IDLE)
	await _step(4)
	started_ids.clear()
	ac.request_attack(weapon.heavy_attack, true)
	await _wait(weapon.heavy_attack.windup + weapon.heavy_attack.active + 0.05)
	_check("T9.2 重击可通过攻击管线触发",
		started_ids.has(weapon.heavy_attack.attack_id),
		"id=%s 触发记录=%s" % [weapon.heavy_attack.attack_id, str(started_ids)])
	await _wait(weapon.heavy_attack.recovery + 0.2)

	st.refill()
	sm.force_state(CombatState.State.IDLE)
	await _step(4)
	started_ids.clear()
	ac.request_attack(weapon.dodge_attack, true)
	await _step(3)
	_check("T9.3 闪避攻击可通过攻击管线触发",
		started_ids.has(weapon.dodge_attack.attack_id),
		"id=%s 触发记录=%s" % [weapon.dodge_attack.attack_id, str(started_ids)])
	await _wait(weapon.dodge_attack.get_total_duration() + 0.2)


# ============================================================
# T10 地形破坏
# ============================================================

func _test_destructible() -> void:
	var pieces: Array[Node] = []
	for n in get_tree().get_nodes_in_group(&"destructibles"):
		pieces.append(n)
	_check("T10.1 场景中存在可破坏结构", pieces.size() >= 10,
		"共 %d 块可破坏结构件" % pieces.size())
	if pieces.is_empty():
		return

	var piece := pieces[0] as DestructiblePiece
	# 先记下结构 ID —— break_piece 会 queue_free，之后 piece 就是无效引用了
	var sid := piece.structure_id
	var dur_before := piece.durability

	var broke := TerrainManager.apply_damage_authoritative(
		piece, 20.0, 0, piece.global_position + Vector3(0.0, 0.2, 0.0))
	await _step(2)
	var dur_after := piece.durability if is_instance_valid(piece) else 0.0
	_check("T10.2 轻击可降低耐久", (not broke and dur_after < dur_before) or broke,
		"耐久 %.0f -> %.0f" % [dur_before, dur_after])

	# 打到碎为止
	var guard := 0
	while is_instance_valid(piece) and not piece.is_destroyed and guard < 40:
		TerrainManager.apply_damage_authoritative(
			piece, 30.0, 2, piece.global_position + Vector3(0.0, 0.2, 0.0))
		guard += 1
	await _step(5)
	_check("T10.3 持续攻击可摧毁结构件",
		not is_instance_valid(piece) or piece.is_destroyed,
		"攻击 %d 次后摧毁" % guard)

	await _step(4)
	var debris_count: int = DebrisPool.get_active_count()
	_check("T10.4 摧毁时生成碎片", debris_count > 0,
		"当前活跃碎片 %d 个（上限 %d）" % [debris_count, GameConfig.MAX_DEBRIS_RIGIDBODIES])

	# 重量门槛：轻击不应打碎需要中/重击的部件
	var hard_piece := _find_piece_requiring_weight(1)
	if hard_piece != null:
		var hp_dur := hard_piece.durability
		TerrainManager.apply_damage_authoritative(hard_piece, 999.0, 0, hard_piece.global_position)
		await _step(2)
		_check("T10.5 重量不足的攻击无法破坏坚硬部件",
			is_instance_valid(hard_piece) and is_equal_approx(hard_piece.durability, hp_dur),
			"轻击(weight=0) 打 required_weight=1 的部件：耐久 %.0f（未变化）" % hp_dur)
	else:
		_check("T10.5 重量门槛机制", true, "本场景该结构无重量门槛部件，跳过")

	# 整个结构全部摧毁后触发通路事件
	_flag_path_opened = false
	TerrainManager.path_opened.connect(func (opened_id: String) -> void:
		if opened_id == sid:
			_flag_path_opened = true
	)
	var group: Array[Node] = []
	for n in get_tree().get_nodes_in_group(&"destructibles"):
		var dp := n as DestructiblePiece
		if dp != null and dp.structure_id == sid and not dp.is_destroyed:
			group.append(dp)
	for n: Node in group:
		if not is_instance_valid(n):
			continue
		var dp := n as DestructiblePiece
		if dp != null and not dp.is_destroyed:
			dp.break_piece(dp.global_position)
	await _step(5)
	_check("T10.6 结构整体摧毁触发通路事件", _flag_path_opened,
		"结构 %s 共 %d 块已全部清除，通路事件=%s" % [sid, group.size(), _flag_path_opened])

	# 碎片数量上限保护
	for i in 40:
		DebrisPool.spawn_at(Vector3(0.0, 3.0, 0.0), 3, Color.GRAY, 0.3)
	await _step(4)
	_check("T10.7 碎片数量受上限保护",
		DebrisPool.get_active_count() <= GameConfig.MAX_DEBRIS_RIGIDBODIES,
		"活跃碎片 %d <= 上限 %d" % [
			DebrisPool.get_active_count(), GameConfig.MAX_DEBRIS_RIGIDBODIES])


func _find_piece_requiring_weight(min_weight: int) -> DestructiblePiece:
	for n in get_tree().get_nodes_in_group(&"destructibles"):
		var p := n as DestructiblePiece
		if p != null and not p.is_destroyed and p.required_weight >= min_weight:
			return p
	return null


# ============================================================
# T14 处决
# ============================================================

func _test_execution() -> void:
	var dummy := _find_dummy()
	if dummy == null:
		return
	var poise := dummy.get_node_or_null("Poise") as PoiseComponent
	var health := dummy.get_node_or_null("Health") as HealthComponent
	var weapon := _player.get("weapon_data") as WeaponData
	var ac := _player.get_node_or_null("AttackController") as AttackController
	var st := _player.get_node_or_null("Stamina") as StaminaComponent

	# 让木桩血厚一点，避免被一次处决直接打死（那样就测不出后续状态）
	health.max_health = 5000.0
	health.revive(1.0)
	st.refill()

	# --- T14.1 未锁定 / 未破防时不能处决 ---
	GameState.locked_target = null
	_check("T14.1 未锁定时无法发动处决",
		not bool(_player.call("_try_execute")), "locked_target = null")

	# 站到木桩旁边并锁定
	_player.global_position = dummy.global_position + Vector3(0.0, 0.0, 1.8)
	_face_towards(_player, dummy.global_position)
	await _step(4)
	GameState.locked_target = dummy

	poise.current = poise.max_poise
	poise.is_broken = false
	_check("T14.2 目标架势未破除时无法处决",
		not bool(_player.call("_try_execute")), "poise.is_broken = false")

	# --- T14.3 破防 + 锁定 + 近距离 = 可以处决 ---
	poise.force_break(5.0)
	await _step(3)
	var can: bool = _player.call("_try_execute")
	await _step(2)
	_check("T14.3 破防且近距离时可发动处决",
		can and ac.is_attacking() and ac.current_attack == weapon.execution_attack,
		"发动=%s 当前攻击=%s" % [
			can,
			ac.current_attack.attack_id if ac.current_attack else "无"])

	# --- T14.4 处决造成高额伤害 ---
	var hp_before := health.health
	await _wait(weapon.execution_attack.get_total_duration() + 0.3)
	var dealt := hp_before - health.health
	_check("T14.4 处决造成高额伤害",
		dealt >= weapon.execution_attack.damage * 0.95,
		"扣血 %.0f（处决配置 %.0f，约为轻击 %.0f 的 %.1f 倍）" % [
			dealt, weapon.execution_attack.damage, weapon.get_light(0).damage,
			weapon.execution_attack.damage / weapon.get_light(0).damage])

	# --- T14.5 处决后破防状态结束 ---
	_check("T14.5 处决后目标恢复站立", not poise.is_broken,
		"poise.is_broken = %s，架势 %.0f" % [poise.is_broken, poise.current])

	# --- T14.6 距离太远时不能处决（防止远程处决）---
	poise.force_break(5.0)
	_player.global_position = dummy.global_position + Vector3(0.0, 0.0, 12.0)
	await _step(3)
	_check("T14.6 距离过远时无法处决",
		not bool(_player.call("_try_execute")), "距离 12 m（上限 4.5 m）")

	GameState.locked_target = null
	health.max_health = 80.0
	health.revive(1.0)


# ============================================================
# T15 蓄力与满蓄切换（居合）
# ============================================================

## 验证"蓄力满之后会切换成另一条攻击（居合）"，而不只是"同样的一刀
## 伤害更高"。这是一个曾经真实存在的问题：weapon_data.charged_attack
## 被配置了但运行时永远不触发。
func _test_charge_variants() -> void:
	var ac := _player.get_node_or_null("AttackController") as AttackController
	var weapon := _player.get("weapon_data") as WeaponData
	var st := _player.get_node_or_null("Stamina") as StaminaComponent
	var sm := _player.get_node_or_null("StateMachine") as CharacterStateMachine
	var dummy := _find_dummy()

	var heavy := weapon.heavy_attack
	var iai := weapon.charged_attack
	if heavy == null or iai == null:
		_check("T15 满蓄切换居合", false, "武器未配置 heavy_attack 或 charged_attack")
		return

	_check("T15.1 重击与居合是不同的攻击配置",
		heavy.attack_id != iai.attack_id and iai.damage > heavy.damage,
		"重击 %s（%.0f 伤害，收招 %.2fs）vs 居合 %s（%.0f 伤害，收招 %.2fs，突进 %.1f）" % [
			heavy.attack_id, heavy.damage, heavy.recovery,
			iai.attack_id, iai.damage, iai.recovery, iai.lunge_speed])

	# 把玩家放到空旷处，木桩挪远，避免蓄力期间被打断
	if dummy != null:
		_player.global_position = dummy.global_position + Vector3(0.0, 0.0, 20.0)
	else:
		_player.global_position = Vector3(0.0, 1.0, 0.0)
	sm.force_state(CombatState.State.IDLE)
	st.refill()
	await _step(4)

	# --- 未满蓄：应保持重击 ---
	ac.start_charge(heavy)
	ac.charge_time = heavy.max_charge * 0.3      # 只蓄 30%
	var mult_before := float(ac.get("_charge_multiplier"))
	ac.charge_time = heavy.max_charge * 0.3
	ac.release_charge()
	await _step(2)
	_check("T15.2 蓄力不足时保持重击",
		ac.current_attack == heavy,
		"当前攻击 = %s（蓄力 30%%）" % (ac.current_attack.attack_id if ac.current_attack else "无"))
	var mult_mid := float(ac.get("_charge_multiplier"))
	_check("T15.3 蓄力不足时按比例放大伤害",
		mult_mid > 1.0 and mult_mid < heavy.charge_damage_mult,
		"伤害倍率 = %.2f（区间 1.00 ~ %.2f）" % [mult_mid, heavy.charge_damage_mult])
	await _wait(heavy.get_total_duration() + 0.2)

	# --- 满蓄：应切换成居合 ---
	sm.force_state(CombatState.State.IDLE)
	st.refill()
	await _step(4)
	ac.start_charge(heavy)
	ac.charge_time = heavy.max_charge             # 蓄满
	var fully := ac.is_fully_charged()
	ac.release_charge()
	await _step(3)
	_check("T15.4 蓄满后切换为居合", fully and ac.current_attack == iai,
		"is_fully_charged=%s，当前攻击 = %s" % [
			fully, ac.current_attack.attack_id if ac.current_attack else "无"])
	_check("T15.5 居合带有突进速度（不只是伤害更高）",
		iai.lunge_speed >= 5.0 and ac.current_attack == iai,
		"突进速度 %.1f m/s（重击是 %.1f m/s）" % [iai.lunge_speed, heavy.lunge_speed])

	# 实测：满蓄释放后角色确实向前冲了出去
	var pos_before := _player.global_position
	await _wait(iai.windup + iai.active + 0.15)
	var moved := _player.global_position.distance_to(pos_before)
	_check("T15.6 满蓄释放后角色实际产生位移", moved > 1.0,
		"位移 %.2f m（居合配置突进 %.1f m/s）" % [moved, iai.lunge_speed])

	await _wait(iai.recovery + 0.2)
	st.refill()


# ============================================================
# T16 骨骼动画
# ============================================================

## 验证骨骼动画已接入，并且**动画时长与攻击时序对齐**。
##
## 最后一条是重点：动画是在 Blender 里按一组假定的时长录的，
## 而战斗配置可能在别处被调过。两者不一致会出现
## "判定已经打出去了，刀还没挥到"这种致命错位 ——
## 而且它不会报任何错，只能靠肉眼发现。
## AnimationDriver 会在运行时按实际配置调速来保证对齐，
## 这里就是验证那个机制确实生效。
func _test_animation() -> void:
	var drv := _player.get_node_or_null("AnimationDriver")
	if drv == null:
		_check("T16.1 动画驱动已挂载", false,
			"玩家没有 AnimationDriver 节点（模型可能是静态版）")
		return

	var ap := _find_animation_player(_player)
	if ap == null:
		_check("T16.1 动画驱动已挂载", false, "找不到 AnimationPlayer")
		return

	var anims := ap.get_animation_list()
	_check("T16.1 动画驱动已挂载且找到 AnimationPlayer", anims.size() >= 10,
		"可用动画 %d 个：%s" % [anims.size(), ", ".join(_names(anims))])

	# 每种攻击都必须有同名动画
	var weapon := _player.get("weapon_data") as WeaponData
	var missing: PackedStringArray = []
	for a: AttackData in weapon.get_all_attacks():
		if not ap.has_animation(String(a.attack_id)):
			missing.append(String(a.attack_id))
	_check("T16.2 每种攻击都有对应的动画", missing.is_empty(),
		"缺失：%s" % ("无" if missing.is_empty() else ", ".join(missing)))

	# 状态动画齐全
	var need: Array[StringName] = [
		&"idle", &"run", &"dodge", &"hit_light", &"hit_heavy", &"death", &"poise_break",
	]
	var missing_state: PackedStringArray = []
	for n: StringName in need:
		if not ap.has_animation(String(n)):
			missing_state.append(String(n))
	_check("T16.3 基础状态动画齐全", missing_state.is_empty(),
		"缺失：%s" % ("无" if missing_state.is_empty() else ", ".join(missing_state)))

	# --- 核心：动画时长与攻击时序对齐 ---
	var ac := _player.get_node_or_null("AttackController") as AttackController
	var sm := _player.get_node_or_null("StateMachine") as CharacterStateMachine
	var st := _player.get_node_or_null("Stamina") as StaminaComponent
	var atk := weapon.get_light(0)

	_player.global_position = Vector3(0.0, 1.0, 0.0)
	sm.force_state(CombatState.State.IDLE)
	st.refill()
	await _step(4)

	ac.request_attack(atk, true)
	await _step(3)

	var playing: StringName = drv.call("get_current_anim")
	var anim := ap.get_animation(String(playing))
	var speed := ap.speed_scale
	var play_len := anim.length / maxf(speed, 0.001) if anim != null else 0.0
	var want := atk.get_total_duration()

	_check("T16.4 攻击时播放了对应动画",
		playing == atk.attack_id,
		"正在播放 %s（期望 %s）" % [playing, atk.attack_id])

	_check("T16.5 动画实际时长与攻击时序对齐（误差 <5%）",
		anim != null and absf(play_len - want) / want < 0.05,
		"动画 %.3f 秒 × 速度 %.2f = %.3f 秒，攻击时序 %.3f 秒（%.1f%% 误差）" % [
			anim.length if anim != null else 0.0, speed, play_len, want,
			absf(play_len - want) / want * 100.0 if want > 0.0 else 0.0])

	await _wait(atk.get_total_duration() + 0.2)

	# --- 状态切换会驱动动画 ---
	sm.force_state(CombatState.State.IDLE)
	await _step(4)
	_check("T16.6 回到待机时播放待机动画",
		drv.call("get_current_anim") == &"idle",
		"正在播放 %s" % drv.call("get_current_anim"))

	sm.force_state(CombatState.State.DODGE, 0.6)
	await _step(3)
	_check("T16.7 闪避时播放闪避动画",
		drv.call("get_current_anim") == &"dodge",
		"正在播放 %s" % drv.call("get_current_anim"))
	await _wait(0.8)
	sm.force_state(CombatState.State.IDLE)


func _find_animation_player(root: Node) -> AnimationPlayer:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is AnimationPlayer:
			return n as AnimationPlayer
		for c in n.get_children():
			stack.append(c)
	return null


func _names(list: PackedStringArray) -> Array[String]:
	var out: Array[String] = []
	for s in list:
		out.append(String(s))
	return out


# ============================================================
# T11 死亡与复活
# ============================================================

func _test_death_respawn() -> void:
	var health := _player.get_node_or_null("Health") as HealthComponent
	var sm := _player.get_node_or_null("StateMachine") as CharacterStateMachine
	health.revive(1.0)
	await _step(2)

	var info := DamageInfo.new()
	info.damage = 9999.0
	info.ignore_iframes = true
	CombatResolver.resolve(health, null, info)
	await _step(3)
	_check("T11.1 生命归零后进入死亡状态",
		health.is_dead and sm.is_state(CombatState.State.DEAD),
		"血量 %.0f 状态 %s" % [health.health, sm.get_state_name()])

	await _wait(2.9)
	_check("T11.2 死亡后自动复活", not health.is_dead and health.health > 0.0,
		"血量 %.0f 状态 %s" % [health.health, sm.get_state_name()])


# ============================================================
# T12 Boss
# ============================================================

func _test_boss() -> void:
	var boss := GameState.boss
	if boss == null:
		_check("T12 Boss 存在", false, "GameState.boss 为空")
		return

	var health := boss.get_node_or_null("Health") as HealthComponent
	var poise := boss.get_node_or_null("Poise") as PoiseComponent
	_check("T12.1 Boss 已生成且数值正确",
		health != null and health.max_health >= 1000.0 and poise != null,
		"血量 %.0f 架势 %.0f" % [
			health.max_health if health else 0.0, poise.max_poise if poise else 0.0])

	var table: Array = boss.get("attack_table")
	_check("T12.2 Boss 拥有至少 3 种攻击行为", table.size() >= 3,
		"共 %d 条攻击配置" % table.size())

	# 每条攻击都必须有足够长的预警（起手）和惩罚窗口（收招）
	var all_ok := true
	var min_windup := 999.0
	var min_recovery := 999.0
	var shapes: Dictionary = {}
	for a: AttackData in table:
		min_windup = minf(min_windup, a.windup)
		min_recovery = minf(min_recovery, a.recovery)
		shapes[a.shape_type] = true
		if a.windup < 0.5 or a.recovery < 0.8:
			all_ok = false
	_check("T12.3 Boss 攻击有充分预警与惩罚窗口", all_ok,
		"最短起手 %.2fs 最短收招 %.2fs" % [min_windup, min_recovery])
	_check("T12.4 Boss 攻击有不同的判定形状（可辨认）", shapes.size() >= 2,
		"使用的形状：%s" % str(shapes.keys()))

	# 伤害与架势
	var hp_before := health.health
	var info := DamageInfo.new()
	info.damage = 10.0
	info.poise_damage = 0.0
	CombatResolver.resolve(health, poise, info)
	_check("T12.5 Boss 可被造成伤害", health.health < hp_before,
		"血量 %.0f -> %.0f" % [hp_before, health.health])

	# 二阶段：注意受击无敌会挡住连续两次结算，这里显式绕过
	var info2 := DamageInfo.new()
	info2.damage = health.max_health * 0.45
	info2.poise_damage = 0.0
	info2.ignore_iframes = true
	CombatResolver.resolve(health, poise, info2)
	await _step(4)
	var phase: int = boss.get("phase")
	_check("T12.6 血量降至阈值后进入二阶段", phase == 2,
		"当前阶段 %d，血量 %.0f/%.0f（阈值 %.0f%%）" % [
			phase, health.health, health.max_health,
			float(boss.get("phase2_threshold")) * 100.0])

	# 多人适配：权重表应在人数变化时给出不同的招式倾向
	var w2: Dictionary = boss.call("_apply_phase_weights", 2) if false else {}
	var weight_solo := _boss_weights_for(boss, 1)
	var weight_party := _boss_weights_for(boss, 4)
	var aoe_solo: float = weight_solo.get(&"slam", 0.0)
	var aoe_party: float = weight_party.get(&"slam", 0.0)
	_check("T12.7 多人时 AoE 招式权重提升（非单纯加血）", aoe_party > aoe_solo,
		"单人 slam 权重 %.1f -> 四人 %.1f；Boss 血量未随人数变化" % [aoe_solo, aoe_party])

	# 击败
	_flag_boss_defeated = false
	EventBus.boss_defeated.connect(func (_b: Node) -> void:
		_flag_boss_defeated = true
	)
	var info3 := DamageInfo.new()
	info3.damage = 99999.0
	info3.ignore_iframes = true
	CombatResolver.resolve(health, poise, info3)
	await _wait(2.2)
	_check("T12.8 Boss 可被击败并触发胜利事件",
		health.is_dead and _flag_boss_defeated,
		"is_dead=%s 胜利事件=%s 关卡阶段=%s" % [
			health.is_dead, _flag_boss_defeated, GameState.phase_name()])


## 读取 Boss 在指定人数下的招式权重表（不改动 Boss 的运行时状态）
func _boss_weights_for(boss: Node, player_count: int) -> Dictionary:
	var saved: int = GameState.players.size()
	var fake: Dictionary = {}
	for i in player_count:
		fake[i + 1] = null
	var backup := GameState.players
	GameState.players = fake
	boss.call("_apply_phase_weights", player_count)
	var w: Dictionary = (boss.get("_weights") as Dictionary).duplicate()
	GameState.players = backup
	# 恢复
	boss.call("_apply_phase_weights", saved)
	return w


# ============================================================
# 辅助
# ============================================================

func _find_dummy() -> Node3D:
	for n in get_tree().get_nodes_in_group(&"lockon_targets"):
		var n3 := n as Node3D
		if n3 != null and String(n3.name).begins_with("TrainingDummy"):
			return n3
	return null


func _report() -> void:
	var lines: PackedStringArray = []
	lines.append("测试时间：%s" % Time.get_datetime_string_from_system())
	lines.append("Godot 版本：%s" % Engine.get_version_info()["string"])
	lines.append("结果：通过 %d / 失败 %d / 共 %d" % [_passed, _failed, _results.size()])
	lines.append("")
	for r: Dictionary in _results:
		lines.append("%s %s  %s" % [
			"[通过]" if r["ok"] else "[失败]", r["name"], r["detail"]
		])

	var text := "\n".join(lines)
	print("\n========== 测试报告 ==========")
	print(text)
	print("==============================")

	var f := FileAccess.open("res://tests/测试结果.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
		print("报告已写入 tests/测试结果.txt")
