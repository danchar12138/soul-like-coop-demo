class_name HealthComponent
extends Node
## 生命值组件。
##
## 挂载位置：角色根节点的子节点，名字固定为 "Health"。
## 任何单位（玩家 / 小怪 / Boss / 可破坏石柱）都可以挂它，
## 这样伤害管线只需要认 `HealthComponent`，不需要认具体类型。
##
## 网络约定（见 docs/架构说明.md）：
##   - 只有权威端（服务器/主机）调用 apply_damage()
##   - 非权威端通过 set_health_authoritative() 接收同步结果
##   - 客户端可以本地预测"我打中了"，但最终血量以权威端为准

signal damaged(info: DamageInfo, remaining: float)
signal healed(amount: float, remaining: float)
signal died(killer: Node)
signal revived()

## 最大生命值
@export var max_health: float = 120.0
## 当前生命值
@export var health: float = 120.0
## 是否已死亡
@export var is_dead: bool = false : set = _set_is_dead

## 死亡后是否自动移除节点（碎片、小怪用）
@export var destroy_on_death: bool = false
## 死亡到移除的延迟
@export var destroy_delay: float = 2.0

## 受击后的无敌时间，防止单次攻击多次结算
@export var invuln_time: float = 0.25
var _invuln_until: float = 0.0

## 最近一次伤害的来源，用于死亡归属
var last_attacker: Node = null

var _owner_node: Node3D


func _ready() -> void:
	_owner_node = get_parent() as Node3D
	if max_health <= 0.0:
		max_health = GameConfig.PLAYER_MAX_HEALTH
	if health <= 0.0:
		health = max_health


func _set_is_dead(v: bool) -> void:
	is_dead = v


## 当前是否处于受击无敌
func is_invulnerable() -> bool:
	return Time.get_ticks_msec() / 1000.0 < _invuln_until


## 强制设置无敌时长（闪避无敌帧用）
func grant_invulnerability(seconds: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	_invuln_until = maxf(_invuln_until, now + seconds)


## 权威端调用：结算一次伤害。返回实际造成的伤害（0 表示被无敌/已死亡吞掉）。
func apply_damage(info: DamageInfo) -> float:
	if is_dead or info == null:
		return 0.0
	if not info.ignore_iframes and is_invulnerable():
		return 0.0

	last_attacker = info.attacker
	health = maxf(0.0, health - info.damage)

	# 受击无敌（避免同一次挥击的多个判定帧重复扣血）
	if invuln_time > 0.0 and not info.ignore_iframes:
		grant_invulnerability(invuln_time)

	damaged.emit(info, health)

	if health <= 0.0 and not is_dead:
		is_dead = true
		died.emit(info.attacker)
		if destroy_on_death:
			_schedule_destroy()
	return info.damage


## 直接扣血（坠落、环境伤害、脚本事件）
func apply_raw(amount: float, source: Node = null) -> float:
	var info := DamageInfo.new()
	info.attacker = source
	info.damage = amount
	info.ignore_iframes = true
	return apply_damage(info)


func heal(amount: float) -> void:
	if is_dead:
		return
	health = minf(max_health, health + amount)
	healed.emit(amount, health)


## 复活：回满血并清除状态
func revive(health_ratio: float = 1.0) -> void:
	is_dead = false
	health = max_health * clampf(health_ratio, 0.0, 1.0)
	_invuln_until = 0.0
	last_attacker = null
	revived.emit()


## 非权威端调用：直接用权威端的数值覆盖本地血量，不触发伤害逻辑。
## 这是防止"客户端各自显示不同战斗结果"的关键。
func set_health_authoritative(new_health: float, dead: bool = false) -> void:
	var was_dead := is_dead
	health = clampf(new_health, 0.0, max_health)
	is_dead = dead or health <= 0.0
	if is_dead and not was_dead:
		died.emit(last_attacker)
	elif not is_dead and was_dead:
		revived.emit()


func get_ratio() -> float:
	if max_health <= 0.0:
		return 0.0
	return health / max_health


func _schedule_destroy() -> void:
	if _owner_node == null or not is_inside_tree():
		return
	var t := get_tree().create_timer(destroy_delay, false)
	t.timeout.connect(func () -> void:
		if is_instance_valid(_owner_node):
			_owner_node.queue_free()
	)


func _to_string() -> String:
	return "[Health %.0f/%.0f%s]" % [health, max_health, " 已死亡" if is_dead else ""]
