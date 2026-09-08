#!/usr/bin/env bash
# Omarchy Help: the parts a plugin cannot ship by itself.
#   1. copy the CLI helpers to ~/.local/bin (omarchy-local-agent, omarchy-local-agent-index)
#   2. add a SUPER + CTRL + SHIFT + L keybinding that summons the help window
#   3. add a window rule that floats the window (it tiles without this)
# Idempotent: every line it adds carries the plugin id, and reruns replace it.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MARK="io.github.modpunk.omarchy-help"

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
  sed -i "/$MARK/s|^o\.bind(.*|$BIND|" "$B"
  echo "updated keybinding in $B"
else
  mkdir -p "$(dirname "$B")"
  printf '\n-- Omarchy Help (%s): summon the help window.\n%s\n' "$MARK" "$BIND" >> "$B"
  echo "added keybinding to $B"
fi

LF="$HOME/.config/hypr/looknfeel.lua"
if [[ -f $LF ]] && grep -q "$MARK) window" "$LF"; then
  echo "window rule already in $LF"
else
  mkdir -p "$(dirname "$LF")"
  cat >> "$LF" <<RULE

-- Omarchy Help ($MARK) window: float it (it tiles without this).
o.window({ class = "^org.quickshell$", title = "^Omarchy Help$" }, { float = true, center = true, size = { 760, 580 } })
RULE
  echo "added window rule to $LF"
fi

command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1 || true
[[ -f $HOME/.local/share/omarchy-local-agent/index.db ]] || echo "No index yet: run omarchy-local-agent-index"
