# Ravi for Windows

Windows 10 and 11. Needs nothing extra: .NET Framework 4.8 and Microsoft Edge WebView2 already come with Windows.

## Install

1. Download `Ravi-windows.zip` and unzip it anywhere.
2. Double-click `install.cmd`. It copies Ravi to `%LOCALAPPDATA%\Programs\Ravi`, adds it to the Start menu
   and starts it. No admin rights needed.

Ravi then lives in the tray, the ravioli by the clock (it may sit under the `^` arrow; drag it out to keep it
visible). It opens at login; switch that off in its tray menu.

If Windows says "Windows protected your PC", choose **More info → Run anyway**: the app isn't code-signed.

## Use

| Key | Does |
| --- | --- |
| Ctrl+Alt+R | give the card the keyboard; again to hand it back |
| Enter, then Enter or D | start the rep timer, then done |
| S / X / H | snooze 5 min / skip / how to |
| M or Esc | tuck the card into a pill |
| P / M / N on the home card | pause / in a meeting / stretch now |
| 1–5 / C / V | interval / chime / moves on and off |

Left-click the tray icon for the home card, right-click for the menu (pause, meeting, interval, chime,
open at login, today's tally). Locking the PC or sleeping for 3+ minutes restarts the clock.

`Ravi.exe --stretch`, `--toggle`, `--meeting`, `--focus` and `--quit` talk to the running Ravi, so you can
bind them to anything that launches programs.

Uninstall: double-click `uninstall.cmd` in `%LOCALAPPDATA%\Programs\Ravi`. Your history in `%APPDATA%\Ravi`
stays unless you run it with `-Purge`.

## Build

```
dotnet build -c Release
```

Output goes to `bin/Release/net48`, with the shared card copied in. It builds on Windows, Linux or macOS with
the .NET SDK (8 or later).

## How it works

- `src/Core.cs`: the clock, move picking, tally and what the card shows. It mirrors `linux/ravi.py`, has no UI
  code, and writes the same `state.json` keys as the Linux version.
- `src/CardWindow.cs`: a borderless always-on-top window holding `shared/card.html` in WebView2. It shows
  without activating (`WS_EX_NOACTIVATE`), gets Windows 11's rounded corners, and parks off screen rather than
  hiding, so the web view never reloads or grabs focus.
- `src/App.cs`: tray icon, Ctrl+Alt+R (`RegisterHotKey`), open at login (`HKCU\...\Run`), lock and sleep events,
  dark mode.
- `src/Ipc.cs`, `src/Program.cs`: one Ravi per user; a second launch passes its command over a named pipe.

## Tests

```
cd tests
dotnet build -c Release && mono bin/Release/net48/CoreTests.exe ../../shared    # or run CoreTests.exe on Windows
RAVI_DUMP=/tmp/ravi mono bin/Release/net48/CoreTests.exe ../../shared && python3 card_test.py ../../shared /tmp/ravi /tmp/shots
```

`CoreTests` runs a working day through the core with a fake clock (51 checks). `card_test.py` feeds the states it
produced to `card.html` in Chromium, the engine inside WebView2, and steps through a stretch by keyboard and mouse.
