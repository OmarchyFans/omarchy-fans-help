# omarchy-local-agent

A fully local, offline assistant for Omarchy: keybindings, CLI commands, and the
manual. No network at query time.

## Status

**Working end to end, on the GPU.** Open it with `SUPER + CTRL + SHIFT + L`.

| | |
|---|---|
| GUI | Quickshell panel, live search + Enter to explain |
| Search (typing) | SQLite FTS5/BM25 — no model, ~1ms |
| Explain (Enter) | PageIndex on Qwen3.8-4B-Distill, GPU |
| Retrieval, tuned set | 20/20 |
| Retrieval, held-out set | **24/27** ← the honest generalization number |
| Answer latency | 1–3s warm, ~5s cold |
| Offline | both sets pass with no route to the internet |

The tuned 20/20 is training accuracy: thresholds, intent regexes, stopwords and
column weights were all iterated against those 20 cases. `HELDOUT` in `eval.py`
was written afterwards — **24/27 is what to believe**, and it is a *lower bound*
on the live prose path, because `eval.py` only checks BM25's top hits while the
real system also hands the model the full outline.

Two caveats, stated plainly: the de-hyphenation fix and the `what <noun> does`
intent pattern were both *found* by looking at held-out failures, so 24/27 is
slightly optimistic. The structural fixes were diagnosed before the expanded set
existed.

### What actually moved the number (21/27 → 23/27)

- **Wider fetch pool.** Re-scoring can only reorder what was retrieved. With a
  limit of 8, `06-themes#0` ranked just outside it, so no amount of re-scoring
  could ever surface it. Fetching 40 and trimming after fixed it.
- **One section per chapter.** `46-faq` alone took two of three candidate slots
  on several queries — its many short entries win on length normalisation.
  PageIndex wants a diverse slate of chapters, not three views of one.
- **De-hyphenation.** `unicode61` splits "Wi-Fi" into `wi` + `fi`, so a user
  typing "wifi" matched *nothing*. The `alt` column indexes joined forms, which
  generalises to every hyphenated term without a hand-written synonym list.

One caveat on the 23/27, stated plainly: the de-hyphenation fix is general, but
it was *found* by looking at a held-out failure ("wifi"). So one of those +2 came
from a fix inspired by the held-out set, which makes 23/27 very slightly
optimistic. The other two structural fixes were diagnosed before the expanded
set existed.

### What didn't work, and why it's documented in the code

Promoting whole-chapter overview sections looked obviously right — 23 of 51
chapters have no `##` headings and get buried by length normalisation. Measured,
it was a trap: at the magnitude that gained a held-out case it pushed overview
sections from 33% to **80% of all candidate slots** and regressed a case that
had been passing. Buying +1 on a metric by flooding every other query is metric
gaming, so there is no overview bonus. The comment in `retrieve()` says so, to
stop it being "fixed" again.

### The remaining 4 failures

Three are pure vocabulary gaps, and the words are simply absent:

| Query | Target chapter | Occurrences of the query word |
|---|---|---|
| "change the wallpaper" | `39-backgrounds` | "wallpaper" × **0** |
| "app keeps crashing" | `45-troubleshooting` | "crash" × **0** |
| "run windows software" | `28-windows-vm` | "software" × **0** |

No lexical ranker reaches those. This is precisely the job of PageIndex
navigation — the model reads `39-backgrounds: Backgrounds` in the outline and
knows a wallpaper is a background. **That is a hypothesis, not a result**, and
it is the first thing to check once `llama-cpp` is installed.

The fourth, "what terminal does this use", is path misclassification:
`classify()` returns `None` and the score comparison sends it down the fast
path. Left alone deliberately — tuning the regex against a held-out case is how
a held-out set stops meaning anything.

## What's here

| Path | What it is |
|---|---|
| `~/.local/bin/omarchy-local-agent` | The CLI. Retrieval + answer. |
| `~/.local/bin/omarchy-local-agent-index` | Index builder. Run after `omarchy update` (hooked). |
| `~/.config/omarchy-local-agent/config.json` | Tuned thresholds, model server, injection cap. |
| `~/.config/systemd/user/omarchy-local-agent.service` | `llama-server`, localhost only. |
| `~/.config/omarchy/hooks/post-update.d/refresh-agent-index` | Rebuilds the index on update. |
| `models/` | 4 GGUF files, 22 GB. |
| `eval.py` | Retrieval harness: tuned + held-out sets reported separately (`--tune` sweeps thresholds, against the tuned set only). |
| `bench.sh` | `llama-bench` bake-off across all four models. |

Keybinding: **`SUPER + CTRL + SHIFT + L`** (was free; verified against all binds).

## Finish setup

```bash
# Already done. Recorded for a rebuild on another machine:
omarchy pkg add llama-cpp ggml-cpu ggml-cuda

# Confirm the binaries landed. `pacman -Fl llama-cpp` listed nothing here, so
# they may live in a variant package if these come up empty:
command -v llama-server llama-bench

bash ~/.local/share/omarchy-local-agent/bench.sh    # ~20 min, decides the default

systemctl --user daemon-reload
systemctl --user enable --now omarchy-local-agent
```

