extends Node
## 性能测试（无头运行）。对应已知问题 K-09「未做性能测试，不知道碎片满屏时的帧率」。
##
## 用法（项目根目录）：
##   godot --headless res://tests/perf_test.tscn
## 或一键：
##   bash tests/run_perf_test.sh
##
## ============================================================
## 【关于测量方法：必须先说清的诚实前提】
## ============================================================
## 本测试跑在 `--headless` 下，Godot 用的是 **dummy 渲染器**：
##   - `Performance.RENDER_TOTAL_OBJECTS_IN_FRAME` 恒为 0
##   - `Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME` 恒为 0
##   - `Performance.TIME_FPS` 读数是"空转主循环速率"（本机实测 ~144），
##     它反映的是 **CPU 空转能跑多快**，与玩家看到的画面无关
##
## 所以本测试**只**测量下面这些在无头下依然真实的东西，并把它们分开报告：
##   1. 逻辑帧时间（idle `_process` 的墙钟间隔）—— 不含任何渲染工作，
##      即"CPU 主循环每帧要花多久"。它的倒数就是**逻辑帧率上限**，
##      而不是玩家看到的 FPS。
##   2. 物理帧间隔（`_physics_process` 的墙钟间隔）—— 正常应恒为
##      1/60 s ≈ 16.67ms。一旦它明显超过 16.67ms，说明**物理步进
##      超过了 60Hz 的预算**，在真实游戏里就会掉物理帧 / 表现抖动。
##   3. `Performance.TIME_PHYSICS_PROCESS` —— 引擎自我报告的物理耗时。
##      实测该值偏高且抖动大（子步进/插值未计入同一统计口径），
##      因此**不作为主指标**，只作为"物理压力随碎片增长而上升"的旁证。
##   4. 活跃物理对象数 / 碰撞对数 / 节点总数 / 静态内存 —— 用于解释
##      瓶颈来源。
##
## **绝对不要**把这里的数字当成"玩家实际看到的帧率"。
## 真实帧率必须在有显示器的环境下测，步骤见 docs/性能报告.md。

const ARENA := "res://scenes/levels/arena.tscn"
const PLAYER_SCENE := "res://scenes/player/player.tscn"
const RESULT_PATH := "res://tests/性能结果.txt"

## 每个场景采样的物理帧数。要求 >= 120，这里取 180（3 秒）留足裕量。
const SAMPLE_FRAMES := 180
## 「连续破坏」每一步的采样帧数（5 步 × 120 帧 = 600 帧 ≈ 10 秒）
const DESTRUCTION_FRAMES := 120

# ------ 采样缓冲 ------
var _idle_iv: Array[float] = []      # 逻辑帧间隔 (ms)，全部主循环迭代
## 【为什么要按"本帧有没有跑物理步进"再分一次】
## Godot 默认把物理跑在**主线程**上（physics/3d/run_on_separate_thread=false）。
## 因此主循环的一次迭代要么"只跑脚本"（轻），要么"顺便推进一次物理步进"（重）。
## 如果混在一起统计，平均逻辑帧时间会被两拨样本拉成没有意义的中间值，
## 而且看起来像是"随机抖动"。分开统计才能回答真正的问题：
##   —— 光跑脚本要多久？（这是游戏逻辑的下限）
##   —— 带上物理步进的那一帧要多久？（这才是帧时间的大头）
var _idle_phys_iv: Array[float] = []    # 含物理步进的主循环迭代间隔
var _idle_nophys_iv: Array[float] = []  # 不含物理步进的主循环迭代间隔
var _phys_iv: Array[float] = []      # 物理帧间隔 (ms)
var _phys_mon: Array[float] = []     # Performance.TIME_PHYSICS_PROCESS (ms)
var _proc_mon: Array[float] = []     # Performance.TIME_PROCESS (ms)
var _collecting: bool = false
var _prev_idle_us: int = 0
var _prev_phys_us: int = 0
var _prev_phys_frames: int = 0

