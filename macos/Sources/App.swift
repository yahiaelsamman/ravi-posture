// Ravi for macOS: the menu-bar item, the floating card panel, ⌃⌥R, login item, sleep/lock events,
// and the glue between RaviCore (Core.swift, the logic) and the shared card (shared/card.html).

import AppKit
import WebKit
import ServiceManagement
import Carbon.HIToolbox

let WEB_URL = "https://github.com/yahiaelsamman/ravi-posture"

// MARK: - Floating card window

final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CardWebView: WKWebView {
    // Let the first click on the card press its button instead of only focusing the panel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - App

@MainActor
final class RaviApp: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, WKScriptMessageHandler, RaviHost {
    var core: RaviCore!
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var statusLine: NSMenuItem?
    var panel: CardPanel!
    var web: CardWebView!
    var timer: Timer?

    var jsReady = false
    var pendingShow = false
    var wantFocus = false
    var onScreen = false
    var focused = false
    var cssSize = NSSize(width: 456, height: 220)
    var anchor = NSPoint.zero            // top-right corner the card hangs from
    var previousApp: NSRunningApplication?
    var hotKeyRef: EventHotKeyRef?

    static var dataDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ravi", isDirectory: true)
    }

    var sharedDir: URL { Bundle.main.resourceURL!.appendingPathComponent("shared", isDirectory: true) }

    // MARK: launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Ravi is enough: ask the running one to show itself and bow out.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            DistributedNotificationCenter.default().postNotificationName(.raviShow, object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }

        RaviCore.log = { NSLog("Ravi: %@", $0) }
        let stateFile = RaviApp.dataDir.appendingPathComponent("state.json")
        let freshInstall = !FileManager.default.fileExists(atPath: stateFile.path) && UserDefaults.standard.data(forKey: "days") == nil
        RaviCore.migrateIfNeeded(from: UserDefaults.standard, to: stateFile)
        do {
            core = try RaviCore(host: self, sharedDir: sharedDir, stateFile: stateFile)
        } catch {
            let a = NSAlert()
            a.messageText = "Ravi couldn't find its card"
            a.informativeText = "The app looks incomplete (\(error.localizedDescription)). Build it again with macos/build.sh."
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        core.boot()
        if freshInstall { setOpenAtLogin(true, quiet: true) }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = RaviApp.menuIcon()
            b.imagePosition = .imageLeading
            b.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            b.toolTip = "Ravi"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        setupPanel()
        registerHotKey()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(wentAway), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(wentAway), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(wentAway), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(cameBack), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(cameBack), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(cameBack), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(wentAway), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(cameBack), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        dnc.addObserver(self, selector: #selector(themeChanged), name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        dnc.addObserver(self, selector: #selector(showFromElsewhere), name: .raviShow, object: nil)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(focusMayHaveChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(focusMayHaveChanged), name: NSApplication.didResignActiveNotification, object: nil)

        let t = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        t.tolerance = 0.25
        RunLoop.main.add(t, forMode: .common)
        timer = t
        statusChanged()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        core?.onShow()   // opened Ravi again from Finder or Spotlight
        return false
    }

    @objc func showFromElsewhere() { core?.onShow() }

    // MARK: menu bar icon

    static func menuIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let crimp = NSBezierPath(roundedRect: NSRect(x: 1.2, y: 1.2, width: 15.6, height: 15.6), xRadius: 5, yRadius: 5)
            crimp.lineWidth = 1.3
            let dash: [CGFloat] = [1.3, 1.5]
            crimp.setLineDash(dash, count: 2, phase: 0)
            crimp.stroke()
            let pillow = NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 10, height: 10), xRadius: 3.2, yRadius: 3.2)
            pillow.lineWidth = 1.4
            pillow.stroke()
            NSBezierPath(ovalIn: NSRect(x: 6.1, y: 8.9, width: 1.8, height: 1.8)).fill()
            NSBezierPath(ovalIn: NSRect(x: 10.1, y: 8.9, width: 1.8, height: 1.8)).fill()
            let smile = NSBezierPath()
            smile.move(to: NSPoint(x: 6.9, y: 6.9))
            smile.curve(to: NSPoint(x: 11.1, y: 6.9), controlPoint1: NSPoint(x: 7.8, y: 5.6), controlPoint2: NSPoint(x: 10.2, y: 5.6))
            smile.lineWidth = 1.2
            smile.lineCapStyle = .round
            smile.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: card panel

    func setupPanel() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "ravi")
        cfg.websiteDataStore = .nonPersistent()      // the card keeps nothing in the browser
        let frame = NSRect(origin: .zero, size: cssSize)
        web = CardWebView(frame: frame, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = nil

        panel = CardPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                      // the card draws its own shadow
        // The card is drawn by the web view, which macOS doesn't count as part of the window's own
        // pixels, so a clear window would let every click fall through to the app underneath.
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.contentView = web

        let card = sharedDir.appendingPathComponent("card.html")
        web.loadFileURL(card, allowingReadAccessTo: sharedDir)
    }

    func js(_ code: String) {
        web.evaluateJavaScript(code, completionHandler: nil)
    }

    /// Top right of the screen your pointer is on, just under the menu bar.
    func takeAnchor() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        anchor = NSPoint(x: vf.maxX + 8, y: vf.maxY)   // the card's 20 pt transparent margin hangs past the edge
    }

    func placePanel() {
        let f = NSRect(x: anchor.x - cssSize.width, y: anchor.y - cssSize.height, width: cssSize.width, height: cssSize.height)
        panel.setFrame(f, display: true)
    }

    func showNow() {
        pendingShow = false
        guard core.mode != "none" else { return }
        takeAnchor()
        placePanel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()                 // shows without taking the keyboard
        onScreen = true
        if wantFocus { wantFocus = false; focusCard() }
    }

    func showWhenReady(tries: Int = 0) {
        guard pendingShow else { return }
        if jsReady || tries > 20 { showNow(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showWhenReady(tries: tries + 1) }
    }

    // MARK: RaviHost

    var hasFocus: Bool { focused }

    var theme: String {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
    }

    func render(_ stateJSON: String) {
        if jsReady { js("window.Ravi && Ravi.update(\(stateJSON))") }
    }

    func present(focus: Bool) {
        wantFocus = wantFocus || focus
        core.push()
        if onScreen {
            if wantFocus { wantFocus = false; focusCard() }
        } else {
            // normally the card reports its size for this mode first and then shows (see "size")
            pendingShow = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.showWhenReady() }
        }
    }

    func hideCard() {
        pendingShow = false
        wantFocus = false
        let had = focused || NSApp.isActive
        panel.orderOut(nil)
        onScreen = false
        if had { handBack() }
        updateFocus()
    }

    func releaseFocus() {
        let wasActive = NSApp.isActive
        if panel.isKeyWindow {
            panel.orderOut(nil)                      // drop key status…
            if onScreen { panel.orderFrontRegardless() }   // …but keep the card where it is
        }
        if wasActive { handBack() }
        updateFocus()
    }

    func statusChanged() {
        guard let b = statusItem?.button, let core = core else { return }
        let text = core.menuBarText()
        let title = text.isEmpty ? "" : " " + text
        if b.title != title { b.title = title }
        statusLine?.title = core.trayLine()
    }

    func chime(_ kind: String) {
        let name = kind == "done" ? "Hero" : "Glass"
        _ = NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: keyboard focus

    /// Bring the card to the keyboard (and Homerow).
    func focusCard() {
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me {
            previousApp = front
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(web)
        updateFocus()
    }

    /// Hand the keyboard back to whatever you were using before.
    func handBack() {
        if let p = previousApp, !p.isTerminated { p.activate(options: []) } else { NSApp.deactivate() }
        previousApp = nil
    }

    @objc func focusMayHaveChanged() { updateFocus() }
    func windowDidBecomeKey(_ notification: Notification) { updateFocus() }
    func windowDidResignKey(_ notification: Notification) { updateFocus() }

    func updateFocus() {
        let f = panel.isKeyWindow
        guard f != focused else { return }
        focused = f
        core.focusChanged()
        if !f && core.mode == "home" {
            // the home card behaves like a popover: click elsewhere and it goes away
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self, !self.focused, self.core.mode == "home" else { return }
                self.core.hideCard()
            }
        }
    }

    // MARK: messages from the card

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String,
              let msg = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        switch msg["t"] as? String {
        case "ready":
            jsReady = true
            core.push()
        case "size":
            guard (msg["mode"] as? String) == core.mode,
                  let w = (msg["w"] as? NSNumber)?.doubleValue, let h = (msg["h"] as? NSNumber)?.doubleValue else { return }
            cssSize = NSSize(width: w, height: h)
            if onScreen { placePanel() }
            if pendingShow { showNow() }
        default:
            core.onMessage(msg)
        }
    }

    // MARK: clock and OS events

    @objc func tick() { core.tick() }
    @objc func wentAway() { core.wentAway() }
    @objc func cameBack() { core.back() }

    @objc func themeChanged() {
        // the new appearance isn't applied until the notification has been handled
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.core.push() }
    }

    // MARK: global shortcut ⌃⌥R

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData = userData else { return OSStatus(0) }
            let app = Unmanaged<RaviApp>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in app.core.onFocusKey() }
            return OSStatus(0)
        }, 1, &spec, me, nil)
        let id = EventHotKeyID(signature: OSType(0x5241_5649), id: 1) // "RAVI"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { NSLog("Ravi: ⌃⌥R is taken by another app (%d)", status) }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let line = NSMenuItem(title: core.trayLine(), action: nil, keyEquivalent: "")
        line.isEnabled = false
        statusLine = line
        menu.addItem(line)
        add(menu, core.todayLine(), nil).isEnabled = false
        add(menu, "Last 7 days: \(core.weekDone()) done", nil).isEnabled = false
        menu.addItem(.separator())

        if let n = core.nudge, !n.finished {
            let show = add(menu, core.mode == "pill" ? "Open the stretch card" : "Use the card with the keyboard", #selector(focusFromMenu), key: "r")
            show.keyEquivalentModifierMask = [.control, .option]
            if core.nudgePhase != "active" { add(menu, "Start the stretch", #selector(startFromMenu)) }
            add(menu, "Snooze 5 minutes", #selector(snoozeFromMenu))
            add(menu, "Skip this one", #selector(skipFromMenu))
            if core.mode == "nudge" { add(menu, "Minimize the card", #selector(minimizeFromMenu)) }
        } else {
            let show = add(menu, "Show Ravi", #selector(showFromMenu), key: "r")
            show.keyEquivalentModifierMask = [.control, .option]
            add(menu, "Stretch now", #selector(stretchNow))
        }
        menu.addItem(.separator())
        add(menu, core.runLabel, #selector(togglePause), key: "p")
        add(menu, "In a meeting", #selector(toggleMeeting), key: "m").state = core.st.run.meeting ? .on : .off

        let every = NSMenuItem(title: "Every", action: nil, keyEquivalent: "")
        let everyMenu = NSMenu()
        for minutes in RaviCore.intervals {
            let i = add(everyMenu, "\(minutes) minutes", #selector(setEvery(_:)))
            i.tag = minutes
            i.state = core.interval == minutes ? .on : .off
        }
        every.submenu = everyMenu
        menu.addItem(every)

        let moves = NSMenuItem(title: "Moves", action: nil, keyEquivalent: "")
        let movesMenu = NSMenu()
        for mv in core.moves {
            guard let id = mv["id"] as? String, let name = mv["name"] as? String else { continue }
            let i = add(movesMenu, name, #selector(toggleMove(_:)))
            i.representedObject = id
            i.state = core.enabled(id) ? .on : .off
        }
        movesMenu.addItem(.separator())
        add(movesMenu, "Try one now", nil).isEnabled = false
        for mv in core.moves {
            guard let id = mv["id"] as? String, let name = mv["name"] as? String else { continue }
            let i = add(movesMenu, "   " + name, #selector(tryMove(_:)))
            i.representedObject = id
        }
        moves.submenu = movesMenu
        menu.addItem(moves)
        menu.addItem(.separator())

        add(menu, "Chime", #selector(toggleChime)).state = core.st.settings.sound ? .on : .off
        add(menu, "Countdown in menu bar", #selector(toggleCountdown)).state = core.st.settings.showCountdown ? .on : .off
        add(menu, "Restart the clock when I step away", #selector(toggleAway)).state = core.st.settings.restartWhenAway ? .on : .off
        let login = add(menu, "Open at login", #selector(toggleLogin))
        if #available(macOS 13.0, *) { login.state = SMAppService.mainApp.status == .enabled ? .on : .off }
        menu.addItem(.separator())
        add(menu, "Ravi on GitHub", #selector(openWeb))
        add(menu, "Quit Ravi", #selector(quit), key: "q")
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if action != nil { i.target = self }
        menu.addItem(i)
        return i
    }

    // MARK: actions

    @objc func showFromMenu() { core.onShow() }
    @objc func stretchNow() { core.stretchNow() }
    @objc func focusFromMenu() { core.setMode("nudge", focus: true) }
    @objc func startFromMenu() { js("Ravi.act('start')") }
    @objc func snoozeFromMenu() { core.snooze() }
    @objc func skipFromMenu() { core.skip("skip") }
    @objc func minimizeFromMenu() { core.onMessage(["t": "minimize"]) }
    @objc func togglePause() { core.toggleRun() }
    @objc func toggleMeeting() { core.toggleMeeting() }
    @objc func setEvery(_ sender: NSMenuItem) { core.setInterval(sender.tag) }
    @objc func toggleChime() { core.setSound(!core.st.settings.sound) }
    @objc func toggleCountdown() { core.setShowCountdown(!core.st.settings.showCountdown) }
    @objc func toggleAway() { core.setRestartWhenAway(!core.st.settings.restartWhenAway) }

    @objc func toggleMove(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        core.setMove(id, on: !core.enabled(id))
    }

    @objc func tryMove(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        core.tryMove(id)
    }

    @objc func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        setOpenAtLogin(SMAppService.mainApp.status != .enabled, quiet: false)
    }

    func setOpenAtLogin(_ on: Bool, quiet: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            if quiet { NSLog("Ravi: couldn't change Open at login: %@", error.localizedDescription); return }
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Couldn't change Open at login"
            a.informativeText = "macOS said: \(error.localizedDescription)\n\nYou can add Ravi yourself in System Settings › General › Login Items."
            a.runModal()
        }
    }

    @objc func openWeb() {
        if let u = URL(string: WEB_URL) { NSWorkspace.shared.open(u) }
    }

    @objc func quit() {
        core.save()
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let raviShow = Notification.Name("app.ravi.show")
}

// MARK: - Entry point

@main
struct RaviMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = RaviApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        _ = delegate
    }
}
