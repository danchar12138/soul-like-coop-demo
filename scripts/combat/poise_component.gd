class_name PoiseComponent
extends Node
## 架势 / 韧性组件（Poise）。
##
## 解决的问题：如果敌人每次被轻击都硬直，玩家就能无限连打死任何敌人；
## 如果完全不硬直，打击感就变成"打海绵"。
##
## 方案（类魂通用做法）：
##   - 每次受击扣"架势值"而不是打断动作
##   - 架势还有余量时，敌人只播放受击表现，动作继续（"霸体"）
##   - 架势归零 -> 进入"架势破除"状态，播放长硬直，并开启处决窗口
##   - 一段时间不被打，架势自动回满
##
## 这给了玩家一个明确目标：敢于在敌人出招间隙持续进攻。
##
## 攻击的 poise_damage 与这里的数据配合：
##   连续轻击（每下 12）打 4 下 = 48 > 小怪 40 架势 -> 破防
##   重击（35）打 2 下 -> 破防，是更高效的破防手段

signal poise_changed(current: float, maximum: float)
signal broken(window_seconds: float)
signal recovered()

@export var max_poise: float = 40.0
@export var current: float = 40.0
## 自然恢复速度（每秒）
@export var regen_rate: float = 14.0
## 受击后多久开始恢复
@export var regen_delay: float = 1.6
## 架势破除后的处决窗口时长
@export var break_window: float = 3.0

var is_broken: bool = false
var owner_entity: Node

var _regen_delay_left: float = 0.0
var _break_timer: float = 0.0


func _ready() -> void:
	owner_entity = get_parent()
	current = clampf(current, 0.0, max_poise)


func _process(delta: float) -> void:
	if is_broken:
		_break_timer -= delta
		if _break_timer <= 0.0:
			_recover_from_break()
		return

	if _regen_delay_left > 0.0:
		_regen_delay_left -= delta
		return
	if current >= max_poise:
		return
	current = minf(max_poise, current + regen_rate * delta)
	poise_changed.emit(current, max_poise)


## 权威端调用：结算架势伤害。返回本次是否触发破除。
func apply_poise_damage(amount: float) -> bool:
	if amount <= 0.0:
		return false
	_regen_delay_left = regen_delay
	current = maxf(0.0, current - amount)
	poise_changed.emit(current, max_poise)

	if current <= 0.0 and not is_broken:
		is_broken = true
		_break_timer = break_window
		broken.emit(break_window)
		return true
	return false


## 手动破除（例如 Boss 进入二阶段、处决后强制失衡）
func force_break(window: float = -1.0) -> void:
	if is_broken:
		return
	is_broken = true
	_break_timer = window if window > 0.0 else break_window
	current = 0.0
	poise_changed.emit(current, max_poise)
	broken.emit(_break_timer)


## 处决命中后调用：结束破除状态并回满架势
func consume_break() -> void:
	if not is_broken:
		return
	_recover_from_break()


func set_poise_authoritative(value: float, broken: bool) -> void:
	current = clampf(value, 0.0, max_poise)
	if broken != is_broken:
		is_broken = broken
		if is_broken:
			_break_timer = break_window
	poise_changed.emit(current, max_poise)


func get_ratio() -> float:
	return current / max_poise if max_poise > 0.0 else 0.0


## 剩余处决窗口时间（未破除时为 0）
func get_break_time_left() -> float:
	return maxf(0.0, _break_timer)


func _recover_from_break() -> void:
	is_broken = false
	current = max_poise
	_break_timer = 0.0
	poise_changed.emit(current, max_poise)
	recovered.emit()


func _to_string() -> String:
	return "[Poise %.0f/%.0f%s]" % [current, max_poise, " 已破除" if is_broken else ""]
