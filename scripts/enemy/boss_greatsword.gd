extends EnemyBase
## Boss：低多边形类魂 Demo 的唯一 Boss。
##
## 设计定位（详见 docs/战斗设计.md）：
##   体型：约 3.2m 高的重甲巨人，肩宽、腿短、手臂粗 —— 轮廓一眼可辨
##   风格：慢、重、范围大。每一招都能一击打掉玩家半血，但每一招都有
##         清晰的前摇和可以走位绕开的形状。
##
## 三种核心攻击（任务要求"至少三种可辨认的攻击行为"）：
##   1. 巨剑横扫（sweep）  —— 正面扇形，两段。可向后闪避绕开。
##   2. 跳劈震荡（slam）   —— 以自身为中心的圆形 AoE。逼玩家离开近身。
##   3. 冲锋突刺（charge） —— 直线长距离突进。惩罚只会后退的玩家。
##   4. 回身斩（backhand） —— 二阶段追加，惩罚一直绕背的玩家。
##
## 关键设计：**惩罚窗口**。
##   每次攻击结束后都有 0.8~1.6 秒的收招，这是玩家唯一安全的输出窗口。
##   如果收招太短，玩家就只能被动挨打；太长，Boss 就变成木桩。
##   这些数值（recovery）比伤害伤害更决定战斗好不好玩。
##
## 多人适配（任务要求"不能只靠加血量"）：
##   - 目标切换：每次攻击结束后有概率换人，避免一个人被追到死
##   - 人数 >= 2 时，AoE 类攻击（跳劈、回身斩）权重提高
##   - 人数 >= 3 时，攻击冷却缩短（而不是加血）
##   - **不平摊血量**：Boss 血量固定，靠行为让战斗有意义
##
## 阶段：血量 60% 进入二阶段（更快、多一招、更爱用 AoE）

signal phase_changed(phase: int)
signal victory()

# ============================================================
# 导出配置
# ============================================================

@export_group("数值")
@export var max_health: float = 1400.0
@export var max_poise: float = 160.0
## 架势恢复速度（Boss 恢复得慢，鼓励持续进攻）
@export var poise_regen: float = 8.0

@export_group("阶段阈值")
## 进入二阶段的血量比例
@export var phase2_threshold: float = 0.60
## 二阶段攻速倍率（越小越快）
@export var phase2_speed_scale: float = 0.82
## 二阶段伤害倍率
@export var phase2_damage_scale: float = 1.15

@export_group("多人适配")
## 2 人及以上时，AoE 权重提升
@export var aoe_weight_bonus: float = 1.6
## 3 人及以上时，冷却缩短倍率
@export var crowd_cooldown_scale: float = 0.72
## 每次攻击结束后换目标的概率（0~1）
@export var retarget_chance: float = 0.55

@export_group("攻击配置")
@export var attack_sweep: AttackData
@export var attack_sweep_2: AttackData
@export var attack_slam: AttackData
@export var attack_charge: AttackData
@export var attack_backhand: AttackData
## Boss 的所有攻击（用于"choose"时的权重表）
@export var attack_table: Array[AttackData] = []

# ============================================================
# 运行时
# ============================================================

## 当前阶段：1 或 2
var phase: int = 1
## 当前正在执行的攻击 ID（用于表现与调试）
var current_move: StringName = &""

var _head: Node3D
var _weapon_pivot: Node3D
var _telegraph_mesh: MeshInstance3D
var _telegraph_mat: StandardMaterial3D

## 攻击权重表：id -> 权重
var _weights: Dictionary = {
	&"sweep": 3.0,
	&"slam": 1.6,
	&"charge": 1.4,
	&"backhand": 0.0,   # 二阶段解锁
}

## 各招式的前摇预警颜色
const TELEGRAPH_COLORS := {
	&"sweep": Color(1.0, 0.6, 0.15),
	&"slam": Color(1.0, 0.25, 0.2),
	&"charge": Color(0.4, 0.7, 1.0),
	&"backhand": Color(0.85, 0.35, 1.0),
}

## 冲锋内部状态
var _charge_velocity: float = 0.0
var _charging: bool = false

## 站桩待机（未发现玩家时）
var _idle_scan_timer: float = 0.0

