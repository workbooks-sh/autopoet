#!/usr/bin/env python3
"""Qwen3-TTS sidecar — persistent MLX process behind Autopoet.QwenTts.

Protocol (line-oriented, stdout is SACRED — logs go to stderr):
  stdin :  {"id": 1, "text": "...", "voice": "Ryan", "instruct": "..."|null}
  stdout:  {"ready": true, "model": "..."}                    (once, after load)
           {"id": 1, "path": "/tmp/qtts-1.wav", "ms": 3710, "dur": 6.8}
           {"id": 1, "error": "..."}
Model: Qwen3-TTS-12Hz-1.7B-CustomVoice 4-bit (MLX) — the spike winner:
1.83x realtime on M-series, correct-length speech (0.6B-4bit is collapsed).
"""
import json, sys, time, tempfile, os, zlib, wave, struct

import numpy as np

def log(m): print(m, file=sys.stderr, flush=True)

MODEL = os.environ.get("QWEN_TTS_MODEL", "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit")

t0 = time.time()
log(f"loading {MODEL}…")
from mlx_audio.tts.utils import load_model
model = load_model(model_path=MODEL)
import inspect
GEN_PARAMS = set(inspect.signature(model.generate).parameters)
# sampling stays at MODEL DEFAULTS: 0.4 temp starved EOS → babble-to-cap
# (33s from a 5-word line). Override only via env if ever needed.
TEMP = os.environ.get("QWEN_TTS_TEMP")
TOP_P = os.environ.get("QWEN_TTS_TOP_P")
log(f"loaded in {time.time()-t0:.1f}s")
print(json.dumps({"ready": True, "model": MODEL}), flush=True)

import soundfile as sf
import mlx.core as mx

# ── SPEAKER GATE (clone lane) ────────────────────────────────────────────
# ICL cloning re-rolls delivery per generation (temp 0.9 default); measured
# median-f0 of takes from ONE ref wandered 148-250 Hz — audibly "different
# people". Gate: a take must land within ±12% of the REF's median f0 or we
# re-roll (deterministic seed per attempt, ≤3 tries, keep the closest).
# Seeds are stable hashes (crc32 — python hash() is process-salted), so the
# same voice+text yields the SAME take across sessions and processes.

def _f0_median(w, sr=24000):
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

_ref_f0_cache = {}

def ref_f0(path):
    try:
        mt = os.path.getmtime(path)
        hit = _ref_f0_cache.get(path)
        if hit and hit[0] == mt:
            return hit[1]
        wf = wave.open(path, "rb")
        srr = wf.getframerate()
        raw = np.array(struct.unpack(f"<{wf.getnframes()}h",
                                     wf.readframes(wf.getnframes())),
                       dtype=np.float32) / 32768
        wf.close()
        f0 = _f0_median(raw, srr)
        _ref_f0_cache[path] = (mt, f0)
        return f0
    except Exception:
        return 0.0

