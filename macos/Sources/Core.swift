// Ravi's brain on macOS: the clock, which move comes next, the tally and what the card shows.
// It mirrors windows/src/Core.cs and linux/ravi.py, uses only Foundation (no AppKit), and writes the
// same state.json keys, so it can be built and tested anywhere Swift runs (see macos/Tests).
import Foundation

/// What the core needs from the window, menu bar and OS around it. Everything runs on the main thread.
@MainActor
public protocol RaviHost: AnyObject {
    var hasFocus: Bool { get }
    var theme: String { get }               // "light" or "dark"
    func render(_ stateJSON: String)        // window.Ravi.update(state) in the card
    func present(focus: Bool)               // show the card for the current mode
    func hideCard()                         // take the card off screen, keyboard goes back to your app
    func releaseFocus()                     // keep the card where it is, keyboard goes back to your app
    func statusChanged()                    // refresh the menu bar
    func chime(_ kind: String)              // "nudge", "done" or "test" (macOS plays system sounds)
}

// MARK: - State on disk (same keys as the Linux and Windows state.json)

public struct Settings: Codable {
    public var interval = 20
    public var sound = true
    public var enabled: [String: Bool] = [:]
    public var startOnLogin = true          // start watching when Ravi starts
    public var restartWhenAway = true       // lock or sleep for 3+ min starts the clock over
    public var showCountdown = true         // minutes left next to the menu-bar icon

    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 20
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? true
        enabled = try c.decodeIfPresent([String: Bool].self, forKey: .enabled) ?? [:]
        startOnLogin = try c.decodeIfPresent(Bool.self, forKey: .startOnLogin) ?? true
        restartWhenAway = try c.decodeIfPresent(Bool.self, forKey: .restartWhenAway) ?? true
        showCountdown = try c.decodeIfPresent(Bool.self, forKey: .showCountdown) ?? true
    }
}

public struct RunState: Codable {
    public var running = false
    public var paused = false
    public var meeting = false
    public var held = false
    public var nextDueAt: Double?
    public var remaining: Double?
    public var cycleStart: Double?
    public var recent: [String] = []
    public var snoozedMove: String?

    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        meeting = try c.decodeIfPresent(Bool.self, forKey: .meeting) ?? false
        held = try c.decodeIfPresent(Bool.self, forKey: .held) ?? false
        nextDueAt = try c.decodeIfPresent(Double.self, forKey: .nextDueAt)
        remaining = try c.decodeIfPresent(Double.self, forKey: .remaining)
        cycleStart = try c.decodeIfPresent(Double.self, forKey: .cycleStart)
        recent = try c.decodeIfPresent([String].self, forKey: .recent) ?? []
        snoozedMove = try c.decodeIfPresent(String.self, forKey: .snoozedMove)
    }
}

public struct Day: Codable, Equatable {
    public var done = 0
    public var snoozed = 0
    public var skipped = 0
    public var moves: [String: Int] = [:]

    public init(done: Int = 0, snoozed: Int = 0, skipped: Int = 0, moves: [String: Int] = [:]) {
        self.done = done; self.snoozed = snoozed; self.skipped = skipped; self.moves = moves
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        done = try c.decodeIfPresent(Int.self, forKey: .done) ?? 0
        snoozed = try c.decodeIfPresent(Int.self, forKey: .snoozed) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        moves = try c.decodeIfPresent([String: Int].self, forKey: .moves) ?? [:]
    }
}

public struct LogBook: Codable {
    public var days: [String: Day] = [:]
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        days = try c.decodeIfPresent([String: Day].self, forKey: .days) ?? [:]
    }
}

public struct SavedState: Codable {
    public var settings = Settings()
    public var run = RunState()
    public var log = LogBook()
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        run = try c.decodeIfPresent(RunState.self, forKey: .run) ?? RunState()
        log = try c.decodeIfPresent(LogBook.self, forKey: .log) ?? LogBook()
    }
}

public final class Nudge {
    public let key: Int
    public let move: String
    public let intro: Bool
    public let manual: Bool
    public let opened: Double
    public var finished = false
    init(key: Int, move: String, intro: Bool, manual: Bool, opened: Double) {
        self.key = key; self.move = move; self.intro = intro; self.manual = manual; self.opened = opened
    }
}

// MARK: - The core