## Boss 战低频环境氛围（assets/audio/boss_ambient.wav，6 秒无缝循环）。
##
## 【为什么不放进 AudioManager 的 SFX_DEFS】
##   环境氛围是**长音床**，不是一次性音效：它要独立循环、独立音量、
##   走 Ambient 总线吃大空间混响。混进 SFX 表会挤占 3D 音效的 16 个声部，
##   而且会被一次性音效的 pitch_scale 随机化逻辑破坏循环感。
##
## 【为什么自己建播放器而不是复用别处】
##   Boss 是场景节点，随关卡一起销毁；把播放器作为它的子节点，
##   关卡切换时自动回收，不会留下孤儿节点或跨场景的残留音。
var _ambient_player: AudioStreamPlayer = null


func _ready() -> void:
	super()
	entity_name = "灰烬巨兵"
	poise_armor = true
	add_to_group(&"boss")
	GameState.boss = self

	_build_attacks_if_missing()
	_cache_nodes()
	_create_telegraph_indicator()
	_setup_ambient_audio()

	if health != null:
		health.health = max_health
	# Boss 必须在多人时也是权威端控制
	if NetManager != null and NetManager.is_session_active():
		set_multiplayer_authority(1)

	# 攻击完全结束后要换目标，通过攻击控制器的信号挂上
	if attack_controller != null:
		attack_controller.attack_finished.connect(_on_attack_finished_hook)

	# 稍作延迟再开 AI，让玩家看清它站起来。
	# 必须走 enable_ai_after_delay()：它会让这一步尊重"外部强制关闭 AI"
	# 的记号，否则自动化测试关掉 AI 后 1.2 秒它又自己开起来了。
	enable_ai_after_delay(1.2)
	print("[Boss] 灰烬巨兵 已就位（%d 血量 / %d 架势）" % [int(max_health), int(max_poise)])


func _setup_stats() -> void:
	if health != null:
		health.max_health = max_health
		health.health = max_health
	if poise != null:
		poise.max_poise = max_poise
		poise.current = max_poise
		poise.break_window = 3.5
		poise.regen_rate = poise_regen
		poise.regen_delay = 2.2


func _cache_nodes() -> void:
	_head = get_node_or_null("Model/Head") as Node3D
	_weapon_pivot = get_node_or_null("Model/WeaponPivot") as Node3D


## 建立 Boss 战环境氛围音。
##
## 只在**权威端**播放（`is_multiplayer_authority()`）：氛围音是全局音床，
## 每个客户端各播一份会造成多次叠加、响度翻倍；由权威端的
## AudioStreamPlayer 通过 Godot 的 3D 音频不生效——所以这里用普通
## AudioStreamPlayer，并靠 `bus = "Ambient"` 走大空间混响。
##
## 找不到文件时直接不播（不报错）：音频资源缺失不应该影响战斗逻辑，
## 这与 `AudioManager._resolve_stream()` 的降级策略一致。
func _setup_ambient_audio() -> void:
	if not is_multiplayer_authority():
		return
	const PATH := "res://assets/audio/boss_ambient.wav"
	if not ResourceLoader.exists(PATH):
		print("[Boss] 未找到 %s，跳过环境氛围音" % PATH)
		return
	var stream: AudioStream = load(PATH) as AudioStream
	if stream == null:
		return
	# 循环在这里设，而不是改 .wav 的导入参数：
	# Godot 重新导入 WAV 会把 edit/loop_mode 重置回默认的"不循环"，
	# 而 tools/generate_audio.py 每次重跑都会让导入参数重置一次。
	# 写在代码里只有一处、且不会随导入设置丢失。
	# boss_ambient.wav 无缝循环是合成时按 1/时长 整数倍频率生成的，
	# 首尾样本差为 0，所以这里直接首尾相接不会产生"咔"声。
	var wav := stream as AudioStreamWAV
	if wav != null:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = 0  # 0 表示"到末尾"，不是"零长度"
	_ambient_player = AudioStreamPlayer.new()
	_ambient_player.name = "BossAmbient"
	_ambient_player.stream = stream
	# 音量刻意压低：它是背景音床，不能盖过挥刀与命中音
	_ambient_player.volume_db = -16.0
	var idx := AudioServer.get_bus_index(&"Ambient")
	if idx >= 0:
		_ambient_player.bus = &"Ambient"
	else:
		# 没有配置 AudioBus 布局时退回 Master，保证仍然听得到
		_ambient_player.bus = &"Master"
	add_child(_ambient_player)
	_ambient_player.play()
	print("[Boss] 环境氛围音已启动（%s）" % PATH)


