// Walks the macOS RaviCore through a working day with a fake clock and a fake window.
// Same walk as windows/tests/CoreTests.cs, so both cores are held to the same behaviour.
//   swiftc -O -parse-as-library ../Sources/Core.swift main.swift -o core-tests && ./core-tests ../../shared
import Foundation

final class FakeHost: RaviHost {
    var focus = false
    var lastJSON = ""
    var presents = 0, hides = 0, releases = 0
    var chimes: [String] = []
    var pushed: () -> Void = {}
    var hasFocus: Bool { focus }
    var theme: String { "light" }
    func render(_ s: String) { lastJSON = s }
    func present(focus f: Bool) { presents += 1; if f { focus = true }; pushed() }
    func hideCard() { hides += 1; focus = false }
    func releaseFocus() { releases += 1; focus = false }
    func statusChanged() {}
    func chime(_ kind: String) { chimes.append(kind) }
}

struct SeededRNG: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s }
}

@main
enum CoreTests {
    @MainActor
    static func main() {
        exit(run() ? 0 : 1)
    }

    @MainActor
    static func run() -> Bool {
        var failures = 0, checks = 0
        func check(_ ok: Bool, _ what: String) {
            checks += 1
            if !ok { failures += 1 }
            print((ok ? "  ok    " : "  FAIL  ") + what)
        }
        func near(_ a: Double?, _ b: Double) -> Bool { abs((a ?? -1) - b) < 0.001 }

        let args = CommandLine.arguments
        let shared = URL(fileURLWithPath: args.count > 1 ? args[1] : "../../shared")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ravi-tests-\(UUID().uuidString)")
        let stateFile = dir.appendingPathComponent("state.json")
        var now: Double = 1_790_000_000
        let host = FakeHost()
        let core = try! RaviCore(host: host, sharedDir: shared, stateFile: stateFile, clock: { now }, rng: SeededRNG(s: 7))
        host.pushed = { core.push() }
        func advance(_ secs: Double) {
            var t = 0.0
            while t < secs { let step = min(30, secs - t); now += step; t += 30; core.tick() }
        }
        func msg(_ t: String, _ kv: [String: Any] = [:]) -> [String: Any] { var d = kv; d["t"] = t; return d }

        print("boot")
        core.boot()
        check(core.moves.count == 24, "24 moves loaded from shared/moves.json")
        check(core.st.run.running && near(core.st.run.nextDueAt, now + 1200), "starts watching, first stretch in 20 min")
        check(FileManager.default.fileExists(atPath: stateFile.path), "state.json written")

        print("first nudge")
        advance(600)
        check(core.nudge == nil, "nothing at 10 min")
        advance(600)
        check(core.nudge != nil && core.nudge!.intro && !core.nudge!.manual, "nudge appears at 20 min")
        check(core.mode == "nudge" && host.presents == 1 && !host.focus, "card shown without taking focus")
        check(core.status().state == "due", "status says stretch time")
        check(host.chimes == ["nudge"], "plays the macOS chime")
        let first = core.nudge!.move

        print("snooze")
        core.onMessage(msg("phase", ["phase": "due", "key": core.nudge!.key]))
        check(core.nudgePhase == "due", "phase from the card is tracked")
        core.onMessage(msg("snooze"))
        check(core.mode == "none" && core.nudge == nil && host.hides == 1, "snooze hides the card")
        check(core.dayOf().snoozed == 1, "snooze counted")
        check(near(core.st.run.nextDueAt, now + 300), "back in 5 min")
        advance(300)
        check(core.nudge?.move == first, "the snoozed move comes back first")

        print("finish")
        core.onMessage(msg("phase", ["phase": "active", "key": core.nudge!.key]))
        core.onMessage(msg("phase", ["phase": "done", "key": core.nudge!.key]))
        core.onMessage(msg("finish"))
        check(core.dayOf().done == 1 && core.dayOf().moves[first] == 1, "done counted once, per move")
        core.onMessage(msg("finish"))
        check(core.dayOf().done == 1, "a second finish doesn't double count")
        check(near(core.st.run.nextDueAt, now + 1200), "fresh 20 min after a stretch")
        core.onMessage(msg("closed"))
        check(core.mode == "none" && core.nudge == nil, "card closes itself after done")

        print("variety")
        check((0..<20).allSatisfy { _ in core.pickMove() != first }, "doesn't repeat a move you just did")

        print("meeting hold")
        core.onMessage(msg("meeting"))
        check(core.st.run.meeting, "meeting on")
        advance(1200)
        check(core.nudge == nil && core.st.run.held, "stretch held during the meeting")
        check(core.trayLine().contains("waiting") && core.menuBarText() == "later", "menu bar says one is waiting")
        core.wentAway(); advance(600); core.back()
        check(core.st.run.held, "a held stretch stays held when you step away")
        core.onMessage(msg("meeting"))
        check(!core.st.run.meeting && core.nudge?.intro == true, "meeting off: the held stretch appears")

        print("skip and close")
        core.onMessage(msg("skip", ["how": "close"]))
        check(core.dayOf().skipped == 1 && core.mode == "none", "closing a due nudge counts as a skip")
        core.stretchNow()
        check(core.nudge?.manual == true && host.focus, "stretch now opens a manual one with focus")
        core.onMessage(msg("skip", ["how": "close"]))
        check(core.dayOf().skipped == 1, "closing a manual one isn't counted")

        print("keyboard (⌃⌥R)")
        host.focus = false
        core.onFocusKey()
        check(core.mode == "home" && host.focus, "no nudge: opens the home card with focus")
        core.onFocusKey()
        check(core.mode == "none", "again: hides it")
        core.devDue(); core.tick()
        check(core.mode == "nudge" && !host.focus, "a nudge arrives unfocused")
        core.onFocusKey()
        check(host.focus, "⌃⌥R focuses it")
        core.onFocusKey()
        check(core.mode == "pill" && !host.focus, "again: tucks it into a pill and hands focus back")
        core.onFocusKey()
        check(core.mode == "nudge" && host.focus, "again: opens it from the pill")
        core.onMessage(msg("minimize"))
        check(core.mode == "pill" && !host.focus, "M minimizes to the pill")

        print("away")
        core.wentAway(); advance(60); core.back()
        check(core.nudge != nil, "a short break changes nothing")
        core.wentAway(); advance(600); core.back()
        check(core.nudge == nil && core.mode == "none", "back from 10 min: the unanswered nudge goes away")
        check(core.dayOf().skipped == 1, "... without counting as a skip")
        check(near(core.st.run.nextDueAt, now + 1200), "... and the clock starts fresh")
        advance(600)
        now += 1300; core.tick()
        check(core.nudge == nil && near(core.st.run.nextDueAt, now + 1200), "a silent sleep (big gap between ticks) also resets")
        core.setRestartWhenAway(false)
        let due = core.st.run.nextDueAt
        core.wentAway(); now += 600; core.back()
        check(core.st.run.nextDueAt == due, "with \"Restart the clock when I step away\" off, the clock keeps going")
        core.setRestartWhenAway(true)

        print("pause, interval, settings")
        core.devDue(); core.tick(); core.onMessage(msg("skip", ["how": "skip"]))
        advance(300); core.toggleRun()
        check(core.st.run.paused && !core.st.run.running && near(core.st.run.remaining, 900), "pause keeps 15 min left")
        advance(5000)
        check(core.nudge == nil && core.menuBarText() == "paused", "nothing while paused")
        core.toggleRun()
        check(core.st.run.running && near(core.st.run.nextDueAt, now + 900), "resume picks up where it was")
        check(core.menuBarText() == "15m", "menu bar shows minutes left")
        core.onMessage(msg("interval", ["m": 30]))
        check(core.interval == 30 && near(core.st.run.nextDueAt, (core.st.run.cycleStart ?? 0) + 1800), "interval 30 stretches the current cycle")
        core.onMessage(msg("sound", ["on": false]))
        check(!core.st.settings.sound, "chime off")
        host.chimes = []
        core.devDue(); core.tick()
        check(host.chimes.isEmpty, "no chime when it's off")
        core.onMessage(msg("skip", ["how": "skip"]))
        core.onMessage(msg("moveOn", ["id": "walk", "on": false]))
        check((0..<50).allSatisfy { _ in core.pickMove() != "walk" }, "a move switched off never comes up")

        print("what the card gets")
        host.focus = true
        core.setMode("home", focus: true)
        let state = try! JSONSerialization.jsonObject(with: Data(host.lastJSON.utf8)) as! [String: Any]
        let home = state["home"] as! [String: Any]
        check(state["mode"] as? String == "home" && state["platform"] as? String == "macos", "mode and platform")
        check(state["nativeChime"] as? Bool == true && state["grabKeys"] as? [String] == ["⌃", "⌥", "R"], "native chime and ⌃⌥R hints")
        check((home["week"] as! [Any]).count == 7 && (home["moves"] as! [Any]).count == 24, "7-day bars and 24 moves")
        check(((home["week"] as! [[String: Any]]).last?["d"] as? String) == "Today", "last bar is today")
        check(((home["today"] as! [String: Any])["done"] as? Int) == 1, "today's count")

        print("saved state")
        let text = (try? String(contentsOf: stateFile, encoding: .utf8)) ?? ""
        check(text.contains("\"nextDueAt\"") && text.contains("\"startOnLogin\"") && text.contains("\"days\""), "same keys as the Linux and Windows state.json")
        let again = try! RaviCore(host: FakeHost(), sharedDir: shared, stateFile: stateFile, clock: { now }, rng: SeededRNG(s: 1))
        again.boot()
        check(again.dayOf().done == 1 && again.dayOf().snoozed == 1 && again.interval == 30, "tally and settings survive a restart")
        check(again.st.settings.enabled["walk"] == false, "switched-off move survives a restart")

        if args.count > 2, FileManager.default.fileExists(atPath: args[2]) {
            let copy = dir.appendingPathComponent("other.json")
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: args[2]), to: copy)
            let other = try! RaviCore(host: FakeHost(), sharedDir: shared, stateFile: copy, clock: { now }, rng: SeededRNG(s: 1))
            other.boot()
            check(!other.st.log.days.isEmpty, "reads a state.json written by the Linux version")
        }

        print("carrying over the old Mac tally")
        let suite = "ravi-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let oldDays = ["2026-10-19": Day(done: 3, snoozed: 1, skipped: 0, moves: ["walk": 2, "eyes": 1])]
        defaults.set(try! JSONEncoder().encode(oldDays), forKey: "days")
        defaults.set(30, forKey: "interval")
        defaults.set(false, forKey: "chime")
        defaults.set(["calves"], forKey: "disabledMoves")
        let migrated = dir.appendingPathComponent("migrated/state.json")
        RaviCore.migrateIfNeeded(from: defaults, to: migrated)
        let m = try! RaviCore(host: FakeHost(), sharedDir: shared, stateFile: migrated, clock: { now }, rng: SeededRNG(s: 1))
        m.boot()
        check(m.dayOf("2026-10-19") == oldDays["2026-10-19"]!, "old days carried over")
        check(m.interval == 30 && !m.st.settings.sound && m.st.settings.enabled["calves"] == false, "old settings carried over")
        RaviCore.migrateIfNeeded(from: defaults, to: migrated)
        check(m.dayOf("2026-10-19").done == 3, "only carried over once")
        defaults.removePersistentDomain(forName: suite)

        print("history is trimmed to 60 days")
        for i in 0..<80 { core.st.log.days[String(format: "2025-01-%02d", i)] = Day(done: 1) }
        core.save()
        let trimmed = try! RaviCore(host: FakeHost(), sharedDir: shared, stateFile: stateFile, clock: { now }, rng: SeededRNG(s: 1))
        trimmed.boot()
        check(trimmed.st.log.days.count == 60, "keeps the newest 60 days")

        try? FileManager.default.removeItem(at: dir)
        print("\n\(checks - failures)/\(checks) checks passed")
        return failures == 0
    }
}
