#!/bin/bash
# Gemma 4 E2B, added at the user's request.
#  UD-IQ2_M  2.29GB - the genuinely smallest usable quant
#  QAT q4_0  3.35GB - Google's quantization-aware-trained build; much better
#                     quality per byte than a post-hoc Q4 of the same model
# Staged outside models/ so an in-flight bake-off's already-expanded glob is
# not disturbed; moved in afterwards.
set -uo pipefail
S="$HOME/.local/share/omarchy-local-agent/staging"
fetch() {
  local repo="$1" file="$2" out="$3"
  [[ -s "$S/$out" ]] && { echo "have $out"; return 0; }
  echo "fetch $out"
  curl -fL --retry 3 --retry-delay 5 --continue-at - \
    -o "$S/$out.part" "https://huggingface.co/${repo}/resolve/main/${file}" \
    && mv "$S/$out.part" "$S/$out" && echo "done $out" || echo "FAILED $out" >&2
}
fetch unsloth/gemma-4-E2B-it-GGUF gemma-4-E2B-it-UD-IQ2_M.gguf gemma-4-E2B-it-UD-IQ2_M.gguf
fetch google/gemma-4-E2B-it-qat-q4_0-gguf gemma-4-E2B_q4_0-it.gguf gemma-4-E2B-it-qat-q4_0.gguf
ls -lh "$S"/*.gguf 2>/dev/null | awk '{print $5, $9}'
