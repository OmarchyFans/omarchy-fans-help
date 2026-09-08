### Repository URL

https://github.com/modpunk/omarchy-help

### Category

System

### Tags

ai, education, system

### Suggest a missing tag

_No response_

### Maintainer notes

Offline help for Omarchy: a bar button and a persistent Quickshell window (panel kind, keepLoaded, FloatingWindow) that searches this machine's keybindings, the `omarchy` CLI, and the manual pinned to the installed version's git tag, with an optional local LLM (llama-server on 127.0.0.1, user unit, hardened) for explanations and chat. The QML only runs the plugin's own Python CLI via argv (`--search-daemon`, `--chat-daemon`, `--open-section`, `--run`) plus `wl-copy` and `hyprctl dispatch focuswindow`. Commands offered to the user go through an execution policy in the CLI: indexed `omarchy` routes with plain arguments run in a terminal on click, everything else opens on an editable prompt, and sudo/pkexec, recursive rm, dd, mkfs, pipe-to-shell, interpreter one-liners, eval/exec, and writes outside $HOME are refused outright; nothing runs without a click. No network at query time; the indexer fetches the manual once from omacom/omarchy at the installed tag over HTTPS, and `tools/fetch-models.sh` downloads GGUF files from Hugging Face as plain data (never executed). `systemctl` references are for the user unit only; the only `sudo`/`pkexec` mentions in the tree are the policy's refuse list and its tests (the plugin never escalates). `install.sh` prints what it will change and asks y/N before appending marker-tagged lines to bindings.lua / looknfeel.lua (backups kept); `uninstall.sh` removes exactly those. MIT.

### Submission checklist

- [x] The repository is public and contains installation and removal instructions.
- [x] I have documented the plugin license and any external dependencies.
- [x] I confirm that I own or have permission to submit this plugin and its preview assets.
- [x] The plugin does not overwrite user configuration without explicit consent.
- [x] I understand that approval is for listing and is not a security review.
