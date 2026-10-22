# Ravi for Linux

Ubuntu 24.04 with GNOME (other GNOME-based distros should work too). The countdown sits in the top bar,
and the stretch card floats at the top right.

## Install

```bash
bash linux/install.sh
```

It installs only for you: the app goes to `~/.local/share/ravi/app`, a `ravi` launcher to `~/.local/bin`,
an app-grid entry, a start-at-login entry and the Ctrl+Alt+R shortcut. If a few Ubuntu packages are missing
(WebKitGTK and the top-bar indicator library) it installs them with `sudo apt`, so it may ask for your
password once. Run it again after any update; it replaces the old copy and restarts Ravi.

If Ctrl+Alt+R is already taken, the installer leaves your shortcut alone and tells you. Pick another key in
Settings → Keyboard → Custom Shortcuts with the command `~/.local/bin/ravi --focus`.

## Use

| Where | Key | Does |
| --- | --- | --- |
| anywhere | Ctrl+Alt+R | give Ravi's card the keyboard; press again to hand it back |
| nudge | Enter | start the rep timer, then Enter (or D) when done |
| nudge | S / X / H | snooze 5 min / skip / how to |
| nudge | M or Esc | tuck it into a small pill (it stays waiting) |
| card | P / M / N | pause / in a meeting / stretch now |
| card | 1–5 | every 15 / 20 / 30 / 45 / 60 min |
| card | C / V / Esc | chime / moves on and off / hide |

The top-bar menu has the same controls plus "Start watching when I log in". Locking the screen or closing the
lid for 3+ minutes restarts the clock, and an unanswered nudge from before you left goes away without counting
as a skip. The tally is kept in `~/.local/share/ravi/state.json`.

No countdown in the top bar? Turn on the indicator extension:
`gnome-extensions enable ubuntu-appindicators@ubuntu.com`

Uninstall: `bash linux/uninstall.sh` (add `--purge` to delete the tally too).

## How it works

`ravi.py` is a GTK 3 app showing `shared/card.html` in WebKitGTK. The card is an XWayland window on purpose:
on GNOME's Wayland session only X11 windows may place themselves at the top right and stay on top. It maps
without taking focus; Ctrl+Alt+R is a GNOME custom shortcut that runs `ravi --focus`, which reaches the running
app over D-Bus (`app.ravi.Ravi`). Screen lock and sleep come from `org.gnome.ScreenSaver` and logind.
