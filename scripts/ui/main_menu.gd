extends CanvasLayer
## 主菜单 / 房间面板。
##
## 首版联机方案的入口（任务要求 7：局域网主机创建 + 输入 IP 加入）：
##   单机开始  —— 不建会话，直接进关卡
##   创建房间  —— host_game()，本机成为权威端
##   加入房间  —— join_game(ip)，输入主机 IP
##
## 界面用代码构建，避免手写 .tscn 的 UI 节点树出错。
## 中文字体使用系统字体回退，见 _apply_font()。

const ARENA_SCENE := "res://scenes/levels/arena.tscn"

var _root: Control
var _status_label: Label
var _ip_field: LineEdit
var _join_panel: PanelContainer
var _button_box: VBoxContainer


func _ready() -> void:
	layer = 10
	_build_ui()
	NetManager.net_error.connect(_on_net_error)
	NetManager.session_started.connect(_on_session_started)
	NetManager.info_updated.connect(_refresh_status)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_status()


# ============================================================
# 界面构建
# ============================================================

func _build_ui() -> void:
	_root = Control.new()
	_root.name = "MenuRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	# 背景
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.075, 0.082, 0.10, 1.0)
	_root.add_child(bg)

	# 左侧装饰条（低多边形风格：一块纯色斜切）
	var accent := ColorRect.new()
	accent.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	accent.custom_minimum_size = Vector2(10, 0)
	accent.color = Color(0.85, 0.55, 0.20)
	_root.add_child(accent)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	col.custom_minimum_size = Vector2(460, 0)
	center.add_child(col)

	var title := Label.new()
	title.text = "低多边形类魂·合作战斗 Demo"
	title.add_theme_font_size_override("font_size", 30)
	title.add_theme_color_override("font_color", Color(0.94, 0.92, 0.88))
	col.add_child(title)

	var sub := Label.new()
	sub.text = "第一阶段：核心战斗原型"
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", Color(0.62, 0.65, 0.70))
	col.add_child(sub)

	col.add_child(HSeparator.new())

	_button_box = VBoxContainer.new()
	_button_box.add_theme_constant_override("separation", 10)
	col.add_child(_button_box)

	_add_button("单机开始（含 Boss 战）", _on_solo_pressed)
	_add_button("创建房间（本机作为主机）", _on_host_pressed)
	_add_button("加入房间…", _on_join_toggle_pressed)
	_add_button("退出", func () -> void: get_tree().quit())

	# 加入房间的输入面板（默认隐藏）
	_join_panel = _build_join_panel()
	_join_panel.visible = false
	col.add_child(_join_panel)

	col.add_child(HSeparator.new())

	_status_label = Label.new()
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", Color(0.72, 0.78, 0.85))
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(440, 0)
	col.add_child(_status_label)

	_apply_font(title, true)
	_apply_font(sub)
	_apply_font(_status_label)
	for b in _button_box.get_children():
		if b is Button:
			_apply_font(b as Button)


func _build_join_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.13, 0.16, 0.9)
	style.set_content_margin_all(12)
	style.set_corner_radius_all(4)
	panel.add_theme_stylebox_override("panel", style)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)

	var hint := Label.new()
	hint.text = "输入主机的局域网 IP（主机可在主菜单看到本机 IP）"
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.68, 0.72, 0.78))
	v.add_child(hint)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)

	_ip_field = LineEdit.new()
	_ip_field.text = _guess_local_ip()
	_ip_field.placeholder_text = "192.168.1.100"
	_ip_field.custom_minimum_size = Vector2(220, 34)
	_ip_field.add_theme_font_size_override("font_size", 15)
	row.add_child(_ip_field)

	var btn := Button.new()
	btn.text = "连接"
	btn.custom_minimum_size = Vector2(90, 34)
	btn.pressed.connect(_on_join_confirm)
	row.add_child(btn)

	var port_label := Label.new()
	port_label.text = "端口 %d（固定）" % NetManager.PORT
	port_label.add_theme_font_size_override("font_size", 12)
	port_label.add_theme_color_override("font_color", Color(0.55, 0.58, 0.63))
	v.add_child(port_label)

	_apply_font(hint)
	_apply_font(_ip_field)
	_apply_font(btn)
	_apply_font(port_label)
	return panel


