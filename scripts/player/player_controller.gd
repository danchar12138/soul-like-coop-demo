class_name PlayerController
extends CharacterBody3D
## 主角控制器：移动、冲刺、闪避、攻击输入、锁定、死亡复活。
##
## 分层说明（避免"一个大脚本什么都干"）：
##   本脚本         = 输入采集 + 位移计算 + 把意图转交给子系统
##   StateMachine   = 谁在做主（能不能出招、能不能移动）
##   AttackController = 攻击时序与判定
##   Health/Stamina/Poise = 数值
##   HitReactor     = 受击表现
##
## 网络：只有本机权威的实例才读取输入并驱动位移。
## 其他玩家的位置由网络同步写入（见 scripts/net/player_sync.gd）。

signal dodge_started(direction: Vector3)
signal dodge_finished()
signal lock_target_changed(target: Node3D)
signal died()
signal respawned()

@export_group("身份")
## 联机 peer id。1 = 主机。
@export var peer_id: int = 1
## 玩家显示名
@export var display_name: String = "玩家"

@export_group("配置")
## 当前武器数据
@export var weapon_data: WeaponData
## 相机支架路径（相机可能放在角色外部，这里用导出便于替换）
@export var camera_rig_path: NodePath = ^"CameraRig"

@export_group("运行时（只读）")
## 是否由本机控制
var is_local: bool = true
## 朝向是否被锁定（攻击期间）
var facing_locked: bool = false

# ------ 子系统引用 ------
var state_machine: CharacterStateMachine
var attack_controller: AttackController
var health: HealthComponent
var stamina: StaminaComponent
var poise: PoiseComponent
var hit_reactor: HitReactor
var camera_rig: Node3D

# ------ 移动内部状态 ------
## 当前水平速度（用于 UI/调试）
var move_speed: float = 0.0
## 闪避方向（世界空间）
var _dodge_direction: Vector3 = Vector3.FORWARD
var _dodge_elapsed: float = 0.0
## 是否已经在这段闪避里给过无敌
var _dodge_iframe_granted: bool = false
## 上一帧是否处于闪避状态。用于检测"外部强制进入闪避"并重置计时器，
## 见 _tick_dodge() 的说明。
var _was_dodging: bool = false

## 颜色标识（联机区分四个玩家）
@export var player_color: Color = Color(0.85, 0.85, 0.9)

## 死亡后复活点
var _respawn_position: Vector3 = Vector3.ZERO


func _ready() -> void:
	state_machine = get_node_or_null("StateMachine") as CharacterStateMachine
	attack_controller = get_node_or_null("AttackController") as AttackController
	health = get_node_or_null("Health") as HealthComponent
	stamina = get_node_or_null("Stamina") as StaminaComponent
	poise = get_node_or_null("Poise") as PoiseComponent
	hit_reactor = get_node_or_null("HitReactor") as HitReactor
	camera_rig = get_node_or_null(camera_rig_path) as Node3D

	if weapon_data == null:
		weapon_data = load("res://resources/weapons/katana.tres") as WeaponData

	_is_local_setup()

	if health != null:
		health.max_health = GameConfig.PLAYER_MAX_HEALTH
		health.health = health.max_health
		health.died.connect(_on_died)
		health.damaged.connect(_on_damaged)
	if poise != null:
		poise.max_poise = GameConfig.PLAYER_POISE_MAX
		poise.current = poise.max_poise

	_respawn_position = global_position
	_upgrade_materials()
	GameState.register_player(peer_id, self)
	# local_player 是 UI / 相机 / 输入层的入口。
	# 联机时只有本机权威的那个实例才算"本地玩家"。
	# 注意这里用的是 apply_network_role() 的判定结果，而不是在 _ready 里
	# 直接算 —— 因为实例化时 authority 可能还没设好（见 apply_network_role）。
	if is_local:
		GameState.local_player = self
	EventBus.player_spawned.emit(self, peer_id)