# ------ 负载驱动 ------
## 哪些玩家要在采样期间被"逼"着出招（模拟真实操作压力）
var _drive_players: Array[Node3D] = []
## 是否周期性重新抛掷碎片（否则碎片落地后 sleep，物理压力归零）
var _drive_debris: bool = false
var _frame_counter: int = 0

# ------ 场景环境 ------
var _level: Node3D
var _player: Node3D
var _extra_players: Array[Node3D] = []
var _total_destructibles: int = 0
var _debris_container: Node3D

var _rows: Array[Dictionary] = []
var _notes: Array[String] = []


func _ready() -> void:
	print("========== 性能测试（无头） ==========")
	print("[环境] headless=%s  Godot=%s  平台=%s" % [
		DisplayServer.get_name(), Engine.get_version_info()["string"], OS.get_name()])
	print("[环境] CPU=%s  逻辑核心=%d  physics_ticks=%d  max_fps=%d（0 = 不限速）" % [
		OS.get_processor_name(), OS.get_processor_count(),
		Engine.physics_ticks_per_second, Engine.max_fps])
	print("[说明] 无头渲染器不渲染画面，本测试测的是 CPU 逻辑与物理，不是玩家看到的 FPS。")

	await _setup_world()
	await _run_all()
	_report()
	get_tree().quit(0 if _rows.size() > 0 else 1)


# ============================================================
# 场景准备
# ============================================================

func _setup_world() -> void:
	var packed := load(ARENA) as PackedScene
	if packed == null:
		push_error("无法加载 %s" % ARENA)
		get_tree().quit(1)
		return
	_level = packed.instantiate() as Node3D
	add_child(_level)
	# 等关卡把玩家、地形、Boss 都建好
	for i in 30:
		await get_tree().physics_frame
	await _wait(0.5)
	_player = GameState.local_player
	if _player == null:
		push_error("关卡没有生成本地玩家")
		get_tree().quit(1)
		return
	# 先关掉所有敌人的 AI —— 基线场景必须是"干净"的。
	# 关掉时会留下强制关闭记号，后续 _set_ai(true) 会清掉它。
	_set_ai(false)
	await _wait(1.4)
	_set_ai(false)
	# 【为什么要先空跑 2 秒再让基线读数生效】
	# 关卡加载后的头一两秒仍有残留的一次性开销（地形注册、材质复制、
	# 敌人延迟自启的定时器、首帧的物理体创建）。基线必须测"稳态"，
	# 否则会把加载开销误记成"每帧成本"。
	await _step(120)
	# DebrisPool 把容器建在 current_scene（也就是本测试节点）下，
	# 但只有第一次生成碎片时才建，所以这里只记录总数，容器延迟查找。
	_total_destructibles = _destructibles_left()
	if _total_destructibles == 0:
		push_error("场景里没有可破坏件，K-09 的破坏场景无法测量")
	_notes.append("本机 CPU：%s（%d 逻辑核心）" % [OS.get_processor_name(), OS.get_processor_count()])
	_notes.append("场上初始可破坏结构件：%d 块" % _total_destructibles)
	_notes.append("physics/3d/run_on_separate_thread = %s（false 表示物理跑在主线程，会直接吃主循环帧时间）" % str(
		ProjectSettings.get_setting("physics/3d/run_on_separate_thread", false)))
	_notes.append("MAX_DEBRIS_RIGIDBODIES = %d（首次生成碎片时池会按最大值预分配）" % GameConfig.MAX_DEBRIS_RIGIDBODIES)
	_notes.append("无头渲染器：RENDER_TOTAL_OBJECTS_IN_FRAME / DRAW_CALLS 恒为 0，故不测渲染耗时")
	# 每个场景测完主动回收一次，让内存读数尽量干净（否则 8 个场景的残留会累计）
	_notes.append("各场景之间主动调用 DebrisPool.clear_all() 回收碎片，避免残留污染下一个场景")
	_notes.append("碎片堆到 200 个以上时（远超 MAX_DEBRIS_RIGIDBODIES=60）物体会开始互相嵌叠，"
		+ "物理耗时出现 runaway 式膨胀；因此本测试不报告超上限的读数，"
		+ "该边界数据见 docs/性能报告.md 的「上限探针（参考）」一节")


