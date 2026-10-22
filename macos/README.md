# Ravi for macOS

A menu-bar app (Swift, AppKit, WKWebView) for macOS 13 or later. The card floats over every app, Space and
full-screen window. ⌃⌥R hands it the keyboard, and it works with Homerow.

## Build and install

```bash
bash macos/build.sh
```

Needs the Xcode Command Line Tools (`xcode-select --install`). The script builds a universal `Ravi.app`
(Apple silicon and Intel), copies it to Applications and starts it. Run it again after any change.

A ready-made `Ravi-macos.zip` is attached to each GitHub release. It isn't notarized, so the first time macOS
blocks it: open **System Settings → Privacy & Security** and choose **Open Anyway** (or build it yourself as above).

## Use

Click the ravioli in the menu bar for Stretch now, Pause, In a meeting, how often (15–60 min), which moves
are in the rotation, today's tally, Chime, Countdown in menu bar, **Restart the clock when I step away**
and Open at login.

| Key | Does |
| --- | --- |
| ⌃⌥R | give the card the keyboard; again to hand it back. With no stretch waiting it opens Ravi's home card |
| Enter, then Enter or D | start the rep timer, then done |
| S / X / H | snooze 5 min / skip / how to |
| M or Esc | tuck the card into a pill |
| P / M / N on the home card | pause / in a meeting / stretch now |

The tally lives in `~/Library/Application Support/Ravi/state.json`, in the same format as the Linux and Windows
versions. If you used the earlier Ravi for Mac, its tally and settings are carried over the first time.

## How it works

- `Sources/Core.swift`: the clock, move picking, tally and what the card shows. Foundation only, the same logic as
  `windows/src/Core.cs` and `linux/ravi.py`.
- `Sources/App.swift`: menu-bar item, the non-activating panel holding `shared/card.html`, ⌃⌥R (Carbon hot key),
  login item (`SMAppService`), sleep/lock/wake notifications, dark mode, macOS system sounds.
- `Resources/AppIcon.iconset`: the app icon. `build.sh` copies the shared card, moves, fonts and icons into the app.

## Tests

```bash
cd macos/Tests
swiftc -O -parse-as-library ../Sources/Core.swift CoreTests.swift -o core-tests && ./core-tests ../../shared
```

60 checks over a simulated working day. They run on macOS and on Linux (any Swift 5.9+ toolchain).
