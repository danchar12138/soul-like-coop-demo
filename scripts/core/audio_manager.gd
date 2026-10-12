extends Node
## 音效管理器（Autoload 单例）。
##
## 当前状态：**已有正式音效文件**（14 个 WAV，位于 assets/audio/），
## 由 `tools/generate_audio.py` 离线生成。这些是**程序合成的素材**，
## 不是专业录音棚素材 —— 可辨、够用，但音色上限有限。
##
## 加载策略（`_resolve_stream`）：优先加载 `res://assets/audio/<键>.wav`
## 或 `.ogg`，找不到才退回下面 `SFX_DEFS` 里的运行时合成占位音。
## 所以文件缺失时游戏仍然有声音，不会静音。
##
## 合成占位音的做法（仅在文件缺失时使用）：用代码合成 AudioStreamWAV 波形。
##   - 轻击命中：短促的高频噪声爆 + 快速衰减（"嗒"）
##   - 重击命中：低频冲击 + 长一点的衰减（"咚"）
##   - 砍石头：带金属/碎石感的噪声（"咔"）
##   - 挥空：一段有音高滑落的风声
##   - 闪避：短促的低频"唰"
##
## 总线：一次性音效的播放器统一挂到 "SFX" 总线（带混响 + 压缩），
## 总线布局见 `default_bus_layout.tres`，生成脚本 `tools/generate_audio_buses.gd`。
## Boss 战的环境氛围音不走这里，由 `boss_greatsword.gd` 自建播放器，见该文件。

const SAMPLE_RATE := 22050
## 同时播放的音效数量上限（防止连打时爆音）
const MAX_VOICES := 16

## 音效定义表：键 -> {build: 生成函数名, volume_db: 音量}
## 如果 assets/audio/<key>.wav 存在，优先使用文件。
const SFX_DEFS := {
	&"swing_light":   {"gen": "swing",  "freq": 900.0,  "dur": 0.13, "vol": -14.0},
	&"swing_medium":  {"gen": "swing",  "freq": 620.0,  "dur": 0.18, "vol": -11.0},
	&"swing_heavy":   {"gen": "swing",  "freq": 380.0,  "dur": 0.26, "vol": -8.0},
	&"swing_iai":     {"gen": "swing",  "freq": 1500.0, "dur": 0.10, "vol": -10.0},
	&"hit_light":     {"gen": "hit",    "freq": 1500.0, "dur": 0.09, "vol": -7.0},
	&"hit_medium":    {"gen": "hit",    "freq": 950.0,  "dur": 0.14, "vol": -5.0},
	&"hit_heavy":     {"gen": "hit",    "freq": 520.0,  "dur": 0.22, "vol": -3.0},
	&"hit_execution": {"gen": "hit",    "freq": 260.0,  "dur": 0.40, "vol": 0.0},
	&"hit_stone":     {"gen": "stone",  "freq": 2400.0, "dur": 0.16, "vol": -6.0},
	&"dodge":         {"gen": "dodge",  "freq": 300.0,  "dur": 0.16, "vol": -12.0},
	&"died":          {"gen": "death",  "freq": 200.0,  "dur": 0.60, "vol": -2.0},
	&"boss_swing":    {"gen": "swing",  "freq": 240.0,  "dur": 0.34, "vol": -4.0},
	&"boss_hit":      {"gen": "hit",    "freq": 380.0,  "dur": 0.30, "vol": -1.0},
	&"poise_break":   {"gen": "hit",    "freq": 180.0,  "dur": 0.55, "vol": 0.0},
}

var _cache: Dictionary = {}
var _player_pool: Array[AudioStreamPlayer3D] = []
var _ui_pool: Array[AudioStreamPlayer] = []
var _next_voice: int = 0

## 玩家周围在这个距离内才能听到 3D 音效
const MAX_AUDIBLE_DISTANCE := 32.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_prepare_all()


func _prepare_all() -> void:
	for key: StringName in SFX_DEFS:
		_cache[key] = _resolve_stream(key)

	# 所有一次性音效走 "SFX" 总线：混响 + 压缩在总线布局里，
	# 不这么做它们会直接进 Master，效果的开关就不受总线控制。
	# 布局缺失时 get_bus_index 返回 -1，此时保持引擎默认的 "Master"，
	# 声音仍然正常，只是没有那点空间感 —— 音频资源缺失不该影响可玩性。
	var sfx_bus := AudioServer.get_bus_index(&"SFX")
	var bus_name := &"SFX" if sfx_bus >= 0 else &"Master"

	# 预建 3D 播放器池
	for i in MAX_VOICES:
		var p := AudioStreamPlayer3D.new()
		p.name = "Voice%d" % i
		p.bus = bus_name
		p.max_distance = MAX_AUDIBLE_DISTANCE
		p.unit_size = 6.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_player_pool.append(p)

	# 2D 播放器（UI、无位置音效）
	for i in 4:
		var p := AudioStreamPlayer.new()
		p.bus = bus_name
		add_child(p)
		_ui_pool.append(p)


## 加载或合成一个音效流
func _resolve_stream(key: StringName) -> AudioStream:
	# 1) 优先用正式资源（如果之后放了文件，自动生效）
	for ext: String in [".wav", ".ogg"]:
		var path := "res://assets/audio/%s%s" % [key, ext]
		if ResourceLoader.exists(path):
			var res: Variant = load(path)
			if res is AudioStream:
				return res as AudioStream
	# 2) 合成占位音
	var def: Dictionary = SFX_DEFS.get(key, {})
	if def.is_empty():
		return null
	return _synthesize(def)


## 播放 3D 音效（世界位置）
static func play_3d(key: StringName, position: Vector3, pitch_variation: float = 0.08) -> void:
	var mgr := _instance()
	if mgr == null:
		return
	mgr._play_3d(key, position, pitch_variation)


