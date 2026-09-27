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

# --- loot arrivals: a compact mallet/coin pickup whose pitch rises for each icon, then a
# warm resolving chord for the final unit. Playback supplies the progression pitch so one
# pair of tiny assets can make long pickups feel increasingly rewarding.
n = secs(0.24)
pickup = mix(
    tone(lambda t: 760 + 520 * min(1.0, t / 0.055), n, lambda t: 0.75 * env(t, 0.001, 0.16), tri),
    tone(lambda t: 1520, n, lambda t: 0.28 * env(t, 0.001, 0.09)),
    tone(lambda t: 2280, n, lambda t: 0.12 * env(t, 0.001, 0.045)),
)
save("loot_pickup", pickup)
n = secs(0.42)
complete = mix(
    tone(lambda t: 660, n, lambda t: 0.55 * env(t, 0.002, 0.30), tri),
    tone(lambda t: 825, n, lambda t: 0.46 * env(t, 0.018, 0.31), tri),
    tone(lambda t: 990, n, lambda t: 0.36 * env(t, 0.038, 0.32), tri),
    tone(lambda t: 1980, n, lambda t: 0.10 * env(t, 0.001, 0.12)),
)
save("loot_complete", complete)

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

# --- loops: wind outside, room tone inside, and object-local machinery. Built as loops via
# an equal-power crossfade at the seam; DC removed so the seam never clicks.
def loopify(xs, fade=0.6):
    f = secs(fade)
    for i in range(f):
        a = i / f
        ga = math.sin(a * math.pi / 2); gb = math.cos(a * math.pi / 2)
        xs[i] = xs[i] * ga + xs[len(xs) - f + i] * gb
    return xs[: len(xs) - f]
def brown_noise(n, leak=0.995, step=0.02):
    out = []; y = 0.0
    for v in noise(n):
        y = (y + v * step) * leak; out.append(y)
    return highpass(out, 25)

n = secs(14.0)
gusts = [0.5 + 0.3 * math.sin(2 * math.pi * 0.09 * i / SR) * math.sin(2 * math.pi * 0.053 * i / SR + 1.3) + 0.2 * math.sin(2 * math.pi * 0.21 * i / SR + 0.4) for i in range(n)]
wind = [b * g for b, g in zip(lowpass(brown_noise(n), 420), gusts)]
# Keep the exterior bed broadband. A previous 620 Hz oscillating street-whistle layer read
# as a repeating synthetic siren even after the actual siren event had been removed.
save("wind", loopify(wind))

# This was the original blanket indoor ambience. Its rumble, broadband hiss, and distant
# wind read as an untuned television, so preserve that exact sound as TV static instead.
n = secs(12.0)
rumble = mix(tone(lambda t: 48, n, lambda t: 0.35 + 0.1 * math.sin(2 * math.pi * 0.31 * t)), tone(lambda t: 96.5, n, lambda t: 0.12))
hiss = [v * 0.06 for v in highpass(lowpass(noise(n), 2600), 900)]
far_wind = [b * 0.25 * g for b, g in zip(lowpass(brown_noise(n), 180), [0.6 + 0.4 * math.sin(2 * math.pi * 0.07 * i / SR) for i in range(n)])]
save("tv_static", loopify(mix(rumble, hiss, far_wind)))

# Indoors should feel enclosed, not filled with white noise: slow structural pressure,
# a barely audible building resonance, and no broadband component. Contextual electrical
# and pipe layers are crossfaded separately by sfx.gd.
n = secs(16.0)
pressure = mix(
    tone(lambda t: 31.0 + 0.8 * math.sin(2 * math.pi * 0.041 * t), n,
         lambda t: 0.26 + 0.08 * math.sin(2 * math.pi * 0.071 * t)),
    tone(lambda t: 47.5, n, lambda t: 0.11 + 0.04 * math.sin(2 * math.pi * 0.053 * t + 1.1)),
    tone(lambda t: 93.0, n, lambda t: 0.035 * (0.5 + 0.5 * math.sin(2 * math.pi * 0.13 * t))),
)
save("room", loopify(lowpass(pressure, 240), 0.8))

