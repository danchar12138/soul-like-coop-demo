extends Node
## 多人联机性能测试：每个进程都测自己的物理帧时间。
##
## 用法（项目根目录）：
##     bash tests/run_mp_perf_test.sh 4
##
## 手工开终端也可以：
##     godot --headless res://tests/mp_perf_test.tscn -- --role=host --players=4
##     godot --headless res://tests/mp_perf_test.tscn -- --role=client --players=4
##
## 【这测的是什么、不是什么】
##   参与的是同一台机器上的 4 个 Godot 进程。所以它**不能**反映
##   跨设备的真实网络延迟与丢包，但它能回答一个真实的问题：
##   「主机同时伺候 3 个客户端、跑 Boss AI、跑 60 个碎片刚体时，
##     主机这一侧的 CPU 主循环还剩多少余量？」
##   客户端侧的读数反映了"只做同步与表现、不跑 AI"时的开销。
##
## 【无头前提与 perf_test.gd 相同】不渲染画面，测的是 CPU 逻辑/物理，
##   不是玩家看到的 FPS。
##
## 结果写到 tests/_mp_perf/<role>.txt（每个进程一份），由 run_mp_perf_test.sh 汇总。

const ARENA := "res://scenes/levels/arena.tscn"
const OUT_DIR := "res://tests/_mp_perf"
const SAMPLE_FRAMES := 240
const TIMEOUT := 90.0

var _role := "host"
var _expected := 4
var _elapsed := 0.0
var _done := false
var _started := false
var _start_received := false
var _level: Node3D

var _phys_iv: Array[float] = []
var _idle_iv: Array[float] = []
var _phys_mon: Array[float] = []
var _collecting := false
var _prev_phys_us := 0
var _prev_idle_us := 0
var _frame := 0
var _debris_container: Node3D


func _ready() -> void:
	_role = _parse_arg("--role=", "host")
	_expected = int(_parse_arg("--players=", "4"))
	print("[多人性能测试] 角色=%s 期望玩家数=%d" % [_role, _expected])
	if _role == "host":
		_run_host()
	else:
		_run_client()


func _parse_arg(prefix: String, fallback: String) -> String:
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return fallback


func _run_host() -> void:
	if NetManager.host_game(27019, "性能测试房") != OK:
		_fail("创建房间失败")
		return
	_load_arena()
	_arm_timeout()


func _run_client() -> void:
	await get_tree().create_timer(2.0, false).timeout
	if _done:
		return
	if NetManager.join_game("127.0.0.1", 27019) != OK:
		_fail("加入房间失败")
		return
	var left := 30.0
	while left > 0.0:
		var p := multiplayer.multiplayer_peer
		if p != null and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			break
		await get_tree().create_timer(0.15, false).timeout
		left -= 0.15
		if _done:
			return
	_load_arena()
	_arm_timeout()


func _load_arena() -> void:
	var packed := load(ARENA) as PackedScene
	if packed == null:
		_fail("无法加载 %s" % ARENA)
		return
	_level = packed.instantiate() as Node3D
	add_child(_level)


func _arm_timeout() -> void:
	var t := get_tree().create_timer(TIMEOUT, false)
	t.timeout.connect(func () -> void:
		if not _done:
			_fail("等待超时（%.0f 秒）" % TIMEOUT)
	)


# ============================================================
# 就绪 -> 同步开始采样 -> 采样 -> 落盘
# ============================================================

func _process(delta: float) -> void:
	if _done:
		return
	_elapsed += delta

	# 主循环空闲段采样（仅脚本迭代）
	var now := Time.get_ticks_usec()
	if _collecting and _prev_idle_us > 0:
		_idle_iv.append(float(now - _prev_idle_us) / 1000.0)
	_prev_idle_us = now

	if not _started and _elapsed > 4.0 and GameState.players.size() >= _expected \
			and GameState.boss != null:
		if _role == "host":
			# 主机负责发令：所有进程在同一时刻开始采样，读数才可比
			_started = true
			_rpc_start_sampling.rpc()
			_begin_sampling()
		elif _start_received:
			_started = true
			_begin_sampling()


@rpc("authority", "call_remote", "reliable")
func _rpc_start_sampling() -> void:
	_start_received = true


func _begin_sampling() -> void:
	# 每个进程都在本地抛满自己的 60 个碎片（碎片是纯表现、不跨端同步，
	# 各端各自模拟），这样每个进程的物理负载都接近真实游戏的最坏情况。
	for i in 12:
		DebrisPool.spawn_at(Vector3(0.0, 3.5, 2.0), 6, Color(0.6, 0.6, 0.62), 0.32)
	_prev_phys_us = 0
	_collecting = true
	_frame = 0
	await _sample_loop()


func _sample_loop() -> void:
	while _frame < SAMPLE_FRAMES:
		await get_tree().physics_frame
	_collecting = false
	_write_result()
	_done = true
	print("[多人性能测试] %s 完成采样" % _role)
	# 客户端先退，主机最后退（避免主机先退导致客户端刷一堆断线错误）
	if _role == "client":
		await get_tree().create_timer(0.5, false).timeout
	get_tree().quit(0)


func _physics_process(_delta: float) -> void:
	if _done:
		return
	_frame += 1
	var now := Time.get_ticks_usec()
	if _collecting and _prev_phys_us > 0:
		_phys_iv.append(float(now - _prev_phys_us) / 1000.0)
		_phys_mon.append(float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0)
	_prev_phys_us = now


func _write_result() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var phys := _stats(_phys_iv)
	var idle := _stats(_idle_iv)
	var lines: PackedStringArray = []
	lines.append("角色：%s" % _role)
	lines.append("peer_id：%d" % multiplayer.get_unique_id())
	lines.append("本端注册玩家数：%d" % GameState.players.size())
	lines.append("本端活跃碎片：%d" % DebrisPool.get_active_count())
	lines.append("物理帧间隔(ms)  平均 %.2f | 中位数 %.2f | P95 %.2f | 最大 %.2f（样本 %d，超16.67ms %d）" % [
		phys["avg"], phys["med"], phys["p95"], phys["max"], phys["n"],
		_count_over(_phys_iv, 16.67)])
	lines.append("仅脚本迭代(ms)  平均 %.2f | 最大 %.2f（样本 %d）" % [
		idle["avg"], idle["max"], idle["n"]])
	lines.append("活跃刚体 %d | 碰撞对 %d | 节点总数 %d | 静态内存 %.1fMB" % [
		int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)),
		int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0])
	lines.append("引擎自报物理耗时(ms) 平均 %.2f | 最大 %.2f" % [
		_stats(_phys_mon)["avg"], _stats(_phys_mon)["max"]])
	var text := "\n".join(lines)
	print("\n──── %s ────\n%s" % [_role, text])
	# 【文件名必须带上进程 id】
	# 三个客户端进程都会调用本函数；如果都写 client.txt，后写的会覆盖
	# 先写的，最终只剩一份读数（第一版就是这样，看起来像"只有一个客户端"）。
	var fname := "%s_%d.txt" % [_role, OS.get_process_id()]
	var f := FileAccess.open("%s/%s" % [OUT_DIR, fname], FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _count_over(a: Array[float], t: float) -> int:
	var c := 0
	for v in a:
		if v > t:
			c += 1
	return c


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


func _fail(msg: String) -> void:
	print("[多人性能测试][失败] %s" % msg)
	_done = true
	get_tree().quit(1)
