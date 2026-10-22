// Ravi's brain on Windows: the clock, which move comes next, the tally and what the card shows.
// It mirrors linux/ravi.py and has no Windows UI code, so it can be tested anywhere (tests/ runs it under Mono).
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;

namespace Ravi
{
    /// <summary>What the core needs from the window, tray and OS around it.</summary>
    public interface IRaviHost
    {
        bool HasFocus { get; }
        string Theme { get; }                 // "light" or "dark"
        void Render(string stateJson);        // window.Ravi.update(state) in the card
        void Present(bool focus);             // show the card for the current mode
        void HideCard();                      // take the card off screen, keyboard goes back to your app
        void ReleaseFocus();                  // keep the card where it is, keyboard goes back to your app
        void StatusChanged();                 // refresh the tray
    }

    // State on disk: same keys as the Linux version's state.json (lower-case names on purpose).
    public sealed class Settings
    {
        public int interval { get; set; } = 20;
        public bool sound { get; set; }
        public Dictionary<string, bool> enabled { get; set; } = new Dictionary<string, bool>();
        public bool startOnLogin { get; set; } = true;   // start watching when Ravi starts
    }

    public sealed class RunState
    {
        public bool running { get; set; }
        public bool paused { get; set; }
        public bool meeting { get; set; }
        public bool held { get; set; }
        public double? nextDueAt { get; set; }
        public double? remaining { get; set; }
        public double? cycleStart { get; set; }
        public List<string> recent { get; set; } = new List<string>();
        public string snoozedMove { get; set; }
    }

    public sealed class Day
    {
        public int done { get; set; }
        public int snoozed { get; set; }
        public int skipped { get; set; }
        public Dictionary<string, int> moves { get; set; } = new Dictionary<string, int>();
    }

    public sealed class LogBook
    {
        public Dictionary<string, Day> days { get; set; } = new Dictionary<string, Day>();
    }

    public sealed class SavedState
    {
        public Settings settings { get; set; } = new Settings();
        public RunState run { get; set; } = new RunState();
        public LogBook log { get; set; } = new LogBook();
    }

    public sealed class Nudge
    {
        public int Key;
        public string Move;
        public bool Intro, Manual, Finished;
        public double Opened;
    }

    public sealed class RaviCore
    {
        public const int Min = 60;
        public static readonly int[] Intervals = { 15, 20, 30, 45, 60 };
        const int SnoozeSecs = 5 * Min;
        public const int AwayReset = 3 * Min;   // locked or asleep at least this long: start a fresh cycle
        static readonly string[] DayNames = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

        readonly IRaviHost host;
        readonly string stateFile;
        readonly Func<double> clock;
        readonly Random rng;
        readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 };

        public SavedState St;
        public readonly List<Dictionary<string, object>> Moves = new List<Dictionary<string, object>>();
        readonly Dictionary<string, Dictionary<string, object>> moveById = new Dictionary<string, Dictionary<string, object>>();
        readonly Dictionary<string, string[]> lines = new Dictionary<string, string[]>();

        public string Mode = "none";             // none | nudge | pill | home
        public Nudge Nudge;
        public string NudgePhase;                // intro | due | active | done
        int nudgeSeq, snoozeStreak;
        double? awaySince;
        double lastTick;
        string moodPose, bubble;
        double moodUntil, lineAt;

        public string Platform = "windows";
        public string[] GrabKeys = { "Ctrl", "Alt", "R" };
        public bool Flat;

