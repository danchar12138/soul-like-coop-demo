extends Node
## 音效资源与接线校验（无头运行）。
##
## 用法：
##   godot --headless res://tests/audio_test.tscn
##
## 校验内容：
##   S1  SFX_DEFS 里的每个键都能解析成一个**真实的 WAV 文件**（不是合成占位音）
##   S2  每个 WAV 的实际音频参数正确（采样率 / 声道 / 时长 / 无削波）
##   S3  音效接线确实生效：发一个 attack_started 事件能看到播放被调用
##   S4  关键音效的**变频可辨识性**：轻击与重击的频谱质心必须有明显差距
##
## S1 是重点。`AudioManager._resolve_stream()` 会优先加载
## `assets/audio/<键>.wav`，找不到才回退到程序合成的占位音。
## 所以"文件存在"这件事必须在测试里确认 —— 否则很容易出现
## "以为换了正式音效、其实一直在用合成音"的情况。

const AUDIO_DIR := "res://assets/audio/"

var _results: Array[Dictionary] = []
var _passed := 0
var _failed := 0


func _ready() -> void:
	print("========== 音效校验 ==========")
	_run()
	await _run_playback_check()
	_report()
	get_tree().quit(0 if _failed == 0 else 1)


func _run() -> void:
	var defs: Dictionary = AudioManager.SFX_DEFS
	var missing: PackedStringArray = []
	var stats: PackedStringArray = []
	var bad_params: PackedStringArray = []
	var clipped: PackedStringArray = []

	for key: StringName in defs:
		var name_str := String(key)
		# 优先 .wav，其次 .ogg（与 AudioManager._resolve_stream 一致）
		var found := ""
		for ext: String in [".wav", ".ogg"]:
			if ResourceLoader.exists(AUDIO_DIR + name_str + ext):
				found = AUDIO_DIR + name_str + ext
				break
		if found.is_empty():
			missing.append(name_str)
			continue

		var stream: Variant = load(found)
		if not (stream is AudioStream):
			bad_params.append("%s(无法作为 AudioStream 加载)" % name_str)
			continue

		var info := _inspect(stream as AudioStream, name_str)
		stats.append("%s: %.2fs %dHz %s 峰值%.2f%s" % [
			name_str, info["length"], info["mix_rate"],
			"单声道" if info["mono"] else "立体声",
			info["peak"],
			" [削波]" if info["clipped"] else ""])
		if info["mix_rate"] < 22050:
			bad_params.append("%s(采样率过低 %dHz)" % [name_str, info["mix_rate"]])
		if info["length"] < 0.03:
			bad_params.append("%s(时长过短 %.3fs)" % [name_str, info["length"]])
		if info["clipped"]:
			clipped.append(name_str)

	_check("S1 SFX_DEFS 的每个键都有正式音频文件", missing.is_empty(),
		"缺失 %d 个：%s" % [missing.size(),
			"无" if missing.is_empty() else ", ".join(missing)])

	_check("S2 音频参数合理（采样率 ≥22050、时长 ≥0.03s、无削波）",
		bad_params.is_empty() and clipped.is_empty(),
		"参数异常：%s；削波：%s" % [
			"无" if bad_params.is_empty() else ", ".join(bad_params),
			"无" if clipped.is_empty() else ", ".join(clipped)])

	print("      音频文件清单（共 %d 个）：" % stats.size())
	for s in stats:
		print("        " + s)


## 检查一个音频流的参数。返回的 peak 是实测峰值（0~1）。
func _inspect(stream: AudioStream, label: String) -> Dictionary:
	var out := {
		"length": stream.get_length(),
		"mix_rate": 0,
		"mono": true,
		"peak": 0.0,
		"clipped": false,
	}
	var wav := stream as AudioStreamWAV
	if wav == null:
		# .ogg 之类：只能拿到时长
		return out

	out["mix_rate"] = wav.mix_rate
	out["mono"] = wav.stereo == false
	var data := wav.data
	if data.is_empty():
		return out

	# 16 位小端有符号 PCM
	var peak := 0
	var clip_count := 0
	if wav.format == AudioStreamWAV.FORMAT_16_BITS:
		var n := data.size() / 2
		for i in n:
			var v := data.decode_s16(i * 2)
			var a := absi(v)
			if a > peak:
				peak = a
			if a >= 32767:
				clip_count += 1
	elif wav.format == AudioStreamWAV.FORMAT_8_BITS:
		for i in data.size():
			var a := absi(int(data[i]) - 128)
			if a > peak:
				peak = a
			if a >= 127:
				clip_count += 1

	if wav.format == AudioStreamWAV.FORMAT_16_BITS:
		out["peak"] = float(peak) / 32767.0
	else:
		out["peak"] = float(peak) / 127.0
	# 少量削波样本是正常的（峰值归一化本来就会顶到上限），
	# 只有超过 0.1% 才算问题
	out["clipped"] = clip_count > maxi(4, data.size() / 1000)
	return out