# Context beds: clean mains transformer harmonics for powered rooms and resonant water
# pipes for kitchens/bathrooms. Kept separate so they can fade with room semantics.
n = secs(10.0)
electric = mix(
    tone(lambda t: 60.0, n, lambda t: 0.24 + 0.04 * math.sin(2 * math.pi * 0.17 * t)),
    tone(lambda t: 120.0, n, lambda t: 0.10),
    tone(lambda t: 241.0 + 1.5 * math.sin(2 * math.pi * 0.11 * t), n, lambda t: 0.035),
)
save("electric", loopify(electric, 0.5))
n = secs(11.0)
pipes = mix(
    tone(lambda t: 72.0 + 2.0 * math.sin(2 * math.pi * 0.09 * t), n,
         lambda t: 0.18 + 0.07 * math.sin(2 * math.pi * 0.19 * t + 0.7)),
    tone(lambda t: 146.0, n, lambda t: 0.045 * (0.5 + 0.5 * math.sin(2 * math.pi * 0.27 * t))),
)
save("pipes", loopify(lowpass(pipes, 420), 0.6))

# --- atmosphere one-shots ------------------------------------------------------
# crow: 1-3 harsh caws (pulse train through a bandpass), pitch jitter at play time
def caw(dur, f0):
    n = secs(dur)
    out = []
    for i in range(n):
        t = i / SR
        ph = 2 * math.pi * f0 * (1 + 0.15 * math.sin(2 * math.pi * 9 * t)) * t
        out.append((1.0 if math.sin(ph) > 0.3 else -0.6) * env(t, 0.02, dur * 0.9))
    return highpass(lowpass(out, 2200), 500)
crow = []
for k in range(2):
    crow += caw(0.22, 330 + k * 20) + [0.0] * secs(0.12)
save("crow1", crow)
crow = caw(0.28, 300) + [0.0] * secs(0.15) + caw(0.2, 340) + [0.0] * secs(0.1) + caw(0.18, 360)
save("crow2", crow)

# pigeon flutter: rapid soft noise bursts (wingbeats)
n = secs(0.9)
flut = []
for i in range(n):
    t = i / SR
    beat = 0.5 + 0.5 * math.sin(2 * math.pi * 11 * t)
    flut.append(beat ** 3 * env(t, 0.05, 0.8))
flut = [f * v for f, v in zip(flut, lowpass(noise(n), 1400))]
save("flutter", flut)

# far-off groan (a zombie somewhere): low, muffled
n = secs(1.1)
groan = tone(lambda t: 85 + 25 * math.sin(2 * math.pi * 3 * t) - 20 * t, n, lambda t: env(t, 0.15, 0.9), square)
save("groan_far", lowpass(groan, 500))

# metal clank (a can / gate somewhere)
n = secs(0.5)
clank = mix(tone(lambda t: 1250, n, lambda t: env(t, 0.001, 0.25)), tone(lambda t: 1890, n, lambda t: 0.6 * env(t, 0.001, 0.15)),
            [v * env(i / SR, 0.001, 0.04) for i, v in enumerate(highpass(noise(n), 2000))])
save("clank", clank)

# indoors: water drip, wooden creak, distant thump, pipe knock
n = secs(0.35)
drip = tone(lambda t: 1500 * math.exp(-t * 14) + 700, n, lambda t: env(t, 0.002, 0.12))
save("drip", drip)
n = secs(0.7)
creak2 = tone(lambda t: 180 + 140 * math.sin(2 * math.pi * 4 * t) + 60 * t, n, lambda t: 0.5 * env(t, 0.08, 0.5) * (0.6 + 0.4 * math.sin(2 * math.pi * 27 * t)), tri)
save("creak2", creak2)
n = secs(0.6)
thump = mix(tone(lambda t: 60 - 20 * t, n, lambda t: env(t, 0.005, 0.35)), [v * env(i / SR, 0.002, 0.08) for i, v in enumerate(lowpass(noise(n), 400))])
save("thump", thump)
n = secs(0.8)
knock = []
for k in range(3):
    seg = secs(0.22)
    knock += [v * env(i / SR, 0.001, 0.09) for i, v in enumerate(mix(tone(lambda t: 480, seg, lambda t: 1.0), lowpass(noise(seg), 1500)))]
save("knock", knock)