        public RaviCore(IRaviHost host, string sharedDir, string stateFile, Func<double> clock = null, Random rng = null)
        {
            this.host = host;
            this.stateFile = stateFile;
            this.clock = clock ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0);
            this.rng = rng ?? new Random();
            LoadMoves(Path.Combine(sharedDir, "moves.json"));
        }

        // ------------------------------------------------------------ setup
        void LoadMoves(string path)
        {
            var root = (Dictionary<string, object>)json.DeserializeObject(File.ReadAllText(path));
            foreach (var o in (object[])root["moves"])
            {
                var m = (Dictionary<string, object>)o;
                Moves.Add(m);
                moveById[(string)m["id"]] = m;
            }
            foreach (var kv in (Dictionary<string, object>)root["lines"])
                lines[kv.Key] = ((object[])kv.Value).Select(x => (string)x).ToArray();
        }

        public void Boot()
        {
            St = Load();
            var r = St.run;
            r.meeting = false; r.held = false; r.snoozedMove = null;
            lastTick = Now;
            bubble = Pick("off");
            if (St.settings.startOnLogin)
            {
                StartCycle();
                bubble = $"Okay. I'll check on you in {Interval} minutes.";
            }
            else
            {
                r.running = false; r.paused = false; r.nextDueAt = null; r.remaining = null; r.cycleStart = null;
            }
            Save();
        }

        SavedState Load()
        {
            SavedState st = null;
            try
            {
                if (File.Exists(stateFile)) st = json.Deserialize<SavedState>(File.ReadAllText(stateFile));
            }
            catch (Exception) { st = null; }
            st = st ?? new SavedState();
            st.settings = st.settings ?? new Settings();
            st.settings.enabled = st.settings.enabled ?? new Dictionary<string, bool>();
            st.run = st.run ?? new RunState();
            st.run.recent = st.run.recent ?? new List<string>();
            st.log = st.log ?? new LogBook();
            st.log.days = st.log.days ?? new Dictionary<string, Day>();
            if (!Intervals.Contains(st.settings.interval)) st.settings.interval = 20;
            foreach (var k in st.log.days.Keys.OrderBy(k => k, StringComparer.Ordinal).Reverse().Skip(60).ToList())
                st.log.days.Remove(k);
            return st;
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(stateFile));
                var tmp = stateFile + ".tmp";
                File.WriteAllText(tmp, json.Serialize(St));
                if (File.Exists(stateFile)) File.Replace(tmp, stateFile, null);
                else File.Move(tmp, stateFile);
            }
            catch (Exception e) { Log("couldn't save state: " + e.Message); }
        }

        public static Action<string> Log = _ => { };

        // ------------------------------------------------------------ helpers
        public double Now => clock();
        public int Interval => St.settings.interval;
        RunState R => St.run;

        DateTime LocalTime(double t) => DateTimeOffset.FromUnixTimeMilliseconds((long)(t * 1000)).LocalDateTime;
        string DKey(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        string Today => DKey(LocalTime(Now));
        public string Clock(double t) => LocalTime(t).ToString("HH:mm", CultureInfo.InvariantCulture);

        public static string Fmt(double secs)
        {
            var s = Math.Max(0, (int)Math.Ceiling(secs));
            return $"{s / 60}:{s % 60:00}";
        }

        string Pick(string kind)
        {
            var arr = lines.TryGetValue(kind, out var a) && a.Length > 0 ? a : new[] { "" };
            return arr[rng.Next(arr.Length)];
        }

        public Day OwnDay(string k = null)
        {
            k = k ?? Today;
            if (!St.log.days.TryGetValue(k, out var d)) St.log.days[k] = d = new Day();
            return d;
        }

        public Day DayOf(string k = null) =>
            St.log.days.TryGetValue(k ?? Today, out var d) ? d : new Day();

        void Say(string text) { bubble = text; lineAt = Now; }
        void Mood(string pose, string text, double secs) { moodPose = pose; moodUntil = Now + secs; Say(text); }
        bool Enabled(string id) => !St.settings.enabled.TryGetValue(id, out var on) || on;

        void StartCycle()
        {
            var now = Now;
            R.running = true; R.paused = false; R.held = false;
            R.cycleStart = now; R.nextDueAt = now + Interval * Min; R.remaining = null;
        }

        // ------------------------------------------------------------ core -> card
        public void Push() => host.Render(json.Serialize(BuildState()));

        public Dictionary<string, object> BuildState() => new Dictionary<string, object>
        {
            ["mode"] = Mode, ["theme"] = host.Theme, ["flat"] = Flat, ["platform"] = Platform,
            ["grabKeys"] = GrabKeys, ["focused"] = host.HasFocus, ["sound"] = St.settings.sound,
            ["nudge"] = NudgePayload(), ["home"] = Mode == "home" ? HomePayload() : null,
        };

        Dictionary<string, object> NudgePayload()
        {
            if (Nudge == null) return null;
            DayOf().moves.TryGetValue(Nudge.Move, out var doneToday);
            return new Dictionary<string, object>
            {
                ["key"] = Nudge.Key, ["move"] = moveById[Nudge.Move], ["intro"] = Nudge.Intro, ["manual"] = Nudge.Manual,
                ["doneToday"] = doneToday, ["total"] = DayOf().done, ["time"] = Clock(Nudge.Opened),
            };
        }

        public (string state, string text) Status()
        {
            if (Nudge != null && !Nudge.Manual && NudgePhase != "done") return ("due", "Stretch time");
            if (R.running && R.meeting) return ("meeting", R.held ? "In a meeting · 1 waiting" : "In a meeting");
            if (R.running) return ("running", "Watching your posture");
            if (R.paused) return ("paused", "Paused");
            return ("off", "Not started");
        }

        Dictionary<string, object> HomePayload()
        {
            var now = Now;
            double iv = Interval * Min;
            var (s, st) = Status();
            string label, text; double frac; bool isNow = false;
            if (s == "due") { label = "Right now"; text = "Stretch"; frac = 1; isNow = true; }
            else if (R.running && R.held) { label = "Waiting for your meeting to end"; text = "0:00"; frac = 1; }
            else if (R.running && R.nextDueAt.HasValue)
            {
                var left = R.nextDueAt.Value - now;
                label = R.meeting ? "In a meeting · next stretch in" : "Next stretch in";
                text = Fmt(left); frac = 1 - left / iv;
            }
            else if (R.paused)
            {
                var rem = R.remaining ?? iv;
                label = "Paused with"; text = Fmt(rem); frac = 1 - rem / iv;
            }
            else { label = "Ready when you are"; text = Fmt(iv); frac = 0; }

            string pose = moodUntil > now ? moodPose : R.meeting ? "shh" : R.paused ? "crossed" : R.running ? "idle" : "wave";

            var t = DayOf();
            var chips = t.moves.Where(kv => kv.Value > 0 && moveById.ContainsKey(kv.Key))
                .OrderByDescending(kv => kv.Value)
                .Select(kv => new object[] { (string)moveById[kv.Key]["name"], kv.Value }).ToArray();
            var today = LocalTime(now).Date;
            var week = new List<object>();
            for (int i = 6; i >= 0; i--)
            {
                var d = today.AddDays(-i);
                week.Add(new Dictionary<string, object>
                {
                    ["d"] = i == 0 ? "Today" : DayNames[(int)d.DayOfWeek], ["v"] = DayOf(DKey(d)).done,
                    ["today"] = i == 0, ["title"] = d.ToString("dddd", CultureInfo.InvariantCulture),
                });
            }
            return new Dictionary<string, object>
            {
                ["status"] = s, ["statusText"] = st, ["label"] = label, ["countdown"] = text,
                ["frac"] = Math.Max(0, Math.Min(1, frac)), ["isNow"] = isNow, ["interval"] = Interval,
                ["mainLabel"] = R.running ? "Pause" : R.paused ? "Resume" : "Start my workday",
                ["running"] = R.running, ["meeting"] = R.meeting, ["sound"] = St.settings.sound,
                ["bubble"] = bubble, ["pose"] = pose,
                ["today"] = new Dictionary<string, object> { ["done"] = t.done, ["snoozed"] = t.snoozed, ["skipped"] = t.skipped, ["chips"] = chips },
                ["week"] = week,
                ["moves"] = Moves.Select(m => (object)new Dictionary<string, object>
                {
                    ["id"] = m["id"], ["name"] = m["name"], ["area"] = m["area"], ["dose"] = m["dose"], ["on"] = Enabled((string)m["id"]),
                }).ToArray(),
            };
        }

        // ------------------------------------------------------------ card -> core
        /// <summary>Handles a message from the card. Returns false for messages the host deals with (ready, size).</summary>
        public bool OnMessage(Dictionary<string, object> msg)
        {
            string Str(string k) => msg.TryGetValue(k, out var v) && v != null ? Convert.ToString(v, CultureInfo.InvariantCulture) : null;
            switch (Str("t"))
            {
                case "phase":
                    if (Nudge != null && Str("key") == Nudge.Key.ToString(CultureInfo.InvariantCulture))
                    {
                        NudgePhase = Str("phase");
                        host.StatusChanged();
                    }
                    return true;
                case "finish": Finish(); return true;
                case "skip": Skip(Str("how") ?? "skip"); return true;
                case "snooze": Snooze(); return true;
                case "closed": CloseNudge(); return true;
                case "minimize":
                    if (Nudge != null) { Mode = "pill"; Push(); host.ReleaseFocus(); }
                    return true;
                case "restore":
                    if (Nudge != null) SetMode("nudge", host.HasFocus);
                    return true;
                case "unfocus": host.ReleaseFocus(); Push(); return true;
                case "hide": HideCard(); return true;
                case "toggleRun": ToggleRun(); return true;
                case "meeting": ToggleMeeting(); return true;
                case "stretchNow": StretchNow(); return true;
                case "try":
                    var id = Str("id");
                    if (id != null && moveById.ContainsKey(id)) OpenNudge(id, intro: false, manual: true, focus: host.HasFocus);
                    return true;
                case "interval":
                    if (int.TryParse(Str("m"), out var m)) SetInterval(m);
                    return true;
                case "sound": SetSound(Str("on") == "True" || Str("on") == "true"); return true;
                case "moveOn":
                    var mid = Str("id");
                    if (mid != null && moveById.ContainsKey(mid))
                    {
                        St.settings.enabled[mid] = Str("on") == "True" || Str("on") == "true";
                        Save(); Push();
                    }
                    return true;
                default:
                    return false;
            }
        }

        public void FocusChanged()
        {
            Push();
        }

        // ------------------------------------------------------------ modes
        public void SetMode(string mode, bool focus)
        {
            Mode = mode;
            host.Present(focus);
        }

        public void HideCard()
        {
            Mode = "none";
            host.HideCard();
            Push();
        }

        // ------------------------------------------------------------ stretching
        public string PickMove()
        {
            var pool = Moves.Where(m => Enabled((string)m["id"])).ToList();
            if (pool.Count == 0) pool = Moves.ToList();
            var done = DayOf().moves;
            var recent = R.recent ?? new List<string>();
            double Score(Dictionary<string, object> m)
            {
                var id = (string)m["id"];
                var ri = recent.IndexOf(id);
                var recency = ri == -1 ? 0 : (6 - Math.Min(ri, 5)) * 3;
                done.TryGetValue(id, out var n);
                return n * 2 + recency + rng.NextDouble() * 1.5;
            }
            return (string)pool.OrderBy(Score).First()["id"];
        }

        string DueMove()
        {
            var sm = R.snoozedMove;
            R.snoozedMove = null;
            return sm != null && moveById.ContainsKey(sm) ? sm : PickMove();
        }

        void Remember(string id)
        {
            R.recent = new[] { id }.Concat((R.recent ?? new List<string>()).Where(x => x != id)).Take(5).ToList();
        }

        void ScheduleNext()
        {
            if (R.running)
            {
                R.cycleStart = Now;
                R.nextDueAt = R.cycleStart + Interval * Min;
            }
            else if (R.paused) R.remaining = Interval * Min;
            R.held = false;
        }

        public void OpenNudge(string id, bool intro = true, bool manual = false, bool focus = false)
        {
            nudgeSeq++;
            Nudge = new Nudge { Key = nudgeSeq, Move = id, Intro = intro, Manual = manual, Opened = Now };
            NudgePhase = intro ? "intro" : "due";
            if (intro) Say("Up you get. Quick one.");
            SetMode("nudge", focus);
            host.StatusChanged();
        }

        public void Finish()
        {
            if (Nudge == null || Nudge.Finished) return;
            Nudge.Finished = true;
            var d = OwnDay();
            d.done++;
            d.moves.TryGetValue(Nudge.Move, out var n);
            d.moves[Nudge.Move] = n + 1;
            Remember(Nudge.Move);
            ScheduleNext();
            snoozeStreak = 0;
            NudgePhase = "done";
            Mood("cheer", Pick("done"), 4.5);
            Save();
            Push();
            host.StatusChanged();
        }

        public void Skip(string how)
        {
            if (Nudge == null) return;
            if (Nudge.Finished) { CloseNudge(); return; }
            if (!Nudge.Manual)
            {
                OwnDay().skipped++;
                Remember(Nudge.Move);
                if (how == "skip") R.snoozedMove = null;
                ScheduleNext();
                snoozeStreak = 0;
                Mood("crossed", Pick("skip"), 4);
                Save();
            }
            CloseNudge();
        }

        public void Snooze()
        {
            if (Nudge == null) return;
            OwnDay().snoozed++;
            if (R.running)
            {
                R.nextDueAt = Now + SnoozeSecs;
                R.cycleStart = R.nextDueAt - Interval * Min;
            }
            else if (R.paused) R.remaining = SnoozeSecs;
            R.held = false;
            R.snoozedMove = Nudge.Move;
            snoozeStreak++;
            var sl = lines.TryGetValue("snooze", out var a) ? a : new[] { "" };
            Mood("crossed", sl[Math.Min(snoozeStreak, sl.Length) - 1], 4.5);
            Save();
            CloseNudge();
        }

        public void CloseNudge()
        {
            Nudge = null;
            NudgePhase = null;
            if (Mode == "nudge" || Mode == "pill") HideCard();
            else Push();
            host.StatusChanged();
        }

        // ------------------------------------------------------------ controls (tray, card, hotkey)
        /// <summary>Ctrl+Alt+R: take keyboard focus; press again to hand it back.</summary>
        public void OnFocusKey()
        {
            if (Nudge != null)
            {
                if (host.HasFocus)
                {
                    if (Mode == "nudge" && NudgePhase != "done") { Mode = "pill"; Push(); }
                    host.ReleaseFocus();
                    Push();
                }
                else SetMode("nudge", true);
            }
            else if (Mode == "home" && host.HasFocus) HideCard();
            else SetMode("home", true);
        }

        public void OnShow()
        {
            SetMode(Nudge != null ? "nudge" : "home", true);
        }

        public void ToggleRun()
        {
            var now = Now;
            if (R.running)
            {
                R.remaining = Math.Max(0, (R.nextDueAt ?? now) - now);
                R.running = false; R.paused = true; R.nextDueAt = null;
                Say(Pick("paused"));
            }
            else if (R.paused)
            {
                var rem = R.remaining ?? Interval * Min;
                R.running = true; R.paused = false; R.nextDueAt = now + rem; R.remaining = null;
                R.cycleStart = R.nextDueAt - Interval * Min;
                Say(Pick("running"));
            }
            else
            {
                StartCycle();
                Say($"Okay. I'll check on you in {Interval} minutes.");
            }
            Save(); Push(); host.StatusChanged();
        }

        public void ToggleMeeting()
        {
            R.meeting = !R.meeting;
            if (R.meeting) Say(Pick("meeting"));
            else if (R.held)
            {
                R.held = false;
                Save();
                OpenNudge(DueMove(), intro: true, focus: host.HasFocus);
                return;
            }
            else Say(Pick("running"));
            Save(); Push(); host.StatusChanged();
        }

        public void StretchNow()
        {
            if (Nudge != null) { SetMode("nudge", true); return; }
            OpenNudge(PickMove(), intro: false, manual: true, focus: true);
        }

        public void SetInterval(int m)
        {
            if (!Intervals.Contains(m)) return;
            St.settings.interval = m;
            var now = Now;
            if (R.running && R.cycleStart.HasValue && R.nextDueAt.HasValue)
                R.nextDueAt = Math.Max(now + 10, R.cycleStart.Value + m * Min);
            else if (R.paused && R.remaining.HasValue)
                R.remaining = Math.Min(R.remaining.Value, m * Min);
            Save(); Push(); host.StatusChanged();
        }

        public void SetSound(bool on)
        {
            St.settings.sound = on;
            Save(); Push(); host.StatusChanged();
        }

        // ------------------------------------------------------------ the clock
        public void Tick()
        {
            var now = Now;
            var gap = now - lastTick;
            lastTick = now;
            if (gap > 90 && awaySince == null) CameBack(gap);   // the PC slept without telling us
            if (R.running && R.nextDueAt.HasValue && now >= R.nextDueAt.Value && Nudge == null && awaySince == null)
            {
                R.nextDueAt = null;
                if (R.meeting)
                {
                    R.held = true;
                    Say(Pick("held"));
                    Save();
                }
                else
                {
                    Save();
                    OpenNudge(DueMove(), intro: true);
                }
            }
            if (R.running && Nudge == null && !R.meeting && !R.held && moodUntil < now && now - lineAt > 16)
                Say(Pick("running"));
            host.StatusChanged();
            if (Mode == "home") Push();
        }

        // ------------------------------------------------------------ away (locked or asleep)
        public void WentAway()
        {
            if (awaySince == null) awaySince = Now;
        }

        public void Back()
        {
            if (awaySince != null) CameBack(Now - awaySince.Value);
        }

        public void CameBack(double away)
        {
            awaySince = null;
            lastTick = Now;
            if (away < AwayReset) return;
            if (Nudge != null && !Nudge.Manual && (NudgePhase == "intro" || NudgePhase == "due"))
            {
                // you were up and about; that unanswered nudge is moot (not counted as a skip)
                Nudge = null;
                NudgePhase = null;
                if (Mode == "nudge" || Mode == "pill") { Mode = "none"; host.HideCard(); }
            }
            if (R.running && !R.held)   // a stretch held for a meeting stays held
            {
                StartCycle();
                Say(Pick("back"));
            }
            Save(); Push(); host.StatusChanged();
        }

        // ------------------------------------------------------------ tray text
        public string TrayLine()
        {
            var (s, _) = Status();
            if (s == "due") return "Stretch time";
            if (R.running && R.held) return "In a meeting · 1 stretch waiting";
            if (R.running && R.meeting && R.nextDueAt.HasValue) return $"In a meeting · stretch held from {Clock(R.nextDueAt.Value)}";
            if (R.running && R.nextDueAt.HasValue) return $"Next stretch at {Clock(R.nextDueAt.Value)} ({Fmt(R.nextDueAt.Value - Now)})";
            if (R.running) return "Watching your posture";
            if (R.paused) return $"Paused with {Fmt(R.remaining ?? Interval * Min)} left";
            return "Not started";
        }

        public string TodayLine()
        {
            var t = DayOf();
            return $"Today: {t.done} done · {t.snoozed} snoozed · {t.skipped} skipped";
        }

        public string RunLabel => R.running ? "Pause" : R.paused ? "Resume" : "Start my workday";
        public bool Due => Status().state == "due";

        // test helpers
        public void DevDue() { R.running = true; R.nextDueAt = Now - 1; }
    }
}
