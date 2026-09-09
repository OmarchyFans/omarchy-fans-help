#!/usr/bin/env bash
# Fetch GGUF weights for the local Omarchy agent, pinned and verified.
#
# Every model is bound to an immutable Hugging Face revision (a commit SHA, so
# the URL cannot change under us) and to the SHA-256 of the exact file. A
# download is published into models/ only after its digest matches; on a
# mismatch the partial is discarded, never resumed. Limits cap connection
# time, total time, and size so a stalled or oversized transfer fails instead
# of hanging.
#
#   tools/fetch-models.sh              # the default model only
#   tools/fetch-models.sh --all        # the whole bake-off set (~27 GB)
#   tools/fetch-models.sh NAME...      # specific entries from the table
#   tools/fetch-models.sh --verify     # re-check every file already present
set -euo pipefail
MODELS="${OMARCHY_LOCAL_AGENT_MODELS:-$HOME/.local/share/omarchy-local-agent/models}"
MAX_TIME="${FETCH_MAX_TIME:-14400}"      # seconds for one file (27B on slow links)
CONNECT_TIMEOUT="${FETCH_CONNECT_TIMEOUT:-30}"

# name | repo | revision (commit SHA) | file in repo | local name | sha256 | size bytes
TABLE='
qwen3.8-4b     empero-ai/Qwen3.8-4B-Distill-GGUF      391fc7d103e3942a408def3e4f51c2f85d464417 Qwen3.8-4B-Q4_K_M.gguf               Qwen3.8-4B-Distill-Q4_K_M.gguf  dec96e8cf2e11b613bb46513dec485377f9ca5a351e71712ee0e244f287c6790 2783446304
qwen3.5-4b     unsloth/Qwen3.5-4B-GGUF                e87f176479d0855a907a41277aca2f8ee7a09523 Qwen3.5-4B-Q4_K_M.gguf               Qwen3.5-4B-Q4_K_M.gguf          00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4 2740937888
nemotron-4b    nvidia/NVIDIA-Nemotron-3-Nano-4B-GGUF  ba223d14e45525f7fae81db77ea8cabeb2fc6c25 NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf Nemotron-3-Nano-4B-Q4_K_M.gguf  be5d9a656a51922f24f1f09a759cebb694e1f5d9728bf0ef9f8c972c5a0b5ef2 2837072864
gemma-e2b-iq2  unsloth/gemma-4-E2B-it-GGUF            0314792d7f1f7e229411f620751375812bb9faf2 gemma-4-E2B-it-UD-IQ2_M.gguf         gemma-4-E2B-it-UD-IQ2_M.gguf    3d95ada2a122c9c0b42803317239b64b262ac9226a307ff895b3d87eec0c2acd 2290860128
gemma-e2b-qat  google/gemma-4-E2B-it-qat-q4_0-gguf    675cff42a74c774d6cb76f76d8eacb49b48c9b93 gemma-4-E2B_q4_0-it.gguf             gemma-4-E2B-it-qat-q4_0.gguf    fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634 3349516256
qwen3.8-27b    unsloth/Qwen3.8-27B-GGUF               4ca720788d1e01f1bff70c033e0d0028fd02e502 Qwen3.8-27B-UD-IQ4_XS.gguf           Qwen3.8-27B-UD-IQ4_XS.gguf      40fac4050e940397dbf13087afd50f4734a11805bf9d65ef8ddd7483470e6199 14252845984
'
DEFAULT=qwen3.5-4b

digest_of() { sha256sum "$1" | cut -d' ' -f1; }

verify() {  # path sha256 -> 0 if the file matches
  local got; got=$(digest_of "$1")
  [[ $got == "$2" ]]
}

fetch() {
  local name=$1 repo=$2 rev=$3 file=$4 out=$5 sha=$6 size=$7
  local dest="$MODELS/$out" part="$MODELS/$out.part"
  local url="https://huggingface.co/${repo}/resolve/${rev}/${file}"
  if [[ -s $dest ]]; then
    if verify "$dest" "$sha"; then echo "ok      $out (verified)"; return 0; fi
    echo "MISMATCH $out: digest differs from the pinned value; moving aside" >&2
    mv -f "$dest" "$dest.unverified.$(date +%s)"
  fi
  echo "fetch   $out  <- $repo@${rev:0:12}"
  rm -f "$part"                                  # never resume: a partial could straddle two upstream versions
  if ! curl -fL --retry 3 --retry-delay 5 --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        --max-filesize "$size" --proto '=https' --tlsv1.2 -o "$part" "$url"; then
    rm -f "$part"; echo "FAILED  $out (download)" >&2; return 1
  fi
  local got; got=$(stat -c %s "$part")
  if [[ $got != "$size" ]]; then rm -f "$part"; echo "FAILED  $out: size $got, expected $size" >&2; return 1; fi
  if ! verify "$part" "$sha"; then rm -f "$part"; echo "FAILED  $out: SHA-256 mismatch, partial discarded" >&2; return 1; fi
  mv -f "$part" "$dest"
  echo "done    $out (verified)"
}

mkdir -p "$MODELS"
want=()
mode=fetch
for a in "$@"; do
  case $a in
    --all) while read -r n _; do [[ -n $n ]] && want+=("$n"); done <<<"$TABLE" ;;
    --verify) mode=verify ;;
    --list) echo "$TABLE" | awk 'NF{print $1, "->", $5}'; exit 0 ;;
    -h|--help) sed -n 2,14p "$0"; exit 0 ;;
    *) want+=("$a") ;;
  esac
done
[[ ${#want[@]} -gt 0 ]] || want=("$DEFAULT")

rc=0
for n in "${want[@]}"; do
  row=$(echo "$TABLE" | awk -v n="$n" '$1==n')
  [[ -n $row ]] || { echo "unknown model: $n (see --list)" >&2; rc=1; continue; }
  read -r name repo rev file out sha size <<<"$row"
  if [[ $mode == verify ]]; then
    if [[ -s $MODELS/$out ]]; then verify "$MODELS/$out" "$sha" && echo "ok      $out" || { echo "BAD     $out" >&2; rc=1; }; else echo "absent  $out"; fi
  else
    fetch "$name" "$repo" "$rev" "$file" "$out" "$sha" "$size" || rc=1
  fi
done
exit $rc