`bench.sh` does two things: `llama-bench` for pp/tg throughput, then a **prose
smoke test** that starts each model and checks it actually returns a parseable
section id. That second part is the one that matters for model choice —
`enable_thinking:false` is a Qwen chat-template switch, and a model that ignores
it emits a `<think>` block instead of a section id. The agent then silently
falls back to the BM25 top hit: output still looks reasonable, but PageIndex
navigation is dead. The smoke test prints a `WARNING` when that happens.

It was dry-run against stubbed `llama-bench`/`llama-server` binaries, including
three failure modes: a model that emits `<think>` (warns), a server that never
starts (skips), and a port already in use (aborts). That last one exists because
the dry run exposed a real bug: `kill $pid` left a server holding `:8099`, so
the *next* model's smoke test silently talked to the *previous* model's server —
every model after the first would have been attributed the first one's
behaviour, making the whole comparison worthless. It now kills the process
group, waits for the port, and refuses to start if the port is occupied.

Then set `max_inject_chars` from the measured prefill rate — the bake-off prints
the formula.

**Switching models:** edit `MODEL=` in the service file, then
`systemctl --user restart omarchy-local-agent`. `MemoryHigh=20G` is set so the
27B (14 GB resident) is not throttled; the 4B models need far less.

**If the service fails** with "Failed to set up mount namespacing", drop
`PrivateTmp`, `ProtectSystem` and `ProtectHome` from the unit — they need
unprivileged user namespaces.

**First query after a restart** takes ~5s: the 1.7k-token system prompt prefills
cold. Every query after that reuses the cached prefix and lands in 1–3s.

## How it works

Two paths, chosen by what the question actually asks for.

**Fast path** — "keybind for X", "command to Y". BM25 over the binds and
commands tables answers directly, in ~0.00s, with no model involved. It cannot
invent a keybinding, because it only ever prints rows that exist on this machine.

**Prose path** — "how do I X", "what does Y do". PageIndex: the model reads a
cached ~1.7k-token numbered outline of the manual, names one section, that section comes
back verbatim, and it answers from that. Two calls, the first nearly free
because `llama-server` caches the static prefix.

### Why the split

A pure BM25 threshold tops out at **13/20** on the eval set. Score magnitude
cannot separate "how do I record my screen" (wants an explanation) from
"command to update omarchy" (wants a command) — both have strong exact hits.
Classifying the *question form* first takes it to 18/20. Two further fixes
reach 20/20:

- **Porter stemming.** Without it "record my screen" misses the chapter titled
  "Recording", and "resets my bar" misses "reset".
- **Intent markers are not search terms.** The word "command" in "command to
  update omarchy" describes the answer you want, not the thing you're looking
  for. Left in the query it ranks routes whose *summary* says "command" above
  `omarchy update` itself. `omarchy` gets the same treatment, but only in the
  commands table — every route starts with it, so it carries no signal there,
  while in the binds table "Omarchy menu" is exactly how you find that bind.

Column weights matter too: a hit in a heading outranks the same word buried in
body prose (`WEIGHTS` in the CLI).

### Why the manual is pinned

The index builds from git tag `v4.0.2`, matching installed `omarchy version`.
This is not pedantry — the eval caught it. The packaged skill documentation
describes `omarchy debug --no-sudo --print`, but **no `debug` route exists in
4.0.2**. Grounding on `master` would have the assistant confidently describe
commands this machine does not have.

### Why prefill, not generation, sets the budget

Generation speed is what everyone quotes, but time-to-first-token is what makes
this feel quick or not, and that is prompt processing. Hence: sections capped at
~1k tokens each, a static cached system prefix, and `--ctx-size 8192` set
explicitly so the server does not allocate KV cache for a context this workload
never uses.

## Usage

```bash
omarchy-local-agent "keybind to toggle nightlight"   # one-shot
omarchy-local-agent --repl                            # interactive
omarchy-local-agent --popup                           # floating window (the keybind)
omarchy-local-agent --retrieve-only "..."             # show retrieval, no model
omarchy-local-agent --json "..."                      # machine-readable
```

## Verify

```bash
python3 ~/.local/share/omarchy-local-agent/eval.py          # 20/20 tuned, 23/27 held out
python3 ~/.local/share/omarchy-local-agent/eval.py --tune   # re-sweep thresholds

# offline proof: no route to the internet, retrieval still passes
unshare -rn -- python3 ~/.local/share/omarchy-local-agent/eval.py
```

Reports both numbers. `eval.py` checks the *retrieved evidence*, not the model's wording, so a
retrieval regression cannot hide behind a fluent answer.

## Exercised, not just written

Paths that are easy to ship untested, and what running them found:

| Path | Result |
|---|---|
| `omarchy hook post-update` | Works, 3.8s, index valid afterwards |
| The hook under a **stripped PATH** | Found a real bug — see below |
| Index rebuild with no network | Degrades correctly — keeps the existing `v4.0.2` manual, index stays usable |
| `--popup` (the keybinding) | Opens floating 900×600 window, correct app-id, float rule applies |
| `--repl` | Fast path instant; prose path degrades to showing the closest section |
| `bench.sh` + 3 failure modes | Dry-run against stubs; found and fixed the port-reuse bug above |

**The stripped-PATH bug.** Every earlier test had exported
`PATH=$HOME/.local/bin:$PATH` first — but a hook runs under whatever
`omarchy update` gives it. Run with a bare PATH, `omarchy menu keybindings
--print` still **exits 0** and returns 2 lines instead of 231, and the builder
accepted that silently: the index would have lost ~229 keybindings with no error
anywhere, leaving an agent that looks healthy but has quietly forgotten every
keybinding. Two guards now:

- a plausibility floor (`MIN_PLAUSIBLE_BINDS`) — a suspiciously small result
  falls through to the `hyprctl` path instead of being trusted;
- a **collapse check** — if any corpus drops below half its previous size, the
  rebuild refuses and leaves the existing index untouched, exiting 1.

Verified: with a stripped PATH the hook now exits 1 and the 231-bind index
survives. The hook itself calls the binary by absolute path.

(`~/.local/bin` *is* in Hyprland's environment, so the keybinding resolves
fine — that part was checked, not assumed.)

The offline rebuild also had a **misleading diagnostic**: it reported "no tag
v4.0.2 published, falling back to master" when the real problem was that the
network was down. Those need different messages — conflating them sends you
after the wrong bug. `resolve_ref()` now distinguishes "remote unreachable"
from "remote has no such tag".

## Models

All four are downloaded. `bench.sh` decides which becomes default.

| Model | Size | Note |
|---|---|---|
| Qwen3.5-4B Q4_K_M | 2.6G | Runner-up |
| **Qwen3.8-4B-Distill Q4_K_M** | 2.6G | **Default — won the bake-off** |
| Nemotron-3-Nano-4B Q4_K_M | 2.7G | Official NVIDIA GGUF |
| Qwen3.8-27B UD-IQ4_XS | 14G | Measured 2.1 t/s prefill; every query timed out at 180s. Unusable. |

**Correction:** this machine *does* have a discrete GPU — an RTX 3050 Ti Mobile
with 4 GB VRAM. Early in the build `lspci` showed no NVIDIA device and
`nvidia-smi` reported "No supported GPUs were found", because Optimus runtime
power management drops the dGPU off the PCI bus when idle. That reading was
taken as fact and the whole thing was designed CPU-only. It is now running on
the GPU via `ggml-cuda`.

## Phase 2 — voice

`voxtype` (local Whisper STT) is already installed and bound to F9. Add
`omarchy pkg add piper` and pipe `voxtype record` output into the CLI, and the
answer back out through `piper`.

## Measured results (CPU bake-off, 8 threads)

| Model | Prefill | Generation | Manual navigation |
|---|---|---|---|
| **Qwen3.8-4B-Distill** | **39.6 t/s** | 7.7 t/s | **3/3** |
| Qwen3.5-4B | 30.2 t/s | 8.1 t/s | 3/3 |
| Nemotron-3-Nano-4B | 21.4 t/s | 8.7 t/s | 1/3 (two 180s timeouts) |
| Qwen3.8-27B IQ4_XS | 2.1 t/s | 1.4 t/s | 0/3 — all timed out |

Same winner on GPU: **1152 t/s prefill, 42 t/s generation** — 29× and 5.5×.
That is the difference between a 75-second and a 2-second cold start.

### The outline rewrite

The system prompt went 3,032 → 1,721 tokens, and got *more* accurate:

- Sections are numbered 1..265 instead of printed as `13-toggles-idle-screensaver#4`.
  Shorter, and a small model emitting one integer beats it reconstructing a
  compound id.
- **47 of 265 sections were titled "overview"** — every chapter with no `##`
  headings. The outline read `Backgrounds` on one line and `196 overview` on the
  next, so "change the wallpaper" had nothing to match and navigated to a
  *theming* section instead. Single-section chapters are now one self-describing
  line: `196 Backgrounds`.

That one fix resolved two of the three vocabulary gaps BM25 could never reach:

| Query | Before | After |
|---|---|---|
| "change the wallpaper" | theming section (wrong) | `39-backgrounds` ✓ |
| "run windows software" | FAQ (wrong) | `28-windows-vm` ✓ |
| "app keeps crashing" | — | `17-ai §Crash diagnosis` (arguably right: Omarchy diagnoses crashes via its agent) |

Held-out retrieval is now **24/27**. Warm answers land in 1–3 seconds.

## The GUI

`SUPER + CTRL + SHIFT + L` opens a Quickshell panel (plugin
`io.github.modpunk.omarchy-help`), not a terminal. Live BM25 results as you
type, Enter to explain via PageIndex, Esc to close. It uses Omarchy's `[menu]`
colour tokens, so it follows the active theme. Also a bar widget.