func _run_all() -> void:
	await _scenario_baseline()
	await _scenario_debris_full()      # 结束时会自己清空碎片
	await _scenario_boss_fight()       # 结束时会自己清空碎片
	await _scenario_worst_case()
	await _scenario_continuous_destruction()


# ============================================================
# 场景 1：空场景基线
# ============================================================

func _scenario_baseline() -> void:
	_set_ai(false)
	_drive_players.clear()
	_drive_debris = false
	_move_player_away()
	await _wait(0.4)
	await _sample("1. 空场景基线", "只有玩家和地形，无碎片、全部 AI 关闭", SAMPLE_FRAMES)


# ============================================================
# 场景 2：碎片满负荷（60 个刚体全部激活并持续运动）
# ============================================================

func _scenario_debris_full() -> void:
	_set_ai(false)
	_drive_players.clear()
	# 分 12 批抛满 60 个，池上限 MAX_DEBRIS_RIGIDBODIES = 60
	for i in 12:
		DebrisPool.spawn_at(Vector3(0.0, 3.5, 4.0), 6, Color(0.6, 0.6, 0.62), 0.32)
	await _step(3)
	# 【为什么要在采样期间反复 re-launch】
	# 碎片落地后会进入 sleep，物理开销跌到接近 0。而"碎片满屏"要测的是
	# 60 个刚体**同时运动**的最坏时刻，所以每 20 帧重新抛一次。
	_drive_debris = true
	# 【为什么采样缓冲要多花约 1 秒】
	# re-launch 本身会调 launch() -> _build_visuals()/material 赋值，
	# 这属于"碎片生成"的一次性开销，不该混进稳态读数。先空跑 1 秒
	# 让所有缓冲与物理体都稳定，再开始采样。
	await _step(60)
	await _sample("2. 碎片满负荷", "60 个碎片刚体持续运动（每 20 帧重新抛掷）", SAMPLE_FRAMES)
	_drive_debris = false
	await _scenario_debris_settled()


# ============================================================
# 场景 2b：碎片静止（对照组）
# ============================================================
# 【为什么要这个对照组】
# 场景 2 测的是"最坏时刻"：60 个刚体全在飞。但真实游戏里碎片几秒内
# 就会落地，`DebrisPiece` 的 can_sleep 会让它们停止模拟。如果只看场景 2，
# 很容易得出"60 个碎片一直在烧 CPU"的错误结论。
# 这一组测的是碎片落地进入 sleep 之后的稳态开销，用来对照。

func _scenario_debris_settled() -> void:
	_drive_debris = false
	# 重新抛满（顺手把寿命刷新，免得采样期间碎片到期消失）
	for i in 12:
		DebrisPool.spawn_at(Vector3(0.0, 3.5, 4.0), 6, Color(0.6, 0.6, 0.62), 0.32)
	# 等它们落地并进入 sleep。DEBRIS_LIFETIME = 6s，所以下面采样 120 帧
	# （2 秒）+ 这 1.5 秒合计 3.5 秒，不会撞上到期回收。
	await _step(90)
	await _sample("2b. 碎片静止（对照）",
		"60 个碎片已落地并进入 sleep，不再重新抛掷", 120)
	# 场景 2 全部结束，清空碎片（否则它们会在场景 3 采样中途陆续到期）
	DebrisPool.clear_all()
	await _step(2)


# ============================================================
# 场景 3：完整 Boss 战
# ============================================================