## 由 LevelManager 在**加入场景树之后**调用，重新判定"我是不是本机的角色"。
##
## 【为什么需要这个额外的一步】
## `_ready()` 在 `add_child()` 的那一刻就执行，而
## `set_multiplayer_authority(peer_id)` 是之后才调用的。
## 如果在 _ready 里直接用 `is_multiplayer_authority()` 判断，
## 对于客户端来说每个玩家节点的 authority 都还是默认的 1，
## 于是**没有一个**玩家会被认成自己的 —— 症状是客户端的
## `GameState.local_player` 为 null，输入完全没有反应。
##
## LevelManager 现在的顺序是：设好 authority 再 add_child，
## 然后调用本方法再确认一次。两道保险都留着，改动风险最低。
func apply_network_role() -> void:
	_is_local_setup()
	if is_local:
		GameState.local_player = self
		_respawn_position = global_position
	else:
		if GameState.local_player == self:
			GameState.local_player = null


func _is_local_setup() -> void:
	if NetManager != null and NetManager.is_session_active():
		is_local = is_multiplayer_authority()
	else:
		is_local = true

	set_physics_process(is_local)
	if camera_rig != null and camera_rig.has_method("set_active"):
		camera_rig.call("set_active", is_local)

	if not is_local:
		# 远端玩家：不处理输入，位置由同步驱动
		pass


func _upgrade_materials() -> void:
	# 给占位模型染色，联机时四个玩家一眼可分
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(self, meshes)
	for m: MeshInstance3D in meshes:
		if m.material_override != null:
			continue
		var mat := StandardMaterial3D.new()
		mat.albedo_color = player_color
		mat.roughness = 0.7
		m.material_override = mat


func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	for c in node.get_children():
		if c is MeshInstance3D:
			out.append(c as MeshInstance3D)
		_collect_meshes(c, out)


# ============================================================
# 主循环
# ============================================================

func _physics_process(delta: float) -> void:
	if not is_local:
		return

	_tick_dodge(delta)
	_tick_movement(delta)
	_tick_input_buffer_only()

	move_and_slide()
	move_speed = Vector2(velocity.x, velocity.z).length()


func _tick_input_buffer_only() -> void:
	# 输入采集放在移动之后，保证同帧内状态是最新的
	if state_machine == null or state_machine.is_state(CombatState.State.DEAD):
		return
	if state_machine.is_state(CombatState.State.DOWNED):
		return
	_handle_jump_input()
	_handle_lock_on_input()
	_handle_dodge_input()
	_handle_attack_input()


## 跳跃 / 越障。
##
## 定位（任务书 4.1）："基础跳跃或越障能力，前提是不会影响核心战斗开发"。
## 所以这里的实现刻意保守：
##   - 只在待机/冲刺时可用（攻击、闪避、受击中一律不能跳）
##   - 跳跃初速 8.0 m/s，配合重力 26 得到约 0.6 秒滞空、1.2 m 高度
##   - 空中不能攻击、不能再跳，避免出现"跳斩"这种需要额外平衡的机制
## 这样跳跃只解决"越障"和"拉开距离"，不会和战斗系统互相干扰。
func _handle_jump_input() -> void:
	if not Input.is_action_just_pressed(&"jump"):
		return
	if not is_on_floor():
		return
	if state_machine == null:
		return
	if not state_machine.is_state(CombatState.State.IDLE) \
			and not state_machine.is_state(CombatState.State.SPRINT):
		return
	velocity.y = GameConfig.JUMP_VELOCITY


# ------------------------------------------------------------
# 移动
# ------------------------------------------------------------

