extends Node
## 上限探针（参考数据，不属于常规回归测试）。
##
## 目的：找出「碎片刚体数量」与「CPU 物理步进耗时」的饱和点。
##
## 【为什么常规性能测试（perf_test.gd）给不出这个曲线】
## 常规测试用的是 DebrisPool，它把活跃碎片硬性限制在
## MAX_DEBRIS_RIGIDBODIES = 60。60 个刚体远没有压满这台机器的物理预算
## （实测物理帧间隔一直是 16.6ms 的量级，看不出增长），所以"碎片满屏会不会掉帧"
## 这个问题只靠池上限内的数据回答不了。
## 本探针**故意绕过池上限**，直接新建 DebrisPiece 节点，把数量拉到 960，
## 才能看到物理帧间隔从「被 60Hz 计时器夹住」变成「被 CPU 拖长」的拐点。
##
## 【这不是游戏的正常状态】碎片池永远不该被绕过。这里只是测极限。
##
## 用法（项目根目录）：
##     godot --headless res://tests/perf_limit_probe.tscn
## 结果打印到标准输出（同时写入 tests/性能上限探针.txt）。

const ARENA := "res://scenes/levels/arena.tscn"
const OUT_PATH := "res://tests/性能上限探针.txt"
## 每个档位采样的物理帧数
const FRAMES := 120
## 依次测试的碎片数量档位。
## 【为什么档位一直加到 3840】
## 第一次跑的时候只测到 960，结果物理帧间隔几乎没有变化（仍是 ~16.6ms），
## 说明"拐点"还在更后面。所以把档位继续拉高，直到看清它从哪里开始失控。
const LEVELS := [0, 60, 240, 960, 1920, 3840]

var _level: Node3D
var _container: Node3D

var _phys_iv: Array[float] = []
var _phys_mon: Array[float] = []
var _collecting := false
var _prev_phys_us := 0
var _seen := 0
var _rows: Array[Dictionary] = []


func _ready() -> void:
	print("========== 物理上限探针（绕过碎片池上限） ==========")
	print("[环境] CPU=%s（%d 核心）  physics_ticks=%d" % [
		OS.get_processor_name(), OS.get_processor_count(),
		Engine.physics_ticks_per_second])

	var packed := load(ARENA) as PackedScene
	_level = packed.instantiate() as Node3D
	add_child(_level)
	for i in 90:
		await get_tree().physics_frame
	_set_ai(false)

	_container = Node3D.new()
	_container.name = "ProbeContainer"
	add_child(_container)

	var spawned := 0
	for target: int in LEVELS:
		while spawned < target:
			_spawn_one()
			spawned += 1
		await get_tree().physics_frame
		await _sample(target)

	_report()
	get_tree().quit(0)


func _spawn_one() -> void:
	var p := DebrisPiece.new()
	_container.add_child(p)
	p.launch(
		Vector3(randf_range(-14.0, 14.0), randf_range(1.0, 7.0), randf_range(-14.0, 14.0)),
		0.25, Color(0.6, 0.6, 0.62),
		Vector3(randf_range(-1.5, 1.5), 0.3, randf_range(-1.5, 1.5)))


func _sample(target: int) -> void:
	_phys_iv.clear()
	_phys_mon.clear()
	_prev_phys_us = 0
	_seen = 0
	_collecting = true
	while _seen < FRAMES:
		await get_tree().physics_frame
	_collecting = false
	var st := _stats(_phys_iv)
	var over := 0
	for v in _phys_iv:
		if v > 20.0:
			over += 1
	_rows.append({
		"target": target,
		"n": st["n"], "avg": st["avg"], "med": st["med"],
		"p95": st["p95"], "max": st["max"], "over": over,
		"phys_mon_avg": _stats(_phys_mon)["avg"],
		"active": int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		"pairs": int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		"obj": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"mem": float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0,
	})
	print("[%4d 碎片] 物理帧间隔 avg=%.2f med=%.2f P95=%.2f max=%.2f ms（超20ms %d/%d）| TIME_PHYSICS avg=%.1f | 活跃刚体=%d 碰撞对=%d 节点=%d 内存=%.1fMB" % [
		target, st["avg"], st["med"], st["p95"], st["max"], over, st["n"],
		_stats(_phys_mon)["avg"],
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0])


func _physics_process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _collecting:
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


func _report() -> void:
	var lines: PackedStringArray = []
	lines.append("物理上限探针（无头，脚本自动生成，请勿手改）")
	lines.append("生成时间：%s" % Time.get_datetime_string_from_system())
	lines.append("CPU：%s（%d 核心）" % [OS.get_processor_name(), OS.get_processor_count()])
	lines.append("")
	lines.append("方法：绕过 DebrisPool 的上限，直接新建 DebrisPiece 刚体，")
	lines.append("      在空场景（AI 关闭）里依次把数量拉到 %s，各采样 %d 个物理帧。" % [
		str(LEVELS), FRAMES])
	lines.append("注意：碎片是「抛出去后自然落地」的，采样时大部分已进入 sleep。")
	lines.append("      这代表稳态开销。若要看「全部同时运动」的更坏情况，")
	lines.append("      见 perf_test.gd 的场景 2。")
	lines.append("说明：物理帧间隔在 16.67ms 附近说明「没吃满 60Hz 预算」；")
	lines.append("      一旦随数量持续上抬并越过 ~20ms，就说明物理步进开始拖慢主循环。")
	lines.append("")
	for r: Dictionary in _rows:
		lines.append("%4d 碎片 | 物理帧间隔 avg %.2f | med %.2f | P95 %.2f | max %.2f ms | 超20ms %d/%d | TIME_PHYSICS avg %.1f ms | 活跃刚体 %d | 碰撞对 %d | 内存 %.1fMB" % [
			r["target"], r["avg"], r["med"], r["p95"], r["max"], r["over"], r["n"],
			r["phys_mon_avg"], r["active"], r["pairs"], r["mem"]])
	var text := "\n".join(lines)
	print("\n" + text)
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
		print("结果已写入 %s" % OUT_PATH)