func _scenario_boss_fight() -> void:
	# 把玩家放到 Boss 面前的近战距离，Boss AI 才会锁定并进攻
	var boss := GameState.boss as Node3D
	if boss == null:
		_notes.append("场景 3 跳过：GameState.boss 为空")
		return
	_move_player_away()  # 先清掉场景 1/2 可能残留的状态
	# 【为什么这里要显式清空碎片】
	# 场景 2/2b 留下的碎片寿命是 6 秒，如果不清，它们会在本场景采样
	# 中途陆续到期消失 —— 同一个采样窗口里的负载前后不一致，读数就没意义。
	# 清掉之后场景 3 才是干净的"纯 Boss 战"。
	DebrisPool.clear_all()
	await _step(2)
	_player.global_position = boss.global_position + Vector3(0.0, 0.0, 4.0)
	_player.global_rotation.y = PI
	await _step(4)
	_set_ai(true)
	_drive_players.clear()
	_drive_players.append(_player)
	await _sample("3. 完整 Boss 战",
		"Boss AI + 攻击 + 预警圆 + 玩家持续出招（Boss 血量 %.0f）" % _boss_health(),
		SAMPLE_FRAMES)
	# 【为什么场景 3 结束后要立刻停 AI 并清目标】
	# Boss 的 _update_target 会遍历 GameState.players 并跳过无效实例，
	# 但它选中的 target 引用可能指向后续被 queue_free 的节点。把 AI 关掉
	# 并把玩家挪远，可以让场景 4 的负载干净地从 0 开始，也避免残留目标。
	_set_ai(false)
	_move_player_away()
	await _step(4)


# ============================================================
# 场景 4：最坏情况（碎片满负荷 + Boss 战 + 4 个玩家）
# ============================================================

func _scenario_worst_case() -> void:
	var boss := GameState.boss as Node3D
	if boss == null:
		_notes.append("场景 4 跳过：GameState.boss 为空")
		return

	# 造 3 个额外的玩家实体（peer_id 2/3/4），凑成 4 人。
	# 【为什么在 _ready 之后要还原 GameState.local_player】
	# PlayerController._ready 只要 is_local 为真就写 GameState.local_player。
	# 每多造一个都会把 local_player 覆盖成新实例，导致原玩家后续不再被
	# 输入驱动。这里造完统一还原，保证原玩家仍是"本地玩家"。
	var original_local := GameState.local_player
	var ps := load(PLAYER_SCENE) as PackedScene
	for i in 3:
		var p := ps.instantiate() as PlayerController
		if p == null:
			continue
		p.peer_id = i + 2
		_level.add_child(p)
		p.global_position = boss.global_position + Vector3(float(i + 1) * 1.6 - 2.4, 0.0, 4.0)
		_extra_players.append(p)
		await get_tree().physics_frame
	GameState.local_player = original_local

	# 清空碎片，让场景 4 是从"干净的 Boss 战"叠加 60 碎片，而不是叠加
	# 场景 2 的残留（残留会在采样中途到期消失，读数就不稳定）。
	DebrisPool.clear_all()
	await _step(2)

	# 碎片再抛满
	for i in 12:
		DebrisPool.spawn_at(Vector3(0.0, 3.5, 2.0), 6, Color(0.6, 0.6, 0.62), 0.32)
	await _step(4)

	_set_ai(true)
	_drive_players.clear()
	_drive_players.append(_player)
	for p in _extra_players:
		_drive_players.append(p)
	_drive_debris = true
	await _sample("4. 最坏情况",
		"60 碎片 + Boss 战 + 4 个玩家实体同时出招（场上玩家 %d）" % GameState.get_player_count(),
		SAMPLE_FRAMES)
	_drive_debris = false
	_drive_players.clear()

	# 清场，避免污染后续场景。
	#
	# 【为什么要从 GameState.players 里注销】
	# 这些额外玩家注册用的是 peer_id 2/3/4，与真实游戏一致。如果只
	# queue_free 而不注销，GameState.players 里会留下已被释放的引用；
	# 任何后来遍历玩家的代码（例如 Boss 的 get_alive_players）就可能
	# 撞上 "Trying to assign invalid previously freed instance" 崩溃。
	# 这是被测代码路径的真实脆弱点，测试自己不该去触发它。
	# 清场，避免污染后续场景
	DebrisPool.clear_all()
	await _step(2)
	var original_local2 := GameState.local_player
	for p in _extra_players:
		if is_instance_valid(p):
			GameState.unregister_player(int(p.peer_id))
			p.queue_free()
	_extra_players.clear()
	GameState.local_player = original_local2
	_set_ai(false)
	await _step(4)


