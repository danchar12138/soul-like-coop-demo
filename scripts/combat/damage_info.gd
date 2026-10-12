class_name DamageInfo
extends RefCounted
## 一次伤害事件的完整上下文。
##
## 为什么需要这个类：伤害不是一个数字，而是带来源、方向、重量、
## 是否可格挡等信息的事件包。这样受击方才能决定表现（硬直时长、
## 击退方向、音效），而不必反查攻击者的内部状态。
##
## 联机时这个对象由权威端构造并用于计算，客户端只接收结果。

## 攻击者节点（可能为 null，例如环境伤害）
var attacker: Node = null
## 造成伤害的攻击配置
var attack: AttackData = null
## 攻击者的 peer id（联机时用于归属判定，-1 = 本地/离线）
var attacker_peer_id: int = -1

## 最终伤害值（已计入蓄力倍率、处决加成等）
var damage: float = 0.0
## 架势伤害
var poise_damage: float = 0.0
## 重量等级 0/1/2
var weight: int = 0
## 是否重击（用于音效、硬直、粒子选择）
var is_heavy: bool = false
## 是否可以格挡（首版暂不实现格挡，预留）
var blockable: bool = true
## 是否无视无敌帧（Boss 处决、坠落伤害用）
var ignore_iframes: bool = false

## 命中点世界坐标
var hit_position: Vector3 = Vector3.ZERO
## 从攻击者指向受击者的方向（归一化）。用于击退。
var hit_direction: Vector3 = Vector3.FORWARD
## 击退强度 (m/s)
var knockback: float = 0.0
## 硬直时长（秒）
var hitstun: float = 0.0

## 命中停顿等级 -1=无 0=轻 1=中 2=重
var hitstop_tier: int = 0
## 镜头抖动强度
var camera_shake: float = 0.0

## 该次伤害的唯一序号，权威端分配，用于客户端去重
var hit_sequence: int = 0


static func create(
	p_attacker: Node,
	p_attack: AttackData,
	p_hit_position: Vector3
) -> DamageInfo:
	var info := DamageInfo.new()
	info.attacker = p_attacker
	info.attack = p_attack
	info.hit_position = p_hit_position
	if p_attack != null:
		info.damage = p_attack.damage
		info.poise_damage = p_attack.poise_damage
		info.weight = p_attack.weight
		info.is_heavy = p_attack.weight >= 2
	if p_attacker != null and p_attacker is Node3D:
		var from: Vector3 = (p_attacker as Node3D).global_position
		var dir := p_hit_position - from
		dir.y = 0.0
		if dir.length_squared() > 0.0001:
			info.hit_direction = dir.normalized()
	return info


func duplicate_info() -> DamageInfo:
	var c := DamageInfo.new()
	c.attacker = attacker
	c.attack = attack
	c.attacker_peer_id = attacker_peer_id
	c.damage = damage
	c.poise_damage = poise_damage
	c.weight = weight
	c.is_heavy = is_heavy
	c.blockable = blockable
	c.ignore_iframes = ignore_iframes
	c.hit_position = hit_position
	c.hit_direction = hit_direction
	c.knockback = knockback
	c.hitstun = hitstun
	c.hitstop_tier = hitstop_tier
	c.camera_shake = camera_shake
	c.hit_sequence = hit_sequence
	return c


func _to_string() -> String:
	var atk_name := attack.attack_id if attack != null else &"?"
	return "[Damage %.1f poise=%.1f w=%d from=%s at=%s]" % [
		damage, poise_damage, weight,
		atk_name,
		"%.1f,%.1f,%.1f" % [hit_position.x, hit_position.y, hit_position.z]
	]
