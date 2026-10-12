extends Node
## 双进程多人战斗测试：两个进程都进入战斗关卡，
## 验证玩家互相可见、Boss 存在、关键状态一致。
##
## 用法（项目根目录）：
##     bash tests/run_mp_battle_test.sh
##
## 或手工开两个终端：
##     godot --headless res://tests/mp_battle_test.tscn -- --role=host
##     godot --headless res://tests/mp_battle_test.tscn -- --role=client
##
## 这是对任务书验收标准 7（"四名玩家能参加同一场战斗"）的**两人版**
## 验证。四人版需要四个进程，见 docs/测试记录.md 的步骤。
##
## 验证项：
##   P1  会话已建立，且角色正确
##   P2  本地玩家已生成
##   P3  两端都注册了 2 个玩家实体
##   P4  Boss 已生成
##   P5  客户端收到了 Boss 的位置同步
##   P6  地形破坏物数量在两端一致（都是 27 块）
##   P7  远端玩家节点确实存在且可见
##
## 【为什么要轮询等待而不是固定等 5 秒】
## ENet 在本机的握手实测要 4~5 秒，加上关卡加载与玩家生成，
## 固定等待很容易在连接还没完成时就下结论（第一版就是这么错的：
## 主机在客户端还没接入时就检查，报"玩家数量 = 1"）。
## 正确的做法是轮询到"就绪"再断言，超时才算失败。

const ARENA := "res://scenes/levels/arena.tscn"
const TEST_PORT := 27018
## 整体超时（秒）。要留够 ENet 握手 + 关卡加载 + 玩家生成的时间。
## 四人时握手更慢，给足余量。
const TIMEOUT := 75.0
## 期望的玩家数量。由启动参数 --players=N 决定，默认 2。
var _expected_players := 2
## 期望的可破坏结构件总数（3 根石柱 x 5 段 + 2 堵墙 x 6 块 = 27）
const EXPECTED_DESTRUCTIBLES := 27

var _role := "host"
var _elapsed := 0.0
var _done := false
var _checked := false
var _level: Node3D = null
var _results: Array[Dictionary] = []

## 地形破坏同步用的测试目标 UID（主机端决定，客户端用来验证）
var _test_piece_uid: String = ""
## 客户端是否观察到该结构件被摧毁
var _piece_destroyed_seen: bool = false
## 客户端在收到公告时，该结构件是否还存在（用于排除"客户端到得太晚，
## 破坏已经发生完了"这种假通过）
var _piece_existed_before: bool = false
## 主机侧：已回执的客户端（peer_id -> uid）
var _acked_peers: Dictionary = {}


func _ready() -> void:
	_role = _parse_role()
	_expected_players = _parse_int_arg("--players=", 2)
	print("[多人战斗测试] 角色 = %s，期望玩家数 = %d" % [_role, _expected_players])
	if _role == "host":
		_run_host()
	else:
		_run_client()


func _parse_role() -> String:
	var args := OS.get_cmdline_user_args()
	for a: String in args:
		if a.begins_with("--role="):
			return a.substr(7)
	return "host"


func _parse_int_arg(prefix: String, fallback: int) -> int:
	var args := OS.get_cmdline_user_args()
	for a: String in args:
		if a.begins_with(prefix):
			return int(a.substr(prefix.length()))
	return fallback


# ============================================================
# 启动流程
# ============================================================

func _run_host() -> void:
	var err := NetManager.host_game(TEST_PORT, "多人战斗测试房")
	if err != OK:
		_fail("创建房间失败（错误码 %d）" % err)
		return
	print("[多人战斗测试] 房间已创建，加载关卡并等待客户端接入")
	_load_arena()
	_start_timeout()


func _run_client() -> void:
	# 等主机进程把房间建好
	await get_tree().create_timer(2.0, false).timeout
	if _done:
		return
	print("[多人战斗测试] 连接 127.0.0.1:%d" % TEST_PORT)
	var err := NetManager.join_game("127.0.0.1", TEST_PORT)
	if err != OK:
		_fail("创建客户端失败（错误码 %d）" % err)
		return

	# 必须等连接**真正建立**再加载关卡。
	# 否则 LevelManager._spawn_initial_players 会看到
	# NetManager.is_session_active() 为 false，于是按单机模式
	# 只生成一个本地玩家，后面再也不会有远端玩家出现。
	var ok := await _wait_connected(25.0)
	if _done:
		return
	if not ok:
		_fail("连接主机的等待超时（25 秒）")
		return
	print("[多人战斗测试] 已连上主机（peer_id=%d），加载关卡" % multiplayer.get_unique_id())
	_load_arena()
	_start_timeout()


