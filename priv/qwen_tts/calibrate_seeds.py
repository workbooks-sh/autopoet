#!/usr/bin/env python3
"""Calibrate a stable sampling seed per pinned voice (data/voices/<name>.seed).

"Stable seeds" exist per QwenLM/Qwen3-TTS#298: with a fixed ref, some seeds
consistently produce on-identity takes, others wander. We probe a small seed
set against two sentences and keep the seed whose takes land closest to the
ref's median f0 (the speaker gate's own metric). serve.py uses the pinned
seed for attempt 0; gate rerolls fall back to text-hash seeds.

Run: data/qwen-tts-venv/bin/python priv/qwen_tts/calibrate_seeds.py [voice...]
"""
import os, sys, glob, wave, struct

import numpy as np
import mlx.core as mx

HOME = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # autopoet/
VOICES = os.path.join(HOME, "data", "voices")
SEEDS = [11, 23, 37, 42, 51, 64]
PROBES = [
    "Right then, let us map out your first workbook together.",
    "A workspace is a folder that owns its own little world.",
]


def f0_median(w, sr=24000):
    w = np.asarray(w, dtype=np.float32)
    f0s, fl = [], int(sr * 0.04)
    for i in range(0, len(w) - fl, fl):
        fr = w[i:i + fl]
        if np.sqrt((fr ** 2).mean()) < 0.02:
            continue
        fr = fr - fr.mean()
        ac = np.correlate(fr, fr, "full")[fl - 1:]
        lo, hi = sr // 400, sr // 70
        if hi >= len(ac):
            continue
        pk = lo + int(np.argmax(ac[lo:hi]))
        if ac[pk] > 0.3 * ac[0]:
            f0s.append(sr / pk)
    return float(np.median(f0s)) if f0s else 0.0


def wav_f0(path):
    wf = wave.open(path, "rb")
    sr = wf.getframerate()
    raw = np.array(struct.unpack(f"<{wf.getnframes()}h",
                                 wf.readframes(wf.getnframes())),
                   dtype=np.float32) / 32768
    wf.close()
    return f0_median(raw, sr)


def main():
    only = set(sys.argv[1:])
    from mlx_audio.tts.utils import load_model
    model = load_model("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit")
    for wavp in sorted(glob.glob(os.path.join(VOICES, "*.wav"))):
        name = os.path.splitext(os.path.basename(wavp))[0]
        txtp = os.path.join(VOICES, name + ".txt")
        if not os.path.exists(txtp) or (only and name not in only):
            continue
        target = wav_f0(wavp)
        if target <= 0:
            print(f"{name}: no target f0, skipped", flush=True)
            continue
        ref_text = open(txtp).read()
        best = None  # (hits, -avg_dist, seed)
        for seed in SEEDS:
            dists = []
            for probe in PROBES:
                mx.random.seed(seed)
                segs = model.generate(text=probe, ref_audio=wavp, ref_text=ref_text)
                audio = np.concatenate([np.asarray(s.audio) for s in segs])
                dists.append(abs(f0_median(audio) - target))
            hits = sum(1 for d in dists if d <= target * 0.12)
            score = (hits, -sum(dists) / len(dists), seed)
            if best is None or score > best:
                best = score
            print(f"{name} seed {seed}: hits {hits}/2, avg off {sum(dists)/len(dists):.0f}Hz",
                  flush=True)
        open(os.path.join(VOICES, name + ".seed"), "w").write(str(best[2]))
        print(f"{name} → PINNED seed {best[2]} (hits {best[0]}, avg off {-best[1]:.0f}Hz)",
              flush=True)


if __name__ == "__main__":
    main()