# ============================================================
# 场景 5：连续破坏（27 块全部打碎，观察帧时间随碎片数变化）
# ============================================================

func _scenario_continuous_destruction() -> void:
	_set_ai(false)
	_drive_players.clear()
	_drive_debris = false
	_move_player_away()

	# 按结构分组
	var by_structure: Dictionary = {}
	for n in get_tree().get_nodes_in_group(&"destructibles"):
		var dp := n as DestructiblePiece
		if dp == null or dp.is_destroyed:
			continue
		var sid := dp.structure_id
		if not by_structure.has(sid):
			by_structure[sid] = [] as Array
		(by_structure[sid] as Array).append(dp)

	var total_pieces := 0
	for sid: String in by_structure:
		total_pieces += (by_structure[sid] as Array).size()
	_notes.append("场景 5 目标：%d 个结构共 %d 块可破坏件" % [by_structure.size(), total_pieces])

	var step := 0
	for sid: String in by_structure:
		step += 1
		var pieces: Array = by_structure[sid]
		# 用权威入口全部打碎（weight 给 3 保证过重量门槛）
		for node: Node in pieces:
			if not is_instance_valid(node):
				continue
			var dp := node as DestructiblePiece
			if dp == null or dp.is_destroyed:
				continue
			TerrainManager.apply_damage_authoritative(
				dp, 9999.0, 3, dp.global_position + Vector3(0.0, 0.3, 0.0))
		await _step(3)
		await _sample("5.%d 破坏 %s" % [step, sid],
			"累计摧毁 %d 块 / 剩余碎片 %d" % [_destroyed_count(), DebrisPool.get_active_count()],
			DESTRUCTION_FRAMES)


# ============================================================
# 采样核心
# ============================================================

func _sample(name: String, desc: String, frames: int) -> void:
	_reset_buffers()
	_collecting = true
	_frame_counter = 0
	for i in frames:
		await get_tree().physics_frame
	_collecting = false
	# 再收一帧让尾部样本落地
	await get_tree().physics_frame

	var idle := _stats(_idle_iv)
	var idle_p := _stats(_idle_phys_iv)
	var idle_np := _stats(_idle_nophys_iv)
	var phys := _stats(_phys_iv)
	var row := {
		"name": name,
		"desc": desc,
		"idle_avg": idle["avg"], "idle_med": idle["med"],
		"idle_p95": idle["p95"], "idle_max": idle["max"], "idle_n": idle["n"],
		"idlep_avg": idle_p["avg"], "idlep_med": idle_p["med"],
		"idlep_p95": idle_p["p95"], "idlep_max": idle_p["max"], "idlep_n": idle_p["n"],
		"idlenp_avg": idle_np["avg"], "idlenp_max": idle_np["max"], "idlenp_n": idle_np["n"],
		"phys_avg": phys["avg"], "phys_med": phys["med"],
		"phys_p95": phys["p95"], "phys_max": phys["max"], "phys_n": phys["n"],
		"phys_mon_avg": _stats(_phys_mon)["avg"], "phys_mon_max": _stats(_phys_mon)["max"],
		"phys_mon_p95": _stats(_phys_mon)["p95"],
		"phys_hist": _phys_histogram(_phys_iv),
		"proc_avg": _stats(_proc_mon)["avg"], "proc_max": _stats(_proc_mon)["max"],
		"active_bodies": int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		"collision_pairs": int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		"obj_count": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"mem_mb": float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0,
		"debris": DebrisPool.get_active_count(),
		"players": GameState.get_player_count(),
		"destructibles_left": _destructibles_left(),
		"over_budget": _over_budget_count(_phys_iv, 16.67),
	}
	_rows.append(row)
	var logic_cap := 1000.0 / maxf(idle_p["avg"], 0.001)
	print("[%s] %s" % [name, desc])
	print("    帧时间(含物理步进的主循环迭代) avg=%.2f med=%.2f P95=%.2f max=%.2f ms -> 帧率上限约 %.0f" % [
		idle_p["avg"], idle_p["med"], idle_p["p95"], idle_p["max"], logic_cap])
	print("      └ 仅脚本迭代 avg=%.2f max=%.2f ms（%d 次）" % [
		idle_np["avg"], idle_np["max"], idle_np["n"]])
	print("    物理帧间隔 avg=%.2f med=%.2f P95=%.2f max=%.2f ms（超 16.67ms 的帧 %d/%d）" % [
		phys["avg"], phys["med"], phys["p95"], phys["max"], row["over_budget"], phys["n"]])
	var hist := _phys_histogram(_phys_iv)
	print("      分档 <18ms=%d / 18~28ms=%d / >=28ms=%d（Windows 计时器粒度约 15.6ms，双峰属正常）" % [
		hist[0], hist[1], hist[2]])
	print("    引擎自报 TIME_PHYSICS avg=%.2f max=%.2f ms | 活跃刚体=%d 碰撞对=%d 碎片=%d 节点=%d 内存=%.1fMB" % [
		row["phys_mon_avg"], row["phys_mon_max"], row["active_bodies"],
		row["collision_pairs"], row["debris"], row["obj_count"], row["mem_mb"]])


