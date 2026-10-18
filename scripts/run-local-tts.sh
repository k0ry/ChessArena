#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export HF_HOME="$PWD/.local-tts/cache"
export HF_HUB_OFFLINE=1
export TOKENIZERS_PARALLELISM=false
exec .local-tts/venv/bin/python scripts/qwen-server.py --model .local-tts/model
