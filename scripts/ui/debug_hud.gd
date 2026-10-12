extends CanvasLayer
## 调试 HUD（Autoload 单例）：显示战斗状态、时序条、网络信息。
##
## 存在的意义：调战斗手感时，眼睛看动画是不够的。
## 需要同时看到：当前状态、攻击进度（起手/有效/收招）、精力余量、
## 命中停顿是否触发、网络延迟。否则调出来的手感经不起推敲。
##
## 快捷键：F3 切换显示。
## 正式版本中可通过 GameState.debug_enabled = false 关闭。

var _root: Control
var _label: RichTextLabel
var _enabled: bool = true
var _refresh_accum: float = 0.0
const REFRESH_INTERVAL := 0.05


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	EventBus.debug_toggled.connect(_on_debug_toggled)
	EventBus.net_error.connect(_on_net_error)
	EventBus.attack_landed.connect(_on_attack_landed)
	EventBus.poise_broken.connect(_on_poise_broken)

	# 默认开启，方便调参；发布时改 GameState.debug_enabled
	_enabled = GameState.debug_enabled
	_root.visible = _enabled


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "DebugRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var bg := PanelContainer.new()
	bg.set_anchors_preset(Control.PRESET_TOP_LEFT)
	bg.position = Vector2(12, 12)
	bg.custom_minimum_size = Vector2(430, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.08, 0.72)
	style.border_color = Color(0.35, 0.5, 0.7, 0.55)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10)
	bg.add_theme_stylebox_override("panel", style)
	_root.add_child(bg)

	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.custom_minimum_size = Vector2(410, 0)
	_label.add_theme_font_size_override("normal_font_size", 13)
	bg.add_child(_label)


func _process(delta: float) -> void:
	_refresh_accum += delta
	if _refresh_accum < REFRESH_INTERVAL:
		return
	_refresh_accum = 0.0
	if _enabled:
		_update_text()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.keycode == KEY_F3:
			_enabled = not _enabled
			_root.visible = _enabled
			GameState.debug_enabled = _enabled
			EventBus.debug_toggled.emit(_enabled)
			get_viewport().set_input_as_handled()


func _update_text() -> void:
	var lines: PackedStringArray = []
	lines.append("[b][color=#7fd4ff]── 战斗调试面板 (F3 隐藏) ──[/color][/b]")

	var p := GameState.local_player
	if p != null and is_instance_valid(p):
		lines.append(_format_player(p))
	else:
		lines.append("[color=#888]未找到本地玩家[/color]")

	# 锁定
	if GameState.locked_target != null and is_instance_valid(GameState.locked_target):
		lines.append("锁定: [color=#ffd479]%s[/color]" % GameState.locked_target.name)
		# 处决提示：这是玩家最需要知道的信息，放在锁定行下面
		var tp := GameState.locked_target.get_node_or_null("Poise") as PoiseComponent
		if tp != null and tp.is_broken:
			lines.append("[color=#ff5a5a][b]★ 可处决！按 F  剩余 %.1f 秒[/b][/color]" % tp.get_break_time_left())
	else:
		lines.append("锁定: 无")

	# Boss
	if GameState.boss != null and is_instance_valid(GameState.boss):
		lines.append("")
		lines.append("%s" % _format_boss(GameState.boss))

	# 网络
	lines.append("")
	lines.append("[b][color=#7fd4ff]网络[/color][/b]")
	lines.append("模式: %s" % ("离线" if not NetManager.is_session_active() else ("主机" if NetManager.is_host else "客户端")))
	lines.append("玩家数: %d / %d   Ping: %d ms" % [
		NetManager.peer_info.size(), NetManager.MAX_PLAYERS, _get_ping()
	])

	# 统计
	lines.append("")
	lines.append("[b][color=#7fd4ff]统计[/color][/b]")
	lines.append("阶段: %s   用时: %.1fs" % [GameState.phase_name(), GameState.stats["elapsed_time"]])
	lines.append("死亡: %d   累计伤害: %.0f" % [GameState.stats["deaths"], GameState.stats["damage_dealt"]])

	_label.text = "\n".join(lines)