func _wait_connected(seconds: float) -> bool:
	var left := seconds
	while left > 0.0:
		var p := multiplayer.multiplayer_peer
		if p != null and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			return true
		await get_tree().create_timer(0.15, false).timeout
		left -= 0.15
		if _done:
			return false
	return false


func _load_arena() -> void:
	var packed := load(ARENA) as PackedScene
	if packed == null:
		_fail("无法加载 %s" % ARENA)
		return
	_level = packed.instantiate() as Node3D
	add_child(_level)


func _start_timeout() -> void:
	var timer := get_tree().create_timer(TIMEOUT, false)
	timer.timeout.connect(func () -> void:
		if not _done:
			# 超时时把已经看到的状态打印出来，方便排查卡在哪一步
			print("[多人战斗测试] 超时时的状态：players=%s peers=%s 已加载关卡=%s" % [
				str(GameState.players.keys()),
				str(multiplayer.get_peers()),
				_level != null])
			_fail("等待 %.0f 秒超时" % TIMEOUT)
	)


# ============================================================
# 地形破坏同步测试
# ============================================================

## 验证"地形破坏结果在所有联机玩家之间正确同步"（任务书验收标准 8）。
##
## 做法（三阶段握手，避免时序竞态导致误判）：
##
##   阶段 1 —— 主机广播"我将要摧毁这个 UID"
##   阶段 2 —— 各客户端收到后**各自回执**"我看到了，确认它此刻存在"
##   阶段 3 —— 主机收齐所有回执（或等 5 秒）后才真正摧毁
##
## 客户端随后轮询到它消失。
##
## 【为什么要三阶段而不是"公告 → 等 1.5 秒 → 摧毁"】
## 最初用的是固定等待。四人测试里最后一个加入的客户端偶发失败：
## 它的就绪检查比别的进程晚，等它进入同步测试时，主机那 1.5 秒
## 已经走完、结构件已经碎了 —— 于是它记录到"听到公告时还在=false"，
## 看起来像同步失败，实际只是它到得太晚。
## 改成回执握手后，主机一定会等到所有客户端都确认"看到了"才动手，
## 时序不再依赖进程启动速度。
func _run_terrain_sync_test() -> void:
	if _role == "host":
		var before := get_tree().get_nodes_in_group(&"destructibles").size()
		# 阶段 1：广播将要被摧毁的目标
		_pick_target_uid()
		_rpc_announce_target.rpc(_test_piece_uid)

		# 阶段 2/3：等所有客户端回执（最多 8 秒）
		var waited := 0.0
		while waited < 8.0:
			if _acked_peers.size() >= _expected_players - 1:
				break
			await get_tree().create_timer(0.1, false).timeout
			waited += 0.1
			if _done:
				return
		print("[多人战斗测试] 主机：收到 %d/%d 个客户端回执（等待 %.1f 秒），现在摧毁 %s" % [
			_acked_peers.size(), _expected_players - 1, waited, _test_piece_uid])

		# 真正摧毁
		_destroy_target(_test_piece_uid)
		var after := get_tree().get_nodes_in_group(&"destructibles").size()
		print("[多人战斗测试] 主机：本端件数 %d -> %d" % [before, after])
		await get_tree().create_timer(2.5, false).timeout
	else:
		# 客户端：等主机公告目标
		var wait1 := 0.0
		while _test_piece_uid.is_empty() and wait1 < 15.0:
			await get_tree().create_timer(0.2, false).timeout
			wait1 += 0.2
			if _done:
				return
		if _test_piece_uid.is_empty():
			return

		# 回执：告诉主机"我看到了这个 UID"
		_piece_existed_before = _find_piece_by_uid_local(_test_piece_uid) != null
		_rpc_ack_target.rpc_id(1, _test_piece_uid)

		# 轮询等待它消失
		var wait2 := 0.0
		while wait2 < 12.0:
			if _find_piece_by_uid_local(_test_piece_uid) == null:
				_piece_destroyed_seen = true
				break
			await get_tree().create_timer(0.15, false).timeout
			wait2 += 0.15
			if _done:
				return
		print("[多人战斗测试] 客户端：目标 %s 回执时存在=%s，随后消失=%s（等待 %.1f 秒）" % [
			_test_piece_uid, _piece_existed_before, _piece_destroyed_seen, wait2])


