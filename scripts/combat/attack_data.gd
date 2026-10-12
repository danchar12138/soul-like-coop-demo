class_name AttackData
extends Resource
## 一次攻击动作的完整配置。
##
## 这是战斗系统的核心数据单元。每种武器的每一段攻击都是
## 一个独立的 .tres 资源，便于在编辑器里调参、也便于做数据驱动测试。
##
## 时间轴示意（单位：秒，从攻击开始算）：
##
##   0        windup        active_end        total
##   |-----------|==============|----------------|
##     起手阶段      有效判定帧        收招阶段
##                                  ↑
##                          combo_window_open 时允许接续下一段
##
## 判定必须发生在 [windup, active_end) 之间，伤害只在这一窗口内生效。

@export_group("标识")
## 唯一 ID，用于日志、动画查找和网络同步。例如 &"katana_light_1"
@export var attack_id: StringName = &"unnamed"
## 显示名（中文，用于调试面板）
@export var display_name: String = "未命名攻击"
## 这套攻击属于哪把武器（对应 WeaponData.weapon_id）
@export var weapon_id: StringName = &""

@export_group("时序")
## 起手时间：按下攻击到判定开始。这是敌人"读招"和玩家"预判"的依据。
@export var windup: float = 0.32
## 有效判定时长
@export var active: float = 0.12
## 收招时长（从 active 结束到动作结束）
@export var recovery: float = 0.38
## 连招窗口开启时间点（相对攻击开始）。在此之前按攻击只会被缓冲。
@export var combo_window_open: float = 0.0
## 连招窗口关闭时间点。正数 = 接续必须在 combo_window_open..close 内按下。
## 设为 0 表示用 recovery 结束点作为关闭时间。
@export var combo_window_close: float = 0.0
## 收招阶段可被翻滚取消的进度（0~1，1 = 必须完全收完）
@export var dodge_cancel_progress: float = 0.65
## 收招阶段可被轻攻击取消的进度（用于目押连招手感）
@export var attack_cancel_progress: float = 0.85

@export_group("伤害")
## 基础伤害
@export var damage: float = 20.0
## 架势伤害（削韧性）
@export var poise_damage: float = 12.0
## 重量等级：0=轻  1=中  2=重。决定硬直、镜头抖动、音效、命中停顿。
@export_range(0, 2) var weight: int = 0
## 是否可处决（架势打破后使用）
@export var is_execution: bool = false

@export_group("判定体积")
## 判定形状。胶囊适合横扫，球适合突刺，盒适合下劈。
@export_enum("Capsule", "Sphere", "Box") var shape_type: String = "Capsule"
## 判定挂点相对角色的局部偏移（前方 = -Z，与 Godot 前向一致）
@export var hit_offset: Vector3 = Vector3(0.0, 1.1, -1.2)
## 胶囊/盒的半长（沿局部 X 轴展开）；球体忽略此值
@export var hit_half_length: float = 0.9
## 半径
@export var hit_radius: float = 0.55
## 盒体的半高（仅 shape_type = Box 时使用）
@export var hit_half_height: float = 0.5
## 判定挂点相对角色的局部旋转（度）
@export var hit_rotation_deg: Vector3 = Vector3.ZERO
## 判定在有效帧内的位移（用于表现挥砍轨迹，从起始偏移移动到结束偏移）
@export var hit_offset_end: Vector3 = Vector3.ZERO
## 是否让判定随角色朝向实时旋转（横扫类应为 true）
@export var follow_facing: bool = true

@export_group("资源消耗")
@export var stamina_cost: float = 18.0
## 精力不足时是否仍允许出招（一般 false，但允许"最后一击"）
@export var allow_when_exhausted: bool = false

@export_group("位移")
## 攻击期间把角色向前推的初速度。起手长的重击通常为 0。
@export var lunge_speed: float = 0.0
## 攻击期间是否锁定角色朝向（轻击前冲时锁住，避免乱转）
@export var lock_facing: bool = true
## 是否允许在攻击中移动（一般只有重攻击蓄力时允许微调）
@export var allow_movement: bool = false

@export_group("表现")
## 时长（秒）；用于动画播放和调试时间轴显示
@export var sfx_hit: StringName = &""
@export var sfx_swing: StringName = &""
## 命中时的粒子/特效场景路径
@export var vfx_hit: String = ""
## 命中停顿类型：0=轻 1=中 2=重（默认跟随 weight）
@export_range(-1, 2) var hitstop_override: int = -1

@export_group("后续连招")
## 命中后可以接续的攻击 ID（留空表示用同一武器的下一段）
@export var combo_next: StringName = &""
## 是否允许蓄力（重攻击用）
@export var chargeable: bool = false
## 最大蓄力时间
@export var max_charge: float = 0.9
## 蓄力满时的伤害倍率
@export var charge_damage_mult: float = 2.0
## 蓄力满时额外的起手时间（蓄力会延长预备动作）
@export var charge_windup_bonus: float = 0.0


## 计算动作总时长
func get_total_duration() -> float:
	return windup + active + recovery


## 有效判定帧的起止时间（绝对秒数）
func get_active_range() -> Vector2:
	return Vector2(windup, windup + active)


## 连招窗口的实际关闭时间
func get_combo_close_time() -> float:
	if combo_window_close > 0.0:
		return combo_window_close
	return get_total_duration()


## 某个时刻是否处于有效判定帧
func is_active_at(t: float) -> bool:
	return t >= windup and t < windup + active


## 某个时刻是否处于收招阶段
func is_recovery_at(t: float) -> bool:
	return t >= windup + active


## 当前时刻是否允许取消成闪避
func can_dodge_cancel_at(t: float) -> bool:
	var total := get_total_duration()
	var threshold := windup + active + recovery * dodge_cancel_progress
	return t >= threshold


## 当前时刻是否允许取消成下一次攻击（连招）
func in_combo_window(t: float) -> bool:
	return t >= combo_window_open and t <= get_combo_close_time()


## 有效帧内的插值进度（0~1），用于判定体积从 hit_offset 移动到 hit_offset_end
func get_hit_sweep_t(t: float) -> float:
	if active <= 0.0:
		return 1.0
	return clampf((t - windup) / active, 0.0, 1.0)


## 解析出实际生效的判定偏移
func get_hit_offset_at(t: float) -> Vector3:
	if hit_offset_end == Vector3.ZERO:
		return hit_offset
	return hit_offset.lerp(hit_offset_end, get_hit_sweep_t(t))


## 实际命中停顿等级（-1 时跟随 weight）
func get_hitstop_tier() -> int:
	return weight if hitstop_override < 0 else hitstop_override


func _to_string() -> String:
	return "[AttackData %s (%s) %.2f+%.2f+%.2f dmg=%.0f]" % [
		attack_id, display_name, windup, active, recovery, damage
	]
