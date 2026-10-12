class_name EnemyBase
extends CharacterBody3D
## 敌人基类：普通敌人和 Boss 的共同父类。
##
## 提供的公共能力：
##   - 移动（追向目标、保持攻击距离）
##   - 攻击（通过 AttackController，与玩家走同一条伤害管线）
##   - 受击硬直 / 架势破除 / 死亡
##   - 目标选择（多人时不能只盯一个人）
##
## 子类只需要覆写 _ai_think() 来决定"下一招出什么"，
## 不必关心攻击时序、命中判定、硬直这些底层机制。
##
## 与玩家的差异：
##   - 敌人不消耗精力（stamina 为 null，AttackController.is_player = false）
##   - 敌人攻击由 AI 直接调用 request_attack(atk, force=true)

signal aggro_changed(new_target: Node3D)
signal attack_telegraphed(attack: AttackData, duration: float)

@export_group("身份")
@export var entity_name: String = "敌人"
## 是否可被锁定
@export var is_lockon_target: bool = true

@export_group("移动")
@export var move_speed: float = 3.2
@export var turn_speed: float = 420.0
## 转身朝向目标的最大角速度（攻击时用）
@export var attack_tracking_speed: float = 260.0

@export_group("AI 通用参数")
## 进入战斗的距离
@export var aggro_range: float = 22.0
## 脱离战斗的距离
@export var deaggro_range: float = 34.0
## 攻击冷却（两次攻击之间的最短间隔）
@export var attack_cooldown: float = 1.4
## 全局攻击行为开关（用于"跪地处决"等状态，也用于测试隔离）
##
## 【注意这个 setter】
## 外部（例如自动化测试、过场演出）把 ai_enabled 设为 false 时，
## 会在 _ai_forced_off 上留一个记号。子类里那些"延迟若干秒后自动
## 开启 AI"的逻辑必须尊重这个记号，否则会出现：
##   测试一开始关掉 AI -> 1.2 秒后 Boss 自己把 AI 打开了 ->
##   玩家在后续用例里被 Boss 打进硬直 -> 一堆无关用例失败。
## 这个坑真实发生过（见 docs/测试记录.md 的 T9 排查记录）。
@export var ai_enabled: bool = true : set = _set_ai_enabled

## 是否被外部强制关闭过 AI。一旦为 true，自动开启逻辑不再生效。
var _ai_forced_off: bool = false
## 转向目标时的死区（角度小于该值认为已经对准）
@export var facing_tolerance_deg: float = 14.0


func _set_ai_enabled(value: bool) -> void:
	ai_enabled = value
	if not value:
		_ai_forced_off = true


## 子类用它替代裸写 `ai_enabled = true`，以尊重外部的强制关闭。
func enable_ai_after_delay(seconds: float) -> void:
	var t := get_tree().create_timer(seconds, false)
	t.timeout.connect(func () -> void:
		if is_instance_valid(self) and not _ai_forced_off:
			ai_enabled = true
	)


## 测试/调试用：彻底解除强制关闭
func clear_ai_force_off() -> void:
	_ai_forced_off = false

# ------ 子系统 ------
var state_machine: CharacterStateMachine
var attack_controller: AttackController
var health: HealthComponent
var poise: PoiseComponent
var hit_reactor: HitReactor
var model_root: Node3D

# ------ AI 状态 ------
var target: Node3D = null
var _cooldown_left: float = 0.0
## 是否已发现自己被打（被打后即使超距也会短暂追击）
var _provoked_timer: float = 0.0

## 受击后是否会被打断（Boss 较重，普通敌人较轻）
@export var poise_armor: bool = false


