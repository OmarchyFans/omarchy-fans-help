# Omarchy Help

Offline help for [Omarchy](https://omarchy.org), in a window that stays open
while you act on what it found. Plugin id `io.github.modpunk.omarchy-help`.

- **Search as you type** over this machine's live keybindings, the `omarchy`
  CLI, and the manual pinned to your installed version. No network, no model.
- **Run a command** from the results. It opens in a floating terminal on an
  editable prompt, so placeholders like `<name>` can be fixed before Enter.
- **Open the manual** at the matching section (read-only `nvim` in a floating
  terminal), or have the local model **explain** the section.
- **Chat with the local agent** about what to do. Answers stream from the
  llama.cpp server on your GPU (`omarchy-local-agent.service`), grounded in the
  manual section it picked, and follow-ups keep the conversation going.
- The input wraps to the window width, so long questions stay visible.
  Shift+Enter adds a line.

## Install

```sh
omarchy plugin add https://github.com/modpunk/omarchy-help
~/.config/omarchy/plugins/io.github.modpunk.omarchy-help/install.sh   # CLI helpers, keybinding, float rule
omarchy-local-agent-index                                              # build the search index
omarchy bar add io.github.modpunk.omarchy-help                         # optional bar button
```

`install.sh` copies `bin/omarchy-local-agent` and `bin/omarchy-local-agent-index`
into `~/.local/bin`, binds SUPER + CTRL + SHIFT + L to summon the window, and
adds a Hyprland rule that floats it. The chat and explain features need the
local model from the `omarchy-local-agent` service; search, run, and open work
without it.

## What can run from the panel

The user chose this model, and it applies to every execution path: an
**allowlist plus a confirmation per step**, never a plain denylist.

- **Run at once:** an `omarchy …` command the index knows, with no
  placeholder left. Your click on that specific command is the confirmation.
- **Editable prompt first:** anything else, including commands with a
  `<placeholder>` and every non-omarchy command. Nothing runs until you press
  Enter in the terminal.
- **Refused, never run and never proposed:** `sudo`, `pkexec`, `doas`,
  recursive `rm`, `find -delete`, `shred`, `dd`, `mkfs`, power commands,
  system-level `systemctl`, recursive `chmod`/`chown` outside `$HOME`, piping
  anything into a shell or interpreter, fork bombs, reading `/etc/shadow`, and
  any write to `/usr`, `/etc`, `/boot`, `/dev`. Writes only under `$HOME`.
  A "run" verdict also requires a plain argument string: any shell syntax
  (`;`, `&&`, `|`, `$(…)`, backticks, redirections) drops it to the prompt.

What keeps this safe is the shape, not the pattern list: nothing runs without
an explicit click; one-click run is limited to indexed omarchy routes with
plain arguments; everything else degrades to an editable prompt the user
reads first. The refuse list defends against model mistakes and foot-guns,
not against an adversary. A string matcher over shell text cannot be made
complete (any interpreter can destroy anything without naming a dangerous
command, which is why interpreters given `-c`/`-e` are refused outright), and
there is no untrusted input channel here: the model is local and the manual
is pinned to a tag of the official repository.

Chat answers list the commands they contain as separate "Run" buttons, one
click per step. Under each button the panel shows the verdict, what the
command reads and writes, and, when the model filled in a `<placeholder>`
from the conversation, the resolved command next to the template it came
from, so the path is visible before anything runs. Refused steps show as
blocked. `omarchy-local-agent --check '<cmd>'` prints the verdict and the
read/write preview the panel would apply.

## Keys

| Key | Search view | Chat view |
|-----|-------------|-----------|
| Enter | run command / explain section / copy keybinding / start chat | send |
| Ctrl+Enter | copy command / open manual section | |
| Shift+Enter | new line in the input | new line |
| Up / Down | move the selection | |
| Ctrl+N | | new chat |
| Esc | clear the query, then close | back to search |

Each selected row also shows its actions as buttons.

## CLI

`omarchy-local-agent` answers on the command line too:

```sh
omarchy-local-agent "how do I change my theme"     # one answer
omarchy-local-agent --repl                         # interactive
omarchy-local-agent --open-section 06-themes#0     # open the manual there
omarchy-local-agent --run 'omarchy theme set <name>'   # terminal with the command pre-filled
```

`--search-daemon` and `--chat-daemon` are the JSON-lines interfaces the window
uses. `--check CMD` prints the execution-policy verdict. Configuration lives in `~/.config/omarchy-local-agent/config.json`
(server URL, temperature, token and injection budgets).

## Repository layout

| Path | What |
|------|------|
| `HelpPanel.qml`, `BarWidget.qml`, `manifest.json` | the plugin (a thin client over the CLI) |
| `bin/omarchy-local-agent` | search, chat, explain, open, run, policy |
| `bin/omarchy-local-agent-index` | builds the index; keeps the bind-count and corpus-collapse guards |
| `tools/eval.py` | retrieval regression harness: run after any change to retrieval, ranking, stopwords, weights or the outline; report the held-out number, never tune against it |
| `tools/bench.sh`, `tools/bench-results.txt` | the model bake-off (Qwen3.8-4B-Distill won) |
| `docs/local-agent.md` | the CLI's own design notes |
| `systemd/omarchy-local-agent.service` | llama-server user unit (GPU offload, hardened) |
| `hooks/refresh-agent-index` | post-update hook that rebuilds the index |
| `config.example.json` | tuned retrieval thresholds |

The manual is pinned to the installed Omarchy version's git tag on purpose;
do not point the indexer at master.
