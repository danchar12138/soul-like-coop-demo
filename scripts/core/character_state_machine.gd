class_name CharacterStateMachine
extends Node
## 角色状态机：用**单一状态变量 + 优先级表**管理动作。
##
## 为什么不做成每个状态一个 Node（"State 模式"）？
##   对本项目规模（1 个主角 + 1 种小怪 + 1 个 Boss），节点式状态机
##   会带来大量样板文件，而状态逻辑本身很短。用单状态 + 优先级表
##   更紧凑，也让"谁能打断谁"这一条核心规则集中可见、便于调参。
##
## 状态迁移规则：
##   新状态优先级 >= 当前状态优先级时才允许切换（同级允许，便于
##   攻击接攻击实现连招）。唯一的例外见 _allow_same_level()。
##
## 防卡死保护：
##   - 每个带时限的状态都有 timeout 兜底，超时强制回 IDLE
##   - 死亡状态不可被任何状态覆盖
##   - 提供 force_state() 给复活/传送使用

signal state_changed(from: int, to: int)

@export var initial_state: CombatState.State = CombatState.State.IDLE

## 当前状态持续时间
var time_in_state: float = 0.0
## 当前状态的强制退出时间（0 = 无限制）
var _timeout: float = 0.0

var _state: CombatState.State = CombatState.State.IDLE
var _previous: CombatState.State = CombatState.State.IDLE

var actor: Node3D


func _ready() -> void:
	actor = get_parent() as Node3D
	_state = initial_state
	_previous = initial_state


func _process(delta: float) -> void:
	time_in_state += delta
	if _timeout > 0.0 and time_in_state >= _timeout:
		# 超时兜底：绝大多数情况状态会通过自身逻辑正常退出，
		# 这里是为了防止某个分支漏了退出条件导致角色永久卡死。
		_on_timeout()
		_timeout = 0.0


# ============================================================
# 查询
# ============================================================

func get_state() -> CombatState.State:
	return _state


func get_state_name() -> String:
	return CombatState.state_name(_state)


func is_state(s: CombatState.State) -> bool:
	return _state == s


func can_move() -> bool:
	return CombatState.allows_movement(_state)


func can_take_damage() -> bool:
	return CombatState.can_take_damage(_state) and _state != CombatState.State.DODGE


func is_locked() -> bool:
	return CombatState.is_action_locked(_state)


func can_start_attack() -> bool:
	# 待机/冲刺可起手；攻击中也可（用于连招接续，由 AttackController
	# 自己判断连招窗口是否已开启，状态机只负责放行）
	return _state in [CombatState.State.IDLE, CombatState.State.SPRINT, CombatState.State.ATTACK]


func can_start_dodge() -> bool:
	return _state in [
		CombatState.State.IDLE,
		CombatState.State.SPRINT,
		CombatState.State.ATTACK,
		CombatState.State.CHARGE,
		CombatState.State.STAGGER_ATTACK,
	]


# ============================================================
# 迁移
# ============================================================

## 请求切换状态。返回 true 表示切换成功。
## duration > 0 时会在超时后自动回 IDLE。
func request_state(next: CombatState.State, duration: float = 0.0) -> bool:
	if _state == CombatState.State.DEAD and next != CombatState.State.RESPAWNING:
		return false
	if _state == CombatState.State.VICTORY:
		return false

	var cur_p := CombatState.priority(_state)
	var next_p := CombatState.priority(next)

	if _state == next:
		# 同状态重复请求：只刷新时限（例如连续受击刷新硬直）
		if duration > 0.0:
			time_in_state = 0.0
			_timeout = duration
		return true

	# 低优先级不能覆盖高优先级，除非当前状态已允许取消
	if next_p < cur_p and not _can_be_interrupted():
		return false

	_previous = _state
	_state = next
	time_in_state = 0.0
	_timeout = duration
	_on_state_entered(next)
	state_changed.emit(_previous, _state)
	return true


## 强制切换（复活、传送、初始化用），无视优先级
func force_state(next: CombatState.State, duration: float = 0.0) -> void:
	_previous = _state
	_state = next
	time_in_state = 0.0
	_timeout = duration
	_on_state_entered(next)
	state_changed.emit(_previous, _state)


## 当前状态是否允许被同级或更低优先级的状态打断
func _can_be_interrupted() -> bool:
	# 这些状态一旦开始就必须走完（或由自身逻辑结束）
	return _state in [
		CombatState.State.IDLE,
		CombatState.State.SPRINT,
		CombatState.State.ATTACK,   # 允许被连招/闪避取消
		CombatState.State.CHARGE,
	]


func _on_state_entered(s: CombatState.State) -> void:
	match s:
		CombatState.State.DEAD:
			_timeout = 0.0
		CombatState.State.HITSTUN, CombatState.State.POISE_BREAK:
			pass  # 时限由调用方给定
		_:
			pass


func _on_timeout() -> void:
	# 超时后回到待机（死亡除外）
	if _state == CombatState.State.DEAD:
		return
	force_state(CombatState.State.IDLE)


# ============================================================
# 供 AttackController 回调的接口
# 这些方法名是被 AttackController 通过 has_method 动态调用的，
# 改名会破坏攻击系统，务必同步修改。
# ============================================================

func on_attack_started(_attack: AttackData) -> void:
	request_state(CombatState.State.ATTACK)


func on_attack_finished(_attack: AttackData, reason: StringName) -> void:
	# 被闪避/连招取消时不回到 IDLE，由新动作的状态请求负责
	if reason == &"dodge" or reason == &"combo":
		return
	if _state == CombatState.State.ATTACK:
		force_state(CombatState.State.IDLE)


func on_attack_hit(_target: Node, _info: DamageInfo) -> void:
	# 预留：命中后允许更早取消（提升连招流畅度）
	pass


# ============================================================
# 便捷状态入口（供角色控制器调用）
# ============================================================

func enter_hitstun(duration: float) -> void:
	request_state(CombatState.State.HITSTUN, duration)


func enter_poise_break(duration: float) -> void:
	request_state(CombatState.State.POISE_BREAK, duration)


func enter_dead() -> void:
	force_state(CombatState.State.DEAD)


func enter_dodge(duration: float) -> bool:
	return request_state(CombatState.State.DODGE, duration)


func enter_charge() -> void:
	request_state(CombatState.State.CHARGE)


func enter_idle() -> void:
	force_state(CombatState.State.IDLE)


func _to_string() -> String:
	return "[状态 %s %.2fs]" % [get_state_name(), time_in_state]