func _format_player(p: Node3D) -> String:
	var out: PackedStringArray = []
	out.append("[b][color=#7fd4ff]玩家[/color][/b] [color=#a8ff9e]%s[/color]" % p.get("display_name"))

	var sm := p.get_node_or_null("StateMachine")
	if sm != null:
		var st: int = sm.call("get_state")
		var st_name: String = sm.call("get_state_name")
		var t: float = sm.get("time_in_state")
		out.append("状态: [color=#ffd479]%s[/color] (%.2fs)" % [st_name, t])

	var h := p.get_node_or_null("Health") as HealthComponent
	if h != null:
		out.append("生命: %s %.0f/%.0f" % [
			_make_bar(h.health / maxf(h.max_health, 1.0), 12, "#e05a5a"),
			h.health, h.max_health
		])

	var s := p.get_node_or_null("Stamina") as StaminaComponent
	if s != null:
		var ex := " [color=#ff9a4a]气竭[/color]" if s.is_exhausted else ""
		out.append("精力: %s %.0f/%.0f%s" % [
			_make_bar(s.current / maxf(s.max_stamina, 1.0), 12, "#5ad07a"),
			s.current, s.max_stamina, ex
		])

	var po := p.get_node_or_null("Poise") as PoiseComponent
	if po != null:
		out.append("架势: %s %.0f/%.0f" % [
			_make_bar(po.current / maxf(po.max_poise, 1.0), 12, "#6ab8ff"),
			po.current, po.max_poise
		])

	# 攻击时序（最关键的一行：起手/有效/收招用颜色区分）
	var ac := p.get_node_or_null("AttackController")
	if ac != null and ac.call("is_attacking"):
		out.append(_format_attack_timeline(ac))

	# 命中停顿
	var hs := p.get_node_or_null("HitstopManager")
	if hs != null and hs.call("is_active"):
		out.append("[color=#ff8aff]◆ 命中停顿中[/color]")

	var v: Vector3 = p.get("velocity")
	out.append("速度: %.1f m/s" % Vector2(v.x, v.z).length())
	return "\n".join(out)


func _format_attack_timeline(ac: Node) -> String:
	var atk: AttackData = ac.get("current_attack")
	if atk == null:
		return ""
	var el: float = ac.get("elapsed")
	var phase: int = ac.get("current_phase")
	var segs: PackedStringArray = []
	var slot := 0.045  # 每个单位时间格的宽度

	var w_cells := maxi(1, int(round(atk.windup / slot)))
	var a_cells := maxi(1, int(round(atk.active / slot)))
	var r_cells := maxi(1, int(round(atk.recovery / slot)))

	var phase_names: Array[String] = ["无", "起手", "有效判定", "收招"]
	var phase_colors: Array[String] = ["#888888", "#6ab8ff", "#ff5a5a", "#c8a04a"]
	var pi := clampi(phase, 0, 3)
	var phase_name: String = phase_names[pi]
	var phase_color: String = phase_colors[pi]

	segs.append("[color=#6ab8ff]%s[/color]" % "▉".repeat(w_cells))
	segs.append("[color=#ff5a5a]%s[/color]" % "▉".repeat(a_cells))
	segs.append("[color=#c8a04a]%s[/color]" % "▉".repeat(r_cells))

	return "攻击: [color=#fff]%s[/color] [color=%s]%s[/color] %.2f/%.2fs\n       %s" % [
		atk.display_name, phase_color, phase_name, el, atk.get_total_duration(),
		"".join(segs)
	]


