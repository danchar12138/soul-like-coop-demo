extends Node
## 运行时注册输入映射（InputMap）。
##
## 为什么不在 project.godot 里写 [input] 段？
## 见 docs/技术决策.md TD-003。简单说：手写 project.godot 的
## Object(InputEventKey, ...) 序列化格式极易出错且不可读，
## 用代码注册则集中、可读、便于后续做按键重绑定界面。
##
## 本项目动作列表（中文操作说明见 README.md）：
##   移动 / 闪避 / 冲刺 / 轻攻击 / 重攻击 / 锁定 / 交互 / 调试

## 键盘动作映射：动作名 -> 物理键码数组
## 使用物理键码（physical_keycode）以便支持非 QWERTY 键盘布局。
const KEY_ACTIONS := {
	&"move_forward": [KEY_W, KEY_UP],
	&"move_back": [KEY_S, KEY_DOWN],
	&"move_left": [KEY_A, KEY_LEFT],
	&"move_right": [KEY_D, KEY_RIGHT],
	&"dodge": [KEY_SPACE],
	&"sprint": [KEY_SHIFT],
	&"jump": [KEY_V],
	&"light_attack": [KEY_J],
	&"heavy_attack": [KEY_K],
	## 处决：在锁定目标架势被破除的窗口内按下即触发
	&"execute": [KEY_F],
	&"lock_on": [KEY_Q],
	&"interact": [KEY_E],
	&"toggle_debug": [KEY_F3],
	&"restart_level": [KEY_F5],
}

## 鼠标动作映射：动作名 -> 鼠标键码数组
const MOUSE_ACTIONS := {
	&"light_attack": [MOUSE_BUTTON_LEFT],
	&"heavy_attack": [MOUSE_BUTTON_RIGHT],
	&"lock_on": [MOUSE_BUTTON_MIDDLE],
	## 锁定目标切换用鼠标滚轮。
	## 【为什么不用方向键】锁定状态下 A/D 是横向绕圈走位的常用键，
	## 用它切目标会导致"每次横移都跳目标"，镜头乱甩（见 camera_rig.gd
	## 的 _handle_lock_switch 注释）。滚轮不和任何操作冲突。
	&"lock_switch_next": [MOUSE_BUTTON_WHEEL_UP],
	&"lock_switch_prev": [MOUSE_BUTTON_WHEEL_DOWN],
}

## 相机动作（鼠标轴，单独处理）
const CAMERA_ACTIONS := {
	&"camera_x": [],
	&"camera_y": [],
}


func _enter_tree() -> void:
	_register_all()


func _register_all() -> void:
	for action: StringName in KEY_ACTIONS:
		var events: Array = []
		for keycode: int in KEY_ACTIONS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = keycode
			events.append(ev)
		_add_action(action, events)

	for action: StringName in MOUSE_ACTIONS:
		var events: Array = []
		for button: int in MOUSE_ACTIONS[action]:
			var ev := InputEventMouseButton.new()
			ev.button_index = button
			events.append(ev)
		_add_action(action, events)


func _add_action(action: StringName, events: Array) -> void:
	if not InputMap.has_action(action):
		# deadzone 0.2：手柄摇杆用；键盘按键不受影响。
		InputMap.add_action(action, 0.2)
	for ev: InputEvent in events:
		# 幂等：重复注册同一事件会被跳过，避免热重载时重复叠加。
		if not InputMap.action_has_event(action, ev):
			InputMap.action_add_event(action, ev)


## 返回当前所有已注册动作名，供调试面板显示。
func get_registered_actions() -> Array[StringName]:
	var out: Array[StringName] = []
	out.assign(InputMap.get_actions())
	return out