func _reset_buffers() -> void:
	_idle_iv.clear()
	_idle_phys_iv.clear()
	_idle_nophys_iv.clear()
	_phys_iv.clear()
	_phys_mon.clear()
	_proc_mon.clear()
	_prev_idle_us = 0
	_prev_phys_us = 0
	_prev_phys_frames = Engine.get_physics_frames()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	# 判断刚刚过去的这段时间里，主循环有没有顺带推进一次物理步进
	var cur_phys := Engine.get_physics_frames()
	var had_physics := cur_phys != _prev_phys_frames
	_prev_phys_frames = cur_phys
	if _collecting and _prev_idle_us > 0:
		var dt := float(now - _prev_idle_us) / 1000.0
		_idle_iv.append(dt)
		if had_physics:
			_idle_phys_iv.append(dt)
		else:
			_idle_nophys_iv.append(dt)
	_prev_idle_us = now


func _physics_process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if _collecting and _prev_phys_us > 0:
		_phys_iv.append(float(now - _prev_phys_us) / 1000.0)
		_phys_mon.append(float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0)
		_proc_mon.append(float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0)
	_prev_phys_us = now

	# 负载驱动：周期性让被驱动的玩家出招、重新抛掷碎片
	_frame_counter += 1
	if _collecting:
		if not _drive_players.is_empty() and _frame_counter % 24 == 0:
			_drive_attack_once()
		if _drive_debris and _frame_counter % 20 == 0:
			_relaunch_debris()
		if _frame_counter % 10 == 0:
			_keep_players_alive()


## 让每个被驱动的玩家发起一次轻攻击。force=true 绕过精力限制，
## 目的是制造持续的战斗负荷（判定盒开启、攻击时序推进）。
func _drive_attack_once() -> void:
	for p in _drive_players:
		if not is_instance_valid(p):
			continue
		var ac := p.get_node_or_null("AttackController") as AttackController
		var wd: Variant = p.get("weapon_data")
		if ac == null or not (wd is WeaponData):
			continue
		var atk: AttackData = (wd as WeaponData).get_light(0)
		ac.request_attack(atk, true)


