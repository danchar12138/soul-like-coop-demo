class_name CombatResolver
extends Node
## 伤害结算中枢（权威端）。
##
## 单一入口：所有伤害都走 resolve()。这样有三个好处：
##   1. 联机时只有一处需要判断"我是不是权威端"
##   2. 伤害/架势/硬直/死亡的处理顺序永远一致，不会因为调用者不同而错乱
##   3. 想加"伤害统计""战斗日志""命中率"这类功能，改一个地方就够
##
## 处理顺序（顺序很关键）：
##   闪避无敌检查 -> 扣血 -> 削架势 -> 判定破除 -> 决定硬直等级
##   -> 应用状态 -> 播放表现 -> 广播结果

## 伤害被无敌帧吞掉时
signal damage_evaded(target: Node)
## 权威端处理完一次伤害
signal damage_resolved(target: Node, info: DamageInfo, applied: float, poise_broken: bool)


## 结算一次伤害。权威端调用。
## 返回：DamageResult（见下方内部类）
static func resolve(health: HealthComponent, poise: PoiseComponent, info: DamageInfo) -> Dictionary:
	var result := {
		"applied": 0.0,
		"evaded": false,
		"poise_broken": false,
		"killed": false,
	}
	if health == null or info == null:
		return result

	if health.is_dead:
		return result

	# 1. 闪避无敌
	if not info.ignore_iframes and health.is_invulnerable():
		result["evaded"] = true
		EventBus.attack_whiffed.emit(info.attacker, info.attack.attack_id if info.attack else &"")
		return result

	# 2. 扣血
	var applied := health.apply_damage(info)
	result["applied"] = applied
	if applied <= 0.0:
		return result

	# 3. 削架势（只在目标还活着时）
	if poise != null and info.poise_damage > 0.0 and not health.is_dead:
		var broke := poise.apply_poise_damage(info.poise_damage)
		result["poise_broken"] = broke
		if broke:
			EventBus.poise_broken.emit(health.get_parent(), poise.break_window)

	# 4. 死亡判定
	if health.is_dead:
		result["killed"] = true
		EventBus.entity_died.emit(health.get_parent(), info.attacker)

	return result


## 命中反馈：本地副作用（音效、顿帧、粒子、镜头）。**不涉及战斗数值**。
## 所有客户端（含权威端）都调用它，因为它只影响表现。
static func play_hit_feedback(attacker: Node, target: Node, info: DamageInfo) -> void:
	if info == null:
		return

	# 命中停顿：只减速攻击者本地的动画，不影响世界
	if attacker != null and is_instance_valid(attacker):
		HitstopManager.request_by_tier(attacker, info.hitstop_tier)

	# 音效（占位：通过 EventBus 让声音管理器处理）
	EventBus.attack_landed.emit(attacker, target, info.hit_position, info.damage, float(info.weight))

	# 受击方表现
	var receiver := target.get_node_or_null("HitReactor")
	if receiver != null and receiver.has_method("react_to_hit"):
		receiver.call("react_to_hit", info)

	if GameConfig != null and GameConfig.DEBUG_PRINT_COMBAT_LOG:
		print("[命中] %s -> %s %s" % [
			attacker.name if attacker else "环境",
			target.name if target else "?",
			info
		])


## 攻击落空的反馈（挥空音效、无顿帧）
static func play_whiff_feedback(attacker: Node, attack: AttackData) -> void:
	EventBus.attack_whiffed.emit(attacker, attack.attack_id if attack else &"")
