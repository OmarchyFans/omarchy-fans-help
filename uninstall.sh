#!/usr/bin/env bash
# Omarchy Help: undo what install.sh added. Leaves the model files and the
# index alone (they are large and yours); tells you how to remove them.
set -euo pipefail
MARK="io.github.modpunk.omarchy-help"

ts=$(date +%s)
for f in "$HOME/.config/hypr/bindings.lua" "$HOME/.config/hypr/looknfeel.lua"; do
  [[ -f $f ]] && grep -q "$MARK" "$f" || continue
  cp "$f" "$f.bak.$ts"
  # Drop the marker comment line and the line that follows it.
  sed -i "/$MARK/{N;d;}" "$f"
  echo "removed the $MARK lines from $f (backup: $f.bak.$ts)"
done
command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1 || true

rm -f "$HOME/.local/bin/omarchy-local-agent" "$HOME/.local/bin/omarchy-local-agent-index" \
      "$HOME/.config/omarchy/hooks/post-update.d/refresh-agent-index"
echo "removed the CLI helpers and the post-update hook"

cat <<MSG
Left in place (remove yourself if you want them gone):
  systemctl --user disable --now omarchy-local-agent   # the llama-server unit
  rm ~/.config/systemd/user/omarchy-local-agent.service
  rm -r ~/.local/share/omarchy-local-agent             # index, manual copy, models (GBs)
  rm -r ~/.config/omarchy-local-agent                  # config.json
Then: omarchy plugin remove $MARK
MSG
