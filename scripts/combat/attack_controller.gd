class_name AttackController
extends Node
## 攻击控制器：把一个 AttackData 的时序真正跑起来。
##
## 这是战斗手感的执行核心。它负责：
##   1. 接收攻击请求（带输入缓冲，按早了不会丢，按晚了不会错帧）
##   2. 按时序推进 起手 -> 有效判定 -> 收招
##   3. 在正确的时间窗口开关判定盒（绝不提前、绝不延后）
##   4. 处理连招接续与取消规则
##   5. 统计命中结果并给出不同反馈（命中/落空/被打断）
##
## 设计要点：
##   - 时间推进用**本地 delta**，不用 Timer 节点。因为命中停顿会让
##     动画播放变慢，我们希望攻击时序也按同样节奏走，才不会出现
##     "动画卡住了但判定还在推进"的错位。
##   - 所有"允许/不允许"的判断都查 CombatState 的优先级表，
##     而不是散落的 bool，避免状态互相打架。
##
## 玩家和敌人共用这个脚本。差异通过参数传入（is_player / 目标层）。

signal attack_phase_changed(attack: AttackData, phase: int)
signal attack_finished(attack: AttackData, reason: StringName)
signal attack_hit(attack: AttackData, target: Node, info: DamageInfo)

enum Phase { NONE, WINDUP, ACTIVE, RECOVERY }

## 攻击结束原因
const REASON_COMPLETE := &"complete"    ## 正常打完
const REASON_CANCEL_DODGE := &"dodge"   ## 被闪避取消
const REASON_CANCEL_ATTACK := &"combo"  ## 被连招取消
const REASON_INTERRUPTED := &"hit"      ## 被打断
const REASON_DIED := &"death"

@export_group("引用")
## 攻击判定盒节点路径（相对本控制器的父节点）
@export var hitbox_path: NodePath = ^"../Hitbox"
## 动画播放器路径（可选，用于后续接动画驱动）
@export var anim_path: NodePath = ^"../AnimationTree"
## 角色根节点（拥有移动能力）
@export var body_path: NodePath = ^".."

@export_group("行为")
## 是否能被闪避取消
@export var can_dodge_cancel: bool = true
## 是否是玩家（玩家有输入缓冲，敌人由 AI 直接调用）
@export var is_player: bool = false
## 敌人用：攻击时面向目标的最大角度（度/秒），0 = 不自动转向
@export var attack_tracking_speed: float = 0.0

# ------ 运行时状态 ------
var current_attack: AttackData = null
var current_phase: Phase = Phase.NONE
## 当前攻击已推进的时间（秒）
var elapsed: float = 0.0
## 本次挥击是否命中过至少一个目标
var hit_something: bool = false
## 本次挥击命中的目标数
var hit_count: int = 0
## 本段攻击的段数索引（轻攻击连招用）
var combo_index: int = 0
## 蓄力时间
var charge_time: float = 0.0
var is_charging: bool = false
## 蓄力未满时的伤害倍率（满蓄时会换成 charged_attack，此值保持 1.0）
var _charge_multiplier: float = 1.0

var body: Node3D
var hitbox: Hitbox
var health: HealthComponent
var stamina: StaminaComponent

## 输入缓冲：存下被缓冲的攻击请求
var _buffered_attack: AttackData = null
var _buffer_timer: float = 0.0
## 连招记忆：上一段攻击结束后 COMBO_WINDOW 内允许直接接续
var _last_attack: AttackData = null
var _combo_memory_timer: float = 0.0

## 待执行伤害队列（有效帧内命中后立即结算，这里只做去重记录）
var _pending_hit_targets: Array[int] = []


