"""Chatterbox-Turbo ONNX — persistent port engine for Autopoet.Chatterbox.

Protocol (line-based, stdin/stdout):
  in:  SPEAK <base64 utf-8 text>\n
  out: WAV <base64 wav bytes>\n | ERR <msg>\n
  out (once, after load): READY\n

Sessions load once; the reference-voice conditioning is computed once and
cached to disk (conds.npz) so later boots skip the encoder entirely.
"""
import base64
import io
import os
import sys
import numpy as np
import onnxruntime

DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # app root
MODELS = os.path.join(DIR, "data", "models", "chatterbox")
REF = os.path.join(MODELS, "ref-voice.wav")
CONDS = os.path.join(MODELS, "conds.npz")

SAMPLE_RATE = 24000
START_SPEECH_TOKEN = 6561
STOP_SPEECH_TOKEN = 6562
SILENCE_TOKEN = 4299
NUM_KV_HEADS = 16
HEAD_DIM = 64
MAX_TOKENS = 600
REP_PENALTY = 1.2
# the reference implementation SAMPLES (greedy flattens paralinguistic tags
# like [chuckle] into nothing) — temperature + top-p per the torch pipeline
TEMPERATURE = 0.8
TOP_P = 0.95
rng = np.random.default_rng()

onnxruntime.set_default_logger_severity(3)
opts = onnxruntime.SessionOptions()
opts.log_severity_level = 3

def sess(name):
    return onnxruntime.InferenceSession(os.path.join(MODELS, "onnx", name), opts)

cond_dec = sess("conditional_decoder.onnx")
embed = sess("embed_tokens_quantized.onnx")
lm = sess("language_model_q4.onnx")

from tokenizers import Tokenizer
tok = Tokenizer.from_file(os.path.join(MODELS, "tokenizer.json"))

# voice conditioning: cached npz, else computed from ref-voice.wav
if os.path.exists(CONDS):
    z = np.load(CONDS)
    cond_emb, prompt_token = z["cond_emb"], z["prompt_token"]
    spk_embed, spk_feats = z["spk_embed"], z["spk_feats"]
else:
    import soundfile as _sf
    audio, sr = _sf.read(REF, dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != SAMPLE_RATE:
        n = int(len(audio) * SAMPLE_RATE / sr)
        audio = np.interp(np.linspace(0, len(audio), n, endpoint=False),
                          np.arange(len(audio)), audio).astype(np.float32)
    spk = sess("speech_encoder_quantized.onnx")
    cond_emb, prompt_token, spk_embed, spk_feats = spk.run(
        None, {"audio_values": audio[np.newaxis, :].astype(np.float32)})
    np.savez(CONDS, cond_emb=cond_emb, prompt_token=prompt_token,
             spk_embed=spk_embed, spk_feats=spk_feats)

kv_dtype = np.float16 if any(i.type == "tensor(float16)" for i in lm.get_inputs()
                             if "past_key_values" in i.name) else np.float32
kv_names = [i.name for i in lm.get_inputs() if "past_key_values" in i.name]


def synth(text):
    ids = np.array([tok.encode(text).ids], dtype=np.int64)
    gen = np.array([[START_SPEECH_TOKEN]], dtype=np.int64)
    past = {k: np.zeros([1, NUM_KV_HEADS, 0, HEAD_DIM], dtype=kv_dtype) for k in kv_names}
    emb = embed.run(None, {"input_ids": ids})[0]
    emb = np.concatenate((cond_emb, emb), axis=1)
    attn = np.ones((1, emb.shape[1]), dtype=np.int64)
    pos = np.arange(emb.shape[1], dtype=np.int64).reshape(1, -1)
    for _ in range(MAX_TOKENS):
        logits, *present = lm.run(None, dict(inputs_embeds=emb, attention_mask=attn,
                                             position_ids=pos, **past))
        logits = logits[:, -1, :]
        score = np.take_along_axis(logits, gen, axis=1)
        score = np.where(score < 0, score * REP_PENALTY, score / REP_PENALTY)
        np.put_along_axis(logits, gen, score, axis=1)
        # temperature + top-p sampling
        z = logits[0] / TEMPERATURE
        z = z - z.max()
        probs = np.exp(z)
        probs /= probs.sum()
        order = np.argsort(-probs)
        csum = np.cumsum(probs[order])
        keep = order[: max(1, int(np.searchsorted(csum, TOP_P) + 1))]
        kp = probs[keep] / probs[keep].sum()
        nxt = np.array([[rng.choice(keep, p=kp)]], dtype=np.int64)
        gen = np.concatenate((gen, nxt), axis=-1)
        if (nxt.flatten() == STOP_SPEECH_TOKEN).all():
            break
        attn = np.concatenate([attn, np.ones((1, 1), dtype=np.int64)], axis=1)
        pos = pos[:, -1:] + 1
        for j, k in enumerate(kv_names):
            past[k] = present[j]
        emb = embed.run(None, {"input_ids": nxt})[0]

    speech = np.concatenate([prompt_token, gen[:, 1:-1],
                             np.full((1, 3), SILENCE_TOKEN, dtype=np.int64)], axis=1)
    wav = cond_dec.run(None, dict(speech_tokens=speech, speaker_embeddings=spk_embed,
                                  speaker_features=spk_feats))[0].squeeze(axis=0)
    # 16-bit WAV bytes
    pcm = np.clip(wav, -1.0, 1.0)
    pcm = (pcm * 32767.0).astype("<i2").tobytes()
    hdr = (b"RIFF" + (36 + len(pcm)).to_bytes(4, "little") + b"WAVEfmt " +
           (16).to_bytes(4, "little") + (1).to_bytes(2, "little") +
           (1).to_bytes(2, "little") + SAMPLE_RATE.to_bytes(4, "little") +
           (SAMPLE_RATE * 2).to_bytes(4, "little") + (2).to_bytes(2, "little") +
           (16).to_bytes(2, "little") + b"data" + len(pcm).to_bytes(4, "little"))
    return hdr + pcm


sys.stdout.write("READY\n")
sys.stdout.flush()
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("SPEAK "):
        continue
    try:
        text = base64.b64decode(line[6:]).decode("utf-8")
        wav = synth(text)
        sys.stdout.write("WAV " + base64.b64encode(wav).decode("ascii") + "\n")
    except Exception as e:  # noqa: BLE001 — the port must never die mid-session
        sys.stdout.write("ERR " + str(e)[:200].replace("\n", " ") + "\n")
    sys.stdout.flush()
