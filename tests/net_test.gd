extends Node
## 联机连接测试：两个独立 Godot 进程之间建立 ENet 会话。
##
## 用法（需要开两个终端，或在同一个终端里顺序启动）：
##
##   终端 1（主机）：
##     godot --headless res://tests/net_test.tscn -- --role=host
##
##   终端 2（客户端）：
##     godot --headless res://tests/net_test.tscn -- --role=client
##
## 两个进程都退出码 0 时表示连接验证通过。
##
## 为什么必须用两个进程
## --------------------
## Godot 的 `multiplayer` 是每个 SceneTree 一个单例，一个进程里
## 只能有一份 multiplayer peer。所以无法在单进程内同时扮演主机和
## 客户端 —— 必须真的开两个进程，这也是"两人联机测试"最省事的
## 可重复方式（不需要两台机器）。
##
## 本测试验证的是**连接与握手**，不加载战斗关卡。
## 完整战斗同步的验证步骤见 docs/测试记录.md。

const WAIT_TIMEOUT := 20.0
const TEST_PORT := 27016   # 用独立端口，避免和实际游戏（27015）冲突

var _role: String = "host"
var _elapsed: float = 0.0
var _done: bool = false
var _peer_connected: bool = false
## 进入"正在收尾"状态。`_process` 每帧都会跑，而 `_pass()` 之前有一个
## `await` —— 如果没有这个标志，await 期间条件仍然成立，会重复打印
## 并多次调用 quit()。
var _finishing: bool = false


func _ready() -> void:
	_role = _parse_role()
	print("[联机测试] 角色 = %s，端口 = %d" % [_role, TEST_PORT])
	print("[联机测试] Godot 版本 %s" % Engine.get_version_info()["string"])

	NetManager.peer_joined.connect(_on_peer_joined)
	NetManager.net_error.connect(_on_net_error)

	if _role == "host":
		_start_host()
	else:
		_start_client()

	# 超时保护：避免测试因为连接不上而永久挂起
	var timer := get_tree().create_timer(WAIT_TIMEOUT, false)
	timer.timeout.connect(_on_timeout)


func _parse_role() -> String:
	var args := OS.get_cmdline_user_args()
	for a: String in args:
		if a.begins_with("--role="):
			return a.substr(7)
	# 兼容 "--role host" 这种写法
	for i in args.size():
		if args[i] == "--role" and i + 1 < args.size():
			return args[i + 1]
	return "host"


# ============================================================

func _start_host() -> void:
	var err := NetManager.host_game(TEST_PORT, "自动化测试房")
	if err != OK:
		_fail("创建房间失败（错误码 %d）" % err)
		return
	print("[联机测试] 房间已创建，等待客户端连接…")

	# 测试不在游戏关卡里，这里手工登记主机自己的玩家记录
	NetManager.peer_info[1] = {"name": "主机", "ready": true}


func _start_client() -> void:
	# 等 1 秒再连，给主机进程留出启动时间
	await get_tree().create_timer(1.5, false).timeout
	if _done:
		return
	print("[联机测试] 正在连接 127.0.0.1:%d …" % TEST_PORT)
	var err := NetManager.join_game("127.0.0.1", TEST_PORT)
	if err != OK:
		_fail("创建客户端失败（错误码 %d）" % err)


# ============================================================

func _process(delta: float) -> void:
	if _done or _finishing:
		return
	_elapsed += delta

	# 【为什么要等 peer_info 里有 2 个人，而不是"连上就算成功"】
	# 最初的写法是客户端一旦 create_client 返回 OK、is_session_active
	# 变真就判通过。结果客户端立刻退出，把连接关掉了 —— 主机的
	# peer_connected 还没来得及触发（实测 ENet 握手在本机大约要 4~5 秒）。
	#
	# 正确的判据是"双方都确认对方存在"，即 peer_info 里有两个条目。
	# 主机的 peer_info 由 _rpc_register_player 填充（客户端连上后
	# 把自己的名字报过来），客户端的由 _rpc_sync_peer_list 填充。
	# 所以这一条同时验证了：连接建立 + RPC 双向可用。
	var count := NetManager.peer_info.size()
	if count >= 2:
		_finishing = true
		var ids := NetManager.get_sorted_peer_ids()
		var names: PackedStringArray = []
		for id: int in ids:
			names.append("%s(%d)" % [NetManager.get_peer_display_name(id), id])
		print("[联机测试] ✓ 双方均已确认对方存在，peer 列表：%s" % ", ".join(names))
		# 停 1.5 秒，让另一端也走到同样的判断，避免先退出的一方
		# 把连接切断导致另一端超时
		await get_tree().create_timer(1.5, false).timeout
		_pass("会话已建立且双向 RPC 可用（%d 个 peer）" % count)


func _on_peer_joined(id: int) -> void:
	print("[联机测试] 收到 peer_joined 事件：peer_id = %d" % id)


func _on_net_error(msg: String) -> void:
	_fail("网络错误：" + msg)


func _on_timeout() -> void:
	if _done or _finishing:
		return
	_fail("等待 %.0f 秒超时，未能建立连接" % WAIT_TIMEOUT)


# ============================================================

func _pass(msg: String) -> void:
	if _done:
		return
	_done = true
	print("[联机测试] ===== 通过：%s =====" % msg)
	NetManager.leave_session()
	get_tree().quit(0)


func _fail(msg: String) -> void:
	# 【`_finishing` 也必须检查】
	# 双方几乎同时判定"就绪"，各自进入 1.5 秒的收尾等待。先走完的一方
	# 退出时会切断连接，另一方会收到"与主机断开连接"的网络错误 ——
	# 但那时它其实已经通过了检查，只是还没打印结果。
	# 没有这个判断就会出现"检查全通过，却报失败"的假阴性。
	if _done or _finishing:
		return
	_done = true
	printerr("[联机测试] ===== 失败：%s =====" % msg)
	NetManager.leave_session()
	get_tree().quit(1)