@MainActor
public final class RaviCore {
    public static let minute: Double = 60
    public static let intervals = [15, 20, 30, 45, 60]
    static let snoozeSecs: Double = 5 * 60
    public static let awayReset: Double = 3 * 60   // locked or asleep at least this long: start a fresh cycle
    static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    weak var host: RaviHost?
    let stateFile: URL
    let clock: () -> Double
    var rng: RandomNumberGenerator

    public var st = SavedState()
    public private(set) var moves: [[String: Any]] = []
    private var moveById: [String: [String: Any]] = [:]
    private var lines: [String: [String]] = [:]

    public var mode = "none"            // none | nudge | pill | home
    public var nudge: Nudge?
    public var nudgePhase: String?      // intro | due | active | done
    private var nudgeSeq = 0, snoozeStreak = 0
    private var awaySince: Double?
    private var lastTick: Double = 0
    private var moodPose: String?, bubble = ""
    private var moodUntil: Double = 0, lineAt: Double = 0

    public var platform = "macos"
    public var grabKeys = ["⌃", "⌥", "R"]
    public static var log: (String) -> Void = { _ in }

    public init(host: RaviHost, sharedDir: URL, stateFile: URL,
                clock: (() -> Double)? = nil, rng: RandomNumberGenerator = SystemRandomNumberGenerator()) throws {
        self.host = host
        self.stateFile = stateFile
        self.clock = clock ?? { Date().timeIntervalSince1970 }
        self.rng = rng
        try loadMoves(sharedDir.appendingPathComponent("moves.json"))
    }

    // MARK: setup
    private func loadMoves(_ url: URL) throws {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        for case let m as [String: Any] in root["moves"] as? [Any] ?? [] {
            guard let id = m["id"] as? String else { continue }
            moves.append(m)
            moveById[id] = m
        }
        for (k, v) in root["lines"] as? [String: Any] ?? [:] {
            lines[k] = (v as? [Any] ?? []).compactMap { $0 as? String }
        }
    }

    public func boot() {
        st = load()
        st.run.meeting = false; st.run.held = false; st.run.snoozedMove = nil
        lastTick = now
        bubble = pick("off")
        if st.settings.startOnLogin {
            startCycle()
            bubble = "Okay. I'll check on you in \(interval) minutes."
        } else {
            st.run.running = false; st.run.paused = false
            st.run.nextDueAt = nil; st.run.remaining = nil; st.run.cycleStart = nil
        }
        save()
    }

    func load() -> SavedState {
        var s = SavedState()
        if let data = try? Data(contentsOf: stateFile), let v = try? JSONDecoder().decode(SavedState.self, from: data) { s = v }
        if !RaviCore.intervals.contains(s.settings.interval) { s.settings.interval = 20 }
        let keys = s.log.days.keys.sorted()
        if keys.count > 60 { for k in keys.prefix(keys.count - 60) { s.log.days.removeValue(forKey: k) } }
        return s
    }

    public func save() {
        do {
            try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try enc.encode(st).write(to: stateFile, options: .atomic)
        } catch {
            RaviCore.log("couldn't save state: \(error)")
        }
    }

    /// Ravi for Mac before the shared card kept its tally in UserDefaults. Carry it over once.
    public static func migrateIfNeeded(from d: UserDefaults, to stateFile: URL) {
        guard !FileManager.default.fileExists(atPath: stateFile.path), let data = d.data(forKey: "days") else { return }
        var s = SavedState()
        if let days = try? JSONDecoder().decode([String: Day].self, from: data) { s.log.days = days }
        let iv = d.integer(forKey: "interval")
        if intervals.contains(iv) { s.settings.interval = iv }
        if let v = d.object(forKey: "chime") as? Bool { s.settings.sound = v }
        if let v = d.object(forKey: "showCountdown") as? Bool { s.settings.showCountdown = v }
        if let v = d.object(forKey: "restartWhenAway") as? Bool { s.settings.restartWhenAway = v }
        for id in d.stringArray(forKey: "disabledMoves") ?? [] { s.settings.enabled[id] = false }
        s.run.recent = Array((d.stringArray(forKey: "recent") ?? []).prefix(5))
        do {
            try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(s).write(to: stateFile, options: .atomic)
            RaviCore.log("carried over \(s.log.days.count) days from the old Ravi for Mac")
        } catch {
            RaviCore.log("couldn't carry over the old tally: \(error)")
        }
    }

    // MARK: helpers
    public var now: Double { clock() }
    public var interval: Int { st.settings.interval }

