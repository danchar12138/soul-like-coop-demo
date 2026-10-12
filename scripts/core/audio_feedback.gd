extends Node
## 音效接线器（Autoload 单例）。
##
## 职责：把 `EventBus` 上的战斗事件翻译成 `AudioManager` 的播放调用。
##
## ## 为什么单独一个节点，而不是在 CombatResolver 里直接播
##
## 之前 `CombatResolver_resolver.play_hit_feedback()` 只发 EventBus 信号，
## `AttackData` 里的 `sfx_hit` / `sfx_swing` 字段虽然填了值，
## 但**没有任何代码读它们** —— 于是 14 个音效文件全部处于
## "已接入接口但无人调用"的状态，游戏里一片寂静。
##
## 做成独立的接线器有两个好处：
##   1. 音频与战斗逻辑解耦。将来做"关闭音效"选项、
##      或者在联机时只播自己的命中音，改这一个文件就够了。
##   2. 战斗代码不需要知道有音效这回事。`CombatResolver` 只负责
##      "发生了什么"，这里负责"听起来像什么"。
##
## ## 谁决定播哪个音
##
## `AttackData` 上有 `sfx_hit` / `sfx_swing` 两个字段，由
## `tools/generate_weapons.gd` 按攻击的重量级填好（轻/中/重/居合…）。
## 本脚本直接读它们，而不是按重量在这里再写一遍 match ——
## 数值与表现必须来自同一处配置，否则调了一条忘了另一条。

## 命中反馈的音量随重量递增。数值直接取自 SFX_DEFS 的 vol，
## 这里只做"是否需要额外补偿"的判断。
const PLAYER_HIT_PITCH_SPREAD := 0.10

## 统计（供调试面板显示）
var played_hits: int = 0
var played_swings: int = 0
var played_whiffs: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE

	EventBus.attack_started.connect(_on_attack_started)
	EventBus.attack_landed.connect(_on_attack_landed)
	EventBus.attack_whiffed.connect(_on_attack_whiffed)
	EventBus.entity_died.connect(_on_entity_died)
	EventBus.poise_broken.connect(_on_poise_broken)
	EventBus.player_died.connect(_on_player_died)


# ============================================================
# 事件处理
# ============================================================

## 攻击起手：播挥空音。
##
## 【为什么在起手就播，而不是等判定结束确认落空再播】
## 挥空音是"刀划开空气"的声音，它本来就发生在**挥砍的那一刻**，
## 也就是起手之后的瞬间，而不是判定结束之后。
## 等确认落空再播（约 0.4 秒后）会让人感觉声音慢了半拍。
##
## 代价是：如果这一刀打中了，会同时听到挥空音和命中音。
## 这其实是**符合真实听感的** —— 真实的挥击本来就有破空声，
## 命中时再叠加碰撞声。所以不需要抑制。
func _on_attack_started(attacker: Node, attack_id: StringName) -> void:
	if attacker == null or not is_instance_valid(attacker):
		return
	# 闪避用的是同一个信号，但它有自己的音效，不播挥空音
	if attack_id == &"dodge":
		AudioManager.play_3d(&"dodge", _pos(attacker, 0.9))
		return

	var key := _swing_key_for(attacker, attack_id)
	if key.is_empty():
		return
	_play_3d(key, attacker, 1.1)
	played_swings += 1


func _on_attack_landed(attacker: Node, target: Node, hit_position: Vector3,
		_damage: float, _weight: float) -> void:
	# 命中音用**世界命中点**，不是攻击者的位置 ——
	# 玩家打 3 米外的木桩时，声音应该从木桩那边传来。
	#
	# 【联机注意】这里所有端都会收到 attack_landed 并播命中音。
	# 这是刻意的：`CombatResolver.play_hit_feedback()` 在所有端都调用，
	# 因为它只做表现、不改数值。每个玩家都应该听到自己附近的打击声，
	# 而不是只有主机听到。
	var key := _hit_key_for_attacker(attacker)
	if key.is_empty():
		return
	if hit_position != Vector3.ZERO:
		AudioManager.play_3d(key, hit_position, PLAYER_HIT_PITCH_SPREAD)
	else:
		_play_3d(key, attacker, 1.0)
	played_hits += 1

	# 命中可破坏地形时额外播石头音。
	# 判断依据：目标是不是角色（有 Health 组件）。地形件没有。
	if target != null and is_instance_valid(target) and target.get_node_or_null("Health") == null:
		AudioManager.play_3d(&"hit_stone", hit_position, 0.16)


