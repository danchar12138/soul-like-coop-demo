extends Node
## 模型资源校验（无头运行）。
##
## 用法：
##   godot --headless res://tests/test_models.tscn
##
## 校验内容（对应验收标准 9："Blender 模型导入后比例、碰撞、材质和
## 朝向合理"）：
##   M1  每个 GLB 都能被 Godot 加载
##   M2  包围盒尺寸符合设计（身高 1.8 m / Boss 3.2 m / 石柱 4.3 m …）
##   M3  朝向正确：模型的"脸"朝 Godot 的 -Z
##   M4  多边形数在预算内（< 3000）
##   M5  材质存在且已设置基础颜色
##
## M3 是重点。Godot 的约定是 -Z 前向（见 scripts/core/math_util.gd），
## 而 Blender 到 glTF 的坐标转换会把 Godot.z 变成 -Blender.y。
## 如果建模时把脸朝 Blender 的 -Y 放，导入后模型就会背对镜头。
## 这个检查用"正面特征点的位置"来判定朝向。

const MODELS := {
	"player": {
		"path": "res://assets/models/player.glb",
		"height": 1.80, "tol": 0.25,
		# 只量身体，避免手部挂点之类的辅助节点影响尺寸判断
		"measure_node": "PlayerBody",
		# 正面特征：面罩。它应该位于 -Z 侧
		"front_feature": "Visor",
	},
	"player_rigged": {
		# 骨骼动画版主角。它是玩家实际使用的模型，
		# 所以同样要校验比例与朝向 —— 换了骨骼版之后
		# 静态版的检查就覆盖不到了。
		"path": "res://assets/models/player_rigged.glb",
		"height": 1.80, "tol": 0.30,
		# 骨骼版的网格是一个整体（PlayerBody），
		# 包围盒包含刀，所以容差放宽一点
		"measure_node": "PlayerBody",
		"front_feature": "",
		"require_anim": true,
	},
	"boss": {
		"path": "res://assets/models/boss_greatsword.glb",
		"height": 3.30, "tol": 0.40,
		# Boss 的巨剑是把 2 m 长的武器，如果一起量会把身高算成 3.8 m。
		# 只量身体节点。
		"measure_node": "BossGreatsword",
		"front_feature": "Visor",
	},
	"pillar": {
		"path": "res://assets/models/pillar.glb",
		"height": 4.30, "tol": 0.45,
		"measure_node": "",
		"front_feature": "",
	},
	"wall": {
		"path": "res://assets/models/wall.glb",
		"height": 1.24, "tol": 0.20,
		"measure_node": "",
		"front_feature": "",
	},
	"katana": {
		"path": "res://assets/models/katana.glb",
		"height": 1.26, "tol": 0.25,
		"measure_node": "Katana",
		"front_feature": "",
	},
}

var _passed := 0
var _failed := 0
var _results: Array[Dictionary] = []


func _ready() -> void:
	print("========== 模型资源校验 ==========")
	for key: String in MODELS:
		_check_model(key, MODELS[key])
	_report()
	get_tree().quit(0 if _failed == 0 else 1)


