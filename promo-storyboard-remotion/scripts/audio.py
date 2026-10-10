"""Score + SFX for the ScreenTake promo, synthesised with numpy.

python3 scripts/audio.py  ->  public/audio/score.wav, public/audio/score-vertical.wav

150 BPM, Am-F-C-G per bar. Music style follows the scene under the playhead,
so the vertical cut gets its own continuous bed instead of spliced chunks.
SFX come straight from the cue names in src/lib/timeline.json.
"""
import json
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
TLJ = json.loads((ROOT / "src/lib/timeline.json").read_text())
SR = 48000
BEAT = 60 / TLJ["bpm"]
BAR = BEAT * 4
rng = np.random.default_rng(7)


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


# A minor loop: Am F C G (root, chord tones as MIDI).
PROG = [(45, [57, 60, 64]), (41, [57, 60, 65]), (48, [55, 60, 64]), (43, [55, 59, 62])]
FINAL = (36, [48, 55, 62, 64, 67, 74])  # Cadd9


def t_arr(dur):
    return np.arange(int(dur * SR)) / SR


def env(n, a, d, sustain=0.0, rel=None):
    """Attack/exp-decay envelope over n samples."""
    t = np.arange(n) / SR
    e = np.minimum(1, t / max(a, 1e-4)) * (sustain + (1 - sustain) * np.exp(-t / max(d, 1e-4)))
    if rel:
        k = int(rel * SR)
        if k < n:
            e[-k:] *= np.linspace(1, 0, k)
    return e


def band(x, lo, hi):
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    m = ((f >= lo) & (f <= hi)).astype(float)
    # soft edges
    m = np.convolve(m, np.ones(31) / 31, mode="same")
    return np.fft.irfft(X * m, len(x))


def noise(dur):
    return rng.standard_normal(int(dur * SR))


def saw(freq, dur, harm=8, detune=0.0):
    t = t_arr(dur)
    y = np.zeros_like(t)
    for k in range(1, harm + 1):
        if freq * k > 16000:
            break
        y += np.sin(2 * np.pi * freq * k * (1 + detune) * t) / k
    return y


class Bus:
    def __init__(self, dur):
        self.L = np.zeros(int(dur * SR) + SR * 3)
        self.R = np.zeros_like(self.L)

    def add(self, at, y, gain=1.0, pan=0.0):
        i = int(at * SR)
        if i < 0:
            y = y[-i:]
            i = 0
        n = min(len(y), len(self.L) - i)
        if n <= 0:
            return
        l = np.cos((pan + 1) * np.pi / 4) * np.sqrt(2)
        r = np.sin((pan + 1) * np.pi / 4) * np.sqrt(2)
        self.L[i : i + n] += y[:n] * gain * l
        self.R[i : i + n] += y[:n] * gain * r


# ---------- instruments ----------
def kick():
    t = t_arr(0.35)
    f = 45 + 95 * np.exp(-t / 0.03)
    ph = 2 * np.pi * np.cumsum(f) / SR
    return np.sin(ph) * np.exp(-t / 0.16) + band(noise(0.35), 2000, 8000) * np.exp(-t / 0.004) * 0.3


def clap():
    n = noise(0.25)
    t = t_arr(0.25)
    e = np.exp(-t / 0.07) * (1 + 0.6 * (np.sin(t * 2 * np.pi * 90) > 0) * (t < 0.03))
    return band(n, 900, 7000) * e * 0.6


def hat(open_=False):
    d = 0.18 if open_ else 0.05
    t = t_arr(d)
    return band(noise(d), 7000, 16000) * np.exp(-t / (0.05 if open_ else 0.012))


def bass(note, dur):
    y = saw(midi(note), dur, harm=6) + 0.6 * np.sin(2 * np.pi * midi(note - 12) * t_arr(dur))
    return y * env(len(y), 0.004, dur * 0.7, 0.3, rel=0.02) * 0.5


def pad(notes, dur, bright=6):
    L = np.zeros(int(dur * SR))
    R = np.zeros_like(L)
    for n in notes:
        L += saw(midi(n), dur, bright, -0.004)
        R += saw(midi(n), dur, bright, 0.004)
    e = env(len(L), min(0.5, dur * 0.4), 99, 1, rel=min(0.4, dur * 0.3))
    return L * e / len(notes), R * e / len(notes)


def pluck(note, dur=0.3):
    t = t_arr(dur)
    f = midi(note)
    y = np.sin(2 * np.pi * f * t) + 0.35 * np.sin(2 * np.pi * 2 * f * t) * np.exp(-t / 0.04) + 0.15 * np.sin(2 * np.pi * 3 * f * t) * np.exp(-t / 0.02)
    return y * np.exp(-t / 0.09) * np.minimum(1, t / 0.002)


def bell(note, dur=0.9):
    t = t_arr(dur)
    f = midi(note)
    y = np.sin(2 * np.pi * f * t + 1.8 * np.sin(2 * np.pi * f * 3.5 * t) * np.exp(-t / 0.15))
    return y * np.exp(-t / (dur * 0.35)) * np.minimum(1, t / 0.002)


