#!/bin/sh
# Build the Qwen3-TTS sidecar venv (data/qwen-tts-venv). Idempotent.
set -e
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
V="$DIR/data/qwen-tts-venv"
PY="${QWEN_PY:-/opt/homebrew/bin/python3.12}"
[ -x "$V/bin/python" ] || "$PY" -m venv "$V"
"$V/bin/pip" install -q --upgrade pip
"$V/bin/pip" install -q mlx-audio soundfile numpy
# import-time tokenizer registration breaks vs new transformers — best-effort it
TU="$V/lib/python3.12/site-packages/mlx_lm/tokenizer_utils.py"
if [ -f "$TU" ] && ! grep -q "except Exception" "$TU"; then
  export TU
  "$V/bin/python" - << 'PYEOF'
import os
p = os.environ["TU"]
s = open(p).read()
t = 'AutoTokenizer.register("NewlineTokenizer", fast_tokenizer_class=NewlineTokenizer)'
if t in s:
    s = s.replace(t, 'try:\n    ' + t + '\nexcept Exception:\n    pass')
    open(p, 'w').write(s)
    print("patched tokenizer_utils")
PYEOF
fi
"$V/bin/python" -c "import mlx_audio, soundfile; print('qwen-tts venv ready')"

# ICL rep-penalty: mlx-audio floors it at 1.5; official Qwen3-TTS uses 1.05
# everywhere (checkpoint generation_config). The floor perturbs codec tokens →
# audible timbre drift in clone mode. Honor the caller instead.
python3 - << 'PYEOF'
import mlx_audio.tts.models.qwen3_tts.qwen3_tts as q
f = q.__file__
s = open(f).read()
old = "icl_rep_penalty = max(repetition_penalty, 1.5)"
if old in s:
    open(f, "w").write(s.replace(old, "icl_rep_penalty = repetition_penalty  # official 1.05; see setup.sh"))
    print("patched ICL rep penalty")
PYEOF