func _tick_movement(delta: float) -> void:
	if state_machine == null:
		return

	var st := state_machine.get_state()

	# 重力
	if not is_on_floor():
		velocity.y -= ProjectSettings.get_setting("physics/3d/default_gravity", 26.0) \
			* GameConfig.GRAVITY_SCALE * delta
	else:
		velocity.y = maxf(velocity.y, -0.1)

	# 死亡/倒地：只受重力与摩擦
	if st == CombatState.State.DEAD or st == CombatState.State.DOWNED:
		velocity.x = move_toward(velocity.x, 0.0, GameConfig.DECELERATION * delta)
		velocity.z = move_toward(velocity.z, 0.0, GameConfig.DECELERATION * delta)
		return

	# 闪避状态：位移由闪避自己驱动
	if st == CombatState.State.DODGE:
		return

	# 硬直/破防：速度快速衰减 + 击退
	if st == CombatState.State.HITSTUN or st == CombatState.State.POISE_BREAK:
		_apply_knockback(delta)
		velocity.x = move_toward(velocity.x, 0.0, GameConfig.DECELERATION * 1.8 * delta)
		velocity.z = move_toward(velocity.z, 0.0, GameConfig.DECELERATION * 1.8 * delta)
		return

	# 攻击中：只有明确允许移动的攻击才接受输入，否则原地
	var in_attack := attack_controller != null and attack_controller.is_attacking()
	if in_attack:
		var atk := attack_controller.current_attack
		if atk == null or not atk.allow_movement:
			_apply_knockback(delta)
			velocity.x = move_toward(velocity.x, 0.0, GameConfig.DECELERATION * 1.4 * delta)
			velocity.z = move_toward(velocity.z, 0.0, GameConfig.DECELERATION * 1.4 * delta)
			return

	# ---- 正常移动 ----
	var input := _get_move_input()
	var basis := _get_movement_basis()
	var direction := (basis.x * input.x + basis.z * input.y)
	direction.y = 0.0
	if direction.length_squared() > 1.0:
		direction = direction.normalized()

	var want_sprint := Input.is_action_pressed(&"sprint") and input.length() > 0.1 and stamina != null and not stamina.is_exhausted
	var target_speed := GameConfig.SPRINT_SPEED if want_sprint else GameConfig.MOVE_SPEED
	# 重武器略微降低移速，让"重量"体现在走位上
	if weapon_data != null:
		target_speed *= lerpf(1.0, 0.88, clampf(weapon_data.weight_class / 2.0, 0.0, 1.0))

	var target_velocity := direction * target_speed
	var accel := GameConfig.ACCELERATION if direction.length_squared() > 0.01 else GameConfig.DECELERATION
	if not is_on_floor():
		accel *= GameConfig.AIR_CONTROL

	velocity.x = move_toward(velocity.x, target_velocity.x, accel * delta)
	velocity.z = move_toward(velocity.z, target_velocity.z, accel * delta)

	# 冲刺状态标记（供动画与精力消耗）
	if want_sprint and state_machine.is_state(CombatState.State.IDLE):
		state_machine.request_state(CombatState.State.SPRINT)
	elif not want_sprint and state_machine.is_state(CombatState.State.SPRINT):
		state_machine.force_state(CombatState.State.IDLE)

	# 转向：锁定时面向目标，自由时面向移动方向
	_update_facing(delta, direction)

	# 击退叠加
	_apply_knockback(delta)


func _apply_knockback(delta: float) -> void:
	if hit_reactor == null:
		return
	var kb := hit_reactor.consume_knockback()
	if kb == Vector3.ZERO:
		return
	velocity.x += kb.x * delta * 14.0
	velocity.z += kb.z * delta * 14.0


## 相机相关的移动基准：没有相机时退化为世界坐标
func _get_movement_basis() -> Basis:
	if camera_rig != null and camera_rig.has_method("get_movement_basis"):
		return camera_rig.call("get_movement_basis")
	return Basis.IDENTITY


func _get_move_input() -> Vector2:
	var v := Vector2(
		Input.get_action_strength(&"move_right") - Input.get_action_strength(&"move_left"),
		Input.get_action_strength(&"move_back") - Input.get_action_strength(&"move_forward")
	)
	if v.length() > 1.0:
		v = v.normalized()
	return v


func _update_facing(delta: float, move_direction: Vector3) -> void:
	if facing_locked:
		return

	var desired := Vector3.ZERO

	# 锁定时面向目标
	if GameState.locked_target != null and is_instance_valid(GameState.locked_target):
		var to_target := GameState.locked_target.global_position - global_position
		to_target.y = 0.0
		if to_target.length_squared() > 0.01:
			desired = to_target.normalized()
	elif move_direction.length_squared() > 0.01:
		desired = move_direction.normalized()

	if desired == Vector3.ZERO:
		return

	var speed := GameConfig.LOCKED_TURN_SPEED if GameState.locked_target != null else GameConfig.TURN_SPEED
	_rotate_towards(desired, speed, delta)