# ============================================================
# 攻击数据
# ============================================================

## 如果 .tres 没挂上，用代码构造。这样即使资源丢失 Boss 也能跑。
func _build_attacks_if_missing() -> void:
	if attack_sweep == null:
		attack_sweep = _mk(&"boss_sweep_1", "巨剑横扫·一段", 0.85, 0.16, 0.95, 34.0, 22.0, 2,
			2.0, 2.6, 1.35, -1.05, Vector3(0.0, 1.6, -2.3))
	if attack_sweep_2 == null:
		attack_sweep_2 = _mk(&"boss_sweep_2", "巨剑横扫·二段", 0.62, 0.16, 1.15, 40.0, 26.0, 2,
			2.2, 3.1, 1.45, -1.15, Vector3(0.0, 1.7, -2.4))
	if attack_slam == null:
		attack_slam = _mk(&"boss_slam", "跳劈震荡", 1.05, 0.22, 1.45, 52.0, 42.0, 2,
			2.4, 0.5, 3.2, 0.0, Vector3(0.0, 2.2, -1.2), "Sphere")
	if attack_charge == null:
		attack_charge = _mk(&"boss_charge", "冲锋突刺", 0.78, 0.20, 1.60, 46.0, 34.0, 2,
			1.6, 0.55, 1.3, -0.3, Vector3(0.0, 1.4, -2.6))
	if attack_backhand == null:
		attack_backhand = _mk(&"boss_backhand", "回身斩", 0.70, 0.16, 1.25, 44.0, 30.0, 2,
			2.2, 3.6, 1.5, 0.4, Vector3(0.0, 1.6, -1.0), "Capsule", true)

	attack_table = [attack_sweep, attack_sweep_2, attack_slam, attack_charge, attack_backhand]


## 构造一条 Boss 攻击的辅助函数。
## 参数顺序刻意与"手感三要素"一致：起手 / 有效 / 收招。
func _mk(
	id: StringName, disp: String,
	windup: float, active: float, recovery: float,
	dmg: float, poise_dmg: float, weight: int,
	lunge: float, half_len: float, radius: float,
	height: float, offset: Vector3,
	shape: String = "Capsule", full_circle: bool = false
) -> AttackData:
	var a := AttackData.new()
	a.attack_id = id
	a.display_name = disp
	a.weapon_id = &"boss_greatsword"
	a.windup = windup
	a.active = active
	a.recovery = recovery
	a.damage = dmg
	a.poise_damage = poise_dmg
	a.weight = weight
	a.stamina_cost = 0.0
	a.shape_type = shape
	a.hit_offset = offset
	a.hit_offset_end = offset
	a.hit_half_length = half_len
	a.hit_radius = radius
	a.hit_half_height = height
	a.lunge_speed = lunge
	a.follow_facing = not full_circle
	a.lock_facing = true
	a.allow_movement = false
	# Boss 攻击：起手长、收招长，这是给玩家的"读招"和"惩罚"窗口
	a.combo_window_open = 0.0
	a.combo_window_close = 0.0
	a.dodge_cancel_progress = 1.0
	a.attack_cancel_progress = 1.0
	a.sfx_swing = &"boss_swing"
	a.sfx_hit = &"boss_hit"
	a.vfx_hit = "res://scenes/fx/hit_spark_heavy.tscn"
	return a


# ============================================================
# 预警指示器（让玩家看清 AoE 形状）
# ============================================================

func _create_telegraph_indicator() -> void:
	_telegraph_mesh = MeshInstance3D.new()
	_telegraph_mesh.name = "Telegraph"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 1.0
	cyl.bottom_radius = 1.0
	cyl.height = 0.04
	cyl.radial_segments = 24
	_telegraph_mesh.mesh = cyl
	_telegraph_mat = StandardMaterial3D.new()
	_telegraph_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_telegraph_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_telegraph_mat.albedo_color = Color(1.0, 0.4, 0.2, 0.0)
	_telegraph_mat.no_depth_test = false
	_telegraph_mesh.material_override = _telegraph_mat
	_telegraph_mesh.visible = false
	add_child(_telegraph_mesh)


