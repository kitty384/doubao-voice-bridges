#!/bin/bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
bash "$repo_dir/apps/headset-bridge/build.sh"
zsh "$repo_dir/apps/uu-voice-bridge/scripts/build-app.sh"
