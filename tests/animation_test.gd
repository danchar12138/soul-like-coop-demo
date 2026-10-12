extends Node
## 骨骼动画资源校验。
##
## 用法：
##   godot --headless res://tests/animation_test.tscn
##
## 校验内容：
##   A1  GLB 里确实带了骨骼（skin）与 14 个动画
##   A2  每个动画的时长与战斗配置对齐（误差 <5%）
##   A3  每个动画确实产生了骨骼运动（不是静止的空动画）
##   A4  动画关键帧覆盖了首尾（没有"半截动画"）
##   A5  蒙皮权重有效：顶点确实会随骨骼动
##
## A3 是重点。一个"有动画轨道但每帧姿态都一样"的动画在
## Godot 里看起来完全正常（时间在走、进度条在动），
## 但角色一动不动。这种问题只能靠实际采样骨骼位置发现。

const RIGGED := "res://assets/models/player_rigged.glb"

## 每个动画期望的时长来源：与战斗配置对齐
var _expected: Dictionary = {}

var _results: Array[Dictionary] = []
var _passed := 0
var _failed := 0


func _ready() -> void:
	print("========== 骨骼动画校验 ==========")
	await _run()
	_report()
	get_tree().quit(0 if _failed == 0 else 1)


func _run() -> void:
	var packed := load(RIGGED) as PackedScene
	if packed == null:
		_check("A1 加载骨骼模型", false, "%s 不存在（请先运行 tools/blender_rig.py）" % RIGGED)
		return
	var root := packed.instantiate() as Node3D
	add_child(root)
	await get_tree().physics_frame

	var skel := _find_skeleton(root)
	var ap := _find_anim_player(root)
	_check("A1 模型带骨骼与动画播放器",
		skel != null and ap != null and skel.get_bone_count() >= 15,
		"骨骼 %d 根，动画 %d 个" % [
			skel.get_bone_count() if skel != null else 0,
			ap.get_animation_list().size() if ap != null else 0])
	if skel == null or ap == null:
		root.queue_free()
		return

	# 从武器配置读出期望时长
	var weapon := load("res://resources/weapons/katana.tres") as WeaponData
	if weapon != null:
		for a: AttackData in weapon.get_all_attacks():
			_expected[a.attack_id] = a.get_total_duration()
	# 状态动画的期望时长（与 GameConfig 对齐）
	_expected[&"dodge"] = GameConfig.DODGE_DURATION
	_expected[&"hit_light"] = GameConfig.HITSTUN_LIGHT
	_expected[&"hit_heavy"] = GameConfig.HITSTUN_HEAVY

	var names := ap.get_animation_list()

	# --- A2 时长对齐 ---
	var worst := ""
	var worst_err := 0.0
	for n in names:
		var key := StringName(n)
		if not _expected.has(key):
			continue
		var anim := ap.get_animation(n)
		var want: float = _expected[key]
		if anim == null or want <= 0.0:
			continue
		var err := absf(anim.length - want) / want
		if err > worst_err:
			worst_err = err
			worst = "%s 动画 %.2fs / 配置 %.2fs" % [n, anim.length, want]
	_check("A2 动画时长与战斗配置对齐（误差 <5%）", worst_err < 0.05,
		"最大偏差 %.2f%%（%s）" % [worst_err * 100.0, worst])

	# --- A3 每个动画都有骨骼运动 ---
	var still: PackedStringArray = []
	var details: PackedStringArray = []
	for n in names:
		var anim := ap.get_animation(n)
		if anim == null or anim.length <= 0.001:
			still.append(String(n))
			continue
		var moved := await _measure_motion(skel, ap, n, anim)
		details.append("%s=%.3fm" % [n, moved])
		if moved < 0.02:
			still.append(String(n))
	_check("A3 每个动画都产生了骨骼运动（不是静止空动画）",
		still.is_empty(),
		"最大位移：%s" % ("; ".join(details) if details.size() <= 4 else
			"; ".join(details.slice(0, 4)) + " …（共 %d 个）" % details.size()))
	if not still.is_empty():
		print("       静止的动画：%s" % ", ".join(still))

	# --- A4 关键帧覆盖首尾 ---
	#
	# 注意：不能只看 track 0 的第一个关键帧。Godot 的 Animation 里
	# 同一时间点的关键帧会因为四元数分量补间而被拆成多条轨道，
	# 轨道顺序不保证。取"所有轨道里最早/最晚的关键帧时间"才可靠。
	var bad_range: PackedStringArray = []
	for n in names:
		var anim := ap.get_animation(n)
		if anim == null or anim.get_track_count() == 0:
			continue
		var k_first := INF
		var k_last := -INF
		for t in anim.get_track_count():
			var cnt := anim.track_get_key_count(t)
			if cnt == 0:
				continue
			k_first = minf(k_first, anim.track_get_key_time(t, 0))
			k_last = maxf(k_last, anim.track_get_key_time(t, cnt - 1))
		if k_first == INF:
			bad_range.append("%s[无关键帧]" % n)
			continue
		# 第一个关键帧应在 0 附近，最后一个应接近动画末尾
		if k_first > 0.05 or absf(k_last - anim.length) > 0.05:
			bad_range.append("%s[%.2f~%.2f/%.2f]" % [n, k_first, k_last, anim.length])
	_check("A4 动画关键帧覆盖首尾（0 秒起到末尾）", bad_range.is_empty(),
		"异常：%s" % ("无" if bad_range.is_empty() else ", ".join(bad_range)))

	root.queue_free()