## 起手阶段显示地面预警圆
func _update_telegraph(atk: AttackData, elapsed_ratio: float) -> void:
	if _telegraph_mesh == null or atk == null:
		return
	var is_aoe := atk.shape_type == "Sphere" or atk.hit_radius > 2.0
	if not is_aoe:
		_telegraph_mesh.visible = false
		return

	_telegraph_mesh.visible = true
	_telegraph_mesh.global_position = global_position + Vector3(0.0, 0.06, 0.0)
	var r := atk.hit_radius
	_telegraph_mesh.scale = Vector3(r, 1.0, r)

	# 颜色随进度从"淡"变"浓"，最后一下闪白 —— 这是给玩家的最后警告
	var c: Color = TELEGRAPH_COLORS.get(current_move, Color(1.0, 0.4, 0.2))
	var alpha := lerpf(0.12, 0.42, elapsed_ratio)
	if elapsed_ratio > 0.85:
		var flash := (sin(Time.get_ticks_msec() * 0.05) * 0.5 + 0.5)
		c = c.lerp(Color.WHITE, flash * (elapsed_ratio - 0.85) / 0.15)
		alpha = lerpf(0.42, 0.6, (elapsed_ratio - 0.85) / 0.15)
	_telegraph_mat.albedo_color = Color(c.r, c.g, c.b, alpha)


func _hide_telegraph() -> void:
	if _telegraph_mesh != null:
		_telegraph_mesh.visible = false


# ============================================================
# AI 主循环
# ============================================================

func _get_preferred_attack_range() -> float:
	# Boss 的攻击距离较远（巨剑长），但它倾向于站在中距离施压
	return 3.6


func _get_cooldown_scale() -> float:
	var s := 1.0
	if phase == 2:
		s *= phase2_speed_scale
	var n := GameState.get_player_count()
	if n >= 3:
		s *= crowd_cooldown_scale
	elif n == 2:
		s *= 0.88
	return s


func _ai_think(delta: float) -> void:
	if target == null:
		_scan_for_players(delta)
		return

	var dist := _horizontal_distance_to(target)
	var st := state_machine.get_state()

	# 破防中：跪地不动，等待被处决（或窗口结束自己站起来）
	if st == CombatState.State.POISE_BREAK:
		_idle_brake(delta)
		return

	# 更新预警显示
	if attack_controller != null and attack_controller.is_attacking():
		_on_attacking_tick(delta)
		return
	_hide_telegraph()

	# 决策
	if dist > aggro_range:
		if _provoked_timer > 0.0:
			_move_toward(target, delta, 0.75)
		else:
			_scan_for_players(delta)
		return

	# 冲锋途中
	if _charging:
		_tick_charge(delta)
		return

	if dist > _get_preferred_attack_range():
		_move_toward(target, delta, 0.82)
	else:
		_face_target(delta, turn_speed * 0.65)
		_idle_brake(delta)
		_try_attack(dist)


## 攻击进行中的每帧处理
func _on_attacking_tick(delta: float) -> void:
	var ac := attack_controller
	var atk := ac.current_attack
	if atk == null:
		return
	# 预警圆
	if ac.current_phase == AttackController.Phase.WINDUP:
		_update_telegraph(atk, clampf(ac.elapsed / maxf(atk.windup, 0.01), 0.0, 1.0))
		_track_target_during_attack(delta)
	else:
		_hide_telegraph()


## 没找到玩家时缓慢巡视
func _scan_for_players(delta: float) -> void:
	_idle_brake(delta)
	_idle_scan_timer -= delta
	if _idle_scan_timer <= 0.0:
		_idle_scan_timer = 2.5
		global_rotation.y = wrapf(global_rotation.y + randf_range(-1.6, 1.6), -PI, PI)


# ============================================================
# 选招（核心：多人适配在这里）
# ============================================================

