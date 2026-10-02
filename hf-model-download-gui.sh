#!/usr/bin/env bash
# Launch the HF Model Downloader web GUI (opens a browser tab on 127.0.0.1).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$DIR/hf-model-download-gui.py" "$@"