func _rotate_towards(desired: Vector3, max_deg_per_sec: float, delta: float) -> void:
	# 用 MathUtil 统一处理朝向角。Godot 的约定是"前方 = -Z"，
	# 所以是 atan2(-x, -z) 而不是 atan2(x, z)。这个符号写错会导致
	# 角色看起来在走但判定盒留在背后 —— 见 math_util.gd 的说明。
	var current_yaw := global_rotation.y
	var target_yaw := MathUtil.yaw_from_direction(desired)
	global_rotation.y = MathUtil.rotate_yaw_towards(
		current_yaw, target_yaw, deg_to_rad(max_deg_per_sec) * delta)


# ------------------------------------------------------------
# 锁定
# ------------------------------------------------------------

func _handle_lock_on_input() -> void:
	if not Input.is_action_just_pressed(&"lock_on"):
		return
	if state_machine != null and state_machine.is_locked():
		return
	_toggle_lock_on()


func _toggle_lock_on() -> void:
	if GameState.locked_target != null:
		GameState.locked_target = null
		lock_target_changed.emit(null)
		EventBus.lock_on_changed.emit(self, null)
		return

	var target := _find_lock_target()
	GameState.locked_target = target
	lock_target_changed.emit(target)
	EventBus.lock_on_changed.emit(self, target)


## 寻找锁定目标：视野内最近的敌人，且不被墙体完全遮挡
func _find_lock_target() -> Node3D:
	var best: Node3D = null
	var best_score := INF
	var cam_pos := _get_camera_position()
	var cam_forward := _get_camera_forward()

	for node in get_tree().get_nodes_in_group(&"lockon_targets"):
		var n := node as Node3D
		if n == null or not is_instance_valid(n):
			continue
		var h := n.get_node_or_null("Health") as HealthComponent
		if h != null and h.is_dead:
			continue
		var to_n := n.global_position - cam_pos
		var dist := to_n.length()
		if dist > 24.0:
			continue
		var dot := cam_forward.dot(to_n.normalized())
		if dot < 0.25:  # 必须在镜头前方大约 75 度锥内
			continue
		# 评分：越正对、越近越好
		var score := dist * (2.0 - dot)
		if score < best_score:
			best_score = score
			best = n
	return best


func _get_camera_position() -> Vector3:
	if camera_rig != null and camera_rig.has_method("get_camera_global_position"):
		return camera_rig.call("get_camera_global_position")
	return global_position + Vector3.UP * 1.6


func _get_camera_forward() -> Vector3:
	if camera_rig != null and camera_rig.has_method("get_camera_forward"):
		return camera_rig.call("get_camera_forward")
	return -global_transform.basis.z


# ------------------------------------------------------------
# 闪避
# ------------------------------------------------------------

func _handle_dodge_input() -> void:
	if not Input.is_action_just_pressed(&"dodge"):
		return
	_try_dodge()


func _try_dodge() -> bool:
	if state_machine == null:
		return false

	# 攻击中可以取消成闪避（但有效判定帧内不行）
	if attack_controller != null and attack_controller.is_attacking():
		if not attack_controller.can_cancel_to_dodge():
			return false

	if not state_machine.can_start_dodge():
		return false

	if stamina != null and not stamina.try_spend(GameConfig.DODGE_STAMINA_COST, &"dodge"):
		return false

	# 闪避方向：有输入则按输入（相机相对），无输入则后退
	var input := _get_move_input()
	var direction: Vector3
	if input.length_squared() > 0.04:
		var basis := _get_movement_basis()
		direction = (basis.x * input.x + basis.z * input.y)
		direction.y = 0.0
		direction = direction.normalized()
	else:
		direction = global_transform.basis.z  # 向后
		direction.y = 0.0
		direction = direction.normalized()

	# 通知攻击控制器结束当前攻击
	if attack_controller != null and attack_controller.is_attacking():
		attack_controller.notify_cancelled_by_dodge()

	_dodge_direction = direction
	_dodge_elapsed = 0.0
	_dodge_iframe_granted = false

	state_machine.force_state(CombatState.State.DODGE, GameConfig.DODGE_DURATION)
	# 闪避时立即转向到闪避方向（同样注意 -Z 前向约定）
	global_rotation.y = MathUtil.yaw_from_direction(direction)

	dodge_started.emit(direction)
	EventBus.attack_started.emit(self, &"dodge")
	return true


