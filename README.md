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
uses. Configuration lives in `~/.config/omarchy-local-agent/config.json`
(server URL, temperature, token and injection budgets).