## 播放无位置音效（UI、调试提示）
static func play_ui(key: StringName) -> void:
	var mgr := _instance()
	if mgr == null:
		return
	mgr._play_ui(key)


static func _instance() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("AudioManager")


func _play_3d(key: StringName, position: Vector3, pitch_variation: float) -> void:
	var stream: AudioStream = _cache.get(key)
	if stream == null:
		return
	var def: Dictionary = SFX_DEFS.get(key, {})
	var p := _next_player()
	if p == null:
		return
	p.global_position = position
	p.stream = stream
	p.volume_db = def.get("vol", -6.0)
	p.pitch_scale = 1.0 + randf_range(-pitch_variation, pitch_variation)
	p.play()


func _play_ui(key: StringName) -> void:
	var stream: AudioStream = _cache.get(key)
	if stream == null:
		return
	for p: AudioStreamPlayer in _ui_pool:
		if not p.playing:
			p.stream = stream
			p.volume_db = SFX_DEFS.get(key, {}).get("vol", -6.0)
			p.play()
			return


## 轮询取一个空闲播放器；都忙则复用最老的
func _next_player() -> AudioStreamPlayer3D:
	if _player_pool.is_empty():
		return null
	for i in _player_pool.size():
		var idx := (_next_voice + i) % _player_pool.size()
		if not _player_pool[idx].playing:
			_next_voice = (idx + 1) % _player_pool.size()
			return _player_pool[idx]
	var fallback := _player_pool[_next_voice]
	_next_voice = (_next_voice + 1) % _player_pool.size()
	return fallback


# ============================================================
# 程序化合成（占位音）
# ============================================================

func _synthesize(def: Dictionary) -> AudioStreamWAV:
	var kind: String = def.get("gen", "hit")
	var freq: float = def.get("freq", 800.0)
	var dur: float = def.get("dur", 0.15)
	match kind:
		"swing": return _gen_swing(freq, dur)
		"hit": return _gen_hit(freq, dur)
		"stone": return _gen_stone(freq, dur)
		"dodge": return _gen_dodge(freq, dur)
		"death": return _gen_death(freq, dur)
	return _gen_hit(freq, dur)


## 生成一个 AudioStreamWAV，samples 为 -1..1 的浮点数组
func _make_wav(samples: PackedFloat32Array, loop: bool = false) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		var v := clampf(samples[i], -1.0, 1.0)
		# 16 位有符号小端
		var iv := int(v * 32767.0)
		bytes.encode_s16(i * 2, iv)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = bytes
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD if loop else AudioStreamWAV.LOOP_DISABLED
	return wav


## 挥砍声：噪声 + 频率下扫的正弦，快速衰减
func _gen_swing(freq: float, dur: float) -> AudioStreamWAV:
	var n := int(SAMPLE_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / SAMPLE_RATE
		var prog := t / dur
		# 频率从 freq 下扫到 freq*0.35
		var f := freq * lerpf(1.0, 0.35, prog)
		var env := pow(1.0 - prog, 1.6) * 0.5
		# 噪声成分让"呼呼"声更真实
		var noise := randf_range(-1.0, 1.0) * 0.55
		var tone := sin(TAU * f * t)
		out[i] = (tone * 0.45 + noise * 0.55) * env
	return _make_wav(out)


## 命中声：低频冲击 + 短噪声爆，指数衰减
func _gen_hit(freq: float, dur: float) -> AudioStreamWAV:
	var n := int(SAMPLE_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / SAMPLE_RATE
		var prog := t / dur
		var env := exp(-prog * 7.0)
		# 冲击体：频率随时间下降，产生"闷"感
		var f := freq * lerpf(1.0, 0.5, prog)
		var body := sin(TAU * f * t) * 0.8
		# 攻击瞬间的噪声（只有前 15% 时间）
		var burst := 0.0
		if prog < 0.15:
			burst = randf_range(-1.0, 1.0) * (1.0 - prog / 0.15) * 0.9
		out[i] = (body + burst) * env
	return _make_wav(out)


## 砍石头：高频噪声 + 短促金属感
func _gen_stone(freq: float, dur: float) -> AudioStreamWAV:
	var n := int(SAMPLE_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / SAMPLE_RATE
		var prog := t / dur
		var env := exp(-prog * 11.0)
		var noise := randf_range(-1.0, 1.0)
		# 两个不和谐的高频正弦，"咔"的感觉
		var ring := sin(TAU * freq * t) * 0.4 + sin(TAU * freq * 1.71 * t) * 0.3
		out[i] = (noise * 0.5 + ring) * env
	return _make_wav(out)


## 闪避：低频气流划过
func _gen_dodge(freq: float, dur: float) -> AudioStreamWAV:
	var n := int(SAMPLE_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / SAMPLE_RATE
		var prog := t / dur
		# 先升后降的包络，像"唰"地划过
		var env := sin(PI * clampf(prog * 1.15, 0.0, 1.0)) * 0.5
		var f := freq * lerpf(0.7, 1.8, prog)
		var noise := randf_range(-1.0, 1.0) * 0.7
		out[i] = (sin(TAU * f * t) * 0.3 + noise * 0.7) * env
	return _make_wav(out)


## 死亡：低沉下坠
func _gen_death(freq: float, dur: float) -> AudioStreamWAV:
	var n := int(SAMPLE_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / SAMPLE_RATE
		var prog := t / dur
		var env := exp(-prog * 2.4)
		var f := freq * lerpf(1.0, 0.22, prog)
		var tone := sin(TAU * f * t) * 0.7
		var noise := randf_range(-1.0, 1.0) * 0.25 * (1.0 - prog)
		out[i] = (tone + noise) * env
	return _make_wav(out)
