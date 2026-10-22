#!/usr/bin/env bash
# Installs Ravi the Ravioli for you (no system-wide files) on Ubuntu 24.04 / GNOME.
#   bash linux/install.sh            install or update, then start Ravi
#   bash linux/install.sh --no-key   same, but leave your keyboard shortcuts alone
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="$(cd "$SRC/../shared" && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
APP="$DATA/ravi/app"
BIN="$HOME/.local/bin"
LAUNCH="$BIN/ravi"
KEY="<Control><Alt>r"
SET_KEY=1
[ "${1:-}" = "--no-key" ] && SET_KEY=0

bold(){ printf '\n\033[1m%s\033[0m\n' "$*"; }
ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

bold "1/5  Checking what Ravi needs"
need=()
gi_has(){ /usr/bin/python3 -c "import gi; gi.require_version('$1','$2'); from gi.repository import $1" 2>/dev/null; }
/usr/bin/python3 -c "import gi" 2>/dev/null || need+=(python3-gi)
gi_has Gtk 3.0 || need+=(gir1.2-gtk-3.0)
gi_has WebKit2 4.1 || need+=(gir1.2-webkit2-4.1)
gi_has AyatanaAppIndicator3 0.1 || need+=(gir1.2-ayatanaappindicator3-0.1)
/usr/bin/python3 -c "import gi, cairo; gi.require_foreign('cairo')" 2>/dev/null || need+=(python3-gi-cairo)
command -v gdbus >/dev/null 2>&1 || need+=(libglib2.0-bin)
if [ ${#need[@]} -gt 0 ]; then
  echo "  Installing ${need[*]} from Ubuntu's own archive (sudo asks for your password)."
  sudo apt-get install -y "${need[@]}" || { sudo apt-get update && sudo apt-get install -y "${need[@]}"; }
fi
ok "Python, GTK, WebKit and the top-bar indicator library are there"

bold "2/5  Copying Ravi to $APP"
mkdir -p "$DATA/ravi" "$BIN"
rm -rf "$APP.new"
mkdir -p "$APP.new"
cp "$SRC/ravi.py" "$APP.new/"
cp -r "$SHARED/card.html" "$SHARED/moves.json" "$SHARED/fonts" "$SHARED/icons" "$APP.new/"
chmod +x "$APP.new/ravi.py"
rm -rf "$APP.old"
[ -d "$APP" ] && mv "$APP" "$APP.old"
mv "$APP.new" "$APP"
rm -rf "$APP.old"
install -m 755 "$SRC/bin/ravi" "$LAUNCH"
install -D -m 644 "$SHARED/icons/ravi.svg" "$DATA/icons/hicolor/scalable/apps/ravi.svg"
ok "app in $APP, launcher in $LAUNCH"

bold "3/5  App grid entry and start at login"
mkdir -p "$DATA/applications" "$CONF/autostart"
cat > "$DATA/applications/ravi.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Ravi
GenericName=Posture coach
Comment=A ravioli who nudges you to stretch every 20 minutes
Exec=$LAUNCH
Icon=ravi
Terminal=false
Categories=Utility;
Keywords=posture;stretch;break;ravioli;
StartupNotify=false
Actions=stretch;toggle;meeting;

[Desktop Action stretch]
Name=Stretch now
Exec=$LAUNCH --stretch

[Desktop Action toggle]
Name=Pause or resume
Exec=$LAUNCH --toggle

[Desktop Action meeting]
Name=In a meeting (on/off)
Exec=$LAUNCH --meeting
EOF
cat > "$CONF/autostart/ravi.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Ravi
Comment=Posture coach
Exec=$LAUNCH --autostart
Icon=ravi
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
EOF
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$DATA/applications" 2>/dev/null || true
gtk-update-icon-cache -q -t "$DATA/icons/hicolor" 2>/dev/null || true
ok "find it as \"Ravi\" with Super; it starts by itself when you log in"

bold "4/5  Keyboard shortcut Ctrl+Alt+R"
if [ "$SET_KEY" = 1 ]; then
  set +e
  result="$(/usr/bin/python3 - "$LAUNCH --focus" "$KEY" <<'PY'
import re, sys
from gi.repository import Gio

cmd, key = sys.argv[1], sys.argv[2]
MK = "org.gnome.settings-daemon.plugins.media-keys"
PATH = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ravi/"
src = Gio.SettingsSchemaSource.get_default()
if not src or not src.lookup(MK, True):
    print("no-gnome"); sys.exit(2)

def norm(b):
    b = b.lower().replace("<primary>", "<control>").replace("<ctrl>", "<control>")
    return "".join(sorted(re.findall(r"<[^>]+>", b))) + re.sub(r"<[^>]+>", "", b)

target = norm(key)
clash = []
for schema in ("org.gnome.desktop.wm.keybindings", "org.gnome.shell.keybindings", "org.gnome.mutter.keybindings",
               "org.gnome.mutter.wayland.keybindings", MK):
    if not src.lookup(schema, True):
        continue
    s = Gio.Settings.new(schema)
    for k in s.props.settings_schema.list_keys():
        v = s.get_value(k)
        if v.get_type_string() not in ("s", "as"):
            continue
        vals = v.unpack()
        for b in ([vals] if isinstance(vals, str) else vals):
            if b and norm(b) == target:
                clash.append(f"{schema.split('.')[-1]}: {k}")
mk = Gio.Settings.new(MK)
paths = list(mk.get_strv("custom-keybindings"))
for p in paths:
    if p == PATH:
        continue
    c = Gio.Settings.new_with_path(MK + ".custom-keybinding", p)
    if norm(c.get_string("binding")) == target:
        clash.append(f"your custom shortcut \"{c.get_string('name')}\"")
if clash:
    print("clash: " + "; ".join(clash)); sys.exit(3)
c = Gio.Settings.new_with_path(MK + ".custom-keybinding", PATH)
c.set_string("name", "Ravi: focus the stretch card")
c.set_string("command", cmd)
c.set_string("binding", key)
if PATH not in paths:
    mk.set_strv("custom-keybindings", paths + [PATH])
Gio.Settings.sync()
print("ok")
PY
)"
  rc=$?
  set -e
  case "$rc" in
    0) ok "Ctrl+Alt+R gives Ravi's card the keyboard; press it again to hand it back" ;;
    3) warn "Ctrl+Alt+R is already taken (${result#clash: }). Left it alone."
       warn "Pick another key in Settings → Keyboard → Custom Shortcuts with the command: $LAUNCH --focus" ;;
    *) warn "Couldn't set the shortcut automatically ($result). Add it in Settings → Keyboard → Custom Shortcuts:"
       warn "  command: $LAUNCH --focus    shortcut: Ctrl+Alt+R" ;;
  esac
else
  ok "skipped (--no-key)"
fi

bold "5/5  Starting Ravi"
"$LAUNCH" --quit >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.NameHasOwner app.ravi.Ravi 2>/dev/null | grep -q true || break
  sleep 0.3
done
setsid -f "$LAUNCH" --show >/dev/null 2>&1 < /dev/null
ok "Ravi is running: countdown in the top bar, card at the top right"

if command -v gnome-extensions >/dev/null 2>&1; then
  if ! gnome-extensions info ubuntu-appindicators@ubuntu.com 2>/dev/null | grep -Eq "State: (ACTIVE|ENABLED)|Enabled: Yes"; then
    warn "The Ubuntu AppIndicators extension looks off, so the top-bar countdown won't show."
    warn "Turn it on with: gnome-extensions enable ubuntu-appindicators@ubuntu.com"
  fi
fi
printf '\n  Uninstall any time with: bash "%s/uninstall.sh"\n\n' "$SRC"