def sweep(f0, f1, dur, shape=1.0):
    t = t_arr(dur)
    f = f0 * (f1 / f0) ** ((t / dur) ** shape)
    return np.sin(2 * np.pi * np.cumsum(f) / SR)


# ---------- SFX ----------
def whoosh(dur=0.55):
    n = noise(dur)
    t = t_arr(dur)
    y = band(n, 300, 1400) * 0.6 + band(n, 1400, 6000) * 0.4 * (t / dur)
    e = np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 2
    return y * e


def sfx(name):
    if name == "tick":
        t = t_arr(0.05)
        return (np.sin(2 * np.pi * 2600 * t) * np.exp(-t / 0.006) + band(noise(0.05), 4000, 12000) * np.exp(-t / 0.003) * 0.4) * 0.5, 0.0
    if name == "click":
        t = t_arr(0.08)
        return (np.sin(2 * np.pi * 1900 * t) * np.exp(-t / 0.008) * 0.6 + np.sin(2 * np.pi * 180 * t) * np.exp(-t / 0.02) * 0.7 + band(noise(0.08), 3000, 10000) * np.exp(-t / 0.002) * 0.5) * 0.7, 0.0
    if name == "whoosh":
        return whoosh(0.6) * 0.8, -0.33
    if name == "swish-rev":
        return whoosh(0.45)[::-1] * 0.7, -0.4
    if name == "rise":
        d = 0.75
        t = t_arr(d)
        y = sweep(220, 1400, d, 1.6) * 0.3 + band(noise(d), 1500, 9000) * 0.35 * (t / d) ** 2
        return y * np.minimum(1, (d - t) / 0.04) * (t / d), -d + 0.02
    if name == "snap":
        t = t_arr(0.09)
        return (band(noise(0.09), 1500, 9000) * np.exp(-t / 0.01) + np.sin(2 * np.pi * 900 * t) * np.exp(-t / 0.012) * 0.5 + kick()[: len(t)] * 0.5) * 0.8, 0.0
    if name == "pip":
        t = t_arr(0.14)
        return np.sin(2 * np.pi * 1320 * t) * np.exp(-t / 0.035) * np.minimum(1, t / 0.003) * 0.45, 0.0
    if name == "shimmer":
        y = np.zeros(int(1.2 * SR))
        for i, n in enumerate([76, 79, 83, 88, 91]):
            b = bell(n, 0.9) * 0.22
            k = int(i * 0.055 * SR)
            y[k : k + len(b)] += b[: len(y) - k]
        return y, 0.0
    if name == "stab":
        L, R = pad([57, 64, 69, 72], 0.5, 10)
        t = t_arr(0.5)
        return (L + R) * np.exp(-t / 0.14) * 0.9, 0.0
    if name == "spring":
        d = 0.22
        t = t_arr(d)
        f = 520 + 380 * (t / d) + 60 * np.sin(2 * np.pi * 28 * t) * np.exp(-t / 0.08)
        return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.07) * 0.35, 0.0
    if name.startswith("tone:"):
        i = int(name.split(":")[1])
        return bell([81, 84, 86, 88, 91, 93][i], 0.8) * 0.4, 0.0
    if name == "pop":
        d = 0.1
        t = t_arr(d)
        f = 300 + 700 * np.exp(-t / 0.015)
        return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.03) * 0.7, 0.0
    if name == "thunk":
        d = 0.2
        t = t_arr(d)
        f = 70 + 110 * np.exp(-t / 0.02)
        return (np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.06) + band(noise(d), 200, 1200) * np.exp(-t / 0.01) * 0.4) * 0.9, 0.0
    if name == "snip":
        y = np.zeros(int(0.12 * SR))
        for k0 in (0, 0.05):
            c, _ = sfx("tick")
            k = int(k0 * SR)
            y[k : k + len(c)] += c[: len(y) - k] * 1.3
        return y, 0.0
    if name == "slide":
        d = 0.4
        t = t_arr(d)
        return band(noise(d), 600, 3500) * np.sin(np.pi * t / d) ** 1.5 * 0.35, -0.05
    if name == "hum":
        d = 1.6
        t = t_arr(d)
        y = np.sin(2 * np.pi * 55 * t) * 0.5 + np.sin(2 * np.pi * 110.4 * t) * 0.2 + band(noise(d), 80, 400) * 0.08
        return y * np.minimum(1, t / 0.8) * np.minimum(1, (d - t) / 0.3) * 0.5, 0.0
    if name == "chord":
        L, R = pad(FINAL[1], 2.2, 10)
        t = t_arr(2.2)
        e = np.exp(-t / 1.1)
        y = (L + R) * e * 0.7 + np.sin(2 * np.pi * midi(FINAL[0]) * t) * e * 0.6
        return y, 0.0
    raise KeyError(name)


# ---------- arrangement ----------
STYLE = {
    "s01": "intro",
    "s02": "lift",
    "s03": "groove",
    "s04": "groove",
    "s05": "drive",
    "s06": "air",
    "s07": "light",
    "s08": "drive",
    "s09": "end",
}


