"""Procedural placeholder SFX/ambience for the game (pure Python, no numpy).
python3 tools/make_sounds.py  ->  assets/audio/*.wav  (22050 Hz, 16-bit mono)
Everything is synthesized: noise bursts, sines, one-pole filters. Replace with real
recordings later; names are what scripts/audio/sfx.gd loads.
"""
import math, random, struct, wave, os

SR = 22050
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "audio")
os.makedirs(OUT, exist_ok=True)
rng = random.Random(7)

def save(name, samples, loop=False):
    peak = max(1e-6, max(abs(s) for s in samples))
    gain = 0.92 / peak
    data = struct.pack("<%dh" % len(samples), *[int(max(-1, min(1, s * gain)) * 32767) for s in samples])
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(data)
    print(name, "%.2fs" % (len(samples) / SR))

def env(t, a, d, curve=1.0):
    """attack a, exponential decay d (seconds to ~ -60 dB)."""
    if t < a: return t / a
    return math.exp(-(t - a) * 6.9 / d) ** curve

def lowpass(xs, cutoff):
    a = 1.0 - math.exp(-2 * math.pi * cutoff / SR)
    y = 0.0; out = []
    for x in xs:
        y += a * (x - y); out.append(y)
    return out

def highpass(xs, cutoff):
    lp = lowpass(xs, cutoff)
    return [x - l for x, l in zip(xs, lp)]

def noise(n): return [rng.uniform(-1, 1) for _ in range(n)]
def secs(s): return int(s * SR)
def mix(*parts):
    n = max(len(p) for p in parts); out = [0.0] * n
    for p in parts:
        for i, v in enumerate(p): out[i] += v
    return out
def tone(freq_fn, n, amp_fn, wave_fn=math.sin):
    ph = 0.0; out = []
    for i in range(n):
        t = i / SR
        ph += 2 * math.pi * freq_fn(t) / SR
        out.append(wave_fn(ph) * amp_fn(t))
    return out
def square(ph): return 1.0 if math.sin(ph) > 0 else -1.0
def tri(ph): return 2 / math.pi * math.asin(math.sin(ph))

# --- bullets: a typed letter. Snappy click with a body; pitch varied at play time.
n = secs(0.16)
crack = [v * env(i / SR, 0.001, 0.035) for i, v in enumerate(highpass(noise(n), 1800))]
body = tone(lambda t: 170 - 90 * t, n, lambda t: env(t, 0.002, 0.07))
save("shot", mix([c * 0.9 for c in crack], [b * 0.8 for b in body]))

# --- hit: flesh thud when a letter lands
n = secs(0.22)
thud = tone(lambda t: 95 - 40 * t, n, lambda t: env(t, 0.003, 0.12))
slap = [v * env(i / SR, 0.001, 0.05) for i, v in enumerate(lowpass(noise(n), 900))]
save("hit", mix(thud, [s * 0.9 for s in slap]))

# --- kill: last letter. Thud + falling comic tone + noise tail
n = secs(0.55)
boom = tone(lambda t: 70 - 25 * t, n, lambda t: env(t, 0.004, 0.3))
fall = tone(lambda t: 420 * math.exp(-t * 4.0) + 60, n, lambda t: 0.5 * env(t, 0.01, 0.35), square)
tail = [v * env(i / SR, 0.002, 0.25) for i, v in enumerate(lowpass(noise(n), 1400))]
save("kill", mix(boom, [f * 0.35 for f in fall], [t * 0.5 for t in tail]))

# --- miss: dull tock
n = secs(0.09)
save("miss", tone(lambda t: 380, n, lambda t: env(t, 0.001, 0.05), tri))

# --- key: correct letter on a door/option word (typewriter tick)
n = secs(0.06)
save("key", mix([v * env(i / SR, 0.0005, 0.02) for i, v in enumerate(highpass(noise(n), 3000))],
                tone(lambda t: 1900, n, lambda t: 0.4 * env(t, 0.0005, 0.015))))

# --- door: wood crack + boom
n = secs(0.7)
crack = [v * env(i / SR, 0.001, 0.06) for i, v in enumerate(highpass(noise(n), 1200))]
splinter = [v * env(i / SR, 0.02, 0.18) * (1 if rng.random() < 0.35 else 0.2) for i, v in enumerate(highpass(noise(n), 2500))]
boom = tone(lambda t: 58 - 20 * t, n, lambda t: env(t, 0.006, 0.4))
save("door", mix(crack, [s * 0.6 for s in splinter], [b * 1.1 for b in boom]))

# --- growls: zombie wakes up. Vibrato'd low buzz through a lowpass, two variants
for k, (f0, dur) in enumerate([(92, 0.7), (118, 0.55)]):
    n = secs(dur)
    buzz = tone(lambda t, f0=f0: f0 * (1 + 0.06 * math.sin(2 * math.pi * 5.5 * t)) + 30 * t,
                n, lambda t, dur=dur: env(t, 0.06, dur * 0.9) * (0.7 + 0.3 * math.sin(2 * math.pi * 11 * t)), square)
    breath = [v * env(i / SR, 0.05, dur * 0.8) for i, v in enumerate(lowpass(noise(n), 700))]
    save("growl%d" % (k + 1), lowpass(mix([b * 0.6 for b in buzz], [b * 0.7 for b in breath]), 1600))

# --- startle: comic "yip", rising
n = secs(0.16)
save("startle", tone(lambda t: 320 + 700 * t, n, lambda t: env(t, 0.005, 0.12), tri))

# --- footsteps (two)
for k, cut in enumerate([1100, 900]):
    n = secs(0.09)
    save("step%d" % (k + 1), [v * env(i / SR, 0.002, 0.04) for i, v in enumerate(lowpass(noise(n), cut))])

# --- stairs creak
n = secs(0.3)
save("creak", tone(lambda t: 240 + 120 * math.sin(2 * math.pi * 7 * t), n, lambda t: env(t, 0.03, 0.2) * 0.5, tri))

# --- loops: wind outside, drone inside. Built as loops via a short crossfade at the seam.
def loopify(xs, fade=0.25):
    f = secs(fade)
    for i in range(f):
        a = i / f
        xs[i] = xs[i] * a + xs[len(xs) - f + i] * (1 - a)
    return xs[: len(xs) - f]

n = secs(7.0)
brown = []; y = 0.0
for v in noise(n):
    y = (y + v * 0.02) * 0.995; brown.append(y)
wind = [b * (0.55 + 0.45 * math.sin(2 * math.pi * 0.11 * i / SR) * math.sin(2 * math.pi * 0.07 * i / SR + 1.3)) for i, b in enumerate(lowpass(brown, 500))]
save("wind", loopify(wind))

n = secs(6.0)
drone = mix(tone(lambda t: 55, n, lambda t: 0.5), tone(lambda t: 110.4, n, lambda t: 0.25), tone(lambda t: 164, n, lambda t: 0.08),
            [v * 0.12 for v in lowpass(noise(n), 300)])
drone = [d * (0.8 + 0.2 * math.sin(2 * math.pi * 0.23 * i / SR)) for i, d in enumerate(drone)]
save("hum", loopify(drone))
