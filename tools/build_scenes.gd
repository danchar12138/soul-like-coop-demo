extends Node
## 场景构建工具：用代码搭出所有 .tscn 场景。
##
## 为什么用代码搭场景而不是手写 .tscn：
##   .tscn 是文本格式但节点 ID / 资源引用 / 变换矩阵容易写错，
##   而且出错时报错信息很难定位。用 Godot 自己的 PackedScene 打包，
##   保证生成的文件一定合法，也能确保节点路径与脚本里的 NodePath 一致。
##
## 用法（项目根目录执行）：
##   godot --headless res://tools/builder.tscn
##
## 注意必须用「运行场景」而不是 --script：
##   构建过程中要 load 各种脚本，而这些脚本引用了 GameConfig /
##   EventBus / GameState 等 Autoload 单例。--script 模式下引擎不会
##   初始化 Autoload，编译器找不到这些全局标识符，会报
##   "Identifier not found: GameConfig"。以场景方式启动则一切正常。
##
## 场景清单：
##   scenes/player/player.tscn          主角（含相机支架、判定盒、受击盒）
##   scenes/enemy/training_dummy.tscn   训练木桩
##   scenes/enemy/boss_arena.tscn       Boss
##   scenes/terrain/pillar.tscn         可破坏石柱（5 块）
##   scenes/terrain/wall.tscn           可破坏墙体（6 块）
##   scenes/levels/arena.tscn           完整战斗关卡
##   scenes/levels/boot.tscn            启动场景（主菜单）

const OUT_PLAYER := "res://scenes/player/player.tscn"
const OUT_DUMMY := "res://scenes/enemy/training_dummy.tscn"
const OUT_BOSS := "res://scenes/enemy/boss_arena.tscn"
const OUT_PILLAR := "res://scenes/terrain/pillar.tscn"
const OUT_WALL := "res://scenes/terrain/wall.tscn"
const OUT_ARENA := "res://scenes/levels/arena.tscn"
const OUT_BOOT := "res://scenes/levels/boot.tscn"

## Blender 导出的 GLB 模型（由 tools/blender_assets.py 生成）。
##
## 【为什么场景里同时有 GLB 和几何体占位】
## 这个脚本按"GLB 存在就用 GLB，不存在就用几何体"的方式工作。
## 好处是：
##   - 没跑过 Blender 脚本的机器也能构建出可运行的项目（用占位体）
##   - 跑过之后重新构建，模型自动替换，不需要改任何代码
## 两者的碰撞体尺寸是分别定义的，替换后要跑 tests/test_models.tscn
## 校验比例，再跑 tests/test_runner.tscn 确认攻击范围没失效。
const GLB_PLAYER := "res://assets/models/player.glb"
## 带骨骼与动画的主角（由 tools/blender_rig.py 生成）。优先于静态版。
const GLB_PLAYER_RIGGED := "res://assets/models/player_rigged.glb"
const GLB_KATANA := "res://assets/models/katana.glb"
const GLB_BOSS := "res://assets/models/boss_greatsword.glb"
const GLB_PILLAR := "res://assets/models/pillar.glb"
const GLB_WALL := "res://assets/models/wall.glb"
const GLB_ARENA_PROPS := "res://assets/models/arena_props.glb"


## 加载一个 GLB 并实例化。文件不存在时返回 null（调用方回退到占位几何体）。
func _try_instance_glb(path: String) -> Node3D:
	if not ResourceLoader.exists(path):
		return null
	var packed := load(path) as PackedScene
	if packed == null:
		push_warning("GLB 无法加载为场景：%s（将使用几何体占位）" % path)
		return null
	var inst := packed.instantiate() as Node3D
	if inst == null:
		push_warning("GLB 根节点不是 Node3D：%s" % path)
		return null
	return inst


## 递归查找 AnimationPlayer。用于判断 GLB 是否带骨骼动画。
func _has_animation_player(root: Node) -> bool:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is AnimationPlayer and (n as AnimationPlayer).get_animation_list().size() > 0:
			return true
		for c in n.get_children():
			stack.append(c)
	return false


## 递归统计 GLB 的三角形数（写进构建日志，方便盯着面数预算）
func _glb_triangle_count(inst: Node) -> int:
	var total := 0
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			if mi.mesh != null:
				for si in mi.mesh.get_surface_count():
					var arr := mi.mesh.surface_get_arrays(si)
					if arr.is_empty():
						continue
					var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
					var vtx: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
					total += idx.size() / 3 if idx.size() > 0 else vtx.size() / 3
		for c in n.get_children():
			stack.append(c)
	return total


func _ready() -> void:
	_ensure_dirs()
	_build_player()
	_build_training_dummy()
	_build_boss()
	_build_pillar()
	_build_wall()
	_build_arena()
	_build_boot()
	print("\n所有场景构建完成。")
	get_tree().quit()


func _ensure_dirs() -> void:
	for d: String in [
		"res://scenes/player", "res://scenes/enemy", "res://scenes/terrain",
		"res://scenes/levels", "res://scenes/ui", "res://scenes/fx"
	]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(d))


# ============================================================
# 通用辅助
# ============================================================

func _pack(root: Node, path: String) -> void:
	# 关键：PackedScene.pack() 只打包 owner 指向根节点的子节点。
	# 在编辑器里拖节点会自动设 owner，但**代码 add_child 不会**。
	# 不补这一步，生成的 .tscn 里就只有根节点一个孤零零的空壳
	# （症状：运行时找不到 Hitbox / Health / AttackController 等子节点）。
	_set_owner_recursive(root, root)

	var ps := PackedScene.new()
	var err := ps.pack(root)
	if err != OK:
		push_error("打包失败 %s（错误码 %d）" % [path, err])
		root.free()
		return
	err = ResourceSaver.save(ps, path)
	if err != OK:
		push_error("保存场景失败 %s（错误码 %d）" % [path, err])
	else:
		print("  -> %s（%d 个节点）" % [path, _count_nodes(root)])
	root.free()


func _set_owner_recursive(node: Node, owner_root: Node) -> void:
	for c in node.get_children():
		c.owner = owner_root
		_set_owner_recursive(c, owner_root)