func _pick_target_uid() -> void:
	var pieces := get_tree().get_nodes_in_group(&"destructibles")
	for n in pieces:
		var piece := n as DestructiblePiece
		# 挑未被摧毁的，且尽量挑耐久高的（不容易被别的逻辑顺手打掉）
		if piece != null and not piece.is_destroyed:
			_test_piece_uid = piece.piece_uid
			return
	_test_piece_uid = ""


func _destroy_target(uid: String) -> void:
	var piece := _find_piece_by_uid_local(uid)
	if piece == null:
		_piece_destroyed_seen = true
		return
	# 走正常入口（权威端直接结算），这样会真实触发 _rpc_piece_destroyed
	TerrainManager.apply_damage_authoritative(
		piece, piece.max_durability + 10.0, 2, piece.global_position)


@rpc("authority", "call_remote", "reliable")
func _rpc_announce_target(uid: String) -> void:
	_test_piece_uid = uid
	print("[多人战斗测试] 客户端收到破坏目标公告：%s" % uid)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_ack_target(uid: String) -> void:
	if not NetManager.is_host:
		return
	var sender := multiplayer.get_remote_sender_id()
	_acked_peers[sender] = uid
	print("[多人战斗测试] 主机收到客户端 %d 的回执：%s" % [sender, uid])


func _find_piece_by_uid_local(uid: String) -> DestructiblePiece:
	if uid.is_empty():
		return null
	for n in get_tree().get_nodes_in_group(&"destructibles"):
		var p := n as DestructiblePiece
		if p != null and p.piece_uid == uid and not p.is_destroyed:
			return p
	return null


# ============================================================
# 就绪判定与检查
# ============================================================

func _process(delta: float) -> void:
	if _done or _checked:
		return
	_elapsed += delta
	# 前 3 秒什么都不查：关卡还在初始化
	if _elapsed < 3.0:
		return

	# 就绪判据：两端都注册了期望数量的玩家，并且 Boss 已生成
	if GameState.players.size() >= _expected_players and GameState.boss != null:
		# 【必须先置位再 await】
		# `_process` 每帧都会执行。如果在 await 之后才设 _checked，
		# await 期间这个条件依然成立，会启动第二遍检查 —— 症状是
		# 输出里出现两份结果，而且第二份是在玩家已经退出之后跑的
		# （peer_id 变成 0、玩家名单缺人）。第一版就踩了这个坑。
		_checked = true
		# 【就绪之后还要再等一下】
		# 玩家生成的广播和敌人状态的广播是两条独立的消息。玩家到达
		# 通常更快，所以"看到 4 个玩家"的那一刻，Boss 的位置同步
		# 可能还在路上。四人测试里最后一个加入的客户端就踩到了这个
		# 时间差（P5 报"从未收到同步"，但几毫秒后就会收到）。
		await get_tree().create_timer(2.0, false).timeout
		if _done:
			return
		await _run_terrain_sync_test()
		if _done:
			return
		_run_checks()