func _ready() -> void:
	state_machine = get_node_or_null("StateMachine") as CharacterStateMachine
	attack_controller = get_node_or_null("AttackController") as AttackController
	health = get_node_or_null("Health") as HealthComponent
	poise = get_node_or_null("Poise") as PoiseComponent
	hit_reactor = get_node_or_null("HitReactor") as HitReactor
	model_root = get_node_or_null("Model") as Node3D

	if is_lockon_target:
		add_to_group(&"lockon_targets")

	if health != null:
		health.died.connect(_on_died)
		health.damaged.connect(_on_damaged)
	if poise != null:
		poise.broken.connect(_on_poise_broken)
		poise.recovered.connect(_on_poise_recovered)
	if attack_controller != null:
		attack_controller.attack_phase_changed.connect(_on_attack_phase)

	_setup_stats()
	EventBus.entity_died.connect(_on_any_entity_died)


## 子类覆写：设置血量/架势等数值
func _setup_stats() -> void:
	if health != null:
		health.max_health = GameConfig.ENEMY_MAX_HEALTH
		health.health = health.max_health
	if poise != null:
		poise.max_poise = GameConfig.ENEMY_POISE_MAX
		poise.current = poise.max_poise


func _physics_process(delta: float) -> void:
	if health != null and health.is_dead:
		_tick_dead(delta)
		return

	# 【联机】敌人 AI 只在权威端（主机）运行。
	# 客户端上的敌人完全由 EnemySync 驱动位置与状态 —— 如果客户端
	# 也跑一份 AI，各端的随机招式选择会让敌人位置和出招迅速分叉，
	# 玩家看到的 Boss 会和队友看到的不是同一个（见 enemy_sync.gd 的说明）。
	if NetManager != null and NetManager.is_session_active() and not multiplayer.is_server():
		_tick_gravity(delta)
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
		move_and_slide()
		return

	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	_provoked_timer = maxf(0.0, _provoked_timer - delta)

	if not ai_enabled:
		velocity.x = move_toward(velocity.x, 0.0, 20.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 20.0 * delta)
		move_and_slide()
		return

	_update_target()
	_tick_gravity(delta)

	var st := state_machine.get_state() if state_machine != null else CombatState.State.IDLE

	# 受击硬直 / 破防 / 死亡：不做 AI
	if st in [CombatState.State.HITSTUN, CombatState.State.POISE_BREAK,
			CombatState.State.EXECUTED, CombatState.State.DEAD]:
		_apply_knockback(delta)
		velocity.x = move_toward(velocity.x, 0.0, 26.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 26.0 * delta)
		move_and_slide()
		return

	# 攻击中：只允许朝向追踪
	if attack_controller != null and attack_controller.is_attacking():
		_track_target_during_attack(delta)
		velocity.x = move_toward(velocity.x, 0.0, 22.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, 22.0 * delta)
		_apply_knockback(delta)
		move_and_slide()
		return

	_ai_think(delta)
	move_and_slide()


## 子类覆写：AI 决策。默认实现 = 追上去砍。
func _ai_think(delta: float) -> void:
	if target == null:
		_idle_brake(delta)
		return
	var dist := _horizontal_distance_to(target)
	var attack_range := _get_preferred_attack_range()

	if dist > attack_range:
		_move_toward(target, delta)
	else:
		_face_target(delta)
		_idle_brake(delta)
		_try_attack(dist)


## 子类覆写：返回希望发起的攻击（null = 不出招）
func _pick_attack(_dist: float) -> AttackData:
	return null


## 子类覆写：期望的攻击距离
func _get_preferred_attack_range() -> float:
	return 2.4


# ============================================================
# 移动辅助
# ============================================================

func _idle_brake(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 22.0 * delta)
	velocity.z = move_toward(velocity.z, 0.0, 22.0 * delta)


func _tick_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity", 26.0) * delta
	else:
		velocity.y = maxf(velocity.y, -0.1)


func _move_toward(pos: Node3D, delta: float, speed_scale: float = 1.0) -> void:
	var to := pos.global_position - global_position
	to.y = 0.0
	if to.length_squared() < 0.01:
		return
	var dir := to.normalized()
	velocity.x = move_toward(velocity.x, dir.x * move_speed * speed_scale, 18.0 * delta)
	velocity.z = move_toward(velocity.z, dir.z * move_speed * speed_scale, 18.0 * delta)
	_face_direction(dir, delta, turn_speed)


