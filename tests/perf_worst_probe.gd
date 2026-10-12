extends Node
## 最坏情况对照探针：60 个碎片刚体**全部处于 sleep=false 的飞行状态**。
##
## 【为什么要单独测这个】
## 常规性能测试（perf_test.gd 场景 2）虽然会周期性 re-launch 碎片，
## 但采样窗口里仍有相当一部分碎片已经落地并进入 sleep，所以那组读数偏"稳态"。
## 本探针在**每个物理帧**都把全部 60 个碎片重新抛起来，保证采样时
## 活跃刚体数恒等于 60（即满负荷物理），得到的是限内真正的上限读数。
##
## 【诚实的说明】
## 让碎片永不落地在真实游戏里不会发生（碎片几秒内必然落地或到期回收）。
## 这里是把「碎片池上限」这一硬约束压到最紧，用来回答
## "如果不做任何优化，60 个刚体同时飞时物理要花多久"。
##
## 用法（项目根目录）：
##     godot --headless res://tests/perf_worst_probe.tscn
## 结果打印到标准输出（同时写入 tests/性能最坏情况探针.txt）。

const ARENA := "res://scenes/levels/arena.tscn"
const OUT_PATH := "res://tests/性能最坏情况探针.txt"
const FRAMES := 240
const DEBRIS_LIMIT := 60

var _container: Node3D
var _phys_iv: Array[float] = []
var _phys_mon: Array[float] = []
var _collecting := false
var _prev_phys_us := 0
var _seen := 0


func _ready() -> void:
	print("========== 最坏情况探针：60 个碎片全程飞行 ==========")
	print("[环境] CPU=%s（%d 核心）" % [OS.get_processor_name(), OS.get_processor_count()])
	var packed := load(ARENA) as PackedScene
	add_child(packed.instantiate())
	for i in 90:
		await get_tree().physics_frame
	_set_ai(false)
	# 【为什么要先 touch 一次池再清掉】
	# DebrisPool 的容器是「首次生成碎片时」才建在 current_scene 下的。
	# 先用 spawn_at 把池预热（容器被创建、60 个池碎片被建好），
	# 再 clear_all() 把它们全部冻结并移到 y=-500，它们不再参与碰撞。
	# 之后用探针自己的容器建 60 个碎片，就得到"恰好 60 个活跃刚体"的干净基线。
	for i in 10:
		DebrisPool.spawn_at(Vector3(0.0, 4.0, 0.0), 6, Color(0.6, 0.6, 0.62), 0.3)
	await get_tree().physics_frame
	print("[探针] DebrisPool 预热 %d 个碎片（上限 %d），随后全部清空" % [
		DebrisPool.get_active_count(), GameConfig.MAX_DEBRIS_RIGIDBODIES])
	DebrisPool.clear_all()
	await get_tree().physics_frame

	_container = Node3D.new()
	_container.name = "WorstProbeContainer"
	add_child(_container)
	for i in DEBRIS_LIMIT:
		_add_debris()
	await get_tree().physics_frame

	_prev_phys_us = 0
	_seen = 0
	_collecting = true
	while _seen < FRAMES:
		await get_tree().physics_frame
	_collecting = false
	_report()
	get_tree().quit(0)


func _add_debris() -> void:
	var p := DebrisPiece.new()
	_container.add_child(p)
	p.launch(Vector3(randf_range(-6, 6), randf_range(2, 6), randf_range(-6, 6)),
		0.3, Color(0.6, 0.6, 0.62), Vector3(randf_range(-1, 1), 1.0, randf_range(-1, 1)))


## 每个物理帧把全部碎片重新抛起 —— 保证采样期间活跃刚体恒为 60
func _relaunch_all() -> void:
	for child in _container.get_children():
		var dp := child as DebrisPiece
		if dp == null:
			continue
		dp.launch(dp.global_position, 0.3, Color(0.6, 0.6, 0.62),
			Vector3(randf_range(-2, 2), randf_range(1, 3), randf_range(-2, 2)))


func _physics_process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _collecting:
		_relaunch_all()
		if _prev_phys_us > 0:
			_phys_iv.append(float(now - _prev_phys_us) / 1000.0)
			_phys_mon.append(float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0)
		_seen += 1
	_prev_phys_us = now


func _set_ai(on: bool) -> void:
	for n in get_tree().get_nodes_in_group(&"lockon_targets"):
		var e := n as Node
		if e != null and e.get("ai_enabled") != null:
			e.set("ai_enabled", on)


func _report() -> void:
	var st := _stats(_phys_iv)
	var over := 0
	for v in _phys_iv:
		if v > 20.0:
			over += 1
	var lines: PackedStringArray = []
	lines.append("最坏情况探针（无头，脚本自动生成，请勿手改）")
	lines.append("生成时间：%s" % Time.get_datetime_string_from_system())
	lines.append("CPU：%s（%d 核心）" % [OS.get_processor_name(), OS.get_processor_count()])
	lines.append("")
	lines.append("方法：空场景 + 关闭全部 AI，%d 个碎片刚体在采样期间**每帧重新抛起**，" % DEBRIS_LIMIT)
	lines.append("      保证活跃物理对象恒为 %d（真实游戏里碎片会落地，所以这是理论上限）。" % DEBRIS_LIMIT)
	lines.append("")
	lines.append("物理帧间隔 avg %.2f | med %.2f | P95 %.2f | max %.2f ms | 超20ms %d/%d" % [
		st["avg"], st["med"], st["p95"], st["max"], over, st["n"]])
	lines.append("引擎自报物理耗时 avg %.2f ms | 活跃刚体 %d | 碰撞对 %d | 节点 %d | 内存 %.1fMB" % [
		_stats(_phys_mon)["avg"],
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0])
	var text := "\n".join(lines)
	print("\n" + text)
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
		print("结果已写入 %s" % OUT_PATH)


func _stats(a: Array[float]) -> Dictionary:
	var n := a.size()
	if n == 0:
		return {"avg": 0.0, "med": 0.0, "p95": 0.0, "max": 0.0, "n": 0}
	var b := a.duplicate()
	b.sort()
	var s := 0.0
	for v in b:
		s += v
	return {
		"avg": s / float(n),
		"med": b[n / 2],
		"p95": b[clampi(int(float(n) * 0.95), 0, n - 1)],
		"max": b[n - 1],
		"n": n,
	}
