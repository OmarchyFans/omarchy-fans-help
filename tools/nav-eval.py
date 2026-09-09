#!/usr/bin/env python3
"""Per-model navigation accuracy over the held-out prose questions.

bench.sh's prose smoke asks three questions, which is enough to prove a model
CAN emit a section id but nowhere near enough to choose between models — all
five candidates passed 3/3. This runs the full held-out prose set against each
model and scores whether PageIndex navigation landed in the right chapter.

This is the number that should pick the default. Throughput only decides ties.

  ./nav-eval.py                  # every gguf in models/
  ./nav-eval.py qwen3.8 gemma    # only models whose filename matches
"""

import importlib.util
import json
import os
import re
import subprocess
import sqlite3
import sys
import time
import urllib.error
import urllib.request
from importlib.machinery import SourceFileLoader

ROOT = os.path.expanduser("~/.local/share/omarchy-local-agent")
MODELS = os.path.join(ROOT, "models")
PORT = 8098

spec = importlib.util.spec_from_loader(
    "agent", SourceFileLoader("agent", os.path.expanduser("~/.local/bin/omarchy-local-agent")))
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)

sys.path.insert(0, ROOT)
import eval as E  # noqa: E402

# Only the prose cases: fast-path lookups never reach the model.
CASES = [(q, want) for q, path, want in E.HELDOUT + E.CASES if path == "prose"]


def wait_ready(proc, timeout=180):
    for _ in range(timeout):
        if proc.poll() is not None:
            return False
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=2)
            return True
        except (urllib.error.URLError, OSError):
            time.sleep(1)
    return False


def score(model_path, cfg, db, system):
    hits = misses = errors = 0
    detail = []
    for query, want in CASES:
        res = agent.retrieve(db, query, cfg)
        try:
            sec, raw = agent.navigate(db, cfg, system, query, res["sections"])
        except Exception as e:
            errors += 1
            detail.append((query, want, f"ERROR {type(e).__name__}"))
            continue
        got = sec["sid"] if sec else "NONE"
        if sec and got.startswith(want):
            hits += 1
        else:
            misses += 1
            detail.append((query, want, got))
    return hits, misses, errors, detail


def main():
    filters = [a.lower() for a in sys.argv[1:]]
    ggufs = sorted(f for f in os.listdir(MODELS) if f.endswith(".gguf"))
    if filters:
        ggufs = [g for g in ggufs if any(f in g.lower() for f in filters)]

    cfg = dict(agent.load_config(), server=f"http://127.0.0.1:{PORT}", timeout=90)
    db = sqlite3.connect(f"file:{agent.DB}?mode=ro", uri=True)
    system = agent.build_system()

    print(f"{len(CASES)} prose questions per model\n")
    results = []
    for g in ggufs:
        path = os.path.join(MODELS, g)
        proc = subprocess.Popen(
            ["llama-server", "--model", path, "--host", "127.0.0.1",
             "--port", str(PORT), "--ctx-size", "8192", "--threads", "8",
             "--n-gpu-layers", "99", "--no-webui"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True)
        name = g.replace(".gguf", "")
        if not wait_ready(proc):
            print(f"  {name:<30} server never came up — skipped")
            proc.kill(); proc.wait()
            continue

        t0 = time.time()
        hits, misses, errors, detail = score(path, cfg, db, system)
        elapsed = time.time() - t0
        pct = 100 * hits / len(CASES)
        print(f"  {name:<30} {hits:>2}/{len(CASES)}  ({pct:4.0f}%)  "
              f"{elapsed/len(CASES):.1f}s/query" + (f"  {errors} errors" if errors else ""))
        results.append((hits, name, detail))

        proc.kill(); proc.wait()
        for _ in range(20):   # wait for the port before the next model
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=1)
                time.sleep(1)
            except (urllib.error.URLError, OSError):
                break

    if results:
        results.sort(reverse=True)
        print(f"\n  best: {results[0][1]} at {results[0][0]}/{len(CASES)}")
        print("\n  misses for the winner:")
        for q, want, got in results[0][2][:8]:
            print(f"    {q[:48]:<50} want {want:<28} got {got}")


if __name__ == "__main__":
    main()