func _tick_dodge(delta: float) -> void:
	if state_machine == null or not state_machine.is_state(CombatState.State.DODGE):
		# 记录"不在闪避中"，这样下次进入闪避时能检测到状态跳变
		_was_dodging = false
		return

	# 【状态跳变检测】
	# 闪避一般由 _try_dodge() 发起，那里会把计时器清零。但状态机也可能
	# 被**外部**强制设为闪避 —— 例如 PlayerSync 收到远端玩家的状态、
	# 或测试直接调用 force_state()。那时计时器还留着上一次闪避的残值，
	# 于是 `_dodge_elapsed >= DODGE_DURATION` 立刻成立，
	# 闪避在第一帧就结束了（表现为"闪避动画根本不播"）。
	# 所以这里主动检测跳变并重置。
	if not _was_dodging:
		_was_dodging = true
		_dodge_elapsed = 0.0
		_dodge_iframe_granted = false

	_dodge_elapsed += delta
	var t := clampf(_dodge_elapsed / GameConfig.DODGE_DURATION, 0.0, 1.0)

	# 速度曲线：前段快、后段急停。用 sqrt 形曲线让起步干脆、收尾利落。
	var curve := 2.0 * (1.0 - sqrt(t))
	var speed := (GameConfig.DODGE_DISTANCE / GameConfig.DODGE_DURATION) * curve * 1.55
	velocity.x = _dodge_direction.x * speed
	velocity.z = _dodge_direction.z * speed

	# 无敌帧窗口
	if not _dodge_iframe_granted and _dodge_elapsed >= GameConfig.DODGE_IFRAME_START:
		_dodge_iframe_granted = true
	if health != null:
		if _dodge_elapsed >= GameConfig.DODGE_IFRAME_START and _dodge_elapsed < GameConfig.DODGE_IFRAME_END:
			# 每帧续一小段，避免时间精度问题；窗口本身很短
			health.grant_invulnerability(delta * 2.0)

	# 收招阶段允许提前取消（接攻击或再翻滚）
	if t >= GameConfig.DODGE_CANCEL_AT and _dodge_elapsed >= GameConfig.DODGE_IFRAME_END:
		# 有缓冲的攻击输入则直接接攻击
		pass

	if _dodge_elapsed >= GameConfig.DODGE_DURATION:
		state_machine.force_state(CombatState.State.IDLE)
		dodge_finished.emit()


# ------------------------------------------------------------
# 攻击输入
# ------------------------------------------------------------

func _handle_attack_input() -> void:
	if attack_controller == null or weapon_data == null:
		return

	# 处决优先于其他攻击：窗口很短（3~3.5 秒），不该被轻击抢走输入
	if Input.is_action_just_pressed(&"execute") and _try_execute():
		return

	# 蓄力重攻击：按下开始蓄，松开释放
	if Input.is_action_just_pressed(&"heavy_attack"):
		_begin_heavy_charge()
		return
	if attack_controller.is_charging:
		attack_controller.charge_time += get_physics_process_delta_time()
		if Input.is_action_just_released(&"heavy_attack") or attack_controller.charge_time >= (attack_controller.current_attack.max_charge if attack_controller.current_attack else 1.0):
			_release_heavy()
		return

	if Input.is_action_just_pressed(&"light_attack"):
		_do_light_attack()


func _begin_heavy_charge() -> void:
	var heavy := weapon_data.heavy_attack
	if heavy == null:
		return
	if state_machine != null and not state_machine.can_start_attack():
		# 收招中按重击 -> 缓冲，收招结束自动接
		attack_controller.request_attack(heavy)
		return
	if stamina != null and not stamina.can_afford(heavy.stamina_cost):
		EventBus.stamina_insufficient.emit(self, &"heavy")
		return
	attack_controller.start_charge(heavy)
	if state_machine != null:
		state_machine.enter_charge()