def seed_for(*parts):
    return zlib.crc32("\x1f".join(str(p) for p in parts).encode()) % (2 ** 31)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
        rid = req.get("id")
        t = time.time()
        text = req["text"]
        # pronunciation respells (synthesis only — never shown): "autopoet"
        # reads as "poe-ET"; hyphenating restores the natural "poet" ending
        import re as _re
        text = _re.sub(r"(?i)autopoets", "auto-poets", text)
        text = _re.sub(r"(?i)autopoet", "auto-poet", text)
        # voice default applies ONLY when nothing else steers the speaker —
        # the VoiceDesign model has NO presets (its instruct IS the voice)
        kwargs = {"text": text}
        if req.get("voice"):
            kwargs["voice"] = req["voice"]
        if req.get("instruct"):
            kwargs["instruct"] = req["instruct"]
        # CLONE lane (Base model): the reference clip + its transcript ARE the
        # voice — no default speaker when a ref is present
        if req.get("ref_audio"):
            kwargs["ref_audio"] = req["ref_audio"]
            kwargs["ref_text"] = req.get("ref_text") or ""
        if "voice" not in kwargs and "instruct" not in kwargs and "ref_audio" not in kwargs:
            kwargs["voice"] = "Ryan"
        for k, v in (("temperature", TEMP), ("top_p", TOP_P)):
            if v is not None and k in GEN_PARAMS:
                kwargs[k] = float(v)
        # SHORT-FRAGMENT RAMBLE GUARD: the AR talker over-generates on short
        # clauses (a 5-word line once produced 23s of audio). English speech
        # runs ~14 chars/s; codec is ~12.5 tokens/s — cap generation at ~2.5x
        # the expected length so a ramble truncates instead of running away.
        expected_s = max(1.6, len(text) / 12.0)
        kwargs["max_tokens"] = int(expected_s * 12.5 * 2.5) + 24
        def pinned_seed(ref):
            # per-voice CALIBRATED seed (data/voices/<name>.seed): a seed known
            # to pass the speaker gate on attempt 0 for this ref ("stable
            # seeds" per QwenLM/Qwen3-TTS#298). Rerolls fall back to text-hash.
            try:
                return int(open(os.path.splitext(ref)[0] + ".seed").read().strip())
            except Exception:
                return None

        # STREAM DECODE: measured faster (4.1s → 2.9s per clip) with ZERO
        # identity drift (f0 Δ1Hz vs non-streaming at interval 1.0 — the old
        # mlx-audio "streaming alters the voice" bug is fixed). We collect the
        # chunks here (one-wav return); the chunk-level streaming to the client
        # for sub-second first-audio rides the same generator.
        gkw = dict(kwargs)
        if "stream" in GEN_PARAMS:
            gkw["stream"] = True
            if "streaming_interval" in GEN_PARAMS:
                gkw["streaming_interval"] = 1.0

        def synth(attempt):
            ref = kwargs.get("ref_audio")
            pin = pinned_seed(ref) if ref else None
            if attempt == 0 and pin is not None:
                mx.random.seed(pin)
            else:
                mx.random.seed(seed_for(ref or kwargs.get("voice")
                                        or kwargs.get("instruct") or "", text, attempt))
            chunks, srr = [], 24000
            for seg in model.generate(**gkw):
                chunks.append(np.array(seg.audio))
                srr = getattr(seg, "sample_rate", srr) or srr
            return (np.concatenate(chunks) if chunks
                    else np.zeros(1, dtype=np.float32)), srr

        # ── STREAMING PATH: emit audio chunks AS they decode (sub-second first
        # audio). No f0 gate (rerolling would defeat streaming; the pinned
        # calibrated seed passes reliably). Each chunk → its own wav; a final
        # "done" line closes the stream. Same generator as the batch path.
        if req.get("stream"):
            ref = kwargs.get("ref_audio")
            pin = pinned_seed(ref) if ref else None
            mx.random.seed(pin if pin is not None else
                           seed_for(ref or kwargs.get("voice") or kwargs.get("instruct") or "", text, 0))
            seq, total = 0, 0
            for seg in model.generate(**gkw):
                a = np.asarray(seg.audio, dtype=np.float32)
                srr = getattr(seg, "sample_rate", 24000) or 24000
                if a.size < 4:
                    continue
                cpath = os.path.join(tempfile.gettempdir(), f"qtts-{os.getpid()}-{rid}-{seq}.wav")
                sf.write(cpath, a, srr, subtype="PCM_16")
                print(json.dumps({"id": rid, "seq": seq, "path": cpath, "sr": srr}), flush=True)
                seq += 1
                total += a.size
            print(json.dumps({"id": rid, "done": True, "chunks": seq,
                              "ms": int((time.time() - t) * 1000),
                              "dur": round(total / 24000, 2)}), flush=True)
            continue

        target = 0.0
        if kwargs.get("ref_audio"):
            # gate v2: prefer the calibrated clone-output median (<name>.f0) —
            # the ref's own f0 sits systematically off what the clone renders
            try:
                target = float(open(os.path.splitext(kwargs["ref_audio"])[0] + ".f0").read())
            except Exception:
                target = ref_f0(kwargs["ref_audio"])
        audio, sr = synth(0)
        if target > 0:
            best, best_d = audio, abs(_f0_median(audio) - target)
            for attempt in range(1, 2):
                if best_d <= target * 0.20:
                    break
                log(f"gate: take f0 off by {best_d:.0f}Hz (target {target:.0f}) — reroll {attempt}")
                cand, sr = synth(attempt)
                d = abs(_f0_median(cand) - target)
                if d < best_d:
                    best, best_d = cand, d
            audio = best
        # edge-trim: drop leading/trailing near-silence (keep 120ms of pad)
        if len(audio) > sr // 2:
            win = sr // 50
            n = (len(audio) // win) * win
            rms = np.sqrt((audio[:n].reshape(-1, win) ** 2).mean(axis=1))
            on = np.where(rms > max(rms.max() * 0.04, 1e-4))[0]
            if len(on):
                a = max(0, on[0] * win - sr // 8)
                b = min(len(audio), (on[-1] + 1) * win + sr // 8)
                audio = audio[a:b]
        path = os.path.join(tempfile.gettempdir(), f"qtts-{os.getpid()}-{rid}.wav")
        sf.write(path, audio, sr, subtype="PCM_16")
        print(json.dumps({"id": rid, "path": path, "ms": int((time.time()-t)*1000),
                          "dur": round(len(audio)/sr, 2)}), flush=True)
    except Exception as e:
        print(json.dumps({"id": req.get("id") if isinstance(req, dict) else None,
                          "error": str(e)[:300]}), flush=True)
