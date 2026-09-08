#!/bin/bash
# Fetch GGUF weights for the local Omarchy agent bake-off.
# Ordered smallest-first so the default model is usable before the 27B lands.

set -uo pipefail
MODELS="$HOME/.local/share/omarchy-local-agent/models"
mkdir -p "$MODELS"

fetch() {
  local repo="$1" file="$2" out="$3"
  local url="https://huggingface.co/${repo}/resolve/main/${file}"
  if [[ -s "$MODELS/$out" ]]; then
    echo "have    $out"
    return 0
  fi
  echo "fetch   $out  <- $repo"
  # --continue-at keeps a resumed run from restarting a 14GB download
  if curl -fL --retry 3 --retry-delay 5 --continue-at - \
       -o "$MODELS/$out.part" "$url"; then
    mv "$MODELS/$out.part" "$MODELS/$out"
    echo "done    $out"
  else
    echo "FAILED  $out" >&2
    return 1
  fi
}

fetch unsloth/Qwen3.5-4B-GGUF \
      Qwen3.5-4B-Q4_K_M.gguf \
      Qwen3.5-4B-Q4_K_M.gguf

fetch empero-ai/Qwen3.8-4B-Distill-GGUF \
      Qwen3.8-4B-Q4_K_M.gguf \
      Qwen3.8-4B-Distill-Q4_K_M.gguf

fetch nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF \
      NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf \
      Nemotron-3-Nano-4B-Q4_K_M.gguf

# The 27B the user specifically asked about. 14.25GB, fetched last.
fetch unsloth/Qwen3.8-27B-GGUF \
      Qwen3.8-27B-UD-IQ4_XS.gguf \
      Qwen3.8-27B-UD-IQ4_XS.gguf

echo
echo "=== models on disk ==="
ls -lh "$MODELS"/*.gguf 2>/dev/null | awk '{print $5, $9}'
