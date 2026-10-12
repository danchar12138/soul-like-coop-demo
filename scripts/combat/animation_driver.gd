class_name AnimationDriver
extends Node
## 用骨骼动画驱动角色表现。
##
## 挂载位置：角色根节点下的 "AnimationDriver" 节点。
## 旁边的 "Model" 下应当有一个 `AnimationPlayer`（由骨架 GLB 带出）。
##
## ## 为什么需要这个脚本
##
## 项目的战斗逻辑（`AttackController` 的起手/有效/收招）早已完成并有
## 测试覆盖，但角色表现一直是"整个模型平移 + 旋转"，看不出挥刀。
## 有了骨骼动画之后，需要有人**在正确的时间点播放正确的动画**，
## 并且**动画时长必须与战斗配置对齐** —— 否则会出现
## "判定已经打出去了，刀还没挥到"这种致命错位。
##
## 本脚本就是做这件事的：把 `AttackController` 的相位事件
## 翻译成 `AnimationPlayer` 的调用，并在开始时按攻击数据
## 动态调整动画播放速度，保证动画的总时长 = 攻击的总时长。
##
## ## 动画名对应关系
##
## 动画名与 `AttackData.attack_id` 一致（生成脚本按此命名），
## 所以不需要额外的映射表。缺动画时静默跳过，不报错 ——
## 这样换模型（例如用没有动画的静态版 player.glb）时不会刷错误日志。

## 动画播放器（在 Model 下自动查找）
var anim_player: AnimationPlayer

## 角色根节点
var actor: Node3D

# --- 子系统引用 ---
var state_machine: CharacterStateMachine
var attack_controller: AttackController
var health: HealthComponent

## 当前正在播放的动画名
var _current: StringName = &""

## 状态 -> 动画名
const STATE_ANIMS := {
	CombatState.State.IDLE: &"idle",
	CombatState.State.SPRINT: &"run",
	CombatState.State.DODGE: &"dodge",
	CombatState.State.POISE_BREAK: &"poise_break",
	CombatState.State.DEAD: &"death",
}

## 是否启用（关掉后完全不影响逻辑，便于对照排查）
@export var enabled: bool = true


func _ready() -> void:
	actor = get_parent() as Node3D
	if actor == null:
		push_error("AnimationDriver 必须挂在角色根节点下")
		return

	anim_player = _find_animation_player(actor)
	if anim_player == null:
		# 没有动画播放器（例如用了静态 GLB）不是错误，直接停用。
		# 这样换模型时不会刷一堆 "动画不存在" 的报错。
		print("[动画] 未找到 AnimationPlayer，动画驱动已停用（模型可能是静态版）")
		enabled = false
		set_process(false)
		return

	print("[动画] 已找到 AnimationPlayer，可用动画 %d 个：%s" % [
		anim_player.get_animation_list().size(),
		", ".join(_anim_names())])

	state_machine = actor.get_node_or_null("StateMachine") as CharacterStateMachine
	attack_controller = actor.get_node_or_null("AttackController") as AttackController
	health = actor.get_node_or_null("Health") as HealthComponent

	if state_machine != null:
		state_machine.state_changed.connect(_on_state_changed)
	if attack_controller != null:
		attack_controller.attack_phase_changed.connect(_on_attack_phase)
	if health != null:
		health.damaged.connect(_on_damaged)

	# 默认播待机
	play(&"idle")


func _anim_names() -> Array[String]:
	var out: Array[String] = []
	for n in anim_player.get_animation_list():
		out.append(String(n))
	return out


## 在 Model 子树里找 AnimationPlayer。
##
## 为什么不用固定路径：GLB 的节点层级随导出设置变化（Blender 会把场景
## 包一层同名的根节点、网格对象和骨架可能分家），写死路径很脆弱。
## 递归查找一次的成本可以忽略，换来的是换模型时不用改代码。
func _find_animation_player(root: Node) -> AnimationPlayer:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is AnimationPlayer:
			return n as AnimationPlayer
		for c in n.get_children():
			stack.append(c)
	return null


# ============================================================
# 播放控制
# ============================================================

## 播放一个动画。force = true 时即使已在播放同一个也重新开始。
func play(anim: StringName, force: bool = false, speed: float = 1.0) -> bool:
	if not enabled or anim_player == null:
		return false
	if anim.is_empty():
		return false
	if not anim_player.has_animation(String(anim)):
		# 动画不存在：不报错，也不改 _current，
		# 让上一个动画继续播（比突然静止好看）
		return false
	if _current == anim and not force:
		return true

	_current = anim
	anim_player.play(String(anim), -1.0, speed)
	return true


