extends SceneTree
## 生成音频总线布局 `res://default_bus_layout.tres`。
##
## 【这个脚本负责什么】
##   用 AudioServer 的运行时 API 搭好总线、挂上效果器，再调用
##   `generate_bus_layout()` 导出一份合法的 AudioBusLayout 资源。
##
## 【不负责什么】
##   不生成音效文件（那是 tools/generate_audio.py），不改任何游戏代码。
##
## 【为什么不直接手写 .tres】
##   项目约定（AGENTS.md 二.3）明确禁止手写 .tscn/.tres：
##   这类格式"语法正确但字段静默取默认值"的错误极难发现。
##   本脚本让引擎自己序列化，字段名与默认值都由引擎保证。
##
## 【为什么不放 Autoload】
##   任务要求尽量别碰 project.godot。Godot 的项目设置
##   `audio/buses/default_bus_layout` 默认值就是 `res://default_bus_layout.tres`，
##   所以把文件放在这个位置即可自动生效，一个字节的 project.godot 都不用改。
##
## 用法（项目根目录）：
##   godot --headless --script tools/generate_audio_buses.gd

const OUT_PATH := "res://default_bus_layout.tres"

## 总线定义：名字 -> 效果器列表
## 每个效果器是一个字典，键 "type" 是 AudioEffect 的子类名，其余键是属性。
const BUS_DEFS := [
	{
		"name": "Master",
		"fx": [
			{
				# 主输出只做"胶水"：轻微压缩，把连击时的多次冲击黏在一起，
				# 避免叠加瞬间顶到头。比率压得低（3:1）、起音留 12ms，
				# 这样单次攻击的瞬态不会被压平 —— 那正是打击感所在。
				"type": "AudioEffectCompressor",
				"threshold": -10.0,
				"ratio": 3.0,
				"attack_us": 12000.0,
				"release_ms": 140.0,
				"gain": 0.0,
			},
		],
	},
	{
		"name": "SFX",
		"fx": [
			{
				# 小房间混响：只给一点点湿声（0.13），目的是让"刀砍在空气里"
				# 和"砍在重甲上"都有个空间参照，而不是干巴巴地贴在耳边。
				# room_size 取 0.35 对应几米量级的竞技场尺度；
				# predelay 24ms 让直达声先到，混响不糊住瞬态。
				"type": "AudioEffectReverb",
				"room_size": 0.35,
				"damping": 0.55,
				"spread": 1.0,
				"predelay_msec": 24.0,
				"dry": 1.0,
				"wet": 0.13,
			},
			{
				# 打击专用压缩：阈值更低、起音更快，专门把重击的"胸腔震动"托起来。
				# 与 Master 的胶水压缩是两级串联，所以这里增益仍留 0 dB，
				# 靠增益分级（SFX_DEFS 里的 vol）控制响度，不在总线上加音量。
				"type": "AudioEffectCompressor",
				"threshold": -16.0,
				"ratio": 3.5,
				"attack_us": 3000.0,
				"release_ms": 90.0,
				"gain": 0.0,
			},
		],
	},
	{
		"name": "Ambient",
		"fx": [
			{
				# 环境氛围走更大的空间：Boss 战的低频轰鸣应该"铺满"场景，
				# 而不是像音效一样从一个点发出来。
				"type": "AudioEffectReverb",
				"room_size": 0.8,
				"damping": 0.6,
				"spread": 1.0,
				"predelay_msec": 40.0,
				"dry": 1.0,
				"wet": 0.30,
			},
		],
	},
]


func _init() -> void:
	var names: Array[String] = []
	for b: Dictionary in BUS_DEFS:
		names.append(String(b["name"]))

	# 先把总线数量摆好再改名：set_bus_count 只能增删，不能定义语义
	AudioServer.set_bus_count(names.size())
	for i in names.size():
		AudioServer.set_bus_name(i, names[i])
		if i > 0:
			AudioServer.set_bus_send(i, &"Master")
		else:
			# Master 没有上游总线，send 必须是空串
			AudioServer.set_bus_send(i, &"")
		AudioServer.set_bus_volume_db(i, 0.0)

	var failed: Array[String] = []
	for i in names.size():
		var def: Dictionary = BUS_DEFS[i]
		for fxd: Dictionary in def["fx"]:
			var type_name := String(fxd["type"])
			# 用 ClassDB 按名字实例化，避免为每种效果器写一个 match 分支
			if not ClassDB.class_exists(type_name):
				failed.append("%s: 引擎不认识效果器类型 %s" % [names[i], type_name])
				continue
			var fx: AudioEffect = ClassDB.instantiate(type_name) as AudioEffect
			if fx == null:
				failed.append("%s: %s 实例化失败" % [names[i], type_name])
				continue
			for key: String in fxd:
				if key == "type":
					continue
				if not _set_prop(fx, key, fxd[key]):
					failed.append("%s/%s: 没有属性 %s" % [names[i], type_name, key])
			AudioServer.add_bus_effect(i, fx)
			print("  总线 %-8s <- %s" % [names[i], type_name])

	if not failed.is_empty():
		for msg: String in failed:
			push_error("[音频总线] %s" % msg)
		print("生成失败，共 %d 处错误" % failed.size())
		quit(1)
		return

	var layout: AudioBusLayout = AudioServer.generate_bus_layout()
	var err := ResourceSaver.save(layout, OUT_PATH)
	if err != OK:
		push_error("[音频总线] 保存失败，错误码 %d" % err)
		quit(1)
		return
	print("已写入 %s（%d 条总线）" % [OUT_PATH, names.size()])
	print("运行时下列总线可用：%s" % ", ".join(names))
	quit(0)


## 按属性名写值；属性不存在时用 set() 会静默新建元数据，
## 所以先查 get_property_list() 确认，避免"看起来设了其实没生效"。
func _set_prop(obj: Object, prop: String, value: Variant) -> bool:
	for pd: Dictionary in obj.get_property_list():
		if String(pd["name"]) == prop:
			obj.set(prop, value)
			return true
	return false
