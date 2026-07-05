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
import json, sys, time, tempfile, os

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
        chunks = []
        sr = 24000
        for seg in model.generate(**kwargs):
            chunks.append(np.array(seg.audio))
            sr = getattr(seg, "sample_rate", sr) or sr
        audio = np.concatenate(chunks) if chunks else np.zeros(1, dtype=np.float32)
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