func _ready() -> void:
	body = get_node_or_null(body_path) as Node3D
	hitbox = get_node_or_null(hitbox_path) as Hitbox
	if hitbox == null:
		# 允许在父节点下直接查找（不同的场景排布）
		hitbox = get_parent().get_node_or_null("Hitbox") as Hitbox
	if hitbox != null:
		hitbox.setup(get_parent())
		hitbox.hit_registered.connect(_on_hit_registered)
		hitbox.destructible_hit.connect(_on_destructible_hit)

	var host := get_parent()
	if host != null:
		health = host.get_node_or_null("Health") as HealthComponent
		stamina = host.get_node_or_null("Stamina") as StaminaComponent
		# HitstopManager 的创建必须延后一帧：
		# _ready 期间父节点仍处于"正在建立子节点"的状态，
		# 此时 add_child() 会失败（Godot 会报 "Parent node is busy setting up children"）。
		if host.get_node_or_null("HitstopManager") == null:
			_ensure_hitstop_manager.call_deferred(host)

	# 始终处理：即使当前没在攻击，也要推进输入缓冲。
	# 单帧开销极小（几次比较），换来的是"硬直结束后自动接招"的手感。
	set_process(true)


func _ensure_hitstop_manager(host: Node) -> void:
	if not is_instance_valid(host) or host.get_node_or_null("HitstopManager") != null:
		return
	var mgr := HitstopManager.new()
	mgr.name = "HitstopManager"
	host.add_child(mgr)


func _process(delta: float) -> void:
	# 输入缓冲与连招记忆始终推进
	if _buffer_timer > 0.0:
		_buffer_timer -= delta
		if _buffer_timer <= 0.0:
			_buffered_attack = null
	if _combo_memory_timer > 0.0:
		_combo_memory_timer -= delta

	if current_attack == null:
		# 空闲时消费缓冲：这是"受击硬直结束后自动接上刚才按的那刀"的实现。
		# 没有这一段，玩家在硬直中提前输入的攻击会被丢弃，手感会显得迟钝。
		if _buffered_attack != null and _can_start_attack():
			var next := _buffered_attack
			_buffered_attack = null
			_buffer_timer = 0.0
			_start_attack(next)
		return

	elapsed += delta
	_update_phase()
	_apply_lunge(delta)


# ============================================================
# 对外接口
# ============================================================

## 请求执行一次攻击。
## 返回 true 表示立刻开始；false 表示被缓冲或拒绝。
## force = true 时忽略精力与状态检查（Boss 脚本、过场用）。
func request_attack(attack: AttackData, force: bool = false) -> bool:
	if attack == null:
		return false
	if health != null and health.is_dead:
		return false
	# 硬性禁止：受击硬直/破防/死亡中一律不出招（force 也不能绕过）
	if _is_hard_blocked_from_attacking():
		# 硬直中可以缓冲，硬直结束后自动接上
		if not force:
			_buffer_attack(attack)
		return false

	# 正在攻击中：判断能否连招接续，否则缓冲
	if current_attack != null:
		if _can_chain_to(attack):
			_start_attack(attack)
			return true
		# 缓冲：稍后如果进入可接续窗口会自动触发
		_buffer_attack(attack)
		return false

	# 其他状态锁（例如蓄力）下：只缓冲，不执行
	if not _can_start_attack() and not force:
		_buffer_attack(attack)
		return false

	return _start_attack(attack, force)


## 缓冲一次攻击输入（避免"按早了没反应"）
func _buffer_attack(attack: AttackData) -> void:
	_buffered_attack = attack
	_buffer_timer = GameConfig.INPUT_BUFFER_TIME if GameConfig else 0.28


## 尝试取消当前动作成为闪避。返回 true 表示允许。
func can_cancel_to_dodge() -> bool:
	if current_attack == null:
		return true
	if current_attack.is_active_at(elapsed):
		return false  # 有效判定帧内不允许取消，保证判定可信
	if not can_dodge_cancel:
		return false
	return current_attack.can_dodge_cancel_at(elapsed)


## 被闪避取消时由角色控制器调用，通知本控制器结束当前攻击
func notify_cancelled_by_dodge() -> void:
	if current_attack != null:
		_end_attack(REASON_CANCEL_DODGE)


## 被受击打断
func notify_interrupted() -> void:
	if current_attack != null:
		_end_attack(REASON_INTERRUPTED)