func _pick_attack(dist: float) -> AttackData:
	var player_count := GameState.get_player_count()
	_apply_phase_weights(player_count)

	# 距离过滤：太远只能用冲锋，太近不能用冲锋
	var candidates: Array[AttackData] = []
	var weights: Array[float] = []

	for id: StringName in _weights:
		var w: float = _weights[id]
		if w <= 0.0:
			continue
		var atk := _attack_by_id(id)
		if atk == null:
			continue
		# 冲锋只在较远距离使用
		if id == &"charge" and dist < 3.5:
			continue
		# 跳劈/回身斩是近身 AoE，远距离没意义
		if id in [&"slam", &"backhand"] and dist > 5.5:
			continue
		# 横扫距离很远（Boss 手长）
		if id == &"sweep" and dist > 5.0:
			continue
		candidates.append(atk)
		weights.append(w)

	if candidates.is_empty():
		return null

	# 加权随机
	var total := 0.0
	for w: float in weights:
		total += w
	var roll := randf() * total
	var acc := 0.0
	for i in candidates.size():
		acc += weights[i]
		if roll <= acc:
			current_move = candidates[i].attack_id
			return candidates[i]
	return candidates.back()


func _attack_by_id(id: StringName) -> AttackData:
	match id:
		&"sweep": return attack_sweep
		&"sweep2": return attack_sweep_2
		&"slam": return attack_slam
		&"charge": return attack_charge
		&"backhand": return attack_backhand
	return null


## 根据阶段与人数调整招式权重。
## 这是"多人适配"的核心：不是给 Boss 加血，而是改变它的行为倾向。
func _apply_phase_weights(player_count: int) -> void:
	var base := {
		&"sweep": 3.0,
		&"sweep2": 2.2,
		&"slam": 1.6,
		&"charge": 1.4,
		&"backhand": 0.0,
	}
	if phase == 2:
		base[&"backhand"] = 2.4
		base[&"slam"] = 2.2
		base[&"sweep"] = 3.2

	# 人多 -> AoE 更重要（否则其他人可以无风险站桩输出）
	if player_count >= 2:
		base[&"slam"] += aoe_weight_bonus
		base[&"backhand"] += aoe_weight_bonus * 0.8
	# 人多 -> 冲锋权重略降（容易只冲一个人）
	if player_count >= 3:
		base[&"charge"] *= 0.7

	_weights = base


# ============================================================
# 攻击结束后的行为
# ============================================================

func _on_attack_phase(atk: AttackData, p: int) -> void:
	super(atk, p)
	if p == AttackController.Phase.WINDUP:
		current_move = atk.attack_id
	elif p == AttackController.Phase.ACTIVE:
		# 有效帧开始时收起预警，让玩家把注意力放回 Boss 身上
		_hide_telegraph()
	elif p == AttackController.Phase.RECOVERY:
		_hide_telegraph()


## 攻击完全结束后：换目标。信号签名为 (attack, reason)。
func _on_attack_finished_hook(_atk: AttackData, _reason: StringName) -> void:
	_hide_telegraph()
	_charging = false
	_maybe_retarget()


func _maybe_retarget() -> void:
	# 多人时按概率换目标，避免"只打一个人"
	var alive := GameState.get_alive_players()
	if alive.size() <= 1:
		return
	if randf() > retarget_chance:
		return
	# 优先换到"最近没被打过的人"——用距离近似（离得远的往往更安全）
	var best: Node3D = null
	var best_dist := -1.0
	for p: Node3D in alive:
		if p == target:
			continue
		var d := global_position.distance_to(p.global_position)
		if d > best_dist:
			best_dist = d
			best = p
	if best != null:
		force_target(best)
		print("[Boss] 切换目标 -> %s" % best.name)


# ============================================================
# 冲锋（需要自己控制位移，所以单独处理）
# ============================================================

func _tick_charge(delta: float) -> void:
	velocity.x = -global_transform.basis.z.x * _charge_velocity
	velocity.z = -global_transform.basis.z.z * _charge_velocity
	_charge_velocity = move_toward(_charge_velocity, 0.0, 14.0 * delta)
	if _charge_velocity <= 0.1:
		_charging = false


# ============================================================
# 阶段
# ============================================================