## 重新抛掷所有活跃碎片，强制它们保持运动（否则会 sleep，物理压力消失）
func _relaunch_debris() -> void:
	if _debris_container == null or not is_instance_valid(_debris_container):
		# 容器由 DebrisPool 在第一次生成碎片时创建，且挂在 current_scene 下，
		# 这里延迟查找一次并缓存。
		_debris_container = get_tree().current_scene.find_child("DebrisContainer", true, false) as Node3D
		if _debris_container == null:
			return
	for child in _debris_container.get_children():
		var dp := child as DebrisPiece
		if dp == null or not dp.is_active_piece():
			continue
		var vel := Vector3(
			randf_range(-3.0, 3.0), randf_range(1.0, 3.0), randf_range(-3.0, 3.0))
		dp.launch(dp.global_position, dp.scale.x, Color(0.6, 0.6, 0.62), vel)


## Boss 会打死玩家，玩家死了就不再处理物理。为了让负载稳定，定期复活。
func _keep_players_alive() -> void:
	for p in _drive_players:
		if not is_instance_valid(p):
			continue
		var h := p.get_node_or_null("Health") as HealthComponent
		if h != null and h.is_dead:
			h.revive(1.0)


## 把玩家挪回出生点附近，远离 Boss（Boss 在 z=-14）
func _move_player_away() -> void:
	if _player != null and is_instance_valid(_player):
		_player.global_position = Vector3(0.0, 1.4, 9.0)


# ============================================================
# 辅助
# ============================================================

func _step(frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, false).timeout


func _set_ai(on: bool) -> void:
	for n in get_tree().get_nodes_in_group(&"lockon_targets"):
		var e := n as Node
		if e == null:
			continue
		if on and e.has_method("clear_ai_force_off"):
			e.call("clear_ai_force_off")
		if e.get("ai_enabled") != null:
			e.set("ai_enabled", on)


func _destructibles_left() -> int:
	var n := 0
	for node in get_tree().get_nodes_in_group(&"destructibles"):
		var dp := node as DestructiblePiece
		if dp != null and not dp.is_destroyed:
			n += 1
	return n


func _destroyed_count() -> int:
	return _total_destructibles - _destructibles_left()


func _boss_health() -> float:
	var boss := GameState.boss
	if boss == null:
		return 0.0
	var h := boss.get_node_or_null("Health") as HealthComponent
	return h.health if h != null else 0.0


func _stats(a: Array[float]) -> Dictionary:
	var n := a.size()
	if n == 0:
		return {"avg": 0.0, "med": 0.0, "p95": 0.0, "max": 0.0, "min": 0.0, "n": 0}
	var b := a.duplicate()
	b.sort()
	var sum := 0.0
	for v in b:
		sum += v
	return {
		"avg": sum / float(n),
		"med": b[n / 2],
		"p95": b[clampi(int(float(n) * 0.95), 0, n - 1)],
		"max": b[n - 1],
		"min": b[0],
		"n": n,
	}


func _over_budget_count(a: Array[float], threshold: float) -> int:
	var c := 0
	for v in a:
		if v > threshold:
			c += 1
	return c


## 把物理帧间隔分三档统计，用于判断"超预算"到底是真的卡顿还是计时器量化
## 【为什么要做这个】
## Windows 上 Godot 的物理步进靠内核计时器唤醒，粒度不是精确的 16.67ms。
## 结果是物理帧间隔常呈 **双峰**：多数帧 ~15.6ms，另有一批跳到 ~31ms
## （约两个计时器周期，即"这一轮没被准时唤醒"）。
## 如果不分档，只报"超 16.67ms 的帧数"，会把这种量化误读成卡顿。
## 用 18 / 28 ms 两个阈值切三档，就能看出别处是不是真的变慢了。
func _phys_histogram(a: Array[float]) -> Array:
	var low := 0
	var mid := 0
	var high := 0
	for v in a:
		if v < 18.0:
			low += 1
		elif v < 28.0:
			mid += 1
		else:
			high += 1
	return [low, mid, high]


# ============================================================
# 报告
# ============================================================