## 死亡
func notify_death() -> void:
	if current_attack != null:
		_end_attack(REASON_DIED)


## 当前是否正在攻击
func is_attacking() -> bool:
	return current_attack != null


## 当前是否处于有效判定帧
func is_in_active_frames() -> bool:
	return current_attack != null and current_attack.is_active_at(elapsed)


## 攻击进度（0~1），用于调试条与连招目押
func get_progress() -> float:
	if current_attack == null:
		return 0.0
	return clampf(elapsed / current_attack.get_total_duration(), 0.0, 1.0)


## 开始蓄力（重攻击）
func start_charge(attack: AttackData) -> void:
	if attack == null or not attack.chargeable:
		return
	is_charging = true
	charge_time = 0.0
	current_attack = attack
	current_phase = Phase.WINDUP
	elapsed = 0.0
	set_process(true)
	attack_phase_changed.emit(attack, Phase.WINDUP)


## 蓄力释放的阈值：蓄力比例超过这个值就算"满蓄"，
## 切换成 charged_attack（居合）而不是"重击 + 伤害倍率"。
##
## 【为什么需要这个切换，而不只是加伤害倍率】
## 最初 release_charge() 只做了一件事：按蓄力比例把伤害乘上一个倍率，
## 攻击本身仍然是 heavy_attack。
## 结果是 weapon_data.charged_attack（居合，带 9 m/s 突进位移）
## **被配置了但运行时从来不会触发** —— 玩家蓄满力看到的还是原来那一刀，
## 只是伤害数字更高。文档里吹的"高风险高回报的位移斩"根本没发生。
##
## 现在的做法：蓄满就换攻击本身。居合有独立的起手（0.22，比重击快）、
## 独立的判定盒（伸到 2.3 m）、独立的收招（0.74，比重击长）
## 和 9 m/s 的突进 —— 这才是"另一招"，而不只是"更疼的一刀"。
const FULL_CHARGE_RATIO := 0.85


## 蓄力进度 0~1
func get_charge_ratio() -> float:
	if current_attack == null or current_attack.max_charge <= 0.0:
		return 0.0
	return clampf(charge_time / current_attack.max_charge, 0.0, 1.0)


## 当前蓄力是否已达到"满蓄"（会切换成居合）
func is_fully_charged() -> bool:
	return is_charging and get_charge_ratio() >= FULL_CHARGE_RATIO


## 释放蓄力攻击。
##
## 两条分支：
##   满蓄（比例 ≥ FULL_CHARGE_RATIO）且武器配置了 charged_attack
##       -> 换成 charged_attack（居合），保持当前蓄力时间作为起手
##   未满蓄
##       -> 保持 heavy_attack，按蓄力比例放大伤害
func release_charge() -> void:
	if not is_charging:
		return
	is_charging = false

	var ratio := get_charge_ratio()
	var charged := _get_charged_variant()

	if charged != null and ratio >= FULL_CHARGE_RATIO:
		# 切换到居合。
		var spent := current_attack
		current_attack = charged
		_charge_multiplier = 1.0
		elapsed = 0.0
		current_phase = Phase.WINDUP

		# 换上来的是一条**新的攻击**，所以 _start_attack() 里做的那些
		# "进入攻击状态"的准备工作必须重做一遍：
		#   1. 锁定朝向（否则居合的 9 m/s 突进会朝错方向冲出去）
		#   2. 施加突进初速度
		#   3. 清空本次挥击的命中记录
		# 漏掉第 1、2 条的症状是"蓄满力了但人没冲出去"。
		hit_something = false
		hit_count = 0
		_pending_hit_targets.clear()
		if charged.lock_facing and body != null:
			body.set("facing_locked", true)
		if charged.lunge_speed > 0.0:
			_apply_lunge_impulse(charged.lunge_speed)

		attack_phase_changed.emit(charged, Phase.WINDUP)
		EventBus.attack_started.emit(get_parent(), charged.attack_id)
		print("[攻击] 蓄力满 -> 切换为「%s」（伤害 %.0f，突进 %.1f m/s，收招 %.2fs）" % [
			charged.display_name, charged.damage, charged.lunge_speed, charged.recovery])
	else:
		# 未满蓄：保持重击，按比例放大伤害
		_charge_multiplier = lerpf(1.0, current_attack.charge_damage_mult, ratio)
		elapsed = 0.0
		current_phase = Phase.WINDUP
		attack_phase_changed.emit(current_attack, Phase.WINDUP)