## 攻击落空（判定结束但一个都没打到）。
##
## 这里**不播**挥空音 —— 那个音在起手时就播过了。
## 保留这个处理函数是为了将来做"未命中时的额外反馈"
## （例如轻微的动作顿挫），以及统计未命中次数。
func _on_attack_whiffed(attacker: Node, _attack_id: StringName) -> void:
	if attacker == null or not is_instance_valid(attacker):
		return
	played_whiffs += 1


func _on_entity_died(entity: Node, _killer: Node) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	# 玩家死亡音只在本地玩家死亡时播（其他玩家的死亡声由
	# 他们自己的客户端播，避免四台机器同时播同一个音）
	var p := entity as PlayerController
	if p != null and not p.is_local:
		return
	_play_3d(&"died", entity, 0.6)


func _on_poise_broken(entity: Node, _window: float) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	_play_3d(&"poise_break", entity, 0.3)


func _on_player_died(player: Node) -> void:
	# 走 entity_died 那条路径即可，这里不重复播。
	# 保留空实现是为了让"哪些事件被监听了"一目了然。
	pass


# ============================================================
# 音效键解析
# ============================================================

## 从攻击者身上取"这条攻击用哪个挥空音"。
##
## 攻击者的武器数据（`WeaponData`）里每种攻击都有 `sfx_swing`。
## 拿不到就退回到按攻击名推断 —— 敌人（木桩、Boss）没有 WeaponData，
## 它们按攻击名包含的关键字选。
func _swing_key_for(attacker: Node, attack_id: StringName) -> StringName:
	var from_data := _lookup_attack_sfx(attacker, attack_id, true)
	if not from_data.is_empty():
		return from_data
	return _guess_by_name(attack_id, true)


func _hit_key_for_attacker(attacker: Node) -> StringName:
	# 攻击者身上"当前正在执行的攻击"决定命中音
	var ac := attacker.get_node_or_null("AttackController")
	if ac != null:
		var atk: Variant = ac.get("current_attack")
		if atk is AttackData:
			var k := (atk as AttackData).sfx_hit
			if not k.is_empty():
				return k
	# 退回到"按攻击者的身份"选
	var is_boss := attacker.is_in_group(&"boss")
	return &"boss_hit" if is_boss else &"hit_light"


## 从攻击者的 WeaponData 里查这条攻击的音效键
func _lookup_attack_sfx(attacker: Node, attack_id: StringName, swing: bool) -> StringName:
	var w: Variant = attacker.get("weapon_data")
	if not (w is WeaponData):
		# 敌人没有 WeaponData，但它可能在 AttackController 上挂着
		# 当前攻击的 AttackData（Boss 就是这样构造自己的招式的）
		var ac := attacker.get_node_or_null("AttackController")
		if ac != null:
			var cur: Variant = ac.get("current_attack")
			if cur is AttackData:
				var a := cur as AttackData
				return a.sfx_swing if swing else a.sfx_hit
		return &""

	var atk := (w as WeaponData).find_attack(attack_id)
	if atk == null:
		return &""
	return atk.sfx_swing if swing else atk.sfx_hit


## 按攻击名的关键字猜音效（兜底）。
## 只在拿不到 AttackData 时用 —— 例如敌人临时构造的招式。
func _guess_by_name(attack_id: StringName, swing: bool) -> StringName:
	var s := String(attack_id)
	if s.contains("iai"):
		return &"swing_iai" if swing else &"hit_heavy"
	if s.contains("execution"):
		return &"swing_iai" if swing else &"hit_execution"
	# Boss 的招式名含 boss_
	if s.contains("boss_") or s.contains("sweep") or s.contains("slam") \
			or s.contains("charge") or s.contains("backhand"):
		return &"boss_swing" if swing else &"boss_hit"
	if s.contains("heavy"):
		return &"swing_heavy" if swing else &"hit_heavy"
	if s.contains("dummy"):
		return &"swing_medium" if swing else &"hit_medium"
	if s.contains("light_3") or s.contains("dodge_attack"):
		return &"swing_medium" if swing else &"hit_medium"
	return &"swing_light" if swing else &"hit_light"


# ============================================================
# 辅助
# ============================================================

func _pos(node: Node, height: float) -> Vector3:
	var n3 := node as Node3D
	if n3 == null:
		return Vector3.ZERO
	return n3.global_position + Vector3.UP * height


func _play_3d(key: StringName, node: Node, height: float) -> void:
	AudioManager.play_3d(key, _pos(node, height), 0.10)
