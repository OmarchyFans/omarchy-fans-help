#!/bin/bash
# Model bake-off for the local Omarchy agent.
#
# Records BOTH numbers that matter on a CPU-only box:
#   pp  prompt processing (prefill) -- decides time-to-first-token, and so the
#       injection budget. This is the constraint people forget to price.
#   tg  token generation -- decides how fast the answer streams out.
#
# The output feeds two decisions: which model becomes default, and what
# max_inject_chars should be set to in ~/.config/omarchy-local-agent/config.json.

set -uo pipefail
MODELS="$HOME/.local/share/omarchy-local-agent/models"
OUT="$HOME/.local/share/omarchy-local-agent/bench-results.txt"
THREADS="${THREADS:-8}"   # physical cores; SMT rarely helps llama.cpp

if ! command -v llama-bench >/dev/null; then
  echo "llama-bench not found. Install first:" >&2
  echo "  omarchy pkg add llama-cpp ggml-cpu" >&2
  exit 1
fi

{
  echo "omarchy-local-agent model bake-off"
  echo "date:    $(date -Is)"
  echo "cpu:     $(lscpu | sed -n 's/^Model name: *//p' | head -1)"
  echo "threads: $THREADS"
  echo "ram:     $(free -h | awk '/^Mem:/{print $2" total, "$7" available"}')"
  echo
} | tee "$OUT"

for m in "$MODELS"/*.gguf; do
  [[ -e "$m" ]] || continue
  name=$(basename "$m")
  size=$(du -h "$m" | cut -f1)
  echo "=== $name ($size)" | tee -a "$OUT"

  # -p 512 prefill, -n 128 generation. Two repetitions to smooth thermal noise;
  # this laptop throttles, so a single run is not trustworthy.
  if ! llama-bench -m "$m" -t "$THREADS" -p 512 -n 128 -r 2 2>&1 \
       | grep -Ev '^(ggml_|load_|llama_|build:|main:)' | tee -a "$OUT"; then
    echo "  FAILED to benchmark $name" | tee -a "$OUT"
  fi
  echo | tee -a "$OUT"
done

# ---------------------------------------------------------------------------
# Prose smoke test. llama-bench measures throughput; it cannot tell you whether
# a model actually WORKS on the PageIndex path. Two specific ways it can fail
# while still benchmarking beautifully:
#
#   - enable_thinking:false is Qwen's chat-template switch. A model that does
#     not honour it emits a <think> block, the id never arrives, and the agent
#     silently falls back to the BM25 top hit -- output looks fine, but the
#     navigation step is dead.
#   - a community chat template may not emit a parseable section id at all.
#
# So: actually run queries through each model and check the nav line.
# ---------------------------------------------------------------------------
PORT=8099

port_busy() { ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]"; }

# Kill the whole process group and WAIT for the port to be released. Without
# this the bake-off silently corrupts itself: a server that outlives its kill
# keeps :PORT bound, the next model's server fails to bind, and its smoke test
# talks to the PREVIOUS model instead -- every model after the first gets
# attributed the first one's behaviour. Caught exactly that in a dry run.
stop_server() {
  local pid="$1"
  [[ -z "$pid" ]] && return
  kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null
  for _ in $(seq 1 20); do
    port_busy || return
    sleep 1
  done
  kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
  for _ in $(seq 1 10); do
    port_busy || return
    sleep 1
  done
}

prose_smoke() {
  local model="$1" name; name=$(basename "$model")
  echo "=== prose smoke: $name" | tee -a "$OUT"

  # Refuse to run against someone else's server rather than silently
  # mis-attributing its answers to this model.
  if port_busy; then
    echo "  ABORT: port $PORT already in use -- results would be attributed to" \
         "the wrong model. Free it and re-run." | tee -a "$OUT"
    return 1
  fi

  # setsid gives the server its own process group so stop_server can take down
  # any children with it.
  setsid llama-server --model "$model" --host 127.0.0.1 --port "$PORT" \
      --ctx-size 8192 --threads "$THREADS" --no-webui >/dev/null 2>&1 &
  local pid=$!

  local ready=0
  for _ in $(seq 1 90); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { ready=1; break; }
    kill -0 $pid 2>/dev/null || break
    sleep 2
  done
  if [[ $ready -eq 0 ]]; then
    echo "  server never came up -- skipped" | tee -a "$OUT"
    stop_server "$pid"
    return
  fi

  for q in "how do I record my screen" \
           "how do I stop my laptop going to sleep" \
           "how does the clipboard history work"; do
    local t0 out
    t0=$(date +%s%3N)
    out=$(OMARCHY_AGENT_SERVER=http://127.0.0.1:$PORT \
          python3 - "$q" <<'PY' 2>&1
import importlib.util, os, sqlite3, sys
from importlib.machinery import SourceFileLoader
A = os.path.expanduser("~/.local/bin/omarchy-local-agent")
spec = importlib.util.spec_from_loader("a", SourceFileLoader("a", A))
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
cfg = a.load_config(); cfg["server"] = os.environ["OMARCHY_AGENT_SERVER"]
db = sqlite3.connect(f"file:{a.DB}?mode=ro", uri=True)
res = a.retrieve(db, sys.argv[1], cfg)
try:
    sec, raw = a.navigate(db, cfg, a.build_system(), sys.argv[1], res["sections"])
    print(f"nav={sec['sid'] if sec else 'NONE'} raw={raw[:60]!r}")
except Exception as e:
    print(f"nav=ERROR {e}")
PY
)
    local t1 ms; t1=$(date +%s%3N); ms=$((t1 - t0))
    printf "  [%d.%03ds] %s\n    %s\n" \
      "$((ms / 1000))" "$((ms % 1000))" "$q" "$out" | tee -a "$OUT"
    case "$out" in
      *"<think>"*) echo "    WARNING: thinking not suppressed for this model" | tee -a "$OUT" ;;
      *nav=NONE*|*nav=ERROR*) echo "    WARNING: navigation failed" | tee -a "$OUT" ;;
    esac
  done

  stop_server "$pid"
  echo | tee -a "$OUT"
}

for m in "$MODELS"/*.gguf; do
  [[ -e "$m" ]] || continue
  prose_smoke "$m"
done

cat <<'NOTE' | tee -a "$OUT"

--- reading this ---
Take pp (t/s) from the winning model and set the injection budget:

    max_inject_chars ~= target_ttft_seconds * pp_tokens_per_sec * 4

e.g. a 3s target at 150 t/s prefill -> ~1800 tokens -> ~7200 chars.
Then edit ~/.config/omarchy-local-agent/config.json and re-run:
    python3 ~/.local/share/omarchy-local-agent/eval.py
NOTE

echo
echo "saved to $OUT"