def render(scene_ids, name):
    scenes = []
    at = 0.0
    for edit in scene_ids:
        sid = edit if isinstance(edit, str) else edit["id"]
        s = next(x for x in TLJ["scenes"] if x["id"] == sid)
        source_in = 0.0 if isinstance(edit, str) else edit.get("in", 0.0)
        duration = s["dur"] if isinstance(edit, str) else edit["dur"]
        scenes.append((sid, at, duration, source_in))
        at += duration
    total = at
    mus = Bus(total)
    fx = Bus(total)
    K, CL = kick(), clap()

    def style_at(t):
        for sid, s0, d, source_in in scenes:
            if s0 <= t < s0 + d:
                local = t - s0 + source_in
                st = STYLE[sid]
                if st == "end":
                    c = TLJ["cues"]["s09"]
                    if local >= c["mark"][0]:
                        return "outro", sid, local
                    if local >= c["close"][0]:
                        return "break", sid, local
                    return "drive", sid, local
                return st, sid, local
        return "outro", None, 0

    # Step through 16ths.
    step = BEAT / 4
    n = int(total / step) + 1
    for i in range(n):
        t = i * step
        st, sid, local = style_at(t)
        bar = int(t / BAR + 1e-6)
        root, chord = PROG[bar % 4]
        s16 = i % 16
        on_bar = s16 == 0
        beat = s16 % 4 == 0
        if on_bar and st not in ("outro", "break"):
            bright = {"intro": 3, "lift": 5, "light": 5}.get(st, 7)
            L, R = pad(chord, BAR + 0.3, bright)
            g = {"intro": 0.07, "lift": 0.12}.get(st, 0.11)
            mus.add(t, L, g, -0.5)
            mus.add(t, R, g, 0.5)
        if st in ("groove", "drive", "lift", "light") and beat:
            if st not in ("lift", "light") or s16 in (0, 8):
                mus.add(t, K, 0.55 if st != "light" else 0.35)
        if st in ("groove", "drive", "light") and s16 in (4, 12):
            mus.add(t, CL, 0.28 if st != "light" else 0.18, 0.05)
        if st in ("groove", "drive", "light", "air") and s16 % 4 == 2:
            mus.add(t, hat(s16 == 14 and st == "drive"), 0.16, 0.25)
        if st == "drive" and s16 % 2 == 1:
            mus.add(t, hat(), 0.07, -0.3)
        if st in ("groove", "drive") and s16 % 2 == 0:
            note = root + (12 if s16 % 8 == 6 else 0)
            mus.add(t, bass(note, step * 1.8), 0.34)
        if st in ("lift", "groove", "drive", "light", "air"):
            tones = chord + [c + 12 for c in chord]
            if st == "lift" and s16 % 2:
                continue
            nt = tones[(i * 5 // 2) % len(tones)] + 12
            g = {"light": 0.07, "lift": 0.09}.get(st, 0.08)
            mus.add(t, pluck(nt, 0.28), g, 0.6 if i % 2 else -0.6)
        if st == "intro" and on_bar:
            mus.add(t, np.sin(2 * np.pi * midi(root - 12) * t_arr(BAR)) * env(int(BAR * SR), 0.3, 99, 1, rel=0.4), 0.08)

    # Riser into the end break, and into s03 from s02.
    for sid, s0, d, source_in in scenes:
        if sid == "s09":
            c = TLJ["cues"]["s09"]
            r0 = s0 + c["close"][0] - source_in
            dd = c["mark"][0] - c["close"][0]
            tt = t_arr(dd)
            y = band(noise(dd), 800, 9000) * (tt / dd) ** 2 * 0.25 + sweep(200, 900, dd, 1.5) * (tt / dd) * 0.12
            mus.add(r0, y)

    # SFX from cues.
    for sid, s0, d, source_in in scenes:
        for key, v in TLJ["cues"].get(sid, {}).items():
            if len(v) < 2 or not source_in <= v[0] < source_in + d:
                continue
            y, off = sfx(v[1])
            pan = {"whoosh": -0.2, "swish-rev": 0.2, "tick": 0.1}.get(v[1], 0.0)
            fx.add(s0 + v[0] - source_in + off, y, 0.9, pan)

    L = mus.L * 0.8 + fx.L
    R = mus.R * 0.8 + fx.R
    n = int(total * SR)
    L, R = L[:n], R[:n]
    # Fade the tail, soft-limit, normalise.
    fade = int(0.25 * SR)
    L[-fade:] *= np.linspace(1, 0, fade)
    R[-fade:] *= np.linspace(1, 0, fade)
    drive = 1.4
    L, R = np.tanh(L * drive), np.tanh(R * drive)
    peak = max(np.abs(L).max(), np.abs(R).max())
    L, R = L / peak * 0.79, R / peak * 0.79
    data = (np.stack([L, R], 1) * 32767).astype("<i2")
    out = ROOT / "public/audio" / name
    out.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(out), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print(f"{out.relative_to(ROOT)}  {total:.1f}s")


if __name__ == "__main__":
    render([s["id"] for s in TLJ["scenes"]], "score.wav")
    render(TLJ["vertical_edit"], "score-vertical.wav")