## 从当前武器的 charged_attack 里取"满蓄变体"。
## 攻击控制器不直接持有 WeaponData，通过宿主节点读。
func _get_charged_variant() -> AttackData:
	var host := get_parent()
	if host == null:
		return null
	var w: Variant = host.get("weapon_data")
	if w is WeaponData:
		return (w as WeaponData).charged_attack
	return null


# ============================================================
# 内部：攻击生命周期
# ============================================================

func _can_start_attack() -> bool:
	var actor := get_parent()
	if actor == null:
		return true
	# 查询角色状态机是否允许出招
	var sm := actor.get_node_or_null("StateMachine")
	if sm != null and sm.has_method("can_start_attack"):
		return sm.call("can_start_attack")
	# 没有状态机时，只有 Idle/Sprint 才能出招
	return true


## 硬性禁止出招的状态。
##
## force = true 会绕过"连招窗口/精力"这类软检查（Boss 脚本和过场需要），
## 但**不能**绕过这一组：如果角色正在受击硬直、架势被破、或已经死亡，
## 强行启动攻击会让 AttackController 和 StateMachine 处于不一致的状态
## （攻击时序在跑，但状态机显示"受击硬直"），是动作卡死的主要来源。
func _is_hard_blocked_from_attacking() -> bool:
	var actor := get_parent()
	if actor == null:
		return false
	if health != null and health.is_dead:
		return true
	var sm := actor.get_node_or_null("StateMachine")
	if sm == null:
		return false
	var st: int = sm.call("get_state")
	return st in [
		CombatState.State.HITSTUN,
		CombatState.State.POISE_BREAK,
		CombatState.State.EXECUTED,
		CombatState.State.DEAD,
		CombatState.State.DOWNED,
		CombatState.State.RESPAWNING,
	]


func _start_attack(attack: AttackData, force: bool = false) -> bool:
	# 精力检查（玩家才消耗，敌人不消耗）
	if is_player and stamina != null and not force:
		if not stamina.try_spend(attack.stamina_cost * _stamina_mult(), attack.attack_id):
			return false

	# 通知状态机进入攻击状态
	var sm := get_parent().get_node_or_null("StateMachine")
	if sm != null and sm.has_method("on_attack_started"):
		sm.call("on_attack_started", attack)

	current_attack = attack
	current_phase = Phase.WINDUP
	elapsed = 0.0
	hit_something = false
	hit_count = 0
	_pending_hit_targets.clear()
	_charge_multiplier = 1.0
	set_process(true)

	# 朝向锁定：攻击期间不允许自由转身（除非配置允许）
	if attack.lock_facing and body != null:
		body.set("facing_locked", true)

	# 突进位移
	if attack.lunge_speed > 0.0:
		_apply_lunge_impulse(attack.lunge_speed)

	attack_phase_changed.emit(attack, Phase.WINDUP)
	EventBus.attack_started.emit(get_parent(), attack.attack_id)
	return true


