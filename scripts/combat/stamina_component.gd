class_name StaminaComponent
extends Node
## 精力组件（类魂战斗的核心资源）。
##
## 规则设计（数值见 GameConfig）：
##   1. 每次消耗精力的动作都会触发一段"恢复延迟"，防止无脑连打。
##   2. 精力降到 0 进入"气竭"（exhausted）状态，恢复变慢、延迟变长。
##   3. 气竭状态持续到精力恢复到 EXHAUST_RECOVER_RATIO 以上才解除。
##
## 这样玩家在连招时必须计算"再来一刀还够不够翻滚"，
## 这是类魂战斗紧张感的主要来源。

signal changed(current: float, maximum: float)
signal exhausted()
signal recovered()
signal insufficient(action: StringName)

@export var max_stamina: float = 100.0
@export var current: float = 100.0
## 恢复速度（每秒）。由 GameConfig 提供默认值。
@export var regen_rate: float = 22.0
## 是否启用自动恢复（死亡、硬直中可临时关闭）
@export var regen_enabled: bool = true

## 气竭状态
var is_exhausted: bool = false
## 解除气竭所需的比例
const EXHAUST_RECOVER_RATIO := 0.35

var _regen_delay_left: float = 0.0

## 组件拥有者（用于信号里带出实体引用）
var owner_entity: Node


func _ready() -> void:
	owner_entity = get_parent()
	if GameConfig != null:
		max_stamina = GameConfig.STAMINA_MAX
		regen_rate = GameConfig.STAMINA_REGEN
		current = max_stamina
	current = clampf(current, 0.0, max_stamina)


func _process(delta: float) -> void:
	_tick(delta)


func _tick(delta: float) -> void:
	if not regen_enabled:
		return
	if _regen_delay_left > 0.0:
		_regen_delay_left -= delta
		return
	if current >= max_stamina:
		return

	var rate := regen_rate
	if is_exhausted:
		rate *= GameConfig.STAMINA_EXHAUSTED_REGEN_MULT if GameConfig else 0.55
	current = minf(max_stamina, current + rate * delta)
	changed.emit(current, max_stamina)

	if is_exhausted and current >= max_stamina * EXHAUST_RECOVER_RATIO:
		is_exhausted = false
		recovered.emit()


## 是否够付这次消耗（不实际扣除）
func can_afford(cost: float) -> bool:
	return current >= cost


## 权威端检查并扣除。返回 true 表示成功扣除。
## action 用于日志与"精力不足"反馈。
func try_spend(cost: float, action: StringName = &"") -> bool:
	if cost <= 0.0:
		return true
	if current < cost:
		insufficient.emit(action)
		EventBus.stamina_insufficient.emit(owner_entity, action)
		return false
	current -= cost
	changed.emit(current, max_stamina)
	_apply_regen_delay(cost)
	if current <= 0.0 and not is_exhausted:
		is_exhausted = true
		exhausted.emit()
	return true


## 无条件扣除（用于已经通过 try_spend 检查过的场景）
func spend(cost: float) -> void:
	if cost <= 0.0:
		return
	current = maxf(0.0, current - cost)
	changed.emit(current, max_stamina)
	_apply_regen_delay(cost)
	if current <= 0.0 and not is_exhausted:
		is_exhausted = true
		exhausted.emit()


## 恢复（吃药、检查点）
func restore(amount: float) -> void:
	current = minf(max_stamina, current + amount)
	changed.emit(current, max_stamina)


func refill() -> void:
	current = max_stamina
	is_exhausted = false
	_regen_delay_left = 0.0
	changed.emit(current, max_stamina)


## 非权威端调用：用权威端数值覆盖
func set_stamina_authoritative(value: float) -> void:
	current = clampf(value, 0.0, max_stamina)
	changed.emit(current, max_stamina)


func get_ratio() -> float:
	return current / max_stamina if max_stamina > 0.0 else 0.0


func _apply_regen_delay(cost: float) -> void:
	if GameConfig == null:
		_regen_delay_left = 0.45
		return
	var base := GameConfig.STAMINA_REGEN_DELAY
	# 消耗越大，延迟越久（重击的惩罚更重）
	var scaled := base * clampf(cost / 25.0, 0.7, 2.2)
	_regen_delay_left = maxf(_regen_delay_left, scaled + (GameConfig.STAMINA_EXHAUSTED_DELAY if is_exhausted else 0.0))


func _to_string() -> String:
	return "[Stamina %.0f/%.0f%s]" % [current, max_stamina, " 气竭" if is_exhausted else ""]
