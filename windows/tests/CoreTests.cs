// Walks RaviCore through a working day with a fake clock and a fake window, and checks every count.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;
using Ravi;

class FakeHost : IRaviHost
{
    public bool Focus;
    public bool Visible;
    public string LastJson;
    public int Presents, Hides, Releases;
    public Action Pushed = () => { };   // the real window pushes the new state to the card when it presents
    public bool HasFocus => Focus;
    public string Theme => "light";
    public void Render(string json) => LastJson = json;
    public void Present(bool focus) { Presents++; Visible = true; if (focus) Focus = true; Pushed(); }
    public void HideCard() { Hides++; Visible = false; Focus = false; }
    public void ReleaseFocus() { Releases++; Focus = false; }
    public void StatusChanged() { }
}

static class CoreTests
{
    static int failures, checks;
    static void Check(bool ok, string what)
    {
        checks++;
        if (!ok) { failures++; Console.WriteLine("  FAIL  " + what); }
        else Console.WriteLine("  ok    " + what);
    }

    static double now = 1_790_000_000;   // a fixed point in time; tests move it forward
    static RaviCore core;
    // time passing while the PC is awake: Ravi ticks every second (here every 30 s)
    static void Advance(double secs)
    {
        for (double t = 0; t < secs; t += 30) { now += Math.Min(30, secs - t); core.Tick(); }
    }

    // RAVI_DUMP=<folder> saves what the card receives, for the browser test of card.html
    static void Dump(string name, string stateJson)
    {
        var d = Environment.GetEnvironmentVariable("RAVI_DUMP");
        if (!string.IsNullOrEmpty(d)) File.WriteAllText(Path.Combine(d, name + ".json"), stateJson);
    }

    static Dictionary<string, object> Msg(string t, params object[] kv)
    {
        var d = new Dictionary<string, object> { ["t"] = t };
        for (int i = 0; i < kv.Length; i += 2) d[(string)kv[i]] = kv[i + 1];
        return d;
    }