## S3/S4：接线与可辨识性
func _run_playback_check() -> void:
	# S3：发一个攻击事件，确认接线器确实响应了
	var before: int = AudioFeedback.played_swings
	var dummy_attacker := Node3D.new()
	dummy_attacker.name = "FakeAttacker"
	var ac := Node.new()
	ac.name = "AttackController"
	dummy_attacker.add_child(ac)
	add_child(dummy_attacker)
	await get_tree().process_frame

	EventBus.attack_started.emit(dummy_attacker, &"katana_light_1")
	await get_tree().process_frame
	var after: int = AudioFeedback.played_swings
	_check("S3 攻击事件能触发音效播放", after > before,
		"played_swings %d -> %d" % [before, after])

	dummy_attacker.queue_free()

	# S4：轻击与重击的频谱差异。
	# 用零交叉率（zero-crossing rate）做粗略的"高频含量"估计 ——
	# 它不需要 FFT，实现简单，而且对"高频 vs 低频"的区分足够可靠：
	# 高频信号单位时间内穿过零点的次数明显更多。
	var zcr_light := _zero_crossing_rate(&"hit_light")
	var zcr_heavy := _zero_crossing_rate(&"hit_heavy")
	_check("S4 轻击与重击的高频含量有明显差异（可听辨）",
		zcr_light > zcr_heavy * 1.5,
		"零交叉率：轻击 %.0f/s vs 重击 %.0f/s（比值 %.2f，需 >1.5）" % [
			zcr_light, zcr_heavy,
			zcr_light / maxf(zcr_heavy, 1.0)])

	# 石头与血肉也要能区分
	var zcr_stone := _zero_crossing_rate(&"hit_stone")
	_check("S5 命中石头与命中血肉的听感有明显差异",
		zcr_stone > zcr_heavy * 1.5,
		"零交叉率：石头 %.0f/s vs 重击 %.0f/s（比值 %.2f）" % [
			zcr_stone, zcr_heavy, zcr_stone / maxf(zcr_heavy, 1.0)])


## 计算音频前 60ms 的零交叉率（每秒过零次数），作为高频含量的粗略指标。
## 只看前 60ms 是因为那一段包含了绝大部分瞬态信息。
func _zero_crossing_rate(key: StringName) -> float:
	var wav := load(AUDIO_DIR + String(key) + ".wav") as AudioStreamWAV
	if wav == null or wav.format != AudioStreamWAV.FORMAT_16_BITS:
		return 0.0
	var data := wav.data
	var n := mini(data.size() / 2, int(wav.mix_rate * 0.06))
	if n < 2:
		return 0.0
	var crossings := 0
	var prev := data.decode_s16(0) >= 0
	for i in range(1, n):
		var cur := data.decode_s16(i * 2) >= 0
		if cur != prev:
			crossings += 1
			prev = cur
	# 换算成每秒
	return float(crossings) * float(wav.mix_rate) / float(n)


func _check(name: String, ok: bool, detail: String = "") -> void:
	_results.append({"name": name, "ok": ok, "detail": detail})
	if ok:
		_passed += 1
		print("  [通过] %s  %s" % [name, detail])
	else:
		_failed += 1
		print("  [失败] %s  %s" % [name, detail])


func _report() -> void:
	var lines: PackedStringArray = []
	lines.append("音效校验时间：%s" % Time.get_datetime_string_from_system())
	lines.append("结果：通过 %d / 失败 %d / 共 %d" % [_passed, _failed, _results.size()])
	lines.append("")
	for r: Dictionary in _results:
		lines.append("%s %s  %s" % [
			"[通过]" if r["ok"] else "[失败]", r["name"], r["detail"]])
	var text := "\n".join(lines)
	print("\n========== 音效校验报告 ==========")
	print(text)
	print("==================================")
	var f := FileAccess.open("res://tests/音效校验结果.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