func _report() -> void:
	var lines: PackedStringArray = []
	lines.append("性能测试结果（无头模式，脚本自动生成，请勿手改）")
	lines.append("生成时间：%s" % Time.get_datetime_string_from_system())
	lines.append("Godot：%s    平台：%s" % [
		Engine.get_version_info()["string"], OS.get_name()])
	lines.append("CPU：%s（%d 逻辑核心）" % [OS.get_processor_name(), OS.get_processor_count()])
	lines.append("")
	lines.append("【重要前提】无头模式使用 dummy 渲染器，不渲染任何画面。")
	lines.append("  本表测的是 CPU 主循环与物理步进的耗时，不是玩家看到的 FPS。")
	lines.append("  物理默认跑在主线程，所以主循环的迭代分两种：含物理步进的（重）")
	lines.append("  与仅跑脚本的（轻）。「帧率上限」用的是含物理步进的迭代，它才是")
	lines.append("  CPU 侧真正的天花板；真实 FPS 还要受 GPU 与渲染管线限制，")
	lines.append("  必须在带显示器的环境下另测（步骤见 docs/性能报告.md）。")
	lines.append("  物理帧间隔正常为 1/60s=16.67ms；稳定超过它 = 物理步进超出 60Hz 预算。")
	lines.append("")
	for note in _notes:
		lines.append("说明：%s" % note)
	lines.append("")

	for r: Dictionary in _rows:
		lines.append("── %s ──" % r["name"])
		lines.append("  场景：%s" % r["desc"])
		lines.append("  帧时间-含物理步进(ms)  平均 %.2f | 中位数 %.2f | P95 %.2f | 最大 %.2f  （样本 %d）" % [
			r["idlep_avg"], r["idlep_med"], r["idlep_p95"], r["idlep_max"], r["idlep_n"]])
		lines.append("  帧率上限            %.0f /s（=1000/含物理帧平均耗时；无头下不含渲染，非真实 FPS）" % (
			1000.0 / maxf(r["idlep_avg"], 0.001)))
		lines.append("  帧时间-仅脚本(ms)    平均 %.2f | 最大 %.2f  （样本 %d，主循环未推进物理的迭代）" % [
			r["idlenp_avg"], r["idlenp_max"], r["idlenp_n"]])
		lines.append("  物理帧间隔(ms)     平均 %.2f | 中位数 %.2f | P95 %.2f | 最大 %.2f  （超 16.67ms：%d/%d）" % [
			r["phys_avg"], r["phys_med"], r["phys_p95"], r["phys_max"],
			r["over_budget"], r["phys_n"]])
		var h: Array = r["phys_hist"]
		lines.append("    分档 <18ms=%d | 18~28ms=%d | ≥28ms=%d（Windows 内核计时器粒度约 15.6ms，双峰是量化不是卡顿）" % [
			h[0], h[1], h[2]])
		lines.append("  引擎自报物理耗时(ms) 平均 %.2f | P95 %.2f | 最大 %.2f  （旁证，统计口径与物理帧间隔不同）" % [
			r["phys_mon_avg"], r["phys_mon_p95"], r["phys_mon_max"]])
		lines.append("  引擎自报脚本耗时(ms) 平均 %.2f | 最大 %.2f" % [r["proc_avg"], r["proc_max"]])
		lines.append("  活跃物理对象 %d | 碰撞对 %d | 碎片 %d | 玩家 %d | 剩余可破坏件 %d | 节点总数 %d | 静态内存 %.1fMB" % [
			r["active_bodies"], r["collision_pairs"], r["debris"], r["players"],
			r["destructibles_left"], r["obj_count"], r["mem_mb"]])
		lines.append("")

	var text := "\n".join(lines)
	print("\n========== 性能测试报告 ==========")
	print(text)
	print("==================================")

	var f := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
		print("结果已写入 %s" % RESULT_PATH)
	else:
		push_error("无法写入 %s" % RESULT_PATH)