func _on_damaged(info: DamageInfo, remaining: float) -> void:
	super(info, remaining)
	# 统计伤害
	if info.attacker != null:
		GameState.stats["damage_dealt"] += info.damage
	_check_phase(remaining)


func _check_phase(remaining: float) -> void:
	if phase == 1 and health != null and remaining <= health.max_health * phase2_threshold:
		_enter_phase_2()


func _enter_phase_2() -> void:
	phase = 2
	# 二阶段：短暂无敌 + 震开周围玩家，给出"它变了"的明确信号
	if poise != null:
		poise.force_break(1.6)
	if health != null:
		health.grant_invulnerability(1.6)

	attack_cooldown *= phase2_speed_scale
	move_speed *= 1.18
	if attack_sweep != null:
		attack_sweep.damage *= phase2_damage_scale
	if attack_slam != null:
		attack_slam.damage *= phase2_damage_scale

	# 视觉：整体染红
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(self, meshes)
	for m: MeshInstance3D in meshes:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.62, 0.18, 0.16)
		mat.emission_enabled = true
		mat.emission = Color(0.45, 0.06, 0.05)
		mat.emission_energy_multiplier = 0.7
		mat.roughness = 0.65
		m.material_override = mat

	phase_changed.emit(phase)
	EventBus.boss_phase_changed.emit(self, phase)
	print("[Boss] 进入二阶段！攻速与伤害提升，解锁「回身斩」")


func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	for c in node.get_children():
		if c is MeshInstance3D and c.name != "Telegraph":
			out.append(c as MeshInstance3D)
		_collect_meshes(c, out)


# ============================================================
# 破防 / 死亡
# ============================================================

## 子类覆写：破防的表现（Boss 跪下、小怪瘫倒）
func _on_poise_break_visual() -> void:
	# 跪下：整体下沉并前倾，一眼看出"可以处决了"
	_hide_telegraph()
	if model_root != null:
		var tw := create_tween()
		tw.tween_property(model_root, "rotation_degrees:x", 42.0, 0.28).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(model_root, "position:y", -0.55, 0.28)


func _on_poise_recovered() -> void:
	super()
	if model_root != null:
		var tw := create_tween()
		tw.tween_property(model_root, "rotation_degrees:x", 0.0, 0.34).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(model_root, "position:y", 0.0, 0.34)


func _on_died(killer: Node) -> void:
	super(killer)
	_hide_telegraph()
	_charging = false
	ai_enabled = false
	# 死亡演出：向前倾倒
	if model_root != null:
		var tw := create_tween()
		tw.tween_property(model_root, "rotation_degrees:x", 88.0, 1.1).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(model_root, "position:y", -1.4, 1.1)

	GameState.phase = GameState.Phase.VICTORY
	var t := get_tree().create_timer(1.4, false)
	t.timeout.connect(func () -> void:
		victory.emit()
		EventBus.boss_defeated.emit(self)
		print("[Boss] 已被击败！")
	)


# ============================================================
# 处决接口
# ============================================================

## 玩家在破防窗口内发动处决、且处决攻击命中后调用。
##
## **这里不额外扣血**：处决的伤害由 `katana_execution` 这条攻击
## 自己的判定盒结算（260 点）。如果这里再加一次，就变成双重结算，
## 与"伤害只有一条路径"的架构原则冲突。
##
## 基类负责结束破防 + 短暂僵直；这里只叠加 Boss 专属的演出与数值后果。
func on_executed(by: Node) -> void:
	super(by)
	# 破防结束后 Boss 会立刻站起来，场面要衔接上"跪下"的补间
	_on_poise_recovered()
	print("[Boss] 被 %s 处决 —— 恢复架势，战斗继续" % (by.name if by != null else "未知"))


func get_debug_string() -> String:
	var st := super()
	var wtxt: PackedStringArray = []
	for id: StringName in _weights:
		var w: float = _weights[id]
		if w > 0.0:
			wtxt.append("%s=%.1f" % [id, w])
	return "%s\n阶段: %d   招式: %s\n权重: %s" % [
		st, phase, String(current_move), ", ".join(wtxt)
	]


func _to_string() -> String:
	return "[Boss 灰烬巨兵 %s 阶段%d]" % [health, phase]
