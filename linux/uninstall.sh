#!/usr/bin/env bash
# Removes Ravi the Ravioli. Your stretch history (~/.local/share/ravi/state.json)
# stays unless you run:  bash linux/uninstall.sh --purge
set -euo pipefail
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"

"$HOME/.local/bin/ravi" --quit >/dev/null 2>&1 || true
rm -rf "$DATA/ravi/app"
rm -f "$HOME/.local/bin/ravi" "$DATA/applications/ravi.desktop" "$CONF/autostart/ravi.desktop" \
      "$DATA/icons/hicolor/scalable/apps/ravi.svg"

/usr/bin/python3 - <<'PY' || true
from gi.repository import Gio
MK = "org.gnome.settings-daemon.plugins.media-keys"
PATH = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ravi/"
src = Gio.SettingsSchemaSource.get_default()
if src and src.lookup(MK, True):
    mk = Gio.Settings.new(MK)
    paths = list(mk.get_strv("custom-keybindings"))
    if PATH in paths:
        mk.set_strv("custom-keybindings", [p for p in paths if p != PATH])
    c = Gio.Settings.new_with_path(MK + ".custom-keybinding", PATH)
    for k in ("name", "command", "binding"):
        c.reset(k)
    Gio.Settings.sync()
PY

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$DATA/ravi"
  echo "Ravi removed, history included."
else
  echo "Ravi removed. Your stretch history is still in $DATA/ravi/state.json (use --purge to remove it too)."
fi