func _face_target(delta: float, speed: float = -1.0) -> void:
	if target == null:
		return
	var to := target.global_position - global_position
	to.y = 0.0
	if to.length_squared() < 0.01:
		return
	_face_direction(to.normalized(), delta, speed if speed > 0.0 else turn_speed)


func _face_direction(dir: Vector3, delta: float, speed: float) -> void:
	# 注意 -Z 前向约定，见 scripts/core/math_util.gd 的说明
	var want := MathUtil.yaw_from_direction(dir)
	var diff := wrapf(want - global_rotation.y, -PI, PI)
	global_rotation.y += clampf(diff, -deg_to_rad(speed) * delta, deg_to_rad(speed) * delta)


func _is_facing_target(tolerance_deg: float = -1.0) -> bool:
	if target == null:
		return false
	var tol := tolerance_deg if tolerance_deg > 0.0 else facing_tolerance_deg
	var to := target.global_position - global_position
	to.y = 0.0
	if to.length_squared() < 0.01:
		return true
	var forward := -global_transform.basis.z
	return rad_to_deg(forward.angle_to(to.normalized())) <= tol


## 攻击时缓慢追踪目标（给玩家"绕背"的战术空间：绕得快就能躲开）
func _track_target_during_attack(delta: float) -> void:
	if target == null or attack_controller == null:
		return
	var atk := attack_controller.current_attack
	if atk == null:
		return
	# 只在起手阶段追踪，一旦进入有效帧就锁死方向
	if attack_controller.current_phase != AttackController.Phase.WINDUP:
		return
	_face_target(delta, attack_tracking_speed)


func _horizontal_distance_to(n: Node3D) -> float:
	var d := n.global_position - global_position
	d.y = 0.0
	return d.length()


func _apply_knockback(delta: float) -> void:
	if hit_reactor == null:
		return
	var kb := hit_reactor.consume_knockback()
	if kb == Vector3.ZERO:
		return
	velocity.x += kb.x * delta * 14.0
	velocity.z += kb.z * delta * 14.0


# ============================================================
# 目标管理（多人战斗中避免只盯一个人）
# ============================================================

func _update_target() -> void:
	# 目标死亡或失效 -> 重新选
	if target != null and (not is_instance_valid(target) or _is_target_dead(target)):
		target = null

	var dist := INF
	if target != null:
		dist = global_position.distance_to(target.global_position)

	# 超出脱战距离且不是刚被打过 -> 放弃
	if target != null and dist > deaggro_range and _provoked_timer <= 0.0:
		target = null

	if target == null:
		var new_target := _select_target()
		if new_target != null:
			target = new_target
			aggro_changed.emit(target)


## 子类可覆写以改变选敌策略（Boss 会用它做目标切换）
func _select_target() -> Node3D:
	var best: Node3D = null
	var best_dist := aggro_range
	for p: Node3D in GameState.get_alive_players():
		var d := global_position.distance_to(p.global_position)
		if d < best_dist:
			best_dist = d
			best = p
	return best


func _is_target_dead(n: Node3D) -> bool:
	var h := n.get_node_or_null("Health") as HealthComponent
	return h != null and h.is_dead


func force_target(t: Node3D) -> void:
	if t == null or t == target:
		return
	target = t
	aggro_changed.emit(target)


# ============================================================
# 攻击
# ============================================================

func _try_attack(dist: float) -> void:
	if attack_controller == null or _cooldown_left > 0.0:
		return
	if not _is_facing_target():
		return

	var atk := _pick_attack(dist)
	if atk == null:
		return

	if attack_controller.request_attack(atk, true):
		_cooldown_left = attack_cooldown * _get_cooldown_scale()


## 子类可覆写：根据阶段/人数调整冷却
func _get_cooldown_scale() -> float:
	return 1.0