    private func localDate(_ t: Double) -> Date { Date(timeIntervalSince1970: t) }
    private func dkey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private var today: String { dkey(localDate(now)) }
    public func clockText(_ t: Double) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: localDate(t))
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    public static func fmt(_ secs: Double) -> String {
        let s = max(0, Int(secs.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func pick(_ kind: String) -> String {
        guard let arr = lines[kind], !arr.isEmpty else { return "" }
        return arr[Int.random(in: 0..<arr.count, using: &rng)]
    }

    @discardableResult
    public func ownDay(_ k: String? = nil, _ change: (inout Day) -> Void = { _ in }) -> Day {
        let key = k ?? today
        var d = st.log.days[key] ?? Day()
        change(&d)
        st.log.days[key] = d
        return d
    }

    public func dayOf(_ k: String? = nil) -> Day { st.log.days[k ?? today] ?? Day() }

    private func say(_ text: String) { bubble = text; lineAt = now }
    private func mood(_ pose: String, _ text: String, _ secs: Double) { moodPose = pose; moodUntil = now + secs; say(text) }
    public func enabled(_ id: String) -> Bool { st.settings.enabled[id] ?? true }

    private func startCycle() {
        let t = now
        st.run.running = true; st.run.paused = false; st.run.held = false
        st.run.cycleStart = t; st.run.nextDueAt = t + Double(interval) * RaviCore.minute; st.run.remaining = nil
    }

    // MARK: core -> card
    public func push() { host?.render(RaviCore.json(buildState())) }

    public static func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    public func buildState() -> [String: Any] {
        [
            "mode": mode, "theme": host?.theme ?? "light", "flat": false, "platform": platform,
            "grabKeys": grabKeys, "focused": host?.hasFocus ?? false, "sound": st.settings.sound,
            "nativeChime": true,
            "nudge": nudgePayload() ?? NSNull(),
            "home": mode == "home" ? homePayload() : NSNull(),
        ]
    }

    private func nudgePayload() -> [String: Any]? {
        guard let n = nudge, let m = moveById[n.move] else { return nil }
        return [
            "key": n.key, "move": m, "intro": n.intro, "manual": n.manual,
            "doneToday": dayOf().moves[n.move] ?? 0, "total": dayOf().done, "time": clockText(n.opened),
        ]
    }

    public func status() -> (state: String, text: String) {
        let r = st.run
        if let n = nudge, !n.manual, nudgePhase != "done" { return ("due", "Stretch time") }
        if r.running && r.meeting { return ("meeting", r.held ? "In a meeting · 1 waiting" : "In a meeting") }
        if r.running { return ("running", "Watching your posture") }
        if r.paused { return ("paused", "Paused") }
        return ("off", "Not started")
    }

    private func homePayload() -> [String: Any] {
        let t = now, r = st.run
        let iv = Double(interval) * RaviCore.minute
        let (s, stText) = status()
        var label = "Ready when you are", text = RaviCore.fmt(iv), frac = 0.0, isNow = false
        if s == "due" { label = "Right now"; text = "Stretch"; frac = 1; isNow = true }
        else if r.running && r.held { label = "Waiting for your meeting to end"; text = "0:00"; frac = 1 }
        else if r.running, let due = r.nextDueAt {
            let left = due - t
            label = r.meeting ? "In a meeting · next stretch in" : "Next stretch in"
            text = RaviCore.fmt(left); frac = 1 - left / iv
        } else if r.paused {
            let rem = r.remaining ?? iv
            label = "Paused with"; text = RaviCore.fmt(rem); frac = 1 - rem / iv
        }
        let pose = moodUntil > t ? (moodPose ?? "idle") : r.meeting ? "shh" : r.paused ? "crossed" : r.running ? "idle" : "wave"

        let d = dayOf()
        let chips: [[Any]] = d.moves.filter { $0.value > 0 && moveById[$0.key] != nil }
            .sorted { $0.value > $1.value }
            .map { [moveById[$0.key]?["name"] as? String ?? $0.key, $0.value] }
        var week: [[String: Any]] = []
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: localDate(t))
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "en_US_POSIX")
        weekday.dateFormat = "EEEE"
        for i in stride(from: 6, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -i, to: startOfToday) ?? startOfToday
            let wd = cal.component(.weekday, from: day) - 1
            week.append(["d": i == 0 ? "Today" : RaviCore.dayNames[wd], "v": dayOf(dkey(day)).done,
                         "today": i == 0, "title": weekday.string(from: day)])
        }
        return [
            "status": s, "statusText": stText, "label": label, "countdown": text,
            "frac": max(0, min(1, frac)), "isNow": isNow, "interval": interval,
            "mainLabel": runLabel, "running": r.running, "meeting": r.meeting, "sound": st.settings.sound,
            "bubble": bubble, "pose": pose,
            "today": ["done": d.done, "snoozed": d.snoozed, "skipped": d.skipped, "chips": chips],
            "week": week,
            "moves": moves.map { m -> [String: Any] in
                let id = m["id"] as? String ?? ""
                return ["id": id, "name": m["name"] ?? "", "area": m["area"] ?? "", "dose": m["dose"] ?? "", "on": enabled(id)]
            },
        ]
    }

    // MARK: card -> core
    /// Handles a message from the card. Returns false for the ones the host deals with (ready, size).
    @discardableResult
    public func onMessage(_ msg: [String: Any]) -> Bool {
        func str(_ k: String) -> String? {
            switch msg[k] {
            case let s as String: return s
            case let n as NSNumber: return n.stringValue
            default: return nil
            }
        }
        func bool(_ k: String) -> Bool {
            switch msg[k] {
            case let b as Bool: return b
            case let n as NSNumber: return n.boolValue
            case let s as String: return s == "true" || s == "True"
            default: return false
            }
        }
        switch str("t") {
        case "phase":
            if let n = nudge, str("key") == String(n.key) { nudgePhase = str("phase"); host?.statusChanged() }
        case "finish": finish()
        case "skip": skip(str("how") ?? "skip")
        case "snooze": snooze()
        case "closed": closeNudge()
        case "minimize":
            if nudge != nil { mode = "pill"; push(); host?.releaseFocus() }
        case "restore":
            if nudge != nil { setMode("nudge", focus: host?.hasFocus ?? false) }
        case "unfocus": host?.releaseFocus(); push()
        case "hide": hideCard()
        case "toggleRun": toggleRun()
        case "meeting": toggleMeeting()
        case "stretchNow": stretchNow()
        case "try":
            if let id = str("id"), moveById[id] != nil { openNudge(id, intro: false, manual: true, focus: host?.hasFocus ?? false) }
        case "interval":
            if let m = str("m").flatMap({ Int($0) }) { setInterval(m) }
        case "sound": setSound(bool("on"))
        case "moveOn":
            if let id = str("id"), moveById[id] != nil { setMove(id, on: bool("on")) }
        default:
            return false
        }
        return true
    }

    public func focusChanged() { push() }

    // MARK: modes
    public func setMode(_ m: String, focus: Bool) {
        mode = m
        host?.present(focus: focus)
    }

    public func hideCard() {
        mode = "none"
        host?.hideCard()
        push()
    }

    // MARK: stretching
    public func pickMove() -> String {
        var pool = moves.filter { enabled($0["id"] as? String ?? "") }
        if pool.isEmpty { pool = moves }
        let done = dayOf().moves
        let recent = st.run.recent
        var best = pool.first?["id"] as? String ?? ""
        var bestScore = Double.greatestFiniteMagnitude
        for m in pool {
            let id = m["id"] as? String ?? ""
            var score = Double(done[id] ?? 0) * 2 + Double.random(in: 0..<1.5, using: &rng)
            if let i = recent.firstIndex(of: id) { score += Double(6 - min(i, 5)) * 3 }
            if score < bestScore { bestScore = score; best = id }
        }
        return best
    }

    private func dueMove() -> String {
        let sm = st.run.snoozedMove
        st.run.snoozedMove = nil
        if let sm = sm, moveById[sm] != nil { return sm }
        return pickMove()
    }

    private func remember(_ id: String) {
        st.run.recent = Array(([id] + st.run.recent.filter { $0 != id }).prefix(5))
    }

    private func scheduleNext() {
        if st.run.running {
            st.run.cycleStart = now
            st.run.nextDueAt = now + Double(interval) * RaviCore.minute
        } else if st.run.paused {
            st.run.remaining = Double(interval) * RaviCore.minute
        }
        st.run.held = false
    }

    public func openNudge(_ id: String, intro: Bool = true, manual: Bool = false, focus: Bool = false) {
        nudgeSeq += 1
        nudge = Nudge(key: nudgeSeq, move: id, intro: intro, manual: manual, opened: now)
        nudgePhase = intro ? "intro" : "due"
        if intro {
            say("Up you get. Quick one.")
            if st.settings.sound { host?.chime("nudge") }
        }
        setMode("nudge", focus: focus)
        host?.statusChanged()
    }

    public func finish() {
        guard let n = nudge, !n.finished else { return }
        n.finished = true
        ownDay { d in d.done += 1; d.moves[n.move, default: 0] += 1 }
        remember(n.move)
        scheduleNext()
        snoozeStreak = 0
        nudgePhase = "done"
        mood("cheer", pick("done"), 4.5)
        if st.settings.sound { host?.chime("done") }
        save(); push()
        host?.statusChanged()
    }

    public func skip(_ how: String) {
        guard let n = nudge else { return }
        if n.finished { closeNudge(); return }
        if !n.manual {
            ownDay { $0.skipped += 1 }
            remember(n.move)
            if how == "skip" { st.run.snoozedMove = nil }
            scheduleNext()
            snoozeStreak = 0
            mood("crossed", pick("skip"), 4)
            save()
        }
        closeNudge()
    }

    public func snooze() {
        guard let n = nudge else { return }
        ownDay { $0.snoozed += 1 }
        if st.run.running {
            st.run.nextDueAt = now + RaviCore.snoozeSecs
            st.run.cycleStart = (st.run.nextDueAt ?? now) - Double(interval) * RaviCore.minute
        } else if st.run.paused {
            st.run.remaining = RaviCore.snoozeSecs
        }
        st.run.held = false
        st.run.snoozedMove = n.move
        snoozeStreak += 1
        let sl = lines["snooze"] ?? [""]
        mood("crossed", sl[max(0, min(snoozeStreak, sl.count) - 1)], 4.5)
        save()
        closeNudge()
    }

    public func closeNudge() {
        nudge = nil
        nudgePhase = nil
        if mode == "nudge" || mode == "pill" { hideCard() } else { push() }
        host?.statusChanged()
    }

    // MARK: controls (menu bar, card, ⌃⌥R)
    /// ⌃⌥R: take keyboard focus; press again to hand it back.
    public func onFocusKey() {
        let focused = host?.hasFocus ?? false
        if nudge != nil {
            if focused {
                if mode == "nudge" && nudgePhase != "done" { mode = "pill"; push() }
                host?.releaseFocus()
                push()
            } else {
                setMode("nudge", focus: true)
            }
        } else if mode == "home" && focused {
            hideCard()
        } else {
            setMode("home", focus: true)
        }
    }

    public func onShow() { setMode(nudge != nil ? "nudge" : "home", focus: true) }

    public func toggleRun() {
        let t = now
        if st.run.running {
            st.run.remaining = max(0, (st.run.nextDueAt ?? t) - t)
            st.run.running = false; st.run.paused = true; st.run.nextDueAt = nil
            say(pick("paused"))
        } else if st.run.paused {
            let rem = st.run.remaining ?? Double(interval) * RaviCore.minute
            st.run.running = true; st.run.paused = false; st.run.nextDueAt = t + rem; st.run.remaining = nil
            st.run.cycleStart = t + rem - Double(interval) * RaviCore.minute
            say(pick("running"))
        } else {
            startCycle()
            say("Okay. I'll check on you in \(interval) minutes.")
        }
        save(); push(); host?.statusChanged()
    }

    public func toggleMeeting() {
        st.run.meeting.toggle()
        if st.run.meeting {
            say(pick("meeting"))
        } else if st.run.held {
            st.run.held = false
            save()
            openNudge(dueMove(), intro: true, focus: host?.hasFocus ?? false)
            return
        } else {
            say(pick("running"))
        }
        save(); push(); host?.statusChanged()
    }

    public func stretchNow() {
        if nudge != nil { setMode("nudge", focus: true); return }
        openNudge(pickMove(), intro: false, manual: true, focus: true)
    }

    public func tryMove(_ id: String) {
        guard moveById[id] != nil else { return }
        if nudge == nil || nudge?.manual == true { openNudge(id, intro: false, manual: true, focus: host?.hasFocus ?? false) }
    }

    public func setInterval(_ m: Int) {
        guard RaviCore.intervals.contains(m) else { return }
        st.settings.interval = m
        let t = now
        if st.run.running, let start = st.run.cycleStart, st.run.nextDueAt != nil {
            st.run.nextDueAt = max(t + 10, start + Double(m) * RaviCore.minute)
        } else if st.run.paused, let rem = st.run.remaining {
            st.run.remaining = min(rem, Double(m) * RaviCore.minute)
        }
        save(); push(); host?.statusChanged()
    }

    public func setSound(_ on: Bool) {
        st.settings.sound = on
        if on { host?.chime("test") }
        save(); push(); host?.statusChanged()
    }

    public func setMove(_ id: String, on: Bool) {
        st.settings.enabled[id] = on
        save(); push()
    }

    public func setRestartWhenAway(_ on: Bool) { st.settings.restartWhenAway = on; save() }
    public func setShowCountdown(_ on: Bool) { st.settings.showCountdown = on; save(); host?.statusChanged() }

    // MARK: the clock
    public func tick() {
        let t = now
        let gap = t - lastTick
        lastTick = t
        if gap > 90 && awaySince == nil { cameBack(gap) }   // the Mac slept without telling us
        if st.run.running, let due = st.run.nextDueAt, t >= due, nudge == nil, awaySince == nil {
            st.run.nextDueAt = nil
            if st.run.meeting {
                st.run.held = true
                say(pick("held"))
                save()
            } else {
                save()
                openNudge(dueMove(), intro: true)
            }
        }
        if st.run.running && nudge == nil && !st.run.meeting && !st.run.held && moodUntil < t && t - lineAt > 16 {
            say(pick("running"))
        }
        host?.statusChanged()
        if mode == "home" { push() }
    }

    // MARK: away (locked, asleep or screens off)
    public var isAway: Bool { awaySince != nil }

    public func wentAway() { if awaySince == nil { awaySince = now } }

    public func back() { if let s = awaySince { cameBack(now - s) } }

    public func cameBack(_ away: Double) {
        awaySince = nil
        lastTick = now
        guard away >= RaviCore.awayReset, st.settings.restartWhenAway else { return }
        if let n = nudge, !n.manual, nudgePhase == "intro" || nudgePhase == "due" {
            // you were up and about; that unanswered nudge is moot (not counted as a skip)
            nudge = nil
            nudgePhase = nil
            if mode == "nudge" || mode == "pill" { mode = "none"; host?.hideCard() }
        }
        if st.run.running && !st.run.held {   // a stretch held for a meeting stays held
            startCycle()
            say(pick("back"))
        }
        save(); push(); host?.statusChanged()
    }

    // MARK: menu-bar text
    public func trayLine() -> String {
        let r = st.run
        if status().state == "due" { return "Stretch time" }
        if r.running && r.held { return "In a meeting · 1 stretch waiting" }
        if isAway && r.running { return "Away · the clock restarts when you're back" }
        if r.running && r.meeting, let due = r.nextDueAt { return "In a meeting · stretch held from \(clockText(due))" }
        if r.running, let due = r.nextDueAt { return "Next stretch at \(clockText(due)) (\(RaviCore.fmt(due - now)))" }
        if r.running { return "Watching your posture" }
        if r.paused { return "Paused with \(RaviCore.fmt(r.remaining ?? Double(interval) * RaviCore.minute)) left" }
        return "Not started"
    }

    /// Short text next to the menu-bar icon: "14m", "stretch", "later", "paused".
    public func menuBarText() -> String {
        guard st.settings.showCountdown else { return "" }
        let r = st.run
        if status().state == "due" { return "stretch" }
        if r.running && r.held { return "later" }
        if r.paused { return "paused" }
        if r.running, let due = r.nextDueAt {
            return "\(Int((max(0, due - now) / 60).rounded(.up)))m"
        }
        return ""
    }

    public func todayLine() -> String {
        let d = dayOf()
        return "Today: \(d.done) done · \(d.snoozed) snoozed · \(d.skipped) skipped"
    }

    public func weekDone() -> Int {
        let cal = Calendar.current
        let start = cal.startOfDay(for: localDate(now))
        return (0..<7).reduce(0) { sum, i in
            sum + dayOf(dkey(cal.date(byAdding: .day, value: -i, to: start) ?? start)).done
        }
    }

    public var runLabel: String { st.run.running ? "Pause" : st.run.paused ? "Resume" : "Start my workday" }
    public var isDue: Bool { status().state == "due" }

    // test helpers
    public func devDue() { st.run.running = true; st.run.nextDueAt = now - 1 }
}
