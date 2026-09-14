#!/usr/bin/env bash
# Omarchy Help: the parts a plugin cannot ship by itself.
#   1. copy the CLI helpers to ~/.local/bin (omarchy-local-agent, omarchy-local-agent-index)
#   2. add a SUPER + CTRL + SHIFT + L keybinding that summons the help window
#   3. add a window rule that floats the window (it tiles without this)
# Idempotent: every line it adds carries the plugin id, and reruns replace it.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MARK="io.github.modpunk.omarchy-help"

cat <<MSG
This will:
  - copy omarchy-local-agent and omarchy-local-agent-index to ~/.local/bin
  - append a SUPER + CTRL + SHIFT + L keybinding to ~/.config/hypr/bindings.lua
  - append a float rule for the "Omarchy Help" window to ~/.config/hypr/looknfeel.lua
  - install the post-update hook that rebuilds the index
  - add the llama-server user unit and a config file only if they do not exist yet
  - offer to download the local AI model (Qwen3.8-4B-Distill, 2.6 GB) if it is missing
Every appended line carries the marker $MARK; uninstall.sh removes them.
Backups of edited files are kept next to them.
MSG
if [[ ${1:-} != --yes ]]; then
  read -rp "Continue? [y/N] " ans
  [[ $ans == [yY]* ]] || { echo "nothing changed"; exit 0; }
fi

mkdir -p "$HOME/.local/bin"
install -m 755 "$HERE/bin/omarchy-local-agent" "$HERE/bin/omarchy-local-agent-index" "$HOME/.local/bin/"
echo "installed CLI helpers into ~/.local/bin"

# Runtime pieces are only added when missing: an existing unit or config may be tuned.
U="$HOME/.config/systemd/user/omarchy-local-agent.service"
if [[ ! -f $U ]]; then
  mkdir -p "$(dirname "$U")" && cp "$HERE/systemd/omarchy-local-agent.service" "$U"
  systemctl --user daemon-reload 2>/dev/null || true
  echo "installed $U (enable with: systemctl --user enable --now omarchy-local-agent)"
fi
C="$HOME/.config/omarchy-local-agent/config.json"
[[ -f $C ]] || { mkdir -p "$(dirname "$C")" && cp "$HERE/config.example.json" "$C" && echo "installed $C"; }
HK="$HOME/.config/omarchy/hooks/post-update.d/refresh-agent-index"
mkdir -p "$(dirname "$HK")" && install -m 755 "$HERE/hooks/refresh-agent-index" "$HK"

B="$HOME/.config/hypr/bindings.lua"
BIND="o.bind(\"SUPER + CTRL + SHIFT + L\", \"Omarchy help\", \"omarchy-shell shell summon $MARK '{}'\")"
if [[ -f $B ]] && grep -q "$MARK" "$B"; then
  # Replace whatever the marked line currently runs (older versions used toggle or --popup).
  cp "$B" "$B.bak.$(date +%s)"
  sed -i "/$MARK/s|^o\.bind(.*|$BIND|" "$B"
  echo "updated keybinding in $B"
else
  mkdir -p "$(dirname "$B")"
  [[ -f $B ]] && cp "$B" "$B.bak.$(date +%s)"
  printf '\n-- Omarchy Help (%s): summon the help window.\n%s\n' "$MARK" "$BIND" >> "$B"
  echo "added keybinding to $B"
fi

LF="$HOME/.config/hypr/looknfeel.lua"
if [[ -f $LF ]] && grep -q "$MARK) window" "$LF"; then
  echo "window rule already in $LF"
else
  mkdir -p "$(dirname "$LF")"
  [[ -f $LF ]] && cp "$LF" "$LF.bak.$(date +%s)"
  cat >> "$LF" <<RULE

-- Omarchy Help ($MARK) window: float it (it tiles without this).
o.window({ class = "^org.quickshell$", title = "^Omarchy Help$" }, { float = true, center = true, size = { 760, 580 }, opacity = "1 1" })
RULE
  echo "added window rule to $LF"
fi

# The local AI agent: Qwen3.8-4B-Distill on your own GPU. Large, so it is
# offered, never assumed: --yes alone does not download it; --with-model does.
MODEL="$HOME/.local/share/omarchy-local-agent/models/Qwen3.8-4B-Distill-Q4_K_M.gguf"
if [[ ! -f $MODEL ]]; then
  want=0
  if [[ " $* " == *" --with-model "* ]]; then want=1
  elif [[ ${1:-} != --yes && -t 0 ]]; then
    echo
    echo "Chat runs a local AI model, Qwen3.8-4B-Distill (Q4_K_M, 2.6 GB), on your GPU."
    echo "It is downloaded from Hugging Face pinned to one revision and checked against its SHA-256."
    read -rp "Download it now and start the local model service? [y/N] " ans
    [[ $ans == [yY]* ]] && want=1
  fi
  if (( want )); then
    if "$HERE/tools/fetch-models.sh"; then
      command -v llama-server >/dev/null || echo "llama-server is missing: omarchy pkg add llama-cpp ggml-cpu ggml-cuda"
      systemctl --user enable --now omarchy-local-agent 2>/dev/null && echo "local model service started"
    else
      echo "model download did not finish; rerun: $HERE/tools/fetch-models.sh"
    fi
  else
    echo "Chat needs the local model. Later: $HERE/tools/fetch-models.sh && systemctl --user enable --now omarchy-local-agent"
  fi
fi

command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1 || true
[[ -f $HOME/.local/share/omarchy-local-agent/index.db ]] || echo "No index yet: run omarchy-local-agent-index"