    static int Main(string[] args)
    {
        var shared = args.Length > 0 ? args[0] : Path.Combine("..", "..", "..", "..", "..", "shared");
        var dir = Path.Combine(Path.GetTempPath(), "ravi-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var stateFile = Path.Combine(dir, "state.json");
        var host = new FakeHost();
        core = new RaviCore(host, shared, stateFile, () => now, new Random(7));
        host.Pushed = () => core.Push();
        var json = new JavaScriptSerializer();

        Console.WriteLine("boot");
        core.Boot();
        var r = core.St.run;
        Check(core.Moves.Count == 24, "24 moves loaded from shared/moves.json");
        Check(r.running && Math.Abs(r.nextDueAt.Value - (now + 1200)) < 0.001, "starts watching, first stretch in 20 min");
        Check(File.Exists(stateFile), "state.json written");

        Console.WriteLine("first nudge");
        Advance(600);
        Check(core.Nudge == null, "nothing at 10 min");
        Advance(600);
        Check(core.Nudge != null && core.Nudge.Intro && !core.Nudge.Manual, "nudge appears at 20 min");
        Check(core.Mode == "nudge" && host.Presents == 1 && !host.Focus, "card shown without taking focus");
        Check(core.Status().state == "due", "status says stretch time");
        Dump("nudge", host.LastJson);
        var first = core.Nudge.Move;

        Console.WriteLine("snooze");
        core.OnMessage(Msg("phase", "phase", "due", "key", core.Nudge.Key));
        Check(core.NudgePhase == "due", "phase from the card is tracked");
        core.OnMessage(Msg("snooze"));
        Check(core.Mode == "none" && core.Nudge == null && host.Hides == 1, "snooze hides the card");
        Check(core.DayOf().snoozed == 1, "snooze counted");
        Check(Math.Abs(r.nextDueAt.Value - (now + 300)) < 0.001, "back in 5 min");
        Advance(300);
        Check(core.Nudge != null && core.Nudge.Move == first, "the snoozed move comes back first");

        Console.WriteLine("finish");
        core.OnMessage(Msg("phase", "phase", "active", "key", core.Nudge.Key));
        core.OnMessage(Msg("phase", "phase", "done", "key", core.Nudge.Key));   // the card reports done before it says finish
        core.OnMessage(Msg("finish"));
        Check(core.DayOf().done == 1 && core.DayOf().moves[first] == 1, "done counted once, per move");
        core.OnMessage(Msg("finish"));
        Check(core.DayOf().done == 1, "a second finish doesn't double count");
        Check(Math.Abs(r.nextDueAt.Value - (now + 1200)) < 0.001, "fresh 20 min after a stretch");
        core.OnMessage(Msg("closed"));
        Check(core.Mode == "none" && core.Nudge == null, "card closes itself after done");

        Console.WriteLine("variety");
        var picks = Enumerable.Range(0, 20).Select(_ => core.PickMove()).ToList();
        Check(picks.All(p => p != first), "doesn't repeat a move you just did");

        Console.WriteLine("meeting hold");
        core.OnMessage(Msg("meeting"));
        Check(r.meeting, "meeting on");
        Advance(1200);
        Check(core.Nudge == null && r.held, "stretch held during the meeting");
        Check(core.TrayLine().Contains("waiting"), "tray says one is waiting");
        core.WentAway(); Advance(600); core.Back();
        Check(r.held, "a held stretch stays held when you step away");
        core.OnMessage(Msg("meeting"));
        Check(!r.meeting && core.Nudge != null && core.Nudge.Intro, "meeting off: the held stretch appears");

        Console.WriteLine("skip and close");
        core.OnMessage(Msg("skip", "how", "close"));
        Check(core.DayOf().skipped == 1 && core.Mode == "none", "closing a due nudge counts as a skip");
        core.StretchNow();
        Check(core.Nudge != null && core.Nudge.Manual && host.Focus, "stretch now opens a manual one with focus");
        core.OnMessage(Msg("skip", "how", "close"));
        Check(core.DayOf().skipped == 1, "closing a manual one isn't counted");

        Console.WriteLine("keyboard (Ctrl+Alt+R)");
        host.Focus = false;
        core.OnFocusKey();
        Check(core.Mode == "home" && host.Focus, "no nudge: opens the home card with focus");
        core.OnFocusKey();
        Check(core.Mode == "none", "again: hides it");
        core.DevDue(); core.Tick();
        Check(core.Mode == "nudge" && !host.Focus, "a nudge arrives unfocused");
        core.OnFocusKey();
        Check(host.Focus, "Ctrl+Alt+R focuses it");
        core.OnFocusKey();
        Check(core.Mode == "pill" && !host.Focus, "again: tucks it into a pill and hands focus back");
        core.OnFocusKey();
        Check(core.Mode == "nudge" && host.Focus, "again: opens it from the pill");
        core.OnMessage(Msg("minimize"));
        Check(core.Mode == "pill" && !host.Focus, "M minimizes to the pill");

        Console.WriteLine("away");
        core.WentAway(); Advance(60); core.Back();
        Check(core.Nudge != null, "a short break changes nothing");
        core.WentAway(); Advance(600); core.Back();
        Check(core.Nudge == null && core.Mode == "none", "back from 10 min: the unanswered nudge goes away");
        Check(core.DayOf().skipped == 1, "... without counting as a skip");
        Check(Math.Abs(r.nextDueAt.Value - (now + 1200)) < 0.001, "... and the clock starts fresh");
        Advance(600);
        now += 1300; core.Tick();   // asleep without a signal: one big jump between ticks
        Check(core.Nudge == null && Math.Abs(r.nextDueAt.Value - (now + 1200)) < 0.001, "a silent sleep (big gap between ticks) also resets");

        Console.WriteLine("pause, interval, settings");
        Advance(300); core.ToggleRun();
        Check(r.paused && !r.running && Math.Abs(r.remaining.Value - 900) < 0.001, "pause keeps 15 min left");
        Advance(5000);
        Check(core.Nudge == null, "nothing while paused");
        core.ToggleRun();
        Check(r.running && Math.Abs(r.nextDueAt.Value - (now + 900)) < 0.001, "resume picks up where it was");
        core.OnMessage(Msg("interval", "m", 30));
        Check(core.Interval == 30 && Math.Abs(r.nextDueAt.Value - (r.cycleStart.Value + 1800)) < 0.001, "interval 30 stretches the current cycle");
        core.OnMessage(Msg("sound", "on", true));
        Check(core.St.settings.sound, "chime on");
        core.OnMessage(Msg("moveOn", "id", "walk", "on", false));
        Check(Enumerable.Range(0, 50).All(_ => core.PickMove() != "walk"), "a move switched off never comes up");

        Console.WriteLine("what the card gets");
        host.Focus = true;
        core.SetMode("home", true);
        var state = (Dictionary<string, object>)json.DeserializeObject(host.LastJson);
        var home = (Dictionary<string, object>)state["home"];
        Dump("home", host.LastJson);
        Check((string)state["mode"] == "home" && (string)state["platform"] == "windows", "mode and platform");
        Check(((object[])home["week"]).Length == 7 && ((object[])home["moves"]).Length == 24, "7-day bars and 24 moves");
        Check((string)((Dictionary<string, object>)((object[])home["week"])[6])["d"] == "Today", "last bar is today");
        Check(Convert.ToInt32(((Dictionary<string, object>)home["today"])["done"]) == 1, "today's count");

        Console.WriteLine("saved state");
        var text = File.ReadAllText(stateFile);
        Check(text.Contains("\"nextDueAt\"") && text.Contains("\"startOnLogin\"") && text.Contains("\"days\""), "same keys as the Linux state.json");
        var again = new RaviCore(new FakeHost(), shared, stateFile, () => now, new Random(1));
        again.Boot();
        Check(again.DayOf().done == 1 && again.DayOf().snoozed == 1 && again.Interval == 30, "tally and settings survive a restart");
        Check(!again.St.settings.enabled["walk"], "switched-off move survives a restart");

        var linux = args.Length > 1 ? args[1] : null;
        if (linux != null && File.Exists(linux))
        {
            var copy = Path.Combine(dir, "linux.json");
            File.Copy(linux, copy);
            var fromLinux = new RaviCore(new FakeHost(), shared, copy, () => now, new Random(1));
            fromLinux.Boot();
            Check(fromLinux.St.log.days.Count > 0, "reads a state.json written by the Linux version");
        }

        Console.WriteLine("history is trimmed to 60 days");
        for (int i = 0; i < 80; i++) core.St.log.days[$"2025-01-{i:00}"] = new Day { done = 1 };
        core.Save();
        var trimmed = new RaviCore(new FakeHost(), shared, stateFile, () => now, new Random(1));
        trimmed.Boot();
        Check(trimmed.St.log.days.Count == 60 && trimmed.St.log.days.ContainsKey(trimmed.St.log.days.Keys.Max()), "keeps the newest 60 days");

        Directory.Delete(dir, true);
        Console.WriteLine($"\n{checks - failures}/{checks} checks passed");
        return failures == 0 ? 0 : 1;
    }
}
