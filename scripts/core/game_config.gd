extends Node
## 全局可调参数（Autoload 单例）。
##
## 目的：把「手感调参」集中到一处，方便快速迭代而不必翻遍脚本。
## 战斗中按 F3 可打开调试面板查看关键数值。
##
## 调参速查（想改什么看这里）：
##   走路/跑步太慢        -> MOVE_SPEED / SPRINT_SPEED
##   闪避不够爽           -> DODGE_DISTANCE / DODGE_IFRAMES
##   攻击太软             -> HITSTOP_* / CAMERA_SHAKE_*
##   精力不够用           -> STAMINA_* / 攻击资源里的 stamina_cost
##   敌人硬直太短         -> POISE_* / 攻击资源里的 poise_damage
##
## 注意：这里放的是全局默认值。每种武器的具体数值放在
##   res://resources/weapons/*.tres 里（AttackData 资源）。

# =========================================================
# 角色移动
# =========================================================

## 普通移动速度 (m/s)
@export var MOVE_SPEED: float = 4.6
## 冲刺速度 (m/s)
@export var SPRINT_SPEED: float = 7.2
## 速度变化加速度 (m/s^2)。数值越高起停越"硬"，越低越"滑"。
@export var ACCELERATION: float = 42.0
## 松开方向键后的减速度
@export var DECELERATION: float = 34.0
## 空中操控加速度倍率
@export var AIR_CONTROL: float = 0.35
## 转向速度（度/秒）。越大转身越快。
@export var TURN_SPEED: float = 720.0
## 锁定状态下的转向速度（度/秒）—— 比自由转向慢，让锁定时有重量感
@export var LOCKED_TURN_SPEED: float = 540.0
## 重力倍率（基础重力在 project.godot 里，默认 26）
@export var GRAVITY_SCALE: float = 1.0
## 跳跃初速度 (m/s)
@export var JUMP_VELOCITY: float = 8.0
## 最大可走坡度（度）
@export var MAX_SLOPE_ANGLE: float = 46.0

# =========================================================
# 闪避
# =========================================================

## 闪避位移距离 (m)
@export var DODGE_DISTANCE: float = 4.5
## 闪避总时长
@export var DODGE_DURATION: float = 0.62
## 无敌开始时间（相对闪避起点）
@export var DODGE_IFRAME_START: float = 0.06
## 无敌结束时间。0.36 - 0.06 = 0.30 秒无敌窗口，属于"精准但不宽容"。
@export var DODGE_IFRAME_END: float = 0.36
## 闪避消耗精力
@export var DODGE_STAMINA_COST: float = 22.0
## 后摇可被取消的时间点（闪避总时长的百分比，0~1）
@export var DODGE_CANCEL_AT: float = 0.72

# =========================================================
# 精力
# =========================================================

@export var STAMINA_MAX: float = 100.0
## 基础恢复速度（每秒）
@export var STAMINA_REGEN: float = 22.0
## 精力耗尽后进入"气竭"，恢复速度降到该倍率，且有延迟
@export var STAMINA_EXHAUSTED_REGEN_MULT: float = 0.55
## 受到该值以上的动作消耗后，恢复延迟（秒）——防止无脑连打
@export var STAMINA_REGEN_DELAY: float = 0.45
## 气竭状态下额外恢复延迟
@export var STAMINA_EXHAUSTED_DELAY: float = 1.1

# =========================================================
# 生命与受击
# =========================================================

@export var PLAYER_MAX_HEALTH: float = 120.0
@export var ENEMY_MAX_HEALTH: float = 80.0
@export var BOSS_MAX_HEALTH: float = 1400.0

## 受击后的无敌时间（防止一次攻击多段判定重复扣血）
@export var HIT_INVULN_TIME: float = 0.25

## 轻受击硬直时长
@export var HITSTUN_LIGHT: float = 0.32
## 重受击硬直时长
@export var HITSTUN_HEAVY: float = 0.72
## 硬直期间的击退初速度
@export var KNOCKBACK_LIGHT: float = 2.2
@export var KNOCKBACK_HEAVY: float = 6.0

