#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""离线生成正式音效资源（WAV）。

【这个脚本负责什么】
  用 Python 标准库合成 14 个战斗音效 + 1 个 Boss 环境氛围音，
  写入 assets/audio/。`AudioManager._resolve_stream()` 会优先加载同名文件，
  所以生成后游戏重启即生效，不需要改任何加载逻辑。

【不负责什么】
  不做混音、不做 AudioBus 配置（那是 scripts/core/audio_bus_setup.gd 的事），
  也不碰模型/场景/武器的生成脚本。

【为什么不用 numpy】
  项目约定"不引入第三方依赖"，而且目标机器上不一定装了 numpy。
  本脚本总样本量不到 40 万，纯 Python 几秒就能跑完，不值得为此加依赖。

【为什么每个音都归一化到同一峰值】
  文件层面统一峰值、真正的响度差异交给 AudioManager.SFX_DEFS 里的
  `vol` 字段控制。如果让文件自身带上响度差异，两处相乘就会失控
  （例如 hit_execution 归一化到 0 dBFS 再乘 vol=0.0 会直接顶到天花板）。

用法：
  python -I tools/generate_audio.py            # 生成 + 校验
  python -I tools/generate_audio.py --verify   # 只校验已有文件
"""

import math
import os
import random
import struct
import sys
import wave

# 44100 Hz：比 22050 留出更多高频余量，挥空的"锋"、碎石的颗粒都需要
# 3k~9kHz 的干净频段；总时长约 4 秒，即便 16 位单声道也不足 400 KB。
SR = 44100
OUT_DIR = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "audio")
)


# ============================================================
# 基础 DSP 工具
# ============================================================

def white(n, rng):
    """白噪声：能量均匀铺满全频段。用于瞬态和颗粒。"""
    return [rng.uniform(-1.0, 1.0) for _ in range(n)]


def pink(n, rng):
    """粉噪声（Paul Kellet 近似）：低频能量更多，-3dB/oct。
    为什么需要它：风声/摩擦声的自然频谱接近粉噪声，
    纯白噪声听感"嘶嘶"的、很薄，做不出气流的重量。"""
    b0 = b1 = b2 = 0.0
    out = [0.0] * n
    for i in range(n):
        w = rng.uniform(-1.0, 1.0)
        b0 = 0.99765 * b0 + w * 0.0990460
        b1 = 0.96300 * b1 + w * 0.2965164
        b2 = 0.57000 * b2 + w * 1.0526913
        out[i] = (b0 + b1 + b2 + w * 0.1848) * 0.25
    return out


def lp1(x, cutoff, sr=SR):
    """单极点低通。cutoff 可以是常数，也可以是逐样本的列表（做滤波扫频）。
    系数用 1-exp(-2πfc/sr)：这是双线性变换的一阶近似，
    在 fc 远低于奈奎斯特时与原传递函数几乎重合，且绝不会不稳定。"""
    n = len(x)
    out = [0.0] * n
    y = 0.0
    if isinstance(cutoff, (int, float)):
        a = 1.0 - math.exp(-2.0 * math.pi * cutoff / sr)
        for i in range(n):
            y += a * (x[i] - y)
            out[i] = y
    else:
        for i in range(n):
            fc = max(20.0, min(cutoff[i], sr * 0.45))
            a = 1.0 - math.exp(-2.0 * math.pi * fc / sr)
            y += a * (x[i] - y)
            out[i] = y
    return out


def hp1(x, cutoff, sr=SR):
    """单极点高通 = 原信号减去低通部分。用于去掉不需要的低频"肉感"。"""
    low = lp1(x, cutoff, sr)
    return [x[i] - low[i] for i in range(len(x))]


def svf(x, cutoff, q=1.0, mode="bp", sr=SR):
    """Chamberlin 状态变量滤波器，支持逐样本变化的 cutoff。
    为什么不用双二阶 biquad：biquad 重算系数代价高、且扫频时相位不连续；
    SVF 的 cutoff 可以直接逐样本改，做"呼啸而过"的带通扫频非常稳。

    稳定性：要求 fc < sr/6（这里夹到 sr/7），q 不要超过 2。"""
    n = len(x)
    out = [0.0] * n
    low = 0.0
    band = 0.0
    fmax = sr / 7.0
    inv_q = 1.0 / max(0.05, q)
    const_fc = isinstance(cutoff, (int, float))
    if const_fc:
        f = 2.0 * math.sin(math.pi * min(cutoff, fmax) / sr)
    for i in range(n):
        if not const_fc:
            fc = min(max(cutoff[i], 20.0), fmax)
            f = 2.0 * math.sin(math.pi * fc / sr)
        hi = x[i] - low - inv_q * band
        band += f * hi
        low += f * band
        if mode == "bp":
            out[i] = band
        elif mode == "lp":
            out[i] = low
        else:
            out[i] = hi
    return out


def osc_sweep(n, f0, f1, curve=1.0, sr=SR):
    """带音高包络的正弦：频率从 f0 滑到 f1。

    必须用相位累加，不能写 sin(2πf(t)·t) —— 后者在 f 变化时会产生
    错误的瞬时频率（f 变化越快误差越大），听起来音高是"飘"的。"""
    out = [0.0] * n
    phase = 0.0
    inv = 1.0 / (n - 1) if n > 1 else 0.0
    for i in range(n):
        p = i * inv
        f = f0 + (f1 - f0) * (p ** curve)
        phase += 2.0 * math.pi * f / sr
        out[i] = math.sin(phase)
    return out


def tone_stack(n, f0, f1, detune_cents=15.0, voices=3, curve=1.0, sr=SR):
    """多个轻微失谐的振荡器叠加。
    单根正弦听起来"电子"，失谐产生的拍频会让声音变厚，
    这是合成"有体积的物体发出的声音"最省事的办法。"""
    out = [0.0] * n
    for v in range(voices):
        ratio = 2.0 ** (((v - (voices - 1) * 0.5) * detune_cents) / 1200.0)
        o = osc_sweep(n, f0 * ratio, f1 * ratio, curve, sr)
        for i in range(n):
            out[i] += o[i]
    k = 1.0 / max(1, voices)
    return [v * k for v in out]


def breakpoints(n, pts):
    """按归一化时间给出折线插值的参数曲线，用来描述"扫频轨迹"。
    pts 形如 [(0.0, 1800.0), (0.3, 5000.0), (1.0, 900.0)]，需按时间升序。"""
    out = [0.0] * n
    inv = 1.0 / (n - 1) if n > 1 else 0.0
    for i in range(n):
        p = i * inv
        val = pts[-1][1]
        for j in range(len(pts) - 1):
            t0, v0 = pts[j]
            t1, v1 = pts[j + 1]
            if p <= t1:
                fr = 0.0 if t1 <= t0 else (p - t0) / (t1 - t0)
                val = v0 + (v1 - v0) * fr
                break
        out[i] = val
    return out


def ad_exp(n, attack, tau, sr=SR):
    """线性起音 + 指数衰减的包络（打击类音效的主力包络）。
    与纯指数衰减的区别：起音段是显式的线性斜坡，
    否则冲击音的"顶点"会被指数曲线吃掉，听起来没有力度。"""
    na = max(1, int(attack * sr))
    out = [0.0] * n
    for i in range(n):
        if i < na:
            out[i] = i / na
        else:
            out[i] = math.exp(-(i - na) / (sr * tau))
    return out


def adsr(n, a, d, s, r, sr=SR):
    """标准 ADSR 包络（秒 + sustain 电平）。
    用于"下坠/氛围"这类需要持续段的声音；打击类用 ad_exp 更合适。"""
    out = [0.0] * n
    na = max(1, int(a * sr))
    nd = max(1, int(d * sr))
    nr = max(1, int(r * sr))
    total = na + nd + nr
    if total > n:  # 时长不够时按比例压缩各段，避免包络被截断
        k = n / float(total)
        na = max(1, int(na * k))
        nd = max(1, int(nd * k))
        nr = max(1, int(nr * k))
    ns = max(0, n - na - nd - nr)
    i = 0
    for j in range(na):
        if i >= n:
            break
        out[i] = j / na
        i += 1
    for j in range(nd):
        if i >= n:
            break
        out[i] = 1.0 + (s - 1.0) * (j / nd)
        i += 1
    for j in range(ns):
        if i >= n:
            break
        out[i] = s
        i += 1
    for j in range(nr):
        if i >= n:
            break
        out[i] = s * (1.0 - j / nr)
        i += 1
    return out


def arch_env(n, peak=0.42):
    """对称拱形包络（升 - 峰 - 降），用于"划过去"的动作类音效。"""
    out = [0.0] * n
    inv = 1.0 / (n - 1) if n > 1 else 0.0
    for i in range(n):
        p = i * inv
        if p < peak:
            out[i] = math.sin(0.5 * math.pi * (p / peak))
        else:
            q = (p - peak) / max(1e-6, 1.0 - peak)
            out[i] = math.sin(0.5 * math.pi * (1.0 - q))
    return out


def lfo_noise(n, rate, rng, sr=SR):
    """低速随机起伏（平滑插值的值噪声）。
    用途：给风声加"阵风"、给金属加音高抖动。
    没有它，长音会像电子音一样平稳得发假。"""
    step = sr / float(rate)
    m = int(n / step) + 3
    pts = [rng.uniform(0.0, 1.0) for _ in range(m)]
    out = [0.0] * n
    for i in range(n):
        pos = i / step
        k = int(pos)
        fr = pos - k
        a = pts[k]
        b = pts[k + 1]
        fr = fr * fr * (3.0 - 2.0 * fr)  # smoothstep，避免折线拐点出现的"棱角"
        out[i] = a + (b - a) * fr
    return out


def grain_gate(n, rate, rng, on_prob=0.55):
    """随机通断的门：把连续的噪声切成不连续的碎块，制造颗粒感。"""
    out = [0.0] * n
    step = max(1, int(SR / float(rate)))
    i = 0
    while i < n:
        ln = min(step, n - i)
        if rng.random() < on_prob:
            for j in range(ln):
                out[i + j] = 1.0
        i += ln
    return out


def soft_clip(x, drive=1.5):
    """tanh 软削波：轻微非线性失真。
    为什么需要它：真实的重击在空气/胸腔里会产生非线性压缩，
    纯线性叠加的低频听起来"软"；加一点失真才有"砸实了"的力度。
    除以 tanh(drive) 是为了把最大幅度仍归一到 1，方便后续统一处理。"""
    k = math.tanh(drive)
    if k < 1e-6:
        return list(x)
    return [math.tanh(v * drive) / k for v in x]


def mix(*layers):
    """等长叠加多个层（长度按最长者，短的补零）。"""
    n = max(len(l) for l in layers)
    out = [0.0] * n
    for l in layers:
        for i in range(len(l)):
            out[i] += l[i]
    return out


def apply_fades(x, in_ms=0.4, out_ms=8.0, sr=SR):
    """首尾淡入淡出。
    必须有：波形若不是从 0 开始、或结束时不为 0，播放时会产生"啪"的爆音。

    淡入只有 0.4ms（约 18 个样本）而不是常见的几毫秒：打击类音效的
    "力度"全在头 1~2ms 的瞬态上，淡入过长会把攻击感削平。
    0.4ms 的斜坡人耳听不出来，但足以消除直流跳变导致的爆音。"""
    n = len(x)
    ni = min(n // 2, max(1, int(in_ms * 0.001 * sr)))
    no = min(n // 2, max(1, int(out_ms * 0.001 * sr)))
    for i in range(ni):
        x[i] *= i / ni
    for i in range(no):
        x[n - 1 - i] *= i / no
    return x


def normalize(x, peak_dbfs=-1.0):
    """峰值归一化。留 1 dB 余量是为了给引擎端的音量/总线效果留头部空间，
    避免任何一级增益加上去就直接削波。"""
    peak = 0.0
    for v in x:
        a = abs(v)
        if a > peak:
            peak = a
    if peak < 1e-9:
        return list(x)
    target = 10.0 ** (peak_dbfs / 20.0)
    k = target / peak
    return [v * k for v in x]


# ============================================================
# 14 个音效的合成实现
# ============================================================

def build_swing_light(rng):
    """轻击挥空：高频"嗖"，起音快、衰减快。
    白噪声过时变带通，中心频率先冲到 5.6kHz 再快速回落——
    这是刀刃划过空气时的感受；再叠一条 3.4k→1.5k 的正弦滑音补"锋"。"""
    n = int(SR * 0.15)
    src = white(n, rng)
    fc = breakpoints(n, [(0.0, 1800.0), (0.28, 5600.0), (1.0, 1100.0)])
    band = svf(src, fc, q=1.7, mode="bp")
    env = ad_exp(n, 0.008, 0.030)
    tone = osc_sweep(n, 3400.0, 1500.0, curve=0.7)
    te = ad_exp(n, 0.004, 0.020)
    out = [band[i] * env[i] + tone[i] * te[i] * 0.28 for i in range(n)]
    return out


def build_swing_medium(rng):
    """中击挥空：比轻击低一档。
    中心频率峰值降到 3kHz，衰减时间常数拉长 60%。"""
    n = int(SR * 0.19)
    src = white(n, rng)
    fc = breakpoints(n, [(0.0, 900.0), (0.30, 3000.0), (1.0, 600.0)])
    band = svf(src, fc, q=1.3, mode="bp")
    env = ad_exp(n, 0.012, 0.048)
    tone = osc_sweep(n, 1400.0, 520.0, curve=0.8)
    te = ad_exp(n, 0.006, 0.028)
    out = [band[i] * env[i] + tone[i] * te[i] * 0.32 for i in range(n)]
    return out


def build_swing_heavy(rng):
    """重击挥空：低沉厚重的风声，必须有气流质感。
    气流质感来自"阵风"：用 7Hz 的低速随机起伏调制振幅。
    如果只用一条平滑包络，听起来是电子音而不是风。"""
    n = int(SR * 0.28)
    src = pink(n, rng)
    fc = breakpoints(n, [(0.0, 300.0), (0.35, 1050.0), (1.0, 220.0)])
    band = svf(src, fc, q=1.1, mode="bp")
    gust = lfo_noise(n, 7.0, rng)
    env = ad_exp(n, 0.028, 0.070)
    body = tone_stack(n, 190.0, 70.0, detune_cents=18.0, voices=3, curve=1.2)
    be = ad_exp(n, 0.020, 0.085)
    out = [0.0] * n
    for i in range(n):
        amp = env[i] * (0.60 + 0.55 * gust[i])
        out[i] = band[i] * amp + body[i] * be[i] * 0.55
    return lp1(out, 4000.0)  # 整体压暗，去掉多余的"嘶"


def build_swing_iai(rng):
    """居合挥空：极短极快的金属"铮"。
    用一组非谐分音（3.05k/5.15k/6.9k/8.8k）而不是单音——
    非整数倍分音是金属体振动的特征，越高频的分音衰减越快。"""
    n = int(SR * 0.11)
    out = [0.0] * n
    for f, tau in [(3050.0, 0.030), (5150.0, 0.021), (6900.0, 0.015), (8800.0, 0.010)]:
        e = ad_exp(n, 0.0015, tau)
        w = 2.0 * math.pi * f / SR
        for i in range(n):
            out[i] += math.sin(w * i) * e[i]
    burst = hp1(white(n, rng), 3500.0)
    be = ad_exp(n, 0.001, 0.009)
    for i in range(n):
        out[i] += burst[i] * be[i] * 0.7
    return out


def build_hit_light(rng):
    """轻击命中：短促清脆的"嗒"，高频冲击。
    三要素 —— 1ms 全频瞬态（"击打感"的来源）+ 1.5kHz 主体 + 空气噪声。"""
    n = int(SR * 0.10)
    out = [0.0] * n
    imp = [0.0] * n
    for i in range(min(60, n)):
        imp[i] = 1.0 - i / 60.0
    tone = osc_sweep(n, 1500.0, 820.0, curve=1.4)
    te = ad_exp(n, 0.002, 0.015)
    noise = hp1(white(n, rng), 2600.0)
    ne = ad_exp(n, 0.001, 0.013)
    for i in range(n):
        out[i] = imp[i] * 0.9 + tone[i] * te[i] * 0.8 + noise[i] * ne[i] * 0.55
    return out


def build_hit_medium(rng):
    """中击命中：比轻击更厚实。
    低频主体降到 280→150Hz，配合 3.5kHz 低通噪声爆。"""
    n = int(SR * 0.16)
    out = [0.0] * n
    body = tone_stack(n, 280.0, 150.0, detune_cents=22.0, voices=2, curve=1.3)
    be = ad_exp(n, 0.003, 0.042)
    noise = lp1(white(n, rng), 3500.0)
    ne = ad_exp(n, 0.001, 0.026)
    imp = [0.0] * n
    for i in range(min(80, n)):
        imp[i] = 1.0 - i / 80.0
    for i in range(n):
        out[i] = body[i] * be[i] + noise[i] * ne[i] * 0.8 + imp[i] * 0.7
    return out


def build_hit_heavy(rng):
    """重击命中：低频"咚" + 冲击噪声，要胸腔震动。
    关键取舍：噪声必须低通到 1.2kHz 以下。高频一旦多，"闷"就变成"脆"，
    胸腔震动感随即消失。再叠 58Hz 次低频拉长余韵。"""
    n = int(SR * 0.26)
    out = [0.0] * n
    thud = tone_stack(n, 135.0, 72.0, detune_cents=14.0, voices=3, curve=1.4)
    te = ad_exp(n, 0.004, 0.070)
    sub = [math.sin(2.0 * math.pi * 58.0 * i / SR) for i in range(n)]
    se = ad_exp(n, 0.006, 0.105)
    noise = lp1(white(n, rng), 1200.0)
    ne = ad_exp(n, 0.0015, 0.042)
    imp = [0.0] * n
    for i in range(min(120, n)):
        imp[i] = 1.0 - i / 120.0
    for i in range(n):
        out[i] = (thud[i] * te[i] + sub[i] * se[i] * 0.6
                  + noise[i] * ne[i] * 0.9 + imp[i] * 0.8)
    out = soft_clip(out, 1.5)
    return lp1(out, 3000.0)


def build_hit_execution(rng):
    """处决命中：最重最长，像骨头碎裂。
    与 hit_heavy 的差别不在音量而在"碎裂颗粒"：0.30 秒内随机撒 16 段
    6~20ms 的宽带噪声爆，模拟连续断裂；再叠一层 52Hz 次低频轰鸣。
    单靠低频做不出"碎"的感觉，必须有不规则的瞬态簇。"""
    n = int(SR * 0.52)
    out = [0.0] * n
    sub = [math.sin(2.0 * math.pi * 52.0 * i / SR) for i in range(n)]
    se = ad_exp(n, 0.005, 0.16)
    boom = tone_stack(n, 110.0, 46.0, detune_cents=16.0, voices=3, curve=1.5)
    be = ad_exp(n, 0.004, 0.125)
    rumble = lp1(pink(n, rng), 420.0)
    re = ad_exp(n, 0.020, 0.19)
    for i in range(n):
        out[i] = sub[i] * se[i] * 0.8 + boom[i] * be[i] + rumble[i] * re[i] * 0.7
    for _ in range(16):
        start = int(rng.uniform(0.0, 0.30) * SR)
        ln = int(rng.uniform(0.006, 0.020) * SR)
        end = min(n, start + ln)
        if end - start < 4:
            continue
        fc = rng.uniform(900.0, 4200.0)
        seg = svf(white(end - start, rng), fc, q=1.2, mode="bp")
        e = ad_exp(end - start, 0.0008, 0.006)
        amp = rng.uniform(0.5, 1.0)
        for j in range(end - start):
            out[start + j] += seg[j] * e[j] * amp
    return soft_clip(out, 1.6)


def build_hit_stone(rng):
    """命中石柱/墙：碎石"咔"，高频颗粒感。
    与血肉命中分界的两条硬规则：(1) 把能量全部放在 1.8kHz 以上；
    (2) 用随机门把噪声切成碎块并叠多次脆裂瞬态。
    血肉命中是"一下闷响"，石头是"连续崩裂"，两者必须一听就分得开。"""
    n = int(SR * 0.17)
    out = [0.0] * n
    g = hp1(white(n, rng), 1800.0)
    grain = lp1(grain_gate(n, 320.0, rng), 6000.0)
    ge = ad_exp(n, 0.0008, 0.042)
    for t0, amp in [(0.000, 1.0), (0.006, 0.75), (0.015, 0.52), (0.028, 0.36)]:
        s = int(t0 * SR)
        ln = min(int(0.006 * SR), n - s)
        if ln <= 2:
            continue
        seg = hp1(white(ln, rng), 2500.0)
        e = ad_exp(ln, 0.0003, 0.0030)
        for j in range(ln):
            out[s + j] += seg[j] * e[j] * amp
    for f, tau in [(2400.0, 0.011), (3900.0, 0.007)]:
        e = ad_exp(n, 0.0008, tau)
        w = 2.0 * math.pi * f / SR
        for i in range(n):
            out[i] += math.sin(w * i) * e[i] * 0.25
    for i in range(n):
        out[i] += g[i] * grain[i] * ge[i]
    out = hp1(out, 500.0)  # 兜底：确保没有任何低频"肉"成分
    # 颗粒噪声的偶发尖峰会把峰值顶得远高于主体，导致归一化后整体偏轻
    # （实测 RMS 只有 -19.5 dB，比其他命中音轻了 5 dB）。
    # 先自行归一到峰值 1.0，再用软削波把峰值相对主体压下来，
    # 波峰因数从 7.3 降到约 3，响度就和其他命中音对齐了。
    out = normalize(out, 0.0)
    out = soft_clip(out, 2.5)
    # 再补一道 12kHz 低通：颗粒噪声在 20kHz 附近有大量能量，
    # 采样点之间会出现接近满量程的跳变（实测相邻样本差 56860），
    # 听感上是一层刺耳的"嘶"。12kHz 以下保留全部碎石质感。
    return lp1(out, 12000.0)


def build_dodge(rng):
    """闪避：布料/气流"唰"，先升后降。
    包络走对称拱形、带通中心也走一条先升后降的弧线，两者同步才有
    "身体划过去"的运动感；只做包络拱形而固定频率会像一次鼓点。"""
    n = int(SR * 0.19)
    src = pink(n, rng)
    fc = breakpoints(n, [(0.0, 500.0), (0.45, 2600.0), (1.0, 400.0)])
    band = svf(src, fc, q=1.2, mode="bp")
    env = arch_env(n, 0.42)
    cloth = lp1(white(n, rng), 6000.0)
    ce = arch_env(n, 0.50)
    for i in range(n):
        band[i] = band[i] * env[i] + cloth[i] * ce[i] * 0.35
    return band


def build_died(rng):
    """玩家死亡：低沉下坠。
    这里用的是**真正的 ADSR**（带 sustain 段）而不是指数衰减：
    下坠需要在中段"撑住"一小会儿再释放，纯指数会散得太快、没有绝望感。
    音高曲线用 curve=1.6 让末尾掉得更急。"""
    n = int(SR * 0.65)
    body = tone_stack(n, 190.0, 48.0, detune_cents=20.0, voices=3, curve=1.6)
    be = adsr(n, 0.012, 0.180, 0.32, 0.42)
    sub = [math.sin(2.0 * math.pi * 46.0 * i / SR) for i in range(n)]
    se = ad_exp(n, 0.010, 0.28)
    breath = lp1(pink(n, rng), 900.0)
    bre = ad_exp(n, 0.050, 0.20)
    out = [body[i] * be[i] + sub[i] * se[i] * 0.7 + breath[i] * bre[i] * 0.45
           for i in range(n)]
    return soft_clip(out, 1.3)


def build_boss_swing(rng):
    """Boss 挥刀：极低频破空声。
    相对 swing_heavy 整体低一个八度、慢一倍：带通峰值只到 420Hz，
    主体是 150→52Hz 的下扫，配合 5Hz 阵风。听感是庞然大物在动。"""
    n = int(SR * 0.38)
    src = pink(n, rng)
    fc = breakpoints(n, [(0.0, 120.0), (0.40, 420.0), (1.0, 80.0)])
    band = svf(src, fc, q=1.4, mode="bp")
    gust = lfo_noise(n, 5.0, rng)
    env = ad_exp(n, 0.055, 0.095)
    body = tone_stack(n, 150.0, 52.0, detune_cents=22.0, voices=3, curve=1.2)
    be = ad_exp(n, 0.040, 0.125)
    out = [0.0] * n
    for i in range(n):
        out[i] = band[i] * env[i] * (0.55 + 0.65 * gust[i]) + body[i] * be[i] * 0.75
    return lp1(out, 1500.0)


def build_boss_hit(rng):
    """Boss 命中玩家：沉重的打击。
    比 hit_heavy 更低更闷（噪声低通 700Hz，整体低通 2.4kHz）、
    衰减更长、失真更重。它必须存在感强，因为这一下往往打掉半血。"""
    n = int(SR * 0.34)
    sub = [math.sin(2.0 * math.pi * 48.0 * i / SR) for i in range(n)]
    se = ad_exp(n, 0.005, 0.135)
    thud = tone_stack(n, 105.0, 50.0, detune_cents=18.0, voices=3, curve=1.3)
    te = ad_exp(n, 0.004, 0.090)
    noise = lp1(white(n, rng), 700.0)
    ne = ad_exp(n, 0.002, 0.058)
    imp = [0.0] * n
    for i in range(min(150, n)):
        imp[i] = 1.0 - i / 150.0
    out = [sub[i] * se[i] * 0.9 + thud[i] * te[i] + noise[i] * ne[i] * 0.8
           + imp[i] * 0.7 for i in range(n)]
    return lp1(soft_clip(out, 1.8), 2400.0)


def build_poise_break(rng):
    """架势破除：金属/盔甲崩裂。
    分音取 1 : 1.61 : 2.49 : 3.62 : 5.26（金属板的非谐振动比例），
    越高的分音衰减越快 —— 这正是真实金属从"亮"到"钝"的自然衰变。
    叠加 11Hz 的轻微音高抖动，避免听起来像呆板的加法合成器。"""
    n = int(SR * 0.58)
    base = 430.0
    ratios = [(1.0, 0.30), (1.61, 0.24), (2.49, 0.18), (3.62, 0.13), (5.26, 0.09)]
    out = [0.0] * n
    shimmer = lfo_noise(n, 11.0, rng)
    for k, (r, tau) in enumerate(ratios):
        e = ad_exp(n, 0.0015, tau)
        w = 2.0 * math.pi * base * r / SR
        g = 1.0 / (1.0 + k * 0.35)
        for i in range(n):
            out[i] += math.sin(w * i + 0.35 * shimmer[i]) * e[i] * g
    for t0, amp in [(0.0, 1.0), (0.055, 0.65)]:
        s = int(t0 * SR)
        ln = min(int(0.06 * SR), n - s)
        if ln <= 2:
            continue
        seg = hp1(white(ln, rng), 1200.0)
        e = ad_exp(ln, 0.0006, 0.012)
        for j in range(ln):
            out[s + j] += seg[j] * e[j] * amp * 1.2
    return soft_clip(out, 1.2)


def build_boss_ambient(rng):
    """Boss 战低频环境氛围，循环 6 秒。

    无缝循环的两个必要条件（缺一就会出现循环点的"咔"声）：
      1. 所有正弦频率吸附到 1/时长 的整数倍，保证首尾相位一致；
      2. 噪声床用"尾接首"交叉淡化，抹掉接缝处的不连续。
    氛围音归一化到 -3 dBFS 而不是 -1，给打击音留出动态余量。"""
    dur = 6.0
    n = int(SR * dur)

    def snap(f):
        return max(1.0, round(f * dur)) / dur

    out = [0.0] * n
    for f, amp in [(55.0, 1.0), (82.5, 0.5), (110.0, 0.35), (164.0, 0.18)]:
        f = snap(f)
        w = 2.0 * math.pi * f / SR
        for i in range(n):
            out[i] += math.sin(w * i) * amp
    bed = lp1(pink(n, rng), 500.0)
    swell = lfo_noise(n, 0.6, rng)
    for i in range(n):
        out[i] += bed[i] * (0.25 + 0.35 * swell[i])
    out = lp1(out, 1400.0)

    xf = int(0.4 * SR)
    for i in range(xf):
        t = i / xf
        out[i] = out[i] * t + out[n - xf + i] * (1.0 - t)
    return out[:n - xf]


# ============================================================
# 规格表：文件名 -> (构造函数, 归一化峰值 dBFS, 随机种子)
# 种子固定是为了让同一份脚本每次跑出完全相同的文件（可复现）。
# ============================================================

SPECS = [
    ("swing_light",   build_swing_light,   -1.0, 1001),
    ("swing_medium",  build_swing_medium,  -1.0, 1002),
    ("swing_heavy",   build_swing_heavy,   -1.0, 1003),
    ("swing_iai",     build_swing_iai,     -1.0, 1004),
    ("hit_light",     build_hit_light,     -1.0, 2001),
    ("hit_medium",    build_hit_medium,    -1.0, 2002),
    ("hit_heavy",     build_hit_heavy,     -1.0, 2003),
    ("hit_execution", build_hit_execution, -1.0, 2004),
    ("hit_stone",     build_hit_stone,     -1.0, 2005),
    ("dodge",         build_dodge,         -1.0, 3001),
    ("died",          build_died,          -1.0, 3002),
    ("boss_swing",    build_boss_swing,    -1.0, 4001),
    ("boss_hit",      build_boss_hit,      -1.0, 4002),
    ("poise_break",   build_poise_break,   -1.0, 4003),
    # Boss 环境氛围属于附加产物，不在 AudioManager.SFX_DEFS 里
    ("boss_ambient",  build_boss_ambient,  -3.0, 5001),
]


def write_wav(path, samples, sr=SR):
    """写 16 位单声道 PCM WAV。"""
    frames = bytearray()
    for v in samples:
        iv = int(round(max(-1.0, min(1.0, v)) * 32767.0))
        frames += struct.pack("<h", iv)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(bytes(frames))


def analyze(path):
    """读回 WAV 做客观校验：时长、峰值、RMS、削波样本数。"""
    with wave.open(path, "rb") as w:
        ch = w.getnchannels()
        sw = w.getsampwidth()
        fr = w.getframerate()
        nf = w.getnframes()
        raw = w.readframes(nf)
    cnt = len(raw) // 2
    vals = struct.unpack("<%dh" % cnt, raw)
    peak = 0
    sumsq = 0.0
    clipped = 0
    for v in vals:
        a = v if v >= 0 else -v
        if a > peak:
            peak = a
        if a >= 32767:
            clipped += 1
        sumsq += float(v) * float(v)
    rms = math.sqrt(sumsq / cnt) if cnt else 0.0
    peak_db = 20.0 * math.log10(peak / 32768.0) if peak > 0 else -999.0
    rms_db = 20.0 * math.log10(rms / 32768.0) if rms > 0 else -999.0
    crest = (peak / rms) if rms > 1e-9 else 0.0
    return {
        "name": os.path.basename(path),
        "channels": ch,
        "bits": sw * 8,
        "rate": fr,
        "frames": nf,
        "seconds": nf / float(fr),
        "peak_db": peak_db,
        "rms_db": rms_db,
        "crest": crest,
        "clipped": clipped,
        "bytes": os.path.getsize(path),
    }


def verify():
    """打印校验表。返回 (全部合格, 总字节数)。"""
    print("")
    print("========== 音效文件校验 ==========")
    print("%-18s %7s %8s %8s %7s %6s %9s" % (
        "文件", "时长s", "峰值dB", "RMS dB", "波峰因数", "削波", "大小KB"))
    ok = True
    total = 0
    for name, _fn, _peak, _seed in SPECS:
        path = os.path.join(OUT_DIR, name + ".wav")
        if not os.path.exists(path):
            print("%-18s  [缺失]" % name)
            ok = False
            continue
        r = analyze(path)
        total += r["bytes"]
        flags = ""
        if r["clipped"] > 0:
            flags += " 削波!"
            ok = False
        if r["channels"] != 1:
            flags += " 非单声道!"
            ok = False
        if r["bits"] != 16:
            flags += " 非16位!"
            ok = False
        print("%-18s %7.3f %8.2f %8.2f %7.2f %6d %9.1f%s" % (
            r["name"], r["seconds"], r["peak_db"], r["rms_db"],
            r["crest"], r["clipped"], r["bytes"] / 1024.0, flags))
    print("-" * 66)
    print("合计 %.1f KB（预算 1536 KB）" % (total / 1024.0))
    if total > 1536 * 1024:
        print("超预算！")
        ok = False
    print("结论：%s" % ("全部合格" if ok else "存在问题"))
    return ok, total


def main():
    # Windows 控制台默认用 GBK，中文日志会变成乱码。显式切成 UTF-8。
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass
    do_verify_only = "--verify" in sys.argv
    if not do_verify_only:
        if not os.path.isdir(OUT_DIR):
            os.makedirs(OUT_DIR)
        print("输出目录：%s" % OUT_DIR)
        for name, fn, peak_dbfs, seed in SPECS:
            rng = random.Random(seed)
            samples = fn(rng)
            samples = normalize(samples, peak_dbfs)
            samples = apply_fades(samples, 0.4, 8.0)
            path = os.path.join(OUT_DIR, name + ".wav")
            write_wav(path, samples)
            print("  生成 %-18s %6.3f s  %d 样本" % (
                name + ".wav", len(samples) / float(SR), len(samples)))
    ok, _ = verify()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