func _add_button(text: String, handler: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(440, 44)
	b.add_theme_font_size_override("font_size", 17)
	b.pressed.connect(handler)
	_button_box.add_child(b)


## 中文字体：Windows 上直接用系统自带的微软雅黑，避免中文显示成方块。
func _apply_font(ctrl: Control, bold: bool = false) -> void:
	var path := "C:/Windows/Fonts/msyhbd.ttc" if bold else "C:/Windows/Fonts/msyh.ttc"
	if FileAccess.file_exists(path):
		var f := FontFile.new()
		f.load_dynamic_font(path)
		ctrl.add_theme_font_override("font", f)
		return
	var fallback := "C:/Windows/Fonts/simhei.ttf"
	if FileAccess.file_exists(fallback):
		var f2 := FontFile.new()
		f2.load_dynamic_font(fallback)
		ctrl.add_theme_font_override("font", f2)


# ============================================================
# 按钮行为
# ============================================================

func _on_solo_pressed() -> void:
	# 单机：不建立会话，直接进关卡
	_start_game()


func _on_host_pressed() -> void:
	var err := NetManager.host_game(NetManager.PORT, "本地测试房")
	if err == OK:
		_status_label.text = "房间已创建。本机 IP：%s\n其他玩家在「加入房间」中输入该 IP 即可。" % _guess_local_ip()
		_start_game()
	else:
		_status_label.text = "创建房间失败，端口 %d 可能被占用。" % NetManager.PORT


func _on_join_toggle_pressed() -> void:
	_join_panel.visible = not _join_panel.visible
	if _join_panel.visible:
		_ip_field.grab_focus()


func _on_join_confirm() -> void:
	var ip := _ip_field.text.strip_edges()
	if ip.is_empty():
		_status_label.text = "请输入主机 IP。"
		return
	_status_label.text = "正在连接 %s:%d …" % [ip, NetManager.PORT]
	var err := NetManager.join_game(ip, NetManager.PORT)
	if err == OK:
		_start_game()
	else:
		_status_label.text = "连接请求发送失败（错误码 %d）。" % err


func _start_game() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var err := get_tree().change_scene_to_file(ARENA_SCENE)
	if err != OK:
		_status_label.text = "无法加载关卡场景 %s（错误码 %d）" % [ARENA_SCENE, err]
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# ============================================================
# 状态显示
# ============================================================

func _refresh_status() -> void:
	if _status_label == null:
		return
	if NetManager.is_session_active():
		var names: PackedStringArray = []
		for id: int in NetManager.get_sorted_peer_ids():
			names.append("%s(%d)" % [NetManager.get_peer_display_name(id), id])
		_status_label.text = "会话中（%s）  玩家：%s" % [
			"主机" if NetManager.is_host else "客户端", ", ".join(names)
		]
	else:
		_status_label.text = "当前为单机模式。本机 IP：%s\n提示：先在一台机器上「创建房间」，其他机器用该 IP「加入房间」。" % _guess_local_ip()


func _on_net_error(msg: String) -> void:
	if _status_label != null:
		_status_label.text = msg


func _on_session_started(is_host: bool) -> void:
	_refresh_status()
	if is_host:
		print("[菜单] 会话已建立，本机为主机。IP: %s" % _guess_local_ip())


## 猜一个本机局域网 IP，用于给玩家参考（不需要联网，纯本地枚举）
func _guess_local_ip() -> String:
	var ips := IP.get_local_addresses()
	for ip: String in ips:
		if ip.begins_with("192.168.") or ip.begins_with("10."):
			return ip
	for ip: String in ips:
		if ip.begins_with("172."):
			return ip
	return "127.0.0.1"