func _release_heavy() -> void:
	if attack_controller == null or not attack_controller.is_charging:
		return
	var atk := attack_controller.current_attack
	if atk == null:
		return
	# 蓄力不收费，出招才收费
	if stamina != null and not stamina.try_spend(atk.stamina_cost * weapon_data.stamina_multiplier, atk.attack_id):
		attack_controller.is_charging = false
		if state_machine != null:
			state_machine.force_state(CombatState.State.IDLE)
		return
	attack_controller.release_charge()


## 轻攻击：根据当前是否在攻击中决定使用哪一段连招
func _do_light_attack() -> void:
	var ac := attack_controller
	var idx := 0

	if ac.is_attacking() and ac.current_attack != null:
		# 连招记忆：知道自己是第几段，才能接下一段
		idx = int(ac.current_attack.get_meta("combo_index", 0))
		var next := weapon_data.get_light(idx + 1)
		if next == null:
			next = weapon_data.get_light(0)  # 打完最后一段从头开始
		# 注意：request_attack 可能返回 false（例如当前处在有效判定帧，
		# 只把这次输入缓冲起来）。这时 current_attack 仍然是旧的那一段，
		# 不能去改它的 combo_index，否则下一段会算错。
		if ac.request_attack(next) and ac.current_attack == next:
			next.set_meta("combo_index", clampi(idx + 1, 0, weapon_data.get_light_count() - 1))
		return

	# 闪避中按攻击 -> 突进攻击
	if state_machine != null and state_machine.is_state(CombatState.State.DODGE):
		if _dodge_elapsed >= GameConfig.DODGE_DURATION * GameConfig.DODGE_CANCEL_AT:
			_do_dodge_attack()
		return

	# 地面普通起手
	var atk := weapon_data.get_light(0)
	if atk == null:
		return
	var started := ac.request_attack(atk)
	if started:
		atk.set_meta("combo_index", 0)


func _do_dodge_attack() -> void:
	var atk := weapon_data.dodge_attack
	if atk == null:
		return
	if attack_controller.request_attack(atk):
		atk.set_meta("combo_index", 0)


# ------------------------------------------------------------
# 处决
# ------------------------------------------------------------

## 尝试发动处决。
##
## 触发条件（全部满足才行）：
##   1. 已锁定一个目标
##   2. 该目标的架势处于破除状态（`Poise.is_broken`）
##   3. 距离足够近（处决是近身动作，不能隔着 10 米处决）
##   4. 自己状态允许出招（不在硬直/死亡中）
##
## 处决的回报与代价：
##   回报 —— 固定 260 伤害（远超任何普通攻击），且过程中精力不消耗
##   代价 —— 起手 0.50 s、收招 0.75 s，且**不能被闪避取消**
##           （`dodge_cancel_progress = 1.0`）。如果时机没算好，
##           Boss 站起来后就会吃一记反击。
func _try_execute() -> bool:
	var target := GameState.locked_target
	if target == null or not is_instance_valid(target):
		return false

	var target_poise := target.get_node_or_null("Poise") as PoiseComponent
	if target_poise == null or not target_poise.is_broken:
		return false

	# 距离检查：以目标的受击盒半径粗略判断
	var dist := global_position.distance_to(target.global_position)
	if dist > 4.5:
		return false

	var atk := weapon_data.execution_attack
	if atk == null:
		return false

	if not attack_controller.request_attack(atk):
		return false

	# 处决命中后结束目标的破防状态。这里用延迟调用，等有效帧过去再判定。
	_apply_execution_effect.call_deferred(target, atk.get_total_duration())

	# 镜头反馈：处决是"爽点"，给一次较强的冲击
	if camera_rig != null and camera_rig.has_method("add_shake"):
		camera_rig.call("add_shake", GameConfig.SHAKE_HEAVY)
	return true