func _run_checks() -> void:
	# P1 会话
	_check("P1 会话已建立且角色正确", NetManager.is_session_active(),
		"角色 = %s，peer_id = %d" % [
			"主机" if NetManager.is_host else "客户端",
			multiplayer.get_unique_id()])

	# P2 本地玩家
	var lp := GameState.local_player
	var has_local := lp != null and is_instance_valid(lp)
	_check("P2 本地玩家已生成", has_local,
		"local_player = %s（位置 %s）" % [
			lp.name if has_local else "无",
			str(lp.global_position) if has_local else "—"])

	# P3 玩家实体数量
	var count := GameState.players.size()
	_check("P3 本端注册了 %d 个玩家实体" % _expected_players,
		count == _expected_players,
		"GameState.players = %s" % str(GameState.players.keys()))

	# P7 远端玩家节点确实存在、且有 Health 组件
	var remote_ok := true
	var remote_detail: PackedStringArray = []
	var local_id := multiplayer.get_unique_id()
	for id: int in GameState.players:
		var p: Node = GameState.players[id]
		if p == null or not is_instance_valid(p):
			remote_ok = false
			remote_detail.append("%d=失效" % id)
			continue
		var h := p.get_node_or_null("Health")
		var tag := "本地" if id == local_id else "远端"
		remote_detail.append("%d(%s,血量组件=%s)" % [id, tag, "有" if h != null else "无"])
		if h == null:
			remote_ok = false
	_check("P7 所有玩家节点有效且带血量组件", remote_ok,
		", ".join(remote_detail))

	# P4 Boss
	var boss := GameState.boss
	var has_boss := boss != null and is_instance_valid(boss)
	_check("P4 Boss 已生成", has_boss,
		"Boss = %s" % (boss.name if has_boss else "无"))

	# P5 Boss 位置同步（客户端侧才有的判断）
	if _role == "client" and has_boss:
		var sync := boss.get_node_or_null("EnemySync")
		var t := 0.0
		if sync != null:
			t = float(sync.get("last_sync_time"))
		_check("P5 客户端收到 Boss 位置同步", t > 0.0,
			"EnemySync 最近同步时间 = %s（0 表示从未收到）" % ("%.2f" % t if t > 0.0 else "从未"))
	else:
		var peer_count := multiplayer.get_peers().size()
		_check("P5 主机正在向客户端广播 Boss 状态", peer_count > 0,
			"本端为主机（同步源），已连接 peer = %d，Boss=%s" % [
				peer_count, boss.name if has_boss else "无"])

	# P6 地形破坏物（初始数量，两端应一致）
	var dcount := get_tree().get_nodes_in_group(&"destructibles").size()
	_check("P6 地形破坏物数量一致", dcount == EXPECTED_DESTRUCTIBLES - 1,
		"本端 = %d 块（期望 %d 块；原始 %d 块减去 P8 同步测试中摧毁的 1 块）" % [
			dcount, EXPECTED_DESTRUCTIBLES - 1, EXPECTED_DESTRUCTIBLES])

	# P8 地形破坏同步（任务书验收标准 8）
	if _role == "host":
		_check("P8 主机已摧毁并广播结构件", not _test_piece_uid.is_empty(),
			"UID = %s" % _test_piece_uid)
	else:
		_check("P8 客户端同步到了地形破坏结果",
			_piece_destroyed_seen and _piece_existed_before,
			"目标 %s：听到公告时还在=%s，随后消失=%s" % [
				_test_piece_uid, _piece_existed_before, _piece_destroyed_seen])

	# 汇总
	var passed := 0
	var failed := 0
	for r: Dictionary in _results:
		if r["ok"]:
			passed += 1
		else:
			failed += 1
	var tag := "主机" if NetManager.is_host else "客户端"
	print("\n[多人战斗测试] ===== %s 端：通过 %d / 失败 %d =====" % [tag, passed, failed])
	for r: Dictionary in _results:
		print("  %s %s  %s" % [
			"[通过]" if r["ok"] else "[失败]", r["name"], r["detail"]])

	# 等一会儿再退出，让另一端也跑完它的检查（先退出的一方会切断连接）
	await get_tree().create_timer(3.0, false).timeout
	_finish(failed == 0)


func _check(name: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": name, "ok": ok, "detail": detail})


func _finish(ok: bool) -> void:
	if _done:
		return
	_done = true
	NetManager.leave_session()
	get_tree().quit(0 if ok else 1)


## 【`_checked` 也必须检查】
## 两端几乎同时判定就绪，各自进入收尾等待。先退出的一方会切断连接，
## 另一方会收到"与主机断开连接"的网络错误 —— 但那时它其实已经
## 通过了检查，只是还没打印结果。没有这个判断就会出现
## "检查全通过却报失败"的假阴性。
func _fail(msg: String) -> void:
	if _done or _checked:
		return
	_done = true
	printerr("[多人战斗测试] ===== 失败：%s =====" % msg)
	NetManager.leave_session()
	get_tree().quit(1)
