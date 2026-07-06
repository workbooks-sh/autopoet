# Qwen3-TTS instead of Kokoro — feasibility (2026-07-05)

What it would take to run Qwen3-TTS as the autopoet's voice, per lane
(WebGPU / EXLA-Nx / Ortex), against what Kokoro gives us today.

## What we run now (baseline)

Kokoro-82M, TWO lanes already live:
- **BEAM-native** (`desktop_ml/kokoro.ex`): Ortex in-process ONNX + espeak-ng
  phonemizer — no python, no downloads at speak time, ~90–300MB on disk,
  faster-than-realtime on CPU. The primary.
- **Browser worker** (`vendor/kokoro.bundle.mjs`, transformers.js): fallback.

Limits: fixed preset voices, no cloning, English-strongest, no instruction
control. Quality ceiling is "good small TTS," not "expressive actor."

## Qwen3-TTS — what it is (verified)

- **Open**: released 2026-01-22, **Apache 2.0**, 0.6B + 1.7B (Base /
  CustomVoice / VoiceDesign) on the Qwen3-TTS-Tokenizer-12Hz.
- **Architecture**: discrete multi-codebook **LM** — an autoregressive talker
  emits codec tokens; the 12Hz tokenizer reconstructs audio. No separate
  vocoder stage.
- **Capabilities**: 10 languages + dialects, **voice design by natural-language
  instruction**, **3-second voice cloning**, dual-track streaming — **97ms E2E**
  (on GPU, FlashAttention-2, fp16/bf16). vLLM-Omni has day-0 support.
- **ONNX**: no official export; community split exists — **9 graphs**
  (text_project → talker_prefill → talker_decode loop → code_predictor →
  codec/12Hz decode → speaker_encoder), **1.6GB INT8** (6.1GB fp32). Known
  issue: ConvInteger ops fail on the CPU EP; no published RTF numbers.

## The three lanes, costed

| lane | verdict | effort | notes |
|---|---|---|---|
| **Browser WebGPU** (transformers.js / ort-web) | ❌ not yet | weeks + | No official transformers.js port. We'd hand-drive the 9-graph AR loop + KV cache + multi-codebook sampling in JS, and ship a **1.6GB** in-app download (vs Kokoro's ~90MB). Wait for the official/Xenova port — Qwen releases usually get one. |
| **EXLA/Nx native port** | ❌ wrong tool | weeks, risky | Reimplementing the talker + codec in Nx/Bumblebee (no Qwen3-TTS port exists), AND our app pins `exla runtime: false` because XLA's dylib **segfaults onnxruntime if it loads first** (mix.exs note) — mixing EXLA inference into the Ortex-first desktop is a footgun. |
| **Ortex (BEAM, our proven lane)** | ⚠️ feasible | ~3–5 days after a spike | The 9-graph split maps onto patterns we ALREADY run: Moonshine drives `decoder_with_past` with an external KV-cache loop — same shape as `talker_prefill`/`talker_decode`. Elixir loop: text_project → prefill → decode-with-cache per 12Hz step → code_predictor → codec decode → wav. Unknowns: INT8 ConvInteger on CPU (may need fp16 = ~3GB, or CoreML EP), CPU RTF for a 0.6B AR model (likely near/below realtime on M-series — fine for plan mode since we **pre-render** lines, marginal for live calls). |
| **Cloud GPU (vLLM-Omni)** | ✅ best fit first | ~1–2 days | Run it where the GPUs are: a Workbooks Cloud voice endpoint (vLLM-Omni day-0), desktop `/voice/tts` server-mode proxies to it. Full quality: streaming 97ms, cloning, voice design, 10 langs. Fits the product line — **local = Kokoro free; cloud nexus = premium voice**. |

## OUTCOME (built 2026-07-05 — the spike graduated)

Local premium voice SHIPPED on the Ortex-free MLX sidecar lane:
- **1.7B-CustomVoice-4bit** (0.6B-4bit is collapsed — breathing/laughs; never ship it)
- measured **xRT ~2.0–2.2** sustained through the production `/voice/tts` route; TTFA ~1.9s
- **defaults matter**: temp 0.4 starves EOS → babble-to-cap; model-default sampling is correct
- **whole-utterance generation** (sentence-only splits) — per-clause fragments each sample
  their own emotion (the "disjointed" bug); one generation = one coherent delivery
- **process drift is real**: long-lived sidecar degrades (longer, breathier takes) —
  fixed with idle recycle every 6 generations
- **ramble guard**: max_tokens ∝ text length (a 5-word line once produced 23s of audio)
- **VoiceDesign-4bit** proven on the same sidecar (`boot?model=design`, description via
  `engine=qwen-design&design=…`) — voices from text descriptions, local
- engine LOCKED per stage session (qwen if ready at entry, else kokoro) — never mid-convo swaps