## 处决的实际效果。等攻击的有效帧走完再扣血量并结束破防，
## 这样数字跳出的时机和挥刀动作是对上的。
func _apply_execution_effect(target: Node, delay: float) -> void:
	await get_tree().create_timer(delay * 0.6, false).timeout
	if not is_instance_valid(target):
		return
	# 如果目标的破防窗口已经自己结束了（玩家出手太慢），处决落空
	var p := target.get_node_or_null("Poise") as PoiseComponent
	if p == null or not p.is_broken:
		return
	if target.has_method("on_executed"):
		target.call("on_executed", self)


# ------------------------------------------------------------
# 命中与受击回调（由 HealthComponent / HitReactor 触发）
# ------------------------------------------------------------

func _on_died(_killer: Node) -> void:
	if state_machine != null:
		state_machine.enter_dead()
	if attack_controller != null:
		attack_controller.notify_death()
	GameState.stats["deaths"] += 1
	died.emit()
	EventBus.player_died.emit(self)
	if is_local and camera_rig != null and camera_rig.has_method("on_owner_died"):
		camera_rig.call("on_owner_died")
	# 短暂延迟后自动复活（首版用自动复活代替救援系统，见 docs/战斗设计.md）
	if is_local:
		var t := get_tree().create_timer(2.2, false)
		t.timeout.connect(_auto_respawn)


## 受击：进入硬直。与 EnemyBase._on_damaged 对称。
##
## 这里刻意做成"受击 = 一定被打断"：
## 类魂战斗里玩家被打中就应该付出代价。如果玩家受击不打断，
## 就会出现"站桩对砍"的无聊局面。
func _on_damaged(info: DamageInfo, _remaining: float) -> void:
	if state_machine == null:
		return
	if state_machine.is_state(CombatState.State.DEAD):
		return
	if attack_controller != null:
		attack_controller.notify_interrupted()
	state_machine.enter_hitstun(info.hitstun if info.hitstun > 0.0 else GameConfig.HITSTUN_LIGHT)
	if is_local and camera_rig != null and camera_rig.has_method("add_shake"):
		camera_rig.call("add_shake", info.camera_shake)
	EventBus.hitstun_started.emit(self, info.hitstun, info.is_heavy)


## 首版的复活流程：死亡 2.2 秒后在最近检查点满血复活。
## 联机救援（队友扶起）见 docs/架构说明.md 的预留接口。
func _auto_respawn() -> void:
	if health == null or not health.is_dead:
		return
	var pos := GameState.checkpoint_position
	if pos == Vector3.ZERO:
		pos = _respawn_position
	respawn(pos, 1.0)
	if is_local:
		global_rotation.y = deg_to_rad(GameState.checkpoint_rotation)
	print("[玩家] %s 已复活" % display_name)


## 由 CombatResolver 命中流程调用（受击硬直）
func apply_hitstun(duration: float, _is_heavy: bool) -> void:
	if state_machine == null:
		return
	if state_machine.is_state(CombatState.State.DEAD):
		return
	if attack_controller != null:
		attack_controller.notify_interrupted()
	state_machine.enter_hitstun(duration)


## 复活（检查点或队友救援）
func respawn(at_position: Vector3 = Vector3.ZERO, health_ratio: float = 1.0) -> void:
	if is_local:
		global_position = at_position if at_position != Vector3.ZERO else _respawn_position
		velocity = Vector3.ZERO
	if health != null:
		health.revive(health_ratio)
	if stamina != null:
		stamina.refill()
	if poise != null:
		poise.current = poise.max_poise
		poise.is_broken = false
	if state_machine != null:
		state_machine.force_state(CombatState.State.IDLE)
	respawned.emit()
	EventBus.player_respawned.emit(self)


## 设置检查点
func set_checkpoint(pos: Vector3, yaw_deg: float = 0.0) -> void:
	_respawn_position = pos
	global_rotation.y = deg_to_rad(yaw_deg)


func get_health_ratio() -> float:
	return health.get_ratio() if health != null else 0.0


func _to_string() -> String:
	var st := state_machine.get_state_name() if state_machine != null else "?"
	return "[玩家 %s %s %s]" % [display_name, st, health]
