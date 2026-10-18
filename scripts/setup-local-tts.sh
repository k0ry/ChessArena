#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
tts_root="$PWD/.local-tts"
python_bin="${CHESSARENA_PYTHON:-python3.12}"
mkdir -p "$tts_root"
if [[ ! -x "$tts_root/venv/bin/python" ]]; then
    "$python_bin" -m venv "$tts_root/venv"
fi
"$tts_root/venv/bin/python" -m pip install --disable-pip-version-check --no-cache-dir 'mlx-audio==0.5.9'
export HF_HOME="$tts_root/cache"
export HF_HUB_DISABLE_TELEMETRY=1
export HF_HUB_DISABLE_XET=1
"$tts_root/venv/bin/python" - "$tts_root/model" <<'PY'
import sys
from huggingface_hub import snapshot_download
snapshot_download("mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
                  revision="f35faf19b0cc2160865af64ecf0f22f83d335135", local_dir=sys.argv[1])
PY
print "Qwen3-TTS installed: $tts_root"