func _format_boss(boss: Node3D) -> String:
	var out: PackedStringArray = []
	out.append("[b][color=#ff8a8a]Boss[/color][/b]")
	var h := boss.get_node_or_null("Health") as HealthComponent
	if h != null:
		out.append("生命: %s %.0f/%.0f" % [
			_make_bar(h.health / maxf(h.max_health, 1.0), 20, "#e05a5a"), h.health, h.max_health
		])
	var po := boss.get_node_or_null("Poise") as PoiseComponent
	if po != null:
		var br := " [color=#ff5a5a]★破防可处决 %.1fs[/color]" % po.get_break_time_left() if po.is_broken else ""
		out.append("架势: %s %.0f/%.0f%s" % [
			_make_bar(po.current / maxf(po.max_poise, 1.0), 20, "#6ab8ff"), po.current, po.max_poise, br
		])
	var sm := boss.get_node_or_null("StateMachine")
	if sm != null:
		out.append("状态: [color=#ffd479]%s[/color]" % sm.call("get_state_name"))
	var ai := boss.get_node_or_null("BossAI")
	if ai != null and ai.has_method("get_debug_string"):
		out.append(ai.call("get_debug_string"))
	return "\n".join(out)


## 用方块拼一个纯文本进度条
func _make_bar(ratio: float, width: int, color: String) -> String:
	ratio = clampf(ratio, 0.0, 1.0)
	var filled := int(round(ratio * width))
	return "[color=%s]%s[/color][color=#445]%s[/color]" % [
		color, "█".repeat(filled), "░".repeat(maxi(0, width - filled))
	]


## Godot 的高层 API 不直接暴露 ping。ENetMultiplayerPeer 提供
## get_peer(id).get_statistic()，其中 ENetPacketPeer.PEER_ROUND_TRIP_TIME
## 即往返延迟（毫秒）。这里取所有远端 peer 的最大值作为显示值。
func _get_ping() -> int:
	if not NetManager.is_session_active():
		return 0
	var peer := multiplayer.multiplayer_peer
	if peer == null or not (peer is ENetMultiplayerPeer):
		return 0
	var worst := 0
	for id: int in multiplayer.get_peers():
		var p := (peer as ENetMultiplayerPeer).get_peer(id)
		if p == null:
			continue
		var rtt: float = p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)
		worst = maxi(worst, int(round(rtt * 1000.0)))
	return worst


# ============================================================
# 事件提示（屏幕中上方短暂文字）
# ============================================================

var _toast_label: Label
var _toast_timer: float = 0.0


func _on_net_error(message: String) -> void:
	_show_toast(message, Color(1.0, 0.45, 0.4))


func _on_attack_landed(_a: Node, _t: Node, _pos: Vector3, _dmg: float, _w: float) -> void:
	if not GameConfig.DEBUG_PRINT_COMBAT_LOG:
		return


func _on_poise_broken(entity: Node, window: float) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	if entity == GameState.boss or (entity.get("peer_id") == null and entity.is_in_group(&"lockon_targets")):
		_show_toast("★ 架势破除！%.1f 秒内可处决" % window, Color(1.0, 0.8, 0.35))


func _show_toast(text: String, color: Color) -> void:
	if _toast_label == null:
		_toast_label = Label.new()
		_toast_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_toast_label.position = Vector2(-200, 90)
		_toast_label.custom_minimum_size = Vector2(400, 0)
		_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_toast_label.add_theme_font_size_override("font_size", 20)
		_toast_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_toast_label.add_theme_constant_override("outline_size", 5)
		_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(_toast_label)
	_toast_label.text = text
	_toast_label.add_theme_color_override("font_color", color)
	_toast_label.modulate.a = 1.0
	_toast_timer = 2.4


func _on_debug_toggled(enabled: bool) -> void:
	_enabled = enabled
	if _root != null:
		_root.visible = enabled


func _physics_process(delta: float) -> void:
	if _toast_timer > 0.0:
		_toast_timer -= delta
		if _toast_label != null:
			_toast_label.modulate.a = clampf(_toast_timer / 0.8, 0.0, 1.0)