## MILESTONE DONE (2026-07-05) — personas pinned via design→clone

The VoiceDesign guidance's recommended pipeline: design a voice → keep the
winning preview clip → reuse it as a CLONE prompt (the Base model's 3-second
cloning) for every future line. That freezes a persona — same voice across
boots and recycles, no re-rolling. Also the onboarding hook: a new autopoet
designs its voice once in plan mode, the owner approves the clip, and the
clone pin makes it permanent identity. Prompt discipline (encoded in
Autopoet.VoicePersonas): identity → pitch/pace/timbre → emotion → "suitable
for…" anchor, 15–40 words, concrete adjectives, iterate one dimension at a time.

SHIPPED + owner-verified ("this worked WAY better"): the design lane INVENTS a
speaker every generation — per-sentence identity drift is inherent there, not
fixable by sampling. Consistency = the clone lane. Pipeline (mechanized): each
accepted voice's ~30s roster TAKE (takes are long; clone REFS stay short) is
cropped at a silence boundary (7–12s), transcribed by our own STT (ref_text =
crop verbatim; fix respell mishears like "autopilot" → "auto poet"), pinned as
data/voices/<name>.wav+txt. ALL 14 accepted voices pinned; the lab routes
kind:pinned through qwen-clone automatically. Default voice: qwen-clone
rosalind. If clone anchoring ever wanders: 8-bit Base, then a longer crop.

## CLONE-FROM-ANYWHERE (proven 2026-07-05)

Any clean ~7s of speech → a permanent voice. The pipeline, run end to end on a
freesound preview (pinned as `tekgnosis`):

1. fetch the audio (mp3/anything) → `afconvert` to 24k mono s16le wav
2. crop ONE clean utterance (~5–10s — the clone sweet spot; more doesn't help,
   the encoder conditions on a short window)
3. transcribe the CROP with our own STT (`POST /voice/dictate`, 16k s16le in) —
   `ref_text` must match the crop's exact words
4. pin the pair: `data/voices/<name>.wav` + `<name>.txt`
5. speak via `POST /voice/tts?engine=qwen-clone&voice=<name>` (Base 1.7B-4bit
   resident; zero-shot — NO per-voice weights, a voice is ~300KB of data)

Same machinery pins design-winners (generate → bless a take → crop+transcribe →
pin) and licensed accent sources (brit-emma came from Kokoro's bf_emma).
LICENSE NOTE: external sources carry their own licenses (freesound previews
vary CC0/CC-BY/CC-BY-NC) — check before a cloned voice ships anywhere.
Candidate roster feature: a "clone from audio" modal (URL/file → auto crop +
transcribe + pin) — the manual pipeline above, mechanized.

## THE ROSTER (the voice studio, /voices/roster)

Persistent, served by the app: verdicts (accept/reject, data/voices/verdicts),
per-voice ACCENT tags (what it actually sounds like — data/voices/accents),
status filter, "+ new voice" modal (name + prompt + accent → POST
/voices/create → /voices/regen polls the design engine until the take lands).
User personas live in data/voices/personas and shadow the compiled registry.
Prompt discipline (owner-tuned): ≤10 words, voice + use case, fast/brisk
always (pacing words skew slow), concrete adjectives (metaphors drift),
energy+youth+high-pitch = cartoon (waived only for character voices).
Accent finding: prompts can't do authentic British/Australian/Black/Southern —
accent comes from the CLONE lane; descriptions carry character.

## Recommendation

1. **Keep Kokoro as the instant local default.** 82M vs 600M is a different
   weight class; pre-render + dual lanes already work.
2. **Ship Qwen3-TTS as the CLOUD voice first** (vLLM-Omni behind the nexus,
   `/voice/tts` proxy). Days of work, full capability, on-brand with the
   cloud/local split the onboarding now sells.
3. **Spike before any desktop port** (hours): run the community ONNX sample
   on an M-series, measure CPU RTF + confirm the INT8/fp16 EP story. If RTF
   < 1 on CoreML/CPU, do the Ortex port (0.6B) as the local premium voice —
   the Moonshine KV-cache pattern carries over directly.
4. **Browser WebGPU: wait.** Revisit when an official transformers.js port
   lands; hand-rolling a 9-graph AR pipeline in JS for a 1.6GB download is
   the god-file of TTS integrations.

Sources: [QwenLM/Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) ·
[Qwen3-TTS collection](https://huggingface.co/collections/Qwen/qwen3-tts) ·
[Qwen3-TTS Technical Report](https://huggingface.co/papers/2601.15621) ·
[community ONNX INT8 export](https://huggingface.co/sivasub987/Qwen3-TTS-0.6B-ONNX-INT8) ·
[ONNX pipeline repo](https://huggingface.co/zukky/Qwen3-TTS-ONNX-DLL) ·
[transformers.js WebGPU](https://huggingface.co/docs/transformers.js/guides/webgpu)