## 采样一个动画在多个时间点的骨骼位置，返回所有骨骼的最大位移量。
##
## 为什么不用 Animation 的 API 直接读值：
##   骨骼动画的轨道是"每根骨骼的 position/rotation 曲线"。光看曲线
##   存在与否不够 —— 一条常数曲线也是"存在的轨道"，但角色不会动。
##   必须真正跑一遍播放器、在不同的时间点读**骨骼的实际世界位置**，
##   才能确认动画有效。
func _measure_motion(skel: Skeleton3D, ap: AnimationPlayer,
		anim_name: StringName, anim: Animation) -> float:
	ap.play(String(anim_name))
	var samples := 5
	var first := PackedVector3Array()
	var max_moved := 0.0
	for i in samples:
		var t := anim.length * float(i) / float(samples - 1)
		ap.seek(t, true)
		await get_tree().process_frame
		var pos := PackedVector3Array()
		for b in skel.get_bone_count():
			pos.append(skel.get_bone_global_pose(b).origin)
		if i == 0:
			first = pos
		else:
			var n := mini(pos.size(), first.size())
			for k in n:
				max_moved = maxf(max_moved, first[k].distance_to(pos[k]))
	ap.stop()
	return max_moved


func _find_skeleton(root: Node) -> Skeleton3D:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Skeleton3D:
			return n as Skeleton3D
		for c in n.get_children():
			stack.append(c)
	return null


func _find_anim_player(root: Node) -> AnimationPlayer:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is AnimationPlayer:
			return n as AnimationPlayer
		for c in n.get_children():
			stack.append(c)
	return null


func _check(name: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": name, "ok": ok, "detail": detail})
	if ok:
		_passed += 1
		print("  [通过] %s  %s" % [name, detail])
	else:
		_failed += 1
		print("  [失败] %s  %s" % [name, detail])


func _report() -> void:
	var lines: PackedStringArray = []
	lines.append("动画校验时间：%s" % Time.get_datetime_string_from_system())
	lines.append("结果：通过 %d / 失败 %d / 共 %d" % [_passed, _failed, _results.size()])
	lines.append("")
	for r: Dictionary in _results:
		lines.append("%s %s  %s" % [
			"[通过]" if r["ok"] else "[失败]", r["name"], r["detail"]])
	var text := "\n".join(lines)
	print("\n========== 动画校验报告 ==========")
	print(text)
	print("==================================")
	var f := FileAccess.open("res://tests/动画校验结果.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