func _update_phase() -> void:
	if current_attack == null:
		return
	var atk := current_attack
	var was_phase := current_phase

	if elapsed < atk.windup:
		current_phase = Phase.WINDUP
	elif elapsed < atk.windup + atk.active:
		current_phase = Phase.ACTIVE
		# 进有效帧的第一帧开启判定
		if was_phase != Phase.ACTIVE and hitbox != null:
			hitbox.activate(_with_charge(atk))
		# 判定盒跟随朝向（横扫类）
		if atk.follow_facing:
			_update_hitbox_transform(atk)
	else:
		current_phase = Phase.RECOVERY
		if was_phase == Phase.ACTIVE and hitbox != null:
			hitbox.deactivate()

	if was_phase != current_phase:
		attack_phase_changed.emit(atk, current_phase)
		if current_phase == Phase.RECOVERY and not hit_something:
			# 有效帧结束但一个都没打到 -> 落空反馈（挥空音效、无顿帧）
			CombatResolver.play_whiff_feedback(get_parent(), atk)

	# 收招中尝试消费缓冲输入
	if current_phase == Phase.RECOVERY:
		_try_consume_buffer()

	if elapsed >= atk.get_total_duration():
		_end_attack(REASON_COMPLETE)


## 把蓄力倍率写进一份临时 AttackData 副本（不污染原资源）
func _with_charge(atk: AttackData) -> AttackData:
	if is_zero_approx(_charge_multiplier - 1.0):
		return atk
	var copy: AttackData = atk.duplicate(true)
	copy.damage = atk.damage * _charge_multiplier
	copy.poise_damage = atk.poise_damage * _charge_multiplier
	return copy


func _update_hitbox_transform(atk: AttackData) -> void:
	if hitbox == null or body == null:
		return
	# 判定盒是 body 的子节点，body 旋转时它跟着转，
	# 这里只需要处理"相对 body 的偏移"的轨迹插值。
	var offset := atk.get_hit_offset_at(elapsed)
	hitbox.position = offset
	if atk.hit_rotation_deg != Vector3.ZERO:
		hitbox.rotation_degrees = atk.hit_rotation_deg


func _apply_lunge(delta: float) -> void:
	# 攻击前冲：在起手+有效帧期间持续施加一个小速度
	if body == null or current_attack == null:
		return
	if current_attack.lunge_speed <= 0.0:
		return
	if elapsed > current_attack.windup + current_attack.active:
		return
	var v: Variant = body.get("velocity")
	if v is Vector3:
		var forward := -body.global_transform.basis.z
		body.set("velocity", (v as Vector3) + forward * current_attack.lunge_speed * delta * 8.0)


func _apply_lunge_impulse(speed: float) -> void:
	if body == null:
		return
	var v: Variant = body.get("velocity")
	if v is Vector3:
		var forward := -body.global_transform.basis.z
		body.set("velocity", (v as Vector3) + forward * speed)


func _end_attack(reason: StringName) -> void:
	var finished := current_attack
	if finished == null:
		return

	if hitbox != null:
		hitbox.deactivate()

	# 解除朝向锁定
	if finished.lock_facing and body != null:
		body.set("facing_locked", false)

	# 连招记忆：正常打完或被连招取消时，允许短时间内直接接续下一段
	if reason == REASON_COMPLETE or reason == REASON_CANCEL_ATTACK:
		_last_attack = finished
		_combo_memory_timer = GameConfig.COMBO_WINDOW if GameConfig else 0.65

	current_attack = null
	current_phase = Phase.NONE
	elapsed = 0.0
	is_charging = false
	_charge_multiplier = 1.0
	set_process(false)

	attack_finished.emit(finished, reason)
	EventBus.attack_finished.emit(get_parent(), finished.attack_id, reason)

	var sm := get_parent().get_node_or_null("StateMachine")
	if sm != null and sm.has_method("on_attack_finished"):
		sm.call("on_attack_finished", finished, reason)

	# 还有缓冲输入且现在能出招 -> 立即执行（保证连招不丢帧）
	if _buffered_attack != null and _can_start_attack():
		var next := _buffered_attack
		_buffered_attack = null
		_buffer_timer = 0.0
		_start_attack(next)

## 当前是否允许接续到指定攻击
func _can_chain_to(next: AttackData) -> bool:
	if current_attack == null or next == null:
		return false
	# 有效判定帧内不可取消
	if current_attack.is_active_at(elapsed):
		return false
	# 必须在连招窗口内
	if not current_attack.in_combo_window(elapsed):
		return false
	# 收招取消点检查（避免出招太早导致动作鬼畜）
	var total := current_attack.get_total_duration()
	var recover_start := current_attack.windup + current_attack.active
	var threshold := recover_start + current_attack.recovery * current_attack.attack_cancel_progress
	if elapsed < threshold:
		return false
	return true