func _count_nodes(node: Node) -> int:
	var n := 1
	for c in node.get_children():
		n += _count_nodes(c)
	return n


## 建立一个标准材质
func _mat(color: Color, rough: float = 0.85, metal: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	return m


## 加一个盒状网格
func _box(parent: Node3D, name_: String, size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name_
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = _mat(color)
	parent.add_child(mi)
	return mi


func _capsule(parent: Node3D, name_: String, radius: float, height: float, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name_
	var cm := CapsuleMesh.new()
	cm.radius = radius
	cm.height = height
	cm.radial_segments = 8
	cm.rings = 3
	mi.mesh = cm
	mi.position = pos
	mi.material_override = _mat(color)
	parent.add_child(mi)
	return mi


func _cyl(parent: Node3D, name_: String, r_top: float, r_bot: float, h: float, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name_
	var cm := CylinderMesh.new()
	cm.top_radius = r_top
	cm.bottom_radius = r_bot
	cm.height = h
	cm.radial_segments = 8
	mi.mesh = cm
	mi.position = pos
	mi.material_override = _mat(color)
	parent.add_child(mi)
	return mi


func _set_script(node: Node, path: String) -> void:
	var s := load(path)
	if s == null:
		push_error("脚本不存在：%s" % path)
		return
	node.set_script(s)


# ============================================================
# 主角
# ============================================================

func _build_player() -> void:
	var root := CharacterBody3D.new()
	root.name = "Player"
	_set_script(root, "res://scripts/player/player_controller.gd")

	# 碰撞：胶囊，身高 1.8
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var cap := CapsuleShape3D.new()
	cap.radius = 0.36
	cap.height = 1.80
	col.shape = cap
	col.position = Vector3(0.0, 0.90, 0.0)
	root.add_child(col)

	# 碰撞层：第 2 层 = player_body
	root.collision_layer = 0
	root.set_collision_layer_value(2, true)
	# 与 world(1)、enemy_body(3)、destructible(6) 碰撞，不与攻击层碰撞
	root.collision_mask = 0
	root.set_collision_mask_value(1, true)
	root.set_collision_mask_value(3, true)
	root.set_collision_mask_value(6, true)
	root.floor_max_angle = deg_to_rad(46.0)

	# ---- 模型：优先用骨骼动画版 GLB，其次静态 GLB，最后几何体占位 ----
	#
	# 三档回退的用意：
	#   1. player_rigged.glb —— 有骨骼 + 14 个动画。战斗表现最好。
	#   2. player.glb        —— 静态网格，没有动画。外观还行，动作僵硬。
	#   3. 几何体占位         —— 连模型都没有，只能确保项目能跑起来。
	# 这样在没跑过 Blender 的机器上也能构建出可运行的项目。
	#
	# 「Model」这个节点名不能改：HitReactor 会递归找它下面的
	# MeshInstance3D 做受击闪白，Boss 脚本也会对它做补间。
	var model := Node3D.new()
	model.name = "Model"
	root.add_child(model)

	var rigged := _try_instance_glb(GLB_PLAYER_RIGGED)
	var has_anim := false
	if rigged != null:
		rigged.name = "PlayerMesh"
		model.add_child(rigged)
		has_anim = _has_animation_player(rigged)
		print("      主体：使用 player_rigged.glb（%d 三角面，骨骼动画 %s）" % [
			_glb_triangle_count(rigged), "有" if has_anim else "缺失"])
	else:
		var glb := _try_instance_glb(GLB_PLAYER)
		if glb != null:
			glb.name = "PlayerMesh"
			model.add_child(glb)
			print("      主体：使用 player.glb（%d 三角面，无动画）" % _glb_triangle_count(glb))
		else:
			_build_player_placeholder(model)
			print("      主体：使用几何体占位（未找到任何 GLB）")

	# 有独立太刀 GLB 时才补挂武器。
	# 骨骼版模型已经把刀作为蒙皮网格的一部分导出了，再挂一把会变成两把刀。
	if not has_anim:
		_build_weapon_from_glb(model)

	# ---- 相机支架（top_level，不继承角色旋转）----
	var rig := Node3D.new()
	rig.name = "CameraRig"
	_set_script(rig, "res://scripts/player/camera_rig.gd")
	rig.position = Vector3(0.0, 1.55, 0.0)
	root.add_child(rig)

	var pitch := Node3D.new()
	pitch.name = "PitchPivot"
	rig.add_child(pitch)

	var arm := SpringArm3D.new()
	arm.name = "SpringArm3D"
	arm.spring_length = 5.2
	# 只被 world(1) 和可破坏地形(6) 遮挡。
	# 注意：SpringArm3D 没有 set_collision_mask_value()，
	# 它是 ShapeCast3D 的子类，碰撞掩码只能整数值赋值。
	arm.collision_mask = (1 << 0) | (1 << 5)   # 层 1 + 层 6
	arm.margin = 0.25
	pitch.add_child(arm)

	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.fov = 75.0
	cam.near = 0.08
	cam.far = 300.0
	# 略微抬高并在肩后，属于常见的第三人称构图
	cam.position = Vector3(0.42, 0.26, 0.0)
	arm.add_child(cam)

	# ---- 攻击判定盒 ----
	# 玩家攻击：属于 player_attack(4)，只打 enemy_body(3) 与 destructible(6)
	var hitbox := Area3D.new()
	hitbox.name = "Hitbox"
	_set_script(hitbox, "res://scripts/combat/hitbox.gd")
	hitbox.set("attack_layer", L_PLAYER_ATTACK)
	hitbox.set("target_layers", (1 << (L_ENEMY_BODY - 1)) | (1 << (L_DESTRUCTIBLE - 1)))
	hitbox.position = Vector3(0.0, 1.15, -1.3)
	root.add_child(hitbox)
	var hshape := CollisionShape3D.new()
	hshape.name = "CollisionShape3D"
	var cs := CapsuleShape3D.new()
	cs.radius = 0.5
	cs.height = 1.9
	hshape.shape = cs
	hshape.rotation = Vector3(0.0, 0.0, PI * 0.5)
	hitbox.add_child(hshape)

	# ---- 受击盒 ----
	var hurtbox := Area3D.new()
	hurtbox.name = "Hurtbox"
	_set_script(hurtbox, "res://scripts/combat/damageable.gd")
	# 受击盒挂在 player_body(2) 层，供敌人攻击的 mask 命中
	hurtbox.collision_layer = 0
	hurtbox.set_collision_layer_value(L_PLAYER_BODY, true)
	hurtbox.collision_mask = 0
	hurtbox.monitoring = false
	hurtbox.monitorable = true
	hurtbox.position = Vector3(0.0, 0.95, 0.0)
	root.add_child(hurtbox)
	var hurt_shape := CollisionShape3D.new()
	var hc := CapsuleShape3D.new()
	hc.radius = 0.45
	hc.height = 1.85
	hurt_shape.shape = hc
	hurtbox.add_child(hurt_shape)

	# ---- 组件 ----
	_add_health(root, 120.0)
	_add_stamina(root, 100.0)
	_add_poise(root, 60.0)
	_add_hit_reactor(root)
	_add_state_machine(root)
	_add_attack_controller(root, true, "res://resources/weapons/katana.tres")

	# 骨骼动画驱动。只在模型确实带动画时才需要 —— 但挂上也无妨，
	# AnimationDriver 找不到 AnimationPlayer 时会自己停用并打印一行说明。
	if has_anim:
		var drv := Node.new()
		drv.name = "AnimationDriver"
		_set_script(drv, "res://scripts/combat/animation_driver.gd")
		root.add_child(drv)

	# ---- 网络同步 ----
	var sync := Node.new()
	sync.name = "PlayerSync"
	_set_script(sync, "res://scripts/net/player_sync.gd")
	root.add_child(sync)

	_pack(root, OUT_PLAYER)


## 玩家武器：优先 GLB 太刀，否则几何体占位。
##
## 挂点位置说明：
##   Blender 里 WeaponSocket 空物体放在 (0.26, 0.0, 0.94)，即角色
##   右前方的"手"位置。经 glTF 的坐标转换（Godot.x = B.x,
##   Godot.y = B.z, Godot.z = -B.y），在 Godot 里就是 (0.26, 0.94, 0.0)。
##
##   如果 GLB 里确实带出了 WeaponSocket 节点，就直接挂到它下面 ——
##   这样以后调整手部位置只需要改 Blender，Godot 侧不用动。
func _build_weapon_from_glb(model: Node3D) -> void:
	var socket := _find_node_named(model, "WeaponSocket")
	var weapon := Node3D.new()
	weapon.name = "WeaponModel"

	var katana := _try_instance_glb(GLB_KATANA)
	if katana != null:
		weapon.add_child(katana)
		print("      武器：使用 katana.glb（%d 三角面）" % _glb_triangle_count(katana))
	else:
		_build_katana_placeholder(weapon)
		print("      武器：使用几何体占位（katana.glb 不存在）")

	if socket != null:
		# 挂到 GLB 带出的手部挂点上。挂点本身没有旋转，
		# 这里再给一个自然的握持姿态。
		socket.add_child(weapon)
		weapon.rotation_degrees = Vector3(-28.0, 0.0, -8.0)
		weapon.position = Vector3.ZERO
	else:
		model.add_child(weapon)
		weapon.position = Vector3(0.26, 0.94, 0.0)
		weapon.rotation_degrees = Vector3(-28.0, 0.0, -8.0)


## 几何体占位的玩家模型（没有 GLB 时的回退方案）。
func _build_player_placeholder(model: Node3D) -> void:
	_capsule(model, "Torso", 0.26, 0.72, Vector3(0.0, 1.16, 0.0), Color(0.78, 0.80, 0.86))
	_box(model, "Head", Vector3(0.26, 0.28, 0.26), Vector3(0.0, 1.66, 0.0), Color(0.86, 0.82, 0.76))
	# 面罩放在 -Z 侧（Godot 的前向），与 GLB 版本的朝向一致
	_box(model, "Visor", Vector3(0.27, 0.06, 0.05), Vector3(0.0, 1.68, -0.13), Color(0.28, 0.28, 0.32))
	_box(model, "LegL", Vector3(0.16, 0.72, 0.18), Vector3(-0.14, 0.38, 0.0), Color(0.42, 0.44, 0.52))
	_box(model, "LegR", Vector3(0.16, 0.72, 0.18), Vector3(0.14, 0.38, 0.0), Color(0.42, 0.44, 0.52))
	_box(model, "ArmL", Vector3(0.13, 0.58, 0.14), Vector3(-0.34, 1.20, 0.0), Color(0.68, 0.70, 0.78))
	_box(model, "ArmR", Vector3(0.13, 0.58, 0.14), Vector3(0.34, 1.20, 0.0), Color(0.68, 0.70, 0.78))


## 几何体占位的太刀。
func _build_katana_placeholder(parent: Node3D) -> void:
	_box(parent, "Blade", Vector3(0.045, 0.9, 0.10), Vector3(0.0, 0.46, 0.0), Color(0.88, 0.90, 0.93))
	_box(parent, "Guard", Vector3(0.16, 0.035, 0.10), Vector3(0.0, 0.01, 0.0), Color(0.35, 0.30, 0.22))
	_box(parent, "Grip", Vector3(0.05, 0.26, 0.055), Vector3(0.0, -0.14, 0.0), Color(0.22, 0.20, 0.18))


func _find_node_named(root: Node, target: String) -> Node:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if String(n.name) == target:
			return n
		for c in n.get_children():
			stack.append(c)
	return null


func _add_health(parent: Node3D, max_hp: float) -> void:
	var h := Node.new()
	h.name = "Health"
	_set_script(h, "res://scripts/combat/health_component.gd")
	h.set("max_health", max_hp)
	h.set("health", max_hp)
	parent.add_child(h)


func _add_stamina(parent: Node3D, max_sp: float) -> void:
	var s := Node.new()
	s.name = "Stamina"
	_set_script(s, "res://scripts/combat/stamina_component.gd")
	s.set("max_stamina", max_sp)
	s.set("current", max_sp)
	parent.add_child(s)


func _add_poise(parent: Node3D, max_p: float) -> void:
	var p := Node.new()
	p.name = "Poise"
	_set_script(p, "res://scripts/combat/poise_component.gd")
	p.set("max_poise", max_p)
	p.set("current", max_p)
	parent.add_child(p)


func _add_hit_reactor(parent: Node3D) -> void:
	var r := Node3D.new()
	r.name = "HitReactor"
	_set_script(r, "res://scripts/combat/hit_reactor.gd")
	parent.add_child(r)


func _add_state_machine(parent: Node3D, initial: int = 0) -> void:
	var s := Node.new()
	s.name = "StateMachine"
	_set_script(s, "res://scripts/core/character_state_machine.gd")
	s.set("initial_state", initial)
	parent.add_child(s)


func _add_attack_controller(parent: Node3D, is_player: bool, weapon_path: String = "") -> void:
	var a := Node.new()
	a.name = "AttackController"
	_set_script(a, "res://scripts/combat/attack_controller.gd")
	a.set("is_player", is_player)
	parent.add_child(a)
	if not weapon_path.is_empty():
		var w = load(weapon_path)
		if w != null:
			parent.set("weapon_data", w)


## 敌人位置与数值的同步组件。
## 只在联机时会实际发消息；离线时它什么都不做（`is_authority()` 恒为真，
## 但由于 `NetManager.is_session_active()` 为假，`_physics_process` 会提前返回）。
func _add_enemy_sync(parent: Node3D) -> void:
	var s := Node.new()
	s.name = "EnemySync"
	_set_script(s, "res://scripts/net/enemy_sync.gd")
	parent.add_child(s)


# ============================================================
# 训练木桩
# ============================================================

func _build_training_dummy() -> void:
	var root := CharacterBody3D.new()
	root.name = "TrainingDummy"
	_set_script(root, "res://scripts/enemy/training_dummy.gd")

	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.42
	cap.height = 1.9
	col.shape = cap
	col.position = Vector3(0.0, 0.95, 0.0)
	root.add_child(col)

	root.collision_layer = 0
	root.set_collision_layer_value(3, true)   # enemy_body
	root.collision_mask = 0
	root.set_collision_mask_value(1, true)
	root.set_collision_mask_value(6, true)

	# 占位模型：稻草人
	var model := Node3D.new()
	model.name = "Model"
	root.add_child(model)
	_cyl(model, "Body", 0.32, 0.38, 1.30, Vector3(0.0, 0.85, 0.0), Color(0.72, 0.63, 0.42))
	_box(model, "Arms", Vector3(1.30, 0.14, 0.16), Vector3(0.0, 1.32, 0.0), Color(0.62, 0.54, 0.36))
	_box(model, "Head", Vector3(0.42, 0.42, 0.42), Vector3(0.0, 1.72, 0.0), Color(0.85, 0.78, 0.58))

	# 判定盒（敌人攻击：属于 enemy_attack(5)，只打 player_body(2) 与 destructible(6)）
	var hitbox := Area3D.new()
	hitbox.name = "Hitbox"
	_set_script(hitbox, "res://scripts/combat/hitbox.gd")
	hitbox.set("attack_layer", L_ENEMY_ATTACK)
	hitbox.set("target_layers", (1 << (L_PLAYER_BODY - 1)) | (1 << (L_DESTRUCTIBLE - 1)))
	hitbox.position = Vector3(0.0, 1.05, -1.25)
	root.add_child(hitbox)
	var hs := CollisionShape3D.new()
	var cs := CapsuleShape3D.new()
	cs.radius = 0.45
	cs.height = 1.7
	hs.shape = cs
	hs.rotation = Vector3(0.0, 0.0, PI * 0.5)
	hitbox.add_child(hs)

	# 受击盒（敌方阵营 -> 挂 enemy_body 层）
	_add_hurtbox(root, 0.46, 1.9, Vector3(0.0, 0.95, 0.0), L_ENEMY_BODY)

	_add_health(root, 80.0)
	_add_poise(root, 40.0)
	_add_hit_reactor(root)
	_add_state_machine(root)
	_add_attack_controller(root, false)
	_add_enemy_sync(root)

	_pack(root, OUT_DUMMY)


## 建立角色的受击盒。
##
## 【为什么受击盒只挂一个层，而不是玩家/敌人两个层都挂】
## 最初我把所有受击盒同时挂在 player_body(2) 和 enemy_body(3) 上，
## 图省事想让攻击判定用同一套 mask。结果出现一个很隐蔽的 bug：
## 敌人的攻击判定 mask 里含有 layer 2，而**另一个敌人的受击盒也在
## layer 2 上**，于是两个训练木桩会互相砍（测试 T5 里表现为
## "一次挥击扣了 30 血 = 自己 18 + 隔壁木桩打的 12"）。
##
## 正确做法是按阵营分层：
##   玩家受击盒 -> layer 2 (player_body)
##   敌人受击盒 -> layer 3 (enemy_body)
##   玩家攻击 mask -> layer 3 + layer 6(可破坏)
##   敌人攻击 mask -> layer 2 + layer 6
## 这样"谁能打谁"由碰撞层一地定义清楚，不需要在代码里写一堆 if。
## Boss 的几何体占位模型（没有 GLB 时的回退方案）。
## 轮廓要点：宽肩、短腿、粗臂、小头 —— 一眼可辨的"重甲巨人"。
func _build_boss_placeholder(model: Node3D) -> void:
	var armor := Color(0.38, 0.36, 0.42)
	var armor_dark := Color(0.26, 0.25, 0.30)
	var cloth := Color(0.46, 0.24, 0.22)

	_box(model, "Torso", Vector3(1.70, 1.30, 1.05), Vector3(0.0, 2.05, 0.0), armor)
	_box(model, "Chest", Vector3(1.30, 0.60, 1.15), Vector3(0.0, 2.55, 0.02), armor_dark)
	_box(model, "Skirt", Vector3(1.40, 0.80, 1.10), Vector3(0.0, 1.25, 0.0), cloth)
	_box(model, "LegL", Vector3(0.46, 1.05, 0.50), Vector3(-0.42, 0.55, 0.0), armor_dark)
	_box(model, "LegR", Vector3(0.46, 1.05, 0.50), Vector3(0.42, 0.55, 0.0), armor_dark)
	_box(model, "ShoulderL", Vector3(0.62, 0.52, 0.72), Vector3(-1.00, 2.72, 0.0), armor)
	_box(model, "ShoulderR", Vector3(0.62, 0.52, 0.72), Vector3(1.00, 2.72, 0.0), armor)
	_box(model, "ArmL", Vector3(0.38, 0.90, 0.40), Vector3(-1.02, 2.10, 0.0), armor_dark)
	_box(model, "ArmR", Vector3(0.38, 0.90, 0.40), Vector3(1.02, 2.10, 0.0), armor_dark)
	_box(model, "Neck", Vector3(0.34, 0.30, 0.34), Vector3(0.0, 2.86, 0.0), armor_dark)
	# 头：刻意做小，视觉上强调"身体庞大"
	_box(model, "Head", Vector3(0.46, 0.46, 0.50), Vector3(0.0, 3.14, 0.0), armor)
	# 面甲放在 -Z 侧，与 GLB 版本朝向一致
	_box(model, "Visor", Vector3(0.40, 0.07, 0.10), Vector3(0.0, 3.16, -0.24), Color(0.95, 0.45, 0.18))

	# 武器枢轴：巨剑挂在 `Model` 下、名为 WeaponPivot。
	# BossGreatsword 会去找 "Model/WeaponPivot"，以后做挥砍位移时用它。
	var pivot := Node3D.new()
	pivot.name = "WeaponPivot"
	pivot.position = Vector3(0.95, 2.15, 0.0)
	model.add_child(pivot)
	_box(pivot, "Blade", Vector3(0.16, 2.30, 0.30), Vector3(0.0, 1.15, 0.0), Color(0.62, 0.63, 0.68))
	_box(pivot, "BladeEdge", Vector3(0.06, 2.34, 0.09), Vector3(-0.10, 1.15, 0.0), Color(0.80, 0.82, 0.86))
	_box(pivot, "Crossguard", Vector3(0.52, 0.13, 0.24), Vector3(0.0, -0.02, 0.0), Color(0.30, 0.28, 0.26))
	_box(pivot, "Handle", Vector3(0.11, 0.50, 0.13), Vector3(0.0, -0.34, 0.0), Color(0.24, 0.21, 0.19))
	pivot.rotation_degrees = Vector3(-14.0, 0.0, 8.0)


func _add_hurtbox(parent: Node3D, radius: float, height: float, pos: Vector3, faction_layer: int) -> void:
	var hb := Area3D.new()
	hb.name = "Hurtbox"
	_set_script(hb, "res://scripts/combat/damageable.gd")
	hb.collision_layer = 0
	hb.set_collision_layer_value(faction_layer, true)
	hb.collision_mask = 0
	hb.monitoring = false
	hb.monitorable = true
	hb.position = pos
	parent.add_child(hb)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = radius
	cap.height = height
	cs.shape = cap
	hb.add_child(cs)


## 统一的碰撞层常量（与 project.godot 的 layer_names 一致）
const L_WORLD := 1
const L_PLAYER_BODY := 2
const L_ENEMY_BODY := 3
const L_PLAYER_ATTACK := 4
const L_ENEMY_ATTACK := 5
const L_DESTRUCTIBLE := 6




# ============================================================
# Boss
# ============================================================

func _build_boss() -> void:
	var root := CharacterBody3D.new()
	root.name = "BossGreatsword"
	_set_script(root, "res://scripts/enemy/boss_greatsword.gd")

	# 碰撞：比玩家大得多
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.95
	cap.height = 3.2
	col.shape = cap
	col.position = Vector3(0.0, 1.60, 0.0)
	root.add_child(col)

	root.collision_layer = 0
	root.set_collision_layer_value(3, true)
	root.collision_mask = 0
	root.set_collision_mask_value(1, true)
	root.set_collision_mask_value(6, true)
	root.floor_max_angle = deg_to_rad(50.0)

	# 模型：优先 GLB，否则几何体占位。
	# 「Model」节点名不能改：BossGreatsword._on_poise_break_visual() 会对它
	# 做"跪下"的旋转补间，HitReactor 也会递归找它下面的 MeshInstance3D。
	var model := Node3D.new()
	model.name = "Model"
	root.add_child(model)

	var glb := _try_instance_glb(GLB_BOSS)
	if glb != null:
		glb.name = "BossMesh"
		model.add_child(glb)
		print("      Boss 模型：使用 boss_greatsword.glb（%d 三角面）" % _glb_triangle_count(glb))
	else:
		_build_boss_placeholder(model)
		print("      Boss 模型：使用几何体占位（boss_greatsword.glb 不存在）")

	# 判定盒：Boss 攻击同样只打玩家身体与可破坏地形
	var hitbox := Area3D.new()
	hitbox.name = "Hitbox"
	_set_script(hitbox, "res://scripts/combat/hitbox.gd")
	hitbox.set("attack_layer", L_ENEMY_ATTACK)
	hitbox.set("target_layers", (1 << (L_PLAYER_BODY - 1)) | (1 << (L_DESTRUCTIBLE - 1)))
	hitbox.position = Vector3(0.0, 1.6, -2.3)
	root.add_child(hitbox)
	var hs := CollisionShape3D.new()
	var cs := CapsuleShape3D.new()
	cs.radius = 1.2
	cs.height = 3.6
	hs.shape = cs
	hs.rotation = Vector3(0.0, 0.0, PI * 0.5)
	hitbox.add_child(hs)

	# 受击盒：做得比模型小一点，让玩家必须靠近才能打中（避免"隔着剑柄也能打到"）
	_add_hurtbox(root, 1.05, 3.0, Vector3(0.0, 1.55, 0.0), L_ENEMY_BODY)

	_add_health(root, 1400.0)
	_add_poise(root, 160.0)
	_add_hit_reactor(root)
	_add_state_machine(root)
	_add_attack_controller(root, false)
	_add_enemy_sync(root)

	_pack(root, OUT_BOSS)


# ============================================================
# 可破坏地形：石柱
# ============================================================

## 一根石柱由 5 块叠成。玩家必须从下往上打（下段耐久低），
## 打完下面几块后上面的会结构失效整体崩塌。
## 这是"逐步损坏"的体现，而不是一刀消失。
func _build_pillar() -> void:
	var root := StaticBody3D.new()
	root.name = "Pillar"
	# 根节点本身不参与碰撞，所有碰撞在 Piece 上
	root.collision_layer = 0
	root.collision_mask = 0

	var radius := 0.62
	var piece_h := 0.86
	# 从下到上：底部最结实，越往上越脆
	var durability := [70.0, 65.0, 58.0, 48.0, 38.0]
	var colors := [
		Color(0.50, 0.50, 0.54), Color(0.52, 0.52, 0.56), Color(0.55, 0.55, 0.59),
		Color(0.57, 0.57, 0.61), Color(0.60, 0.60, 0.64),
	]

	# GLB 里的石柱是按段独立导出的（Piece0..Piece5），直接复用，
	# 让"逐段损坏"在视觉上也成立。文件不存在时回退到几何体。
	var pillar_mesh := _try_instance_glb(GLB_PILLAR)
	if pillar_mesh != null:
		pillar_mesh.name = "PillarMesh"
		print("      石柱：使用 pillar.glb（%d 三角面）" % _glb_triangle_count(pillar_mesh))
	else:
		print("      石柱：使用几何体占位（pillar.glb 不存在）")

	for i in 5:
		var piece := StaticBody3D.new()
		piece.name = "Piece%d" % i
		_set_script(piece, "res://scripts/terrain/destructible_piece.gd")
		piece.set("structure_id", "pillar")
		piece.set("piece_index", i)
		piece.set("max_durability", durability[i])
		piece.set("durability", durability[i])
		# 每块需要的攻击重量：下半截要中/重击，上半截轻击可破
		piece.set("required_weight", 1 if i >= 3 else 0)
		piece.set("debris_count", 5)
		piece.position = Vector3(0.0, piece_h * (i + 0.5), 0.0)

		if pillar_mesh != null:
			# 用 GLB 中对应的那一段。GLB 里每段是独立节点（Piece0..Piece5），
			# 这样"打掉第 2 段"时只有那一段的网格消失，其余保持完好。
			var seg := _find_node_named(pillar_mesh, "Piece%d" % i)
			if seg != null:
				# 把 GLB 段从模型树里摘出来，挂到本 Piece 节点下。
				# 摘之前必须先把 owner 清空 —— 否则 Godot 会警告
				# "Adding 'Mesh' as child to 'Piece0' will make owner
				#  'PillarMesh' inconsistent"，而且这个子节点在
				# PackedScene.pack() 时不会被正确序列化。
				seg.owner = null
				var parent_of_seg := seg.get_parent()
				if parent_of_seg != null:
					parent_of_seg.remove_child(seg)
				seg.name = "Mesh"
				if seg is Node3D:
					(seg as Node3D).position = Vector3.ZERO
				piece.add_child(seg)
			else:
				_build_pillar_segment_mesh(piece, i, radius, piece_h, colors[i])
		else:
			_build_pillar_segment_mesh(piece, i, radius, piece_h, colors[i])

		# 碰撞
		var cs := CollisionShape3D.new()
		cs.name = "CollisionShape3D"
		var cyl_shape := CylinderShape3D.new()
		cyl_shape.radius = radius
		cyl_shape.height = piece_h * 0.98
		cs.shape = cyl_shape
		piece.add_child(cs)

		root.add_child(piece)

	# 柱顶装饰：一块压顶石（不可破坏，用于视觉上"完整"）
	_cyl(root, "Capstone", 0.72, 0.80, 0.24,
		Vector3(0.0, piece_h * 5.0 + 0.10, 0.0), Color(0.44, 0.44, 0.48))

	_pack(root, OUT_PILLAR)


## 用几何体拼一段石柱（没有 GLB 时的回退方案）。
func _build_pillar_segment_mesh(piece: Node3D, i: int, radius: float,
		piece_h: float, color: Color) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	var cyl := CylinderMesh.new()
	# 略带锥度，让石柱看起来是天然岩石而不是完美圆柱
	cyl.top_radius = radius * (0.94 if i < 4 else 0.70)
	cyl.bottom_radius = radius * (1.06 if i > 0 else 1.18)
	cyl.height = piece_h * 0.98
	cyl.radial_segments = 8
	mi.mesh = cyl
	mi.material_override = _mat(color, 0.95)
	piece.add_child(mi)


# ============================================================
# 可破坏地形：墙体
# ============================================================

## 一堵墙：3x2 的方块阵列（6 块）。
## 打掉中间的可以形成"射击孔"式的通道；全部打掉则完全打通。
func _build_wall() -> void:
	var root := StaticBody3D.new()
	root.name = "Wall"
	root.collision_layer = 0
	root.collision_mask = 0

	var bw := 0.88
	var bh := 0.62
	var bd := 0.44

	# GLB 里的墙体是 6 块独立砖（Piece0..Piece5），逐块复用
	var wall_mesh := _try_instance_glb(GLB_WALL)
	if wall_mesh != null:
		wall_mesh.name = "WallMesh"
		print("      墙体：使用 wall.glb（%d 三角面）" % _glb_triangle_count(wall_mesh))
	else:
		print("      墙体：使用几何体占位（wall.glb 不存在）")

	for cx in 3:
		for cy in 2:
			var idx := cy * 3 + cx
			var piece := StaticBody3D.new()
			piece.name = "Piece%d" % idx
			_set_script(piece, "res://scripts/terrain/destructible_piece.gd")
			piece.set("structure_id", "wall")
			piece.set("piece_index", idx)
			var dur := 55.0 if cy == 0 else 42.0
			piece.set("max_durability", dur)
			piece.set("durability", dur)
			# 墙比石柱脆，但需要一定攻击强度
			piece.set("required_weight", 0)
			piece.set("debris_count", 4)
			piece.position = Vector3(
				(float(cx) - 1.0) * bw,
				bh * 0.5 + float(cy) * bh,
				0.0
			)

			var from_glb := false
			if wall_mesh != null:
				var brick := _find_node_named(wall_mesh, "Piece%d" % idx)
				if brick != null:
					var pos := (brick as Node3D).position if brick is Node3D else Vector3.ZERO
					# 同石柱：先清 owner 再摘出来，避免 pack() 丢节点
					brick.owner = null
					var brick_parent := brick.get_parent()
					if brick_parent != null:
						brick_parent.remove_child(brick)
					brick.name = "Mesh"
					if brick is Node3D:
						# 保留 GLB 里那块砖的局部位置，减去本 Piece 的位置，
						# 这样砖块在场景里的绝对位置不变
						(brick as Node3D).position = pos - piece.position
					piece.add_child(brick)
					from_glb = true

			if not from_glb:
				var mi := MeshInstance3D.new()
				mi.name = "Mesh"
				var bm := BoxMesh.new()
				bm.size = Vector3(bw * 0.96, bh * 0.96, bd)
				mi.mesh = bm
				# 灰砖色，每块略有差异
				var shade := 0.40 + float(idx) * 0.018
				mi.material_override = _mat(Color(shade, shade * 1.01, shade * 1.06), 0.93)
				piece.add_child(mi)

			var cs := CollisionShape3D.new()
			cs.name = "CollisionShape3D"
			var bs := BoxShape3D.new()
			bs.size = Vector3(bw * 0.96, bh * 0.96, bd)
			cs.shape = bs
			piece.add_child(cs)

			root.add_child(piece)

	_pack(root, OUT_WALL)


# ============================================================
# 关卡
# ============================================================

func _build_arena() -> void:
	var root := Node3D.new()
	root.name = "Arena"
	_set_script(root, "res://scripts/levels/level_manager.gd")
	root.set("player_scene", load(OUT_PLAYER))
	root.set("spawn_position", Vector3(0.0, 1.4, 9.0))
	root.set("spawn_points", [
		Vector3(-2.2, 1.4, 9.0),
		Vector3(2.2, 1.4, 9.0),
		Vector3(-3.6, 1.4, 10.2),
		Vector3(3.6, 1.4, 10.2),
	] as Array[Vector3])
	root.set("checkpoint_position", Vector3(0.0, 1.4, 9.0))
	root.set("checkpoint_yaw", 180.0)

	# ---- 环境 ----
	var env := WorldEnvironment.new()
	env.name = "WorldEnvironment"
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.24, 0.29, 0.40)
	sky_mat.sky_horizon_color = Color(0.48, 0.47, 0.46)
	sky_mat.ground_bottom_color = Color(0.13, 0.13, 0.15)
	sky_mat.ground_horizon_color = Color(0.30, 0.29, 0.28)
	sky_mat.sun_angle_max = 14.0
	sky.sky_material = sky_mat
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.85
	# 让远处有一点雾，营造"灰烬荒原"的氛围并遮盖远处边界
	e.fog_enabled = true
	e.fog_light_color = Color(0.42, 0.42, 0.45)
	e.fog_density = 0.006
	e.fog_sky_affect = 0.5
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	root.add_child(env)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-42.0, -128.0, 0.0)
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 70.0
	root.add_child(sun)

	# ---- 地面 ----
	# GLB 里带了整块战斗平台与边界石堆，优先使用；没有则用平面占位。
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	ground.collision_layer = 0
	ground.set_collision_layer_value(1, true)   # world
	ground.collision_mask = 0
	root.add_child(ground)

	var props := _try_instance_glb(GLB_ARENA_PROPS)
	if props != null:
		props.name = "ArenaProps"
		ground.add_child(props)
		print("      环境：使用 arena_props.glb（%d 三角面）" % _glb_triangle_count(props))
	else:
		var ground_mesh := MeshInstance3D.new()
		ground_mesh.name = "Mesh"
		var plane := PlaneMesh.new()
		plane.size = Vector2(90.0, 90.0)
		ground_mesh.mesh = plane
		ground_mesh.material_override = _mat(Color(0.30, 0.30, 0.32), 0.98)
		ground.add_child(ground_mesh)
		print("      环境：使用几何体占位（arena_props.glb 不存在）")

	var ground_col := CollisionShape3D.new()
	var wshape := WorldBoundaryShape3D.new()
	ground_col.shape = wshape
	ground.add_child(ground_col)

	# 地面上的低多边形"地砖"装饰（纯粹为了视觉参考与距离感）
	for i in 12:
		var angle := float(i) / 12.0 * TAU
		var r := 22.0
		var tile := MeshInstance3D.new()
		tile.name = "Tile%d" % i
		var bm := BoxMesh.new()
		var h := randf_range(1.2, 3.4)
		bm.size = Vector3(randf_range(1.4, 2.6), h, randf_range(1.4, 2.6))
		tile.mesh = bm
		tile.position = Vector3(cos(angle) * r, h * 0.5, sin(angle) * r)
		tile.rotation.y = randf_range(0.0, TAU)
		tile.material_override = _mat(Color(0.26, 0.26, 0.29), 0.96)
		root.add_child(tile)

	# ---- 边界墙（不可破坏，防止玩家走出战场）----
	_build_boundary(root)

	# ---- 可破坏地形 ----
	var terrain := Node3D.new()
	terrain.name = "Terrain"
	root.add_child(terrain)

	# 东侧石柱（打掉后打开侧翼路线）—— 关键玩法物件
	var pillar_scene := load(OUT_PILLAR)
	if pillar_scene != null:
		# pillar_a：战场左侧，挡住侧翼绕行路线
		var pa := (pillar_scene as PackedScene).instantiate()
		pa.name = "PillarEast"
		pa.position = Vector3(11.0, 0.0, 2.0)
		_set_structure_id(pa, "pillar_east")
		terrain.add_child(pa)

		# pillar_b：中央偏右，提供战斗遮挡
		var pb := (pillar_scene as PackedScene).instantiate()
		pb.name = "PillarCenter"
		pb.position = Vector3(-3.4, 0.0, -2.2)
		_set_structure_id(pb, "pillar_center")
		terrain.add_child(pb)

		# pillar_c：纯装饰性遮挡
		var pc := (pillar_scene as PackedScene).instantiate()
		pc.name = "PillarWest"
		pc.position = Vector3(4.6, 0.0, -6.4)
		_set_structure_id(pc, "pillar_west")
		terrain.add_child(pc)

	# 中央墙体（打掉后战场中央出现新通道）
	var wall_scene := load(OUT_WALL)
	if wall_scene != null:
		var w1 := (wall_scene as PackedScene).instantiate()
		w1.name = "CenterWall"
		w1.position = Vector3(0.0, 0.0, 1.8)
		_set_structure_id(w1, "wall_center")
		terrain.add_child(w1)

		var w2 := (wall_scene as PackedScene).instantiate()
		w2.name = "SideWall"
		w2.position = Vector3(-8.4, 0.0, -1.0)
		w2.rotation_degrees = Vector3(0.0, 90.0, 0.0)
		_set_structure_id(w2, "wall_side")
		terrain.add_child(w2)

	# ---- 通路阻挡物（击碎石柱后会消失，让出新路线）----
	var gates := Node3D.new()
	gates.name = "Gates"
	root.add_child(gates)

	var blocker := StaticBody3D.new()
	blocker.name = "EastFlankBlocker"
	blocker.collision_layer = 0
	blocker.set_collision_layer_value(1, true)
	blocker.position = Vector3(13.6, 1.5, 2.0)
	gates.add_child(blocker)
	_box(blocker, "Mesh", Vector3(0.5, 3.0, 7.0), Vector3.ZERO, Color(0.22, 0.21, 0.24))
	var blocker_col := CollisionShape3D.new()
	var bshape := BoxShape3D.new()
	bshape.size = Vector3(0.5, 3.0, 7.0)
	blocker_col.shape = bshape
	blocker.add_child(blocker_col)

	# ---- Boss ----
	var boss_scene := load(OUT_BOSS)
	if boss_scene != null:
		var boss := (boss_scene as PackedScene).instantiate()
		boss.name = "BossGreatsword"
		boss.position = Vector3(0.0, 0.2, -14.0)
		root.add_child(boss)

	# ---- 训练木桩（调试用，放在起点旁边）----
	var dummy_scene := load(OUT_DUMMY)
	if dummy_scene != null:
		for i in 2:
			var d := (dummy_scene as PackedScene).instantiate()
			d.name = "TrainingDummy%d" % (i + 1)
			d.position = Vector3(-6.0 + float(i) * 3.0, 0.2, 5.0)
			root.add_child(d)

	# ---- 检查点标记 ----
	var cp := Node3D.new()
	cp.name = "Checkpoint"
	cp.position = Vector3(0.0, 0.0, 9.0)
	root.add_child(cp)
	_cyl(cp, "Beacon", 0.30, 0.42, 0.22, Vector3(0.0, 0.11, 0.0), Color(0.85, 0.60, 0.22))
	# 检查点的光柱
	var beacon := MeshInstance3D.new()
	beacon.name = "Glow"
	var cylm := CylinderMesh.new()
	cylm.top_radius = 0.20
	cylm.bottom_radius = 0.24
	cylm.height = 4.0
	cylm.radial_segments = 8
	beacon.mesh = cylm
	beacon.position = Vector3(0.0, 2.1, 0.0)
	var glow_mat := StandardMaterial3D.new()
	glow_mat.albedo_color = Color(1.0, 0.75, 0.35, 0.22)
	glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glow_mat.emission_enabled = true
	glow_mat.emission = Color(1.0, 0.66, 0.24)
	glow_mat.emission_energy_multiplier = 1.6
	glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beacon.material_override = glow_mat
	cp.add_child(beacon)

	var light := OmniLight3D.new()
	light.name = "Light"
	light.position = Vector3(0.0, 1.6, 0.0)
	light.light_color = Color(1.0, 0.74, 0.38)
	light.light_energy = 2.2
	light.omni_range = 9.0
	cp.add_child(light)

	_pack(root, OUT_ARENA)


## 把石柱/墙体下所有 Piece 的 structure_id 改成关卡要用的 ID
func _set_structure_id(structure: Node, id: String) -> void:
	for c in structure.get_children():
		if c.get_script() != null and "destructible_piece" in str(c.get_script().resource_path):
			c.set("structure_id", id)


func _build_boundary(root: Node3D) -> void:
	var walls := [
		Vector3(0.0, 4.0, -30.0), Vector3(0.0, 4.0, 30.0),
		Vector3(-30.0, 4.0, 0.0), Vector3(30.0, 4.0, 0.0),
	]
	var sizes := [Vector3(60.0, 8.0, 1.0), Vector3(60.0, 8.0, 1.0),
		Vector3(1.0, 8.0, 60.0), Vector3(1.0, 8.0, 60.0)]
	# 留出侧翼通道的那一面用较矮的墙，让飞出去的碎片能看见
	for i in walls.size():
		var w := StaticBody3D.new()
		w.name = "Boundary%d" % i
		w.collision_layer = 0
		w.set_collision_layer_value(1, true)
		w.collision_mask = 0
		w.position = walls[i]
		root.add_child(w)
		_box(w, "Mesh", sizes[i], Vector3.ZERO, Color(0.20, 0.20, 0.23))
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = sizes[i]
		cs.shape = bs
		w.add_child(cs)


# ============================================================
# 启动场景
# ============================================================

func _build_boot() -> void:
	var root := Node.new()
	root.name = "Boot"

	var menu := CanvasLayer.new()
	menu.name = "MainMenu"
	_set_script(menu, "res://scripts/ui/main_menu.gd")
	root.add_child(menu)

	_pack(root, OUT_BOOT)