func _on_attack_phase(atk: AttackData, phase: int) -> void:
	# 起手阶段发出"预警"信号，供表现层（红光、音效）订阅
	if phase == AttackController.Phase.WINDUP:
		attack_telegraphed.emit(atk, atk.windup)


# ============================================================
# 受击 / 死亡
# ============================================================

func _on_damaged(info: DamageInfo, _remaining: float) -> void:
	_provoked_timer = 6.0
	# 被打时若没有目标，把攻击者设为目标
	if target == null and info.attacker != null and info.attacker is Node3D:
		if info.attacker.has_node("Health"):
			force_target(info.attacker as Node3D)

	if poise_armor:
		# 霸体：架势没破就不进硬直，只播受击表现
		# 但如果是重击仍然给一个很短的僵直，避免打击感完全丢失
		if info.is_heavy and state_machine != null:
			if not state_machine.is_state(CombatState.State.POISE_BREAK):
				state_machine.enter_hitstun(info.hitstun * 0.35)
		return

	apply_hitstun(info.hitstun, info.is_heavy)


## 进入受击硬直。子类可覆写以加入特殊表现。
func apply_hitstun(duration: float, _is_heavy: bool) -> void:
	if state_machine == null:
		return
	if state_machine.is_state(CombatState.State.DEAD):
		return
	if attack_controller != null:
		attack_controller.notify_interrupted()
	state_machine.enter_hitstun(duration)


func _on_poise_broken(window: float) -> void:
	# 架势破除：播放长硬直，开启处决窗口
	if state_machine == null:
		return
	if attack_controller != null:
		attack_controller.notify_interrupted()
	state_machine.enter_poise_break(window)
	_on_poise_break_visual()
	EventBus.hitstun_started.emit(self, window, true)


## 子类覆写：破防的表现（Boss 跪下、小怪瘫倒）
func _on_poise_break_visual() -> void:
	pass


func _on_poise_recovered() -> void:
	if state_machine != null and state_machine.is_state(CombatState.State.POISE_BREAK):
		state_machine.force_state(CombatState.State.IDLE)


## 玩家在破防窗口内发动处决、且处决攻击命中后调用。
##
## 基类的实现只做"结束破防 + 短暂僵直"。**不在这里扣血** ——
## 伤害由处决攻击自己的判定盒结算，重复扣血会破坏
## "伤害只有一条路径"的架构原则（见 docs/架构说明.md 4.3）。
## 子类可以覆写以加入特殊演出。
func on_executed(_by: Node) -> void:
	if poise != null:
		poise.consume_break()
	if attack_controller != null:
		attack_controller.notify_interrupted()
	if state_machine != null:
		state_machine.enter_hitstun(0.8)


func _on_died(_killer: Node) -> void:
	if state_machine != null:
		state_machine.enter_dead()
	if attack_controller != null:
		attack_controller.notify_death()
	if poise != null:
		poise.set_process(false)
	target = null
	set_collision_layer_value(3, false)


func _tick_dead(_delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0.0, 30.0 * _delta_safe(_delta))
	velocity.z = move_toward(velocity.z, 0.0, 30.0 * _delta_safe(_delta))
	if not is_on_floor():
		velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity", 26.0) * _delta_safe(_delta)
	move_and_slide()


func _delta_safe(d: float) -> float:
	return clampf(d, 0.0, 0.1)


func _on_any_entity_died(_entity: Node, _killer: Node) -> void:
	# 目标死亡后立刻清空，避免 AI 追逐尸体
	if target != null and _is_target_dead(target):
		target = null


func get_debug_string() -> String:
	# 显式声明为 String：三元表达式一边是 StringName、一边是 String，
	# 用 := 推断会得到 Variant 并触发警告（本项目把该警告当错误处理）。
	var t: String = String(target.name) if target != null else "无"
	return "目标: %s   冷却: %.2fs" % [t, _cooldown_left]
