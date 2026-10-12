class_name HitstopManager
extends Node
## 本地命中停顿（Hitstop / 顿帧）管理器。
##
## 关键约束（来自任务要求 4.4 第 4 条）：
##   "命中停顿不能直接冻结整个联机世界"
##
## 所以这里**不使用** Engine.time_scale（那会影响所有玩家和物理）。
## 做法是：只把本地的表现层减速——
##   - 命中者的动画播放速度 -> 接近 0
##   - 本地相机轻微顿帧
##   - 物理与网络照常推进
##
## 这样 A 玩家打出重击的顿帧，不会让 B 玩家卡顿，也不会让 Boss 的
## 攻击计时暂停（否则会出现"顿帧逃避伤害"的作弊）。

## 请求一次命中停顿
## node: 需要减速的节点（通常是动画播放器所属角色）
## duration: 时长（秒）
## target_scale: 减速到多少（0.04 = 几乎冻结）
static func request(node: Node, duration: float, target_scale: float = -1.0) -> void:
	if node == null or duration <= 0.0:
		return
	if target_scale < 0.0:
		target_scale = GameConfig.HITSTOP_TIME_SCALE if GameConfig else 0.04
	var mgr := _get_or_create(node)
	mgr.play(duration, target_scale)


## 按重量等级请求（0轻 1中 2重），-1 表示不顿帧
static func request_by_tier(node: Node, tier: int) -> void:
	if tier < 0 or GameConfig == null:
		return
	var dur := 0.0
	match tier:
		0: dur = GameConfig.HITSTOP_LIGHT
		1: dur = GameConfig.HITSTOP_MEDIUM
		2: dur = GameConfig.HITSTOP_HEAVY
	request(node, dur)


static func _get_or_create(node: Node) -> HitstopManager:
	var existing := node.get_node_or_null("HitstopManager") as HitstopManager
	if existing != null:
		return existing
	var mgr := HitstopManager.new()
	mgr.name = "HitstopManager"
	node.add_child(mgr)
	return mgr


# ---------------------------------------------------------------

## 受影响的 AnimationPlayer 列表（按节点路径缓存）
var _targets: Array[Node] = []
var _timer: float = 0.0
var _duration: float = 0.0
var _target_scale: float = 1.0
var _active: bool = false


func _ready() -> void:
	# 不会因为是表现层就不处理；用 process 而非常量轮询
	set_process(true)


## 注册需要减速的动画播放器。留空则自动查找同级 AnimationPlayer。
func register_target(t: Node) -> void:
	if t != null and not _targets.has(t):
		_targets.append(t)


func play(duration: float, target_scale: float) -> void:
	# 取最长的一次停顿（连续命中不叠加，避免卡成幻灯片）
	if duration > _duration - _timer:
		_duration = duration
		_timer = duration
		_target_scale = target_scale
	_active = true
	_apply_scale(_target_scale)


func _process(delta: float) -> void:
	if not _active:
		return
	# 用真实时间推进，不受自身减速影响
	_timer -= delta
	if _timer <= 0.0:
		_stop()


func _stop() -> void:
	_active = false
	_timer = 0.0
	_duration = 0.0
	_apply_scale(1.0)


func _apply_scale(scale: float) -> void:
	var resolved := _resolve_targets()
	for t: Node in resolved:
		if not is_instance_valid(t):
			continue
		if t is AnimationPlayer:
			(t as AnimationPlayer).speed_scale = scale
		elif t is AnimationTree:
			(t as AnimationTree).set_speed_scale(scale)


func _resolve_targets() -> Array[Node]:
	if not _targets.is_empty():
		return _targets
	# 自动模式：查找父节点下的 AnimationTree / AnimationPlayer
	var host := get_parent()
	if host == null:
		return []
	var found: Array[Node] = []
	var tree := host.get_node_or_null("AnimationTree")
	if tree != null:
		found.append(tree)
	else:
		var ap := host.get_node_or_null("AnimationPlayer")
		if ap != null:
			found.append(ap)
	return found


func is_active() -> bool:
	return _active