## 按"攻击的时序"播放对应动画，并调整播放速度让动画与判定窗口对齐。
##
## 【为什么必须动态调速】
## 动画是在 Blender 里按一组假定的时长录制的（见 blender_rig.py 的
## ATTACK_TIMINGS）。如果之后有人调了 `generate_weapons.gd` 里的
## windup/recovery（这很常见，调手感嘛），动画就会与判定错位。
##
## 与其要求两边永远手工同步（迟早会忘），不如运行时按实际配置
## 把动画拉伸到正确的总时长。代价是"动作快慢"会随调参变化 ——
## 但那种变化本来就是调参想要的效果，而错位是 bug。
func play_attack(attack: AttackData, force: bool = true) -> void:
	if not enabled or attack == null or anim_player == null:
		return
	if not anim_player.has_animation(String(attack.attack_id)):
		return

	var speed := 1.0
	var lib := anim_player.get_animation(String(attack.attack_id))
	if lib != null and lib.length > 0.001:
		var want := attack.get_total_duration()
		speed = lib.length / want
		# 限制在合理区间，避免配置写错时动画变成"闪现"
		speed = clampf(speed, 0.35, 3.0)

	play(attack.attack_id, force, speed)


## 播放一个动画，并直接跳到 `elapsed` 秒处的进度。
##
## 用途：远端玩家的动作同步。队友开始挥刀时要广播 (动画名, 开始时刻)，
## 收到方按"已经过去多久"跳到对应进度 —— 而不是从头播一遍。
## 头播一遍会让远端动作比实际晚一个 RTT，而且慢动作的队友看起来
## 像在重复挥空气。
##
## 已超过动画总时长时直接忽略（那个动作早就结束了）。
func play_at(anim: StringName, elapsed: float, speed: float = 1.0) -> bool:
	if not enabled or anim_player == null:
		return false
	if not anim_player.has_animation(String(anim)):
		return false

	var lib := anim_player.get_animation(String(anim))
	var total := lib.length / maxf(speed, 0.001) if lib != null else 0.0
	if total > 0.0 and elapsed >= total:
		return false

	_current = anim
	anim_player.play(String(anim), -1.0, speed)
	# seek 要在 play 之后调用，否则会被 play 重置回 0
	anim_player.seek(minf(elapsed * speed, lib.length if lib != null else elapsed),
		true)
	return true


# ============================================================
# 事件响应
# ============================================================

func _on_state_changed(_from: int, to: int) -> void:
	if not enabled:
		return

	# 【远端玩家的动画由 PlayerSync 单独驱动，这里要跳过】
	# 远端的动画是按"广播过来的 (动画名, 开始时刻)"跳到对应进度的，
	# 比看状态枚举自己猜要精确得多 —— 状态枚举没法表达"已经挥到哪儿了"。
	# 如果这里也插一手，会跟 PlayerSync 抢控制权，
	# 表现为远端动画在正确的进度和"从头播"之间来回跳。
	if not _is_local_player():
		return

	# 攻击状态由攻击相位事件单独处理 —— 它需要拿到具体的 AttackData。
	# 这里跳过，避免把攻击动画覆盖成待机。
	if to == CombatState.State.ATTACK:
		if attack_controller == null or attack_controller.current_attack == null:
			return
		play_attack(attack_controller.current_attack)
		return

	var anim: StringName = STATE_ANIMS.get(to, &"")
	if anim.is_empty():
		# 没有对应动画的状态（例如蓄力、被处决）保持当前动画，
		# 不要切回待机 —— 那会在蓄力时突然播待机，看起来像卡了
		return
	play(anim, true)


## 本节点所在的角色是否由本机控制。
## 离线时恒为 true（没有"远端"这个概念）。
func _is_local_player() -> bool:
	var p := actor as PlayerController
	if p == null:
		# 不是玩家（例如将来的敌人也用这个驱动），一律当作本地
		return true
	return p.is_local


func _on_attack_phase(attack: AttackData, phase: int) -> void:
	if not enabled or attack == null:
		return
	# 远端玩家的攻击动画由 PlayerSync 按进度驱动（见 _on_state_changed）
	if not _is_local_player():
		return

	match phase:
		AttackController.Phase.WINDUP:
			# 起手第一帧：整段动画从头播，让起手/有效/收招
			# 与动画的姿态变化对齐
			play_attack(attack, true)
		AttackController.Phase.ACTIVE:
			# 有效帧：什么都不做。动画已经在正确的位置上了 ——
			# 这正是"时长对齐"要保证的事。
			pass
		AttackController.Phase.RECOVERY:
			pass


func _on_damaged(info: DamageInfo, _remaining: float) -> void:
	if not enabled or info == null:
		return
	# 远端玩家的受击动画同样由 PlayerSync 驱动（受击也是一种会中断
	# 当前动作的表现），避免两套逻辑抢控制权
	if not _is_local_player():
		return
	# 受击动画按轻重分级。受击会打断攻击，所以强制切换。
	var anim: StringName = &"hit_heavy" if info.is_heavy else &"hit_light"
	play(anim, true)


# ============================================================
# 给测试/调试用的查询
# ============================================================

func get_current_anim() -> StringName:
	return _current


func has_anim(anim: StringName) -> bool:
	return anim_player != null and anim_player.has_animation(String(anim))