## 收招阶段自动消费缓冲输入
func _try_consume_buffer() -> void:
	if _buffered_attack == null:
		return
	if current_attack != null and _can_chain_to(_buffered_attack):
		var next := _buffered_attack
		_buffered_attack = null
		_buffer_timer = 0.0
		_end_attack(REASON_CANCEL_ATTACK)
		_start_attack(next)


## 取出"下一段轻攻击"。连招接续时优先用它。
func get_next_combo_attack(weapon: WeaponData, current_index: int) -> AttackData:
	if weapon == null:
		return null
	if current_index + 1 < weapon.get_light_count():
		return weapon.get_light(current_index + 1)
	return null


# ============================================================
# 命中处理
# ============================================================

func _on_hit_registered(dmg: Damageable, info: DamageInfo) -> void:
	var target := dmg.damage_owner
	if target == null:
		return

	hit_something = true
	hit_count += 1

	# 填入上下文
	var parent_node := get_parent()
	if parent_node != null:
		info.attacker_peer_id = _get_peer_id(parent_node)
	info.hitstop_tier = current_attack.get_hitstop_tier() if current_attack != null else 0
	if GameConfig != null:
		match info.hitstop_tier:
			0: info.camera_shake = GameConfig.SHAKE_LIGHT
			1: info.camera_shake = GameConfig.SHAKE_MEDIUM
			2: info.camera_shake = GameConfig.SHAKE_HEAVY
		info.hitstun = GameConfig.HITSTUN_HEAVY if info.is_heavy else GameConfig.HITSTUN_LIGHT
		info.knockback = GameConfig.KNOCKBACK_HEAVY if info.is_heavy else GameConfig.KNOCKBACK_LIGHT

	# 权威端结算：这里才是真正扣血的地方。非权威端只播放表现。
	if NetManager == null or NetManager.is_authority():
		var h := dmg.get_health()
		var p := dmg.get_poise()
		CombatResolver.resolve(h, p, info)

	# 表现层（所有端都播）
	CombatResolver.play_hit_feedback(parent_node, target, info)

	attack_hit.emit(current_attack, target, info)

	# 通知状态机（用于"命中后可以取消得更早"这类手感调整）
	var sm := get_parent().get_node_or_null("StateMachine")
	if sm != null and sm.has_method("on_attack_hit"):
		sm.call("on_attack_hit", target, info)


func _get_peer_id(node: Node) -> int:
	var pid: Variant = node.get("peer_id")
	if pid is int:
		return pid
	return -1


## 命中可破坏地形。
##
## 网络约定（任务要求 6）：破坏必须由权威端确认。
## 客户端只发"我打到了这块地形"的请求给主机，主机校验后广播结果。
## 首版实现：客户端命中后本地先不销毁（避免各端不一致），
## 而是通过 TerrainManager 上报，等权威端确认。
func _on_destructible_hit(piece: DestructiblePiece, amount: float, weight: int, impact: Vector3) -> void:
	hit_something = true
	hit_count += 1

	# 命中地形也应有打击感（但用较轻的反馈，避免砍石头像砍肉）
	if GameConfig != null:
		HitstopManager.request(get_parent(), GameConfig.HITSTOP_LIGHT * 0.6)

	if NetManager == null or NetManager.is_authority():
		TerrainManager.apply_damage_authoritative(piece, amount, weight, impact)
	else:
		# 客户端：申请由主机结算。本地只播放"打到了"的反馈。
		TerrainManager.request_damage(piece, amount, weight, impact)


func _stamina_mult() -> float:
	var w: Variant = get_parent().get("weapon_data")
	if w is WeaponData:
		return (w as WeaponData).stamina_multiplier
	return 1.0