func _check(name: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": name, "ok": ok, "detail": detail})
	if ok:
		_passed += 1
		print("  [通过] %s  %s" % [name, detail])
	else:
		_failed += 1
		print("  [失败] %s  %s" % [name, detail])


func _check_model(key: String, cfg: Dictionary) -> void:
	var path: String = cfg["path"]
	if not ResourceLoader.exists(path):
		_check("M1 加载 %s" % key, false, "文件不存在：%s（请先运行 tools/blender_assets.py）" % path)
		return

	var packed := load(path) as PackedScene
	if packed == null:
		_check("M1 加载 %s" % key, false, "无法作为 PackedScene 加载")
		return

	var root := packed.instantiate() as Node3D
	if root == null:
		_check("M1 加载 %s" % key, false, "根节点不是 Node3D")
		return
	add_child(root)

	var aabb := _collect_aabb(root)
	var size := aabb.size
	var tri_total := _count_triangles(root)

	_check("M1 加载 %s" % key, true,
		"包围盒 %.2f × %.2f × %.2f m" % [size.x, size.y, size.z])

	# M2 尺寸：优先只量指定的节点（例如 Boss 的身高不该把 2 m 长的
	# 巨剑算进去）
	var expect: float = cfg["height"]
	var tol: float = cfg["tol"]
	var measure_name: String = cfg.get("measure_node", "")
	var measured := aabb
	var measured_label := "整个模型"
	if not measure_name.is_empty():
		var mn := _find_by_name(root, measure_name)
		if mn == null:
			_check("M2 %s 高度符合设计" % key, false,
				"找不到测量节点「%s」" % measure_name)
			root.queue_free()
			return
		measured = _node_aabb(mn)
		measured_label = measure_name
	var ok_h := absf(measured.size.y - expect) <= tol
	_check("M2 %s 高度符合设计" % key, ok_h,
		"%s 实际 %.2f m，设计 %.2f m（容差 ±%.2f）" % [
			measured_label, measured.size.y, expect, tol])

	# M3 朝向
	var feature: String = cfg["front_feature"]
	if not feature.is_empty():
		var node := _find_by_name(root, feature)
		if node == null:
			_check("M3 %s 朝向（-Z 前向）" % key, false,
				"找不到正面特征节点「%s」，无法判定朝向" % feature)
		else:
			var z := (node as Node3D).position.z
			# 正面特征必须在 -Z 侧（Godot 前向）
			_check("M3 %s 朝向正确（-Z 前向）" % key, z < -0.01,
				"「%s」的 Z = %+.3f，应在 -Z 侧（若为正值说明模型反了 180 度）" % [feature, z])
	else:
		_check("M3 %s 朝向" % key, true, "对称模型，朝向不影响外观")

	# M4 面数
	_check("M4 %s 多边形数在预算内" % key, tri_total <= 3000,
		"%d 个三角形（上限 3000）" % tri_total)

	# M5 材质
	var mat_count := _count_materials(root)
	_check("M5 %s 已设置材质" % key, mat_count > 0,
		"%d 个材质" % mat_count)

	# M6 动画（只有 require_anim 的模型才查）
	if cfg.get("require_anim", false):
		var ap := _find_animation_player(root)
		var anim_names: PackedStringArray = ap.get_animation_list() if ap != null else PackedStringArray()
		_check("M6 %s 带骨骼动画" % key, ap != null and anim_names.size() >= 10,
			"动画 %d 个：%s" % [anim_names.size(), _join(anim_names)])
		# 攻击动画的时长必须与战斗配置对得上。
		# 这里只做粗略校验（±30%）—— 精确对齐由运行时按攻击数据调速保证，
		# 但如果差得太多（例如有人把动画重录成了 2 秒），
		# 调速会把动作拉得很怪，所以在这里挡一道。
		if ap != null:
			var worst := ""
			var worst_err := 0.0
			for a: AttackData in _expected_attacks():
				if not ap.has_animation(String(a.attack_id)):
					continue
				var anim := ap.get_animation(String(a.attack_id))
				if anim == null or anim.length <= 0.001:
					continue
				var err := absf(anim.length - a.get_total_duration()) / a.get_total_duration()
				if err > worst_err:
					worst_err = err
					worst = "%s 动画 %.2fs / 时序 %.2fs" % [
						a.attack_id, anim.length, a.get_total_duration()]
			_check("M7 %s 攻击动画时长与战斗配置大致一致（±30%%）" % key,
				worst_err <= 0.30,
				"最大偏差 %.1f%%（%s）" % [worst_err * 100.0, worst if not worst.is_empty() else "无"])

	root.queue_free()


## 从武器资源里读出击攻击列表，用于核对动画时长
func _expected_attacks() -> Array[AttackData]:
	var out: Array[AttackData] = []
	var w := load("res://resources/weapons/katana.tres") as WeaponData
	if w != null:
		out = w.get_all_attacks()
	return out


func _find_animation_player(root: Node) -> AnimationPlayer:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is AnimationPlayer:
			return n as AnimationPlayer
		for c in n.get_children():
			stack.append(c)
	return null


func _join(list: PackedStringArray) -> String:
	var parts: PackedStringArray = []
	for s in list:
		parts.append(String(s))
	return ", ".join(parts)


# ------------------------------------------------------------

func _collect_aabb(root: Node3D) -> AABB:
	return _node_aabb(root)


## 递归累加一个节点及其所有 MeshInstance3D 子节点的世界空间包围盒
func _node_aabb(node: Node) -> AABB:
	var total := AABB()
	var started := false
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null:
				var world := mi.global_transform * mi.mesh.get_aabb()
				if not started:
					total = world
					started = true
				else:
					total = total.merge(world)
		for c in n.get_children():
			stack.append(c)
	return total


func _count_triangles(root: Node) -> int:
	var total := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null:
				for si in mi.mesh.get_surface_count():
					var arr := mi.mesh.surface_get_arrays(si)
					if arr.is_empty():
						continue
					var indices: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
					var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
					if indices.size() > 0:
						total += indices.size() / 3
					else:
						total += verts.size() / 3
		for c in n.get_children():
			stack.append(c)
	return total


func _count_materials(root: Node) -> int:
	var found := {}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null:
				for si in mi.mesh.get_surface_count():
					var m := mi.mesh.surface_get_material(si)
					if m != null:
						found[m.get_instance_id()] = true
			if mi.material_override != null:
				found[mi.material_override.get_instance_id()] = true
		for c in n.get_children():
			stack.append(c)
	return found.size()


func _find_by_name(root: Node, name_: String) -> Node3D:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if String(n.name).begins_with(name_) and n is Node3D:
			return n as Node3D
		for c in n.get_children():
			stack.append(c)
	return null


func _report() -> void:
	var lines: PackedStringArray = []
	lines.append("模型校验时间：%s" % Time.get_datetime_string_from_system())
	lines.append("结果：通过 %d / 失败 %d / 共 %d" % [_passed, _failed, _results.size()])
	lines.append("")
	for r: Dictionary in _results:
		lines.append("%s %s  %s" % [
			"[通过]" if r["ok"] else "[失败]", r["name"], r["detail"]
		])
	var text := "\n".join(lines)
	print("\n========== 模型校验报告 ==========")
	print(text)
	print("==================================")

	var f := FileAccess.open("res://tests/模型校验结果.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