# =========================================================
# 架势 / 韧性（Poise）
# =========================================================

## 玩家架势上限。架势归零 -> 被破防（对玩家表现为大硬直）
@export var PLAYER_POISE_MAX: float = 60.0
@export var ENEMY_POISE_MAX: float = 40.0
@export var BOSS_POISE_MAX: float = 160.0

## 架势自然恢复速度（每秒），仅在未被攻击 STAGGER_RECOVER_DELAY 秒后生效
@export var POISE_REGEN: float = 14.0
## 受击后多久开始恢复架势
@export var POISE_REGEN_DELAY: float = 1.6

## 架势被打破后的处决窗口时长
@export var POISE_BREAK_WINDOW: float = 3.0

# =========================================================
# 打击感：命中停顿（Hitstop）
# =========================================================
#
# 重要：命中停顿只影响「本地表现层」（动画播放速度、时间缩放），
# 绝不允许冻结整个联机世界。详见 docs/技术决策.md TD-006。

## 轻击命中停顿时长。0 表示关闭。
@export var HITSTOP_LIGHT: float = 0.045
@export var HITSTOP_MEDIUM: float = 0.075
@export var HITSTOP_HEAVY: float = 0.13
## 命中停顿期间的时间缩放。0.05 = 几乎冻结但仍在推进。
@export var HITSTOP_TIME_SCALE: float = 0.04
## 攻击落空/被格挡时的较短停顿
@export var HITSTOP_BLOCKED: float = 0.06

# =========================================================
# 打击感：镜头反馈
# =========================================================

## 镜头抖动基础强度（轻击）
@export var SHAKE_LIGHT: float = 0.055
@export var SHAKE_MEDIUM: float = 0.11
@export var SHAKE_HEAVY: float = 0.24
## 抖动衰减速度
@export var SHAKE_DECAY: float = 9.0

## 重击的镜头前推距离 (m)
@export var CAMERA_PUNCH_HEAVY: float = 0.22
@export var CAMERA_PUNCH_LIGHT: float = 0.06

# =========================================================
# 输入缓冲与连招
# =========================================================

## 输入缓冲窗口：在动作结束前 N 秒内按下的攻击会被记住
@export var INPUT_BUFFER_TIME: float = 0.28
## 翻滚输入缓冲（比攻击稍长，避免"按了没滚"的挫败感）
@export var DODGE_BUFFER_TIME: float = 0.32
## 连招窗口：收招阶段前 N 秒内允许接续下一段
@export var COMBO_WINDOW: float = 0.65

# =========================================================
# 地形破坏
# =========================================================

## 同时存在的最大碎片刚体数量（性能保护）
@export var MAX_DEBRIS_RIGIDBODIES: int = 60
## 单个碎片的存活时间
@export var DEBRIS_LIFETIME: float = 6.0
## 碎片超过该时间后开始淡出
@export var DEBRIS_FADE_TIME: float = 1.5
## 碎片自动消失距离（离玩家太远直接回收）
@export var DEBRIS_CULL_DISTANCE: float = 60.0

# =========================================================
# 网络
# =========================================================

const DEFAULT_PORT: int = 27015
const MAX_PLAYERS: int = 4
## 服务器权威帧率上限（每秒最多处理多少次战斗帧）
@export var SERVER_TICK_RATE: int = 30
## 客户端位置插值缓冲（秒）。越大越平滑但延迟越高。
@export var CLIENT_INTERP_BUFFER: float = 0.08

# =========================================================
# 调试
# =========================================================

@export var DEBUG_DRAW_HITBOXES: bool = false
@export var DEBUG_SHOW_ATTACK_TIMELINE: bool = true
@export var DEBUG_PRINT_COMBAT_LOG: bool = false

## 运行时一次性覆盖（供调试面板使用）
func set_value(key: String, value: Variant) -> void:
	if key in self:
		set(key, value)
