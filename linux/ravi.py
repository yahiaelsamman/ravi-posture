#!/usr/bin/python3
"""Ravi the Ravioli, Linux edition.

A posture coach for Ubuntu (GNOME). Every so often Ravi slides in at the top
right with a desk stretch, times your reps and keeps a daily tally. The card is
the same HTML Ravi as the web and Mac versions, shown in a small floating
WebKit window; the countdown lives in the top bar.

Keyboard: Ctrl+Alt+R (set up by install.sh) gives the card keyboard focus, and
pressing it again hands focus back to whatever you were doing.

Runs as one instance (app id app.ravi.Ravi). A second `ravi --focus`,
`--stretch`, `--toggle`, `--meeting`, `--show` or `--quit` talks to the running one.
"""
import os
import sys

# The card is an XWayland window: GNOME on Wayland doesn't let a native window
# place itself or stay on top, X11 windows can. WebKit's DMA-BUF renderer is
# switched off because it can leave transparent windows blank under XWayland.
os.environ.setdefault("GDK_BACKEND", "x11")
os.environ.setdefault("WEBKIT_DISABLE_DMABUF_RENDERER", "1")

import datetime
import json
import random
import signal
import time

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gdk, Gio, GLib, Gtk, WebKit2  # noqa: E402

try:
    gi.require_version("GdkX11", "3.0")
    from gi.repository import GdkX11
except (ValueError, ImportError):
    GdkX11 = None
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator
except (ValueError, ImportError):
    AppIndicator = None
try:
    import cairo
except ImportError:
    cairo = None

APP_ID = "app.ravi.Ravi"
HERE = os.path.dirname(os.path.realpath(__file__))
DATA_DIR = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "ravi")
STATE_FILE = os.path.join(DATA_DIR, "state.json")
DEV = os.environ.get("RAVI_DEV") == "1"

MIN = 60
INTERVALS = [15, 20, 30, 45, 60]
SNOOZE = 5 * MIN
AWAY_RESET = 3 * MIN  # locked or asleep at least this long: start a fresh cycle
PAD = 20              # transparent margin around the card (room for its shadow)
EDGE = 6              # gap between that margin and the screen edge

# ---------------------------------------------------------------- the moves
# The moves and Ravi's lines live in shared/moves.json, used by every version.
def _find_shared():
    for d in (HERE, os.path.join(HERE, "..", "shared")):
        if os.path.exists(os.path.join(d, "card.html")):
            return os.path.realpath(d)
    return HERE


SHARED = _find_shared()
with open(os.path.join(SHARED, "moves.json"), encoding="utf-8") as _f:
    _SHARED_DATA = json.load(_f)
MOVES = _SHARED_DATA["moves"]
MOVE = {m["id"]: m for m in MOVES}
LINES = _SHARED_DATA["lines"]

DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def pick(seq):
    return random.choice(seq)


def dkey(d=None):
    return (d or datetime.date.today()).isoformat()


def fmt(secs):
    s = max(0, int(-(-secs // 1)))  # ceil
    return f"{s // 60}:{s % 60:02d}"


def clock(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%H:%M")


# ---------------------------------------------------------------- state on disk
def default_state():
    return {
        "settings": {"interval": 20, "sound": False, "enabled": {}, "startOnLogin": True},
        "run": {"running": False, "paused": False, "meeting": False, "held": False, "nextDueAt": None,
                "remaining": None, "cycleStart": None, "recent": [], "snoozedMove": None},
        "log": {"days": {}},
    }


def load_state():
    st = default_state()
    try:
        with open(STATE_FILE) as f:
            saved = json.load(f)
        for k in st:
            if isinstance(saved.get(k), dict):
                st[k].update(saved[k])
    except (OSError, ValueError):
        pass
    if st["settings"].get("interval") not in INTERVALS:
        st["settings"]["interval"] = 20
    days = st["log"].setdefault("days", {})
    for k in sorted(days)[:-60]:
        del days[k]
    return st


def save_state(st):
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(st, f, indent=1)
        os.replace(tmp, STATE_FILE)
    except OSError as e:
        print("ravi: couldn't save state:", e, file=sys.stderr)


# ---------------------------------------------------------------- the app
class Ravi(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.booted = False

    # ---------- lifecycle
    def do_startup(self):
        Gtk.Application.do_startup(self)
        acts = {"focus": self.on_focus_key, "show": self.on_show, "stretch": self.on_stretch_now,
                "toggle": self.on_toggle_run, "meeting": self.on_toggle_meeting, "quit": self.on_quit}
        if DEV:
            acts.update({"due": self.dev_due, "away": self.dev_away})
        for name, cb in acts.items():
            a = Gio.SimpleAction.new(name, None)
            a.connect("activate", lambda _a, _p, cb=cb: cb())
            self.add_action(a)
        if DEV:
            for name, cb in (("eval", self.dev_eval), ("snapshot", self.dev_snapshot)):
                a = Gio.SimpleAction.new(name, GLib.VariantType.new("s"))
                a.connect("activate", lambda _a, p, cb=cb: cb(p.get_string()))
                self.add_action(a)

    def do_command_line(self, cmdline):
        args = cmdline.get_arguments()[1:]
        first = not self.booted
        if first:
            self.boot()
        cmd = next((a for a in args if a.startswith("--")), "")
        if cmd == "--autostart":
            pass
        elif cmd in ("--focus", "--show", "--stretch", "--toggle", "--meeting", "--quit"):
            self.lookup_action(cmd[2:]).activate(None)
        elif cmd in ("--help", "-h") or "-h" in args:
            out = getattr(cmdline, "print_literal", None)
            (out or print)(__doc__ + "\n")
        elif not first or not args:
            self.on_show()  # launched from the app grid, or a second plain `ravi`
        return 0

    def do_activate(self):
        if not self.booted:
            self.boot()
        self.on_show()

    def boot(self):
        self.booted = True
        self.hold()
        self.st = load_state()
        self.mode = "none"           # none | nudge | pill | home
        self.nudge = None            # {key, move, intro, manual, opened}
        self.nudge_phase = None
        self.nudge_seq = 0
        self.snooze_streak = 0
        self.js_ready = False
        self.has_focus = False
        self.want_focus = False
        self.pending_show = False
        self.size = (440, 220)
        self.away_since = None
        self.last_tick = time.time()
        self.mood_pose, self.mood_until = None, 0
        self.bubble, self.line_at = pick(LINES["off"]), 0
        self.ind_cache = {}

        r = self.st["run"]
        r.update(meeting=False, held=False, snoozedMove=None)
        if self.st["settings"].get("startOnLogin", True):
            self.start_cycle()
            self.bubble = f"Okay. I'll check on you in {self.interval_min} minutes."
        else:
            r.update(running=False, paused=False, nextDueAt=None, remaining=None, cycleStart=None)
        self.save()

        self.build_window()
        self.build_indicator()
        self.watch_theme()
        self.watch_away()
        GLib.timeout_add_seconds(1, self.tick)
        for sig in (signal.SIGINT, signal.SIGTERM):
            GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, self.on_quit)
        self.update_indicator()

    # ---------- small helpers
    @property
    def settings(self):
        return self.st["settings"]

    @property
    def run_(self):
        return self.st["run"]

    @property
    def interval_min(self):
        return self.settings["interval"]

    def save(self):
        save_state(self.st)

    def own_day(self, k=None):
        return self.st["log"]["days"].setdefault(k or dkey(), {"done": 0, "snoozed": 0, "skipped": 0, "moves": {}})

    def day(self, k=None):
        return self.st["log"]["days"].get(k or dkey(), {"done": 0, "snoozed": 0, "skipped": 0, "moves": {}})

    def say(self, text):
        self.bubble, self.line_at = text, time.time()

    def mood(self, pose, text, secs):
        self.mood_pose, self.mood_until = pose, time.time() + secs
        self.say(text)

    def start_cycle(self):
        now = time.time()
        self.run_.update(running=True, paused=False, held=False, cycleStart=now,
                         nextDueAt=now + self.interval_min * MIN, remaining=None)

    # ---------- the card window
    def build_window(self):
        w = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        self.add_window(w)
        w.set_title("Ravi")
        w.set_decorated(False)
        w.set_resizable(True)   # non-resizable GTK windows won't shrink while mapped; we size it ourselves
        w.set_keep_above(True)
        w.set_skip_taskbar_hint(True)
        w.set_skip_pager_hint(True)
        w.set_type_hint(Gdk.WindowTypeHint.UTILITY)
        w.set_focus_on_map(False)
        w.set_accept_focus(False)   # a nudge never steals your typing; Ctrl+Alt+R hands focus over
        w.stick()                    # on every workspace
        scr = w.get_screen()
        vis = scr.get_rgba_visual()
        self.composited = bool(vis and scr.is_composited())
        if self.composited:
            w.set_visual(vis)
            w.set_app_paintable(True)
            w.connect("draw", self._clear_bg)
        w.connect("delete-event", self._on_delete)
        w.connect("notify::is-active", self._on_active)

        ucm = WebKit2.UserContentManager()
        ucm.connect("script-message-received::ravi", self.on_js)
        ucm.register_script_message_handler("ravi")
        # the card stores nothing in the browser, so WebKit gets no data folders of its own
        ctx = WebKit2.WebContext.new_with_website_data_manager(WebKit2.WebsiteDataManager.new_ephemeral())
        wv = WebKit2.WebView(web_context=ctx, user_content_manager=ucm)
        s = wv.get_settings()
        s.set_allow_file_access_from_file_urls(True)
        s.set_media_playback_requires_user_gesture(False)
        s.set_enable_developer_extras(DEV)
        s.set_enable_write_console_messages_to_stdout(DEV)
        wv.set_background_color(Gdk.RGBA(0, 0, 0, 0))
        wv.connect("context-menu", lambda *a: True)
        wv.connect("decide-policy", self._on_policy)
        wv.connect("web-process-terminated", self._on_crash)
        wv.set_size_request(1, 1)
        w.set_default_size(*self.size)
        w.add(wv)
        wv.show()
        self.win, self.wv = w, wv
        wv.load_uri(GLib.filename_to_uri(os.path.join(SHARED, "card.html"), None))

    def _clear_bg(self, widget, cr):
        cr.set_source_rgba(0, 0, 0, 0)
        cr.set_operator(1)  # CAIRO_OPERATOR_SOURCE
        cr.paint()
        cr.set_operator(2)  # CAIRO_OPERATOR_OVER
        return False

    def _on_delete(self, *a):
        self.hide_card()
        return True

    def _on_policy(self, wv, decision, kind):
        if kind == WebKit2.PolicyDecisionType.NAVIGATION_ACTION:
            uri = decision.get_navigation_action().get_request().get_uri()
            if not uri.startswith("file://"):
                decision.ignore()
                Gio.AppInfo.launch_default_for_uri(uri, None)
                return True
        return False

    def _on_crash(self, *a):
        self.js_ready = False
        self.wv.reload()

    def _on_active(self, *a):
        active = self.win.is_active()
        if active == self.has_focus:
            return
        self.has_focus = active
        self.push()
        if not active and self.mode == "home":
            GLib.timeout_add(200, self._hide_home_if_unfocused)

    def _hide_home_if_unfocused(self):
        if not self.has_focus and self.mode == "home":
            self.hide_card()
        return False

    def js(self, code):
        if hasattr(self.wv, "evaluate_javascript"):
            self.wv.evaluate_javascript(code, -1, None, None, None, None, None)
        else:
            self.wv.run_javascript(code, None, None, None)

    def place(self):
        w, h = self.size
        disp = Gdk.Display.get_default()
        mon = disp.get_primary_monitor() or disp.get_monitor(0)
        wa = mon.get_workarea()
        edge = EDGE if self.composited else 12
        self.win.move(wa.x + wa.width - w - edge, wa.y + edge)

    def apply_size(self, w, h):
        self.size = (w, h)
        self.win.resize(w, h)
        self.place()
        gw = self.win.get_window()
        if self.composited and cairo and gw:
            # clicks on the transparent margin fall through to the window underneath
            try:
                self.win.input_shape_combine_region(cairo.Region(cairo.RectangleInt(PAD, PAD, w - 2 * PAD, h - 2 * PAD)))
            except (TypeError, AttributeError):
                pass

    def present(self, focus=False):
        """Show the card for the current mode. JS reports its size first, then the window maps."""
        self.want_focus = self.want_focus or focus
        self.push()
        if self.win.get_visible():
            if self.want_focus:
                self.grab_focus()
        else:
            self.pending_show = True
            GLib.timeout_add(450, self._show_now)

    def _show_now(self):
        if not self.pending_show or self.mode == "none":
            self.pending_show = False
            return False
        self.pending_show = False
        self.win.set_accept_focus(self.want_focus)
        self.place()
        self.win.show()
        self.place()
        if self.want_focus:
            self.grab_focus()
        return False

    def server_time(self):
        gw = self.win.get_window()
        if GdkX11 and gw is not None and isinstance(gw, GdkX11.X11Window):
            return GdkX11.x11_get_server_time(gw)  # a fresh timestamp gets past GNOME's focus-stealing guard
        return Gdk.CURRENT_TIME

    def grab_focus(self):
        self.want_focus = False
        self.win.set_accept_focus(True)
        self.win.present_with_time(self.server_time())
        self.wv.grab_focus()

    def release_focus(self):
        """Give the keyboard back to the app you were in (GNOME refocuses it when we unmap)."""
        if not self.has_focus:
            return
        stay = self.mode in ("nudge", "pill")
        self.win.set_accept_focus(False)
        self.win.hide()   # GNOME gives the keyboard back to the window you used last
        self.has_focus = False
        if stay:
            GLib.timeout_add(80, self._reshow)
        self.push()

    def _reshow(self):
        if self.mode in ("nudge", "pill") and not self.win.get_visible():
            self.place()
            self.win.show()
            self.place()
        return False

    def hide_card(self):
        self.mode = "none"
        self.pending_show = False
        self.want_focus = False
        self.win.set_accept_focus(False)
        self.win.hide()
        self.has_focus = False
        self.push()

    def set_mode(self, mode, focus=False):
        self.mode = mode
        self.present(focus=focus)

    # ---------- Python -> page
    def push(self):
        if not self.js_ready:
            return
        st = {
            "mode": self.mode, "theme": self.theme, "flat": not self.composited, "focused": self.has_focus,
            "sound": bool(self.settings.get("sound")), "nudge": self.nudge_payload(),
            "home": self.home_payload() if self.mode == "home" else None,
        }
        self.js("window.Ravi && Ravi.update(%s)" % json.dumps(st))

    def nudge_payload(self):
        if not self.nudge:
            return None
        n = self.nudge
        return {"key": n["key"], "move": MOVE[n["move"]], "intro": n["intro"], "manual": n["manual"],
                "doneToday": self.day()["moves"].get(n["move"], 0), "total": self.day()["done"],
                "time": clock(n["opened"])}

    def status(self):
        r = self.run_
        due_now = self.nudge and not self.nudge["manual"] and self.nudge_phase != "done"
        if due_now:
            return "due", "Stretch time"
        if r["running"] and r["meeting"]:
            return "meeting", ("In a meeting · 1 waiting" if r["held"] else "In a meeting")
        if r["running"]:
            return "running", "Watching your posture"
        if r["paused"]:
            return "paused", "Paused"
        return "off", "Not started"

    def home_payload(self):
        r, now = self.run_, time.time()
        iv = self.interval_min * MIN
        s, st = self.status()
        if s == "due":
            label, text, frac, is_now = "Right now", "Stretch", 1, True
        elif r["running"] and r["held"]:
            label, text, frac, is_now = "Waiting for your meeting to end", "0:00", 1, False
        elif r["running"] and r["nextDueAt"]:
            left = r["nextDueAt"] - now
            label = "In a meeting · next stretch in" if r["meeting"] else "Next stretch in"
            text, frac, is_now = fmt(left), 1 - left / iv, False
        elif r["paused"]:
            rem = r["remaining"] if r["remaining"] is not None else iv
            label, text, frac, is_now = "Paused with", fmt(rem), 1 - rem / iv, False
        else:
            label, text, frac, is_now = "Ready when you are", fmt(iv), 0, False

        if self.mood_until > now:
            pose = self.mood_pose
        elif r["meeting"]:
            pose = "shh"
        elif r["paused"]:
            pose = "crossed"
        elif r["running"]:
            pose = "idle"
        else:
            pose = "wave"

        t = self.day()
        chips = sorted(((MOVE[i]["name"], n) for i, n in t["moves"].items() if n > 0 and i in MOVE),
                       key=lambda x: -x[1])
        week = []
        today = datetime.date.today()
        for i in range(6, -1, -1):
            d = today - datetime.timedelta(days=i)
            week.append({"d": "Today" if i == 0 else DAYS[d.weekday()], "v": self.day(dkey(d))["done"],
                         "today": i == 0, "title": d.strftime("%A")})
        en = self.settings.get("enabled", {})
        return {
            "status": s, "statusText": st, "label": label, "countdown": text,
            "frac": max(0, min(1, frac)), "isNow": is_now, "interval": self.interval_min,
            "mainLabel": "Pause" if r["running"] else "Resume" if r["paused"] else "Start my workday",
            "running": r["running"], "meeting": r["meeting"], "sound": bool(self.settings.get("sound")),
            "bubble": self.bubble, "pose": pose,
            "today": {"done": t["done"], "snoozed": t["snoozed"], "skipped": t["skipped"], "chips": chips},
            "week": week,
            "moves": [{"id": m["id"], "name": m["name"], "area": m["area"], "dose": m["dose"],
                       "on": en.get(m["id"], True) is not False} for m in MOVES],
            "dateText": today.strftime("%a %-d %b"),
        }

    # ---------- page -> Python
    def on_js(self, _ucm, res):
        try:
            v = res.get_js_value() if hasattr(res, "get_js_value") else res
            msg = json.loads(v.to_string())
        except Exception as e:  # noqa: BLE001
            print("ravi: bad message from card:", e, file=sys.stderr)
            return
        t = msg.get("t")
        if t == "ready":
            self.js_ready = True
            self.push()
        elif t == "size":
            if msg.get("mode") == self.mode:
                self.apply_size(int(msg["w"]), int(msg["h"]))
                if self.pending_show:
                    self._show_now()
        elif t == "phase":
            if self.nudge and msg.get("key") == self.nudge["key"]:
                self.nudge_phase = msg.get("phase")
                self.update_indicator()
        elif t == "finish":
            self.finish()
        elif t == "skip":
            self.skip(msg.get("how", "skip"))
        elif t == "snooze":
            self.snooze()
        elif t == "closed":
            self.close_nudge()
        elif t == "minimize":
            if self.nudge:
                self.mode = "pill"
                self.push()
                self.release_focus()
        elif t == "restore":
            if self.nudge:
                self.set_mode("nudge", focus=self.has_focus)
        elif t == "unfocus":
            self.release_focus()
        elif t == "hide":
            self.hide_card()
        elif t == "toggleRun":
            self.on_toggle_run()
        elif t == "meeting":
            self.on_toggle_meeting()
        elif t == "stretchNow":
            self.on_stretch_now()
        elif t == "try":
            if msg.get("id") in MOVE:
                self.open_nudge(msg["id"], intro=False, manual=True, focus=self.has_focus)
        elif t == "interval":
            self.set_interval(int(msg.get("m", 20)))
        elif t == "sound":
            self.set_sound(bool(msg.get("on")))
        elif t == "moveOn":
            if msg.get("id") in MOVE:
                self.settings.setdefault("enabled", {})[msg["id"]] = bool(msg.get("on"))
                self.save()
                self.push()

    # ---------- stretching
    def pick_move(self):
        en = self.settings.get("enabled", {})
        pool = [m for m in MOVES if en.get(m["id"], True) is not False] or MOVES
        done = self.day()["moves"]
        recent = self.run_.get("recent") or []

        def score(m):
            ri = recent.index(m["id"]) if m["id"] in recent else -1
            recency = 0 if ri == -1 else (6 - min(ri, 5)) * 3
            return done.get(m["id"], 0) * 2 + recency + random.random() * 1.5

        return min(pool, key=score)["id"]

    def due_move(self):
        sm = self.run_.get("snoozedMove")
        self.run_["snoozedMove"] = None
        return sm if sm in MOVE else self.pick_move()

    def remember(self, mid):
        self.run_["recent"] = ([mid] + [x for x in self.run_.get("recent") or [] if x != mid])[:5]

    def schedule_next(self):
        r = self.run_
        if r["running"]:
            r["cycleStart"] = time.time()
            r["nextDueAt"] = r["cycleStart"] + self.interval_min * MIN
        elif r["paused"]:
            r["remaining"] = self.interval_min * MIN
        r["held"] = False

    def open_nudge(self, mid, intro=True, manual=False, focus=False):
        self.nudge_seq += 1
        self.nudge = {"key": self.nudge_seq, "move": mid, "intro": intro, "manual": manual, "opened": time.time()}
        self.nudge_phase = "intro" if intro else "due"
        if intro:
            self.say("Up you get. Quick one.")
        self.mode = "nudge"
        self.present(focus=focus)
        self.update_indicator()

    def finish(self):
        if not self.nudge or self.nudge.get("finished"):
            return
        self.nudge["finished"] = True
        mid = self.nudge["move"]
        d = self.own_day()
        d["done"] += 1
        d["moves"][mid] = d["moves"].get(mid, 0) + 1
        self.remember(mid)
        self.schedule_next()
        self.snooze_streak = 0
        self.nudge_phase = "done"
        self.mood("cheer", pick(LINES["done"]), 4.5)
        self.save()
        self.push()
        self.update_indicator()
        key = self.nudge["key"]
        GLib.timeout_add(7000, lambda: (self.nudge and self.nudge["key"] == key and self.close_nudge(), False)[1])

    def skip(self, how):
        if not self.nudge:
            return
        n = self.nudge
        if n.get("finished"):
            self.close_nudge()
            return
        counts = not n["manual"]
        if counts:
            self.own_day()["skipped"] += 1
            self.remember(n["move"])
            if how == "skip":
                self.run_["snoozedMove"] = None
            self.schedule_next()
            self.snooze_streak = 0
            self.mood("crossed", pick(LINES["skip"]), 4)
            self.save()
        self.close_nudge()

    def snooze(self):
        if not self.nudge:
            return
        r = self.run_
        self.own_day()["snoozed"] += 1
        if r["running"]:
            r["nextDueAt"] = time.time() + SNOOZE
            r["cycleStart"] = r["nextDueAt"] - self.interval_min * MIN
        elif r["paused"]:
            r["remaining"] = SNOOZE
        r["held"] = False
        r["snoozedMove"] = self.nudge["move"]
        self.snooze_streak += 1
        self.mood("crossed", LINES["snooze"][min(self.snooze_streak, len(LINES["snooze"])) - 1], 4.5)
        self.save()
        self.close_nudge()

    def close_nudge(self):
        self.nudge = None
        self.nudge_phase = None
        if self.mode in ("nudge", "pill"):
            self.hide_card()
        else:
            self.push()
        self.update_indicator()

    # ---------- controls (tray, card, shortcut)
    def on_focus_key(self):
        """Ctrl+Alt+R: take keyboard focus; press again to hand it back."""
        if self.nudge:
            if self.has_focus:
                if self.mode == "nudge" and self.nudge_phase != "done":
                    self.mode = "pill"
                    self.push()
                self.release_focus()
            else:
                self.set_mode("nudge", focus=True)
        elif self.mode == "home" and self.has_focus:
            self.hide_card()
        else:
            self.set_mode("home", focus=True)

    def on_show(self):
        if self.nudge:
            self.set_mode("nudge", focus=True)
        else:
            self.set_mode("home", focus=True)

    def on_toggle_run(self):
        r, now = self.run_, time.time()
        if r["running"]:
            r["remaining"] = max(0, (r["nextDueAt"] or now) - now)
            r.update(running=False, paused=True, nextDueAt=None)
            self.say(pick(LINES["paused"]))
        elif r["paused"]:
            rem = r["remaining"] or self.interval_min * MIN
            r.update(running=True, paused=False, nextDueAt=now + rem, remaining=None)
            r["cycleStart"] = r["nextDueAt"] - self.interval_min * MIN
            self.say(pick(LINES["running"]))
        else:
            self.start_cycle()
            self.say(f"Okay. I'll check on you in {self.interval_min} minutes.")
        self.save()
        self.push()
        self.update_indicator()

    def on_toggle_meeting(self):
        r = self.run_
        r["meeting"] = not r["meeting"]
        if r["meeting"]:
            self.say(pick(LINES["meeting"]))
        elif r["held"]:
            r["held"] = False
            self.save()
            self.open_nudge(self.due_move(), intro=True, focus=self.has_focus)
            return
        else:
            self.say(pick(LINES["running"]))
        self.save()
        self.push()
        self.update_indicator()

    def on_stretch_now(self):
        if self.nudge:
            self.set_mode("nudge", focus=True)
            return
        self.open_nudge(self.pick_move(), intro=False, manual=True, focus=True)

    def set_interval(self, m):
        if m not in INTERVALS:
            return
        self.settings["interval"] = m
        r, now = self.run_, time.time()
        if r["running"] and r["cycleStart"] and r["nextDueAt"]:
            r["nextDueAt"] = max(now + 10, r["cycleStart"] + m * MIN)
        elif r["paused"] and r["remaining"] is not None:
            r["remaining"] = min(r["remaining"], m * MIN)
        self.save()
        self.push()
        self.update_indicator()

    def set_sound(self, on):
        self.settings["sound"] = on
        self.save()
        self.push()
        self.update_indicator()

    def on_quit(self, *a):
        self.save()
        self.quit()
        return False

    # ---------- the clock
    def tick(self):
        now = time.time()
        gap = now - self.last_tick
        self.last_tick = now
        if gap > 90 and self.away_since is None:
            self.came_back(gap)  # the laptop slept without telling us
        r = self.run_
        if r["running"] and r["nextDueAt"] and now >= r["nextDueAt"] and not self.nudge and self.away_since is None:
            r["nextDueAt"] = None
            if r["meeting"]:
                r["held"] = True
                self.say(LINES["held"][0])
                self.save()
            else:
                self.save()
                self.open_nudge(self.due_move(), intro=True)
        if (r["running"] and not self.nudge and not r["meeting"] and not r["held"]
                and self.mood_until < now and now - self.line_at > 16):
            self.say(pick(LINES["running"]))
        self.update_indicator()
        if self.mode == "home" and self.win.get_visible():
            self.push()
        return True

    # ---------- away (screen locked or laptop asleep)
    def watch_away(self):
        try:
            sess = Gio.bus_get_sync(Gio.BusType.SESSION, None)
            for iface in ("org.gnome.ScreenSaver", "org.freedesktop.ScreenSaver"):
                sess.signal_subscribe(None, iface, "ActiveChanged", None, None, Gio.DBusSignalFlags.NONE,
                                      lambda *a: self._on_locked(a[5].unpack()[0]))
        except GLib.Error as e:
            print("ravi: no screensaver signal:", e.message, file=sys.stderr)
        try:
            system = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
            system.signal_subscribe("org.freedesktop.login1", "org.freedesktop.login1.Manager", "PrepareForSleep",
                                    "/org/freedesktop/login1", None, Gio.DBusSignalFlags.NONE,
                                    lambda *a: self._on_locked(a[5].unpack()[0]))
        except GLib.Error as e:
            print("ravi: no sleep signal:", e.message, file=sys.stderr)

    def _on_locked(self, locked):
        if locked:
            if self.away_since is None:
                self.away_since = time.time()
        elif self.away_since is not None:
            self.came_back(time.time() - self.away_since)

    def came_back(self, away):
        self.away_since = None
        self.last_tick = time.time()
        if away < AWAY_RESET:
            return
        if self.nudge and not self.nudge["manual"] and self.nudge_phase in ("intro", "due"):
            # you were up and about; that unanswered nudge is moot (not counted as a skip)
            self.nudge = None
            self.nudge_phase = None
            if self.mode in ("nudge", "pill"):
                self.hide_card()
        r = self.run_
        if r["running"] and not r["held"]:   # a stretch held for a meeting stays held
            self.start_cycle()
            self.say(pick(LINES["back"]))
        self.save()
        self.push()
        self.update_indicator()

    # ---------- theme
    def watch_theme(self):
        self.iface = None
        src = Gio.SettingsSchemaSource.get_default()
        if src and src.lookup("org.gnome.desktop.interface", True):
            self.iface = Gio.Settings.new("org.gnome.desktop.interface")
            keys = self.iface.props.settings_schema.list_keys()
            for k in ("color-scheme", "gtk-theme"):
                if k in keys:
                    self.iface.connect("changed::" + k, lambda *a: self.push())

    @property
    def theme(self):
        forced = os.environ.get("RAVI_THEME")
        if forced in ("dark", "light"):
            return forced
        if self.iface:
            keys = self.iface.props.settings_schema.list_keys()
            if "color-scheme" in keys and self.iface.get_string("color-scheme") == "prefer-dark":
                return "dark"
            if "gtk-theme" in keys and self.iface.get_string("gtk-theme").lower().endswith("dark"):
                return "dark"
        return "light"

    # ---------- top bar
    def build_indicator(self):
        self.ind = None
        if not AppIndicator:
            print("ravi: AyatanaAppIndicator3 missing, running without the top-bar countdown", file=sys.stderr)
            return
        ind = AppIndicator.Indicator.new("ravi-the-ravioli", "ravi-panel",
                                         AppIndicator.IndicatorCategory.APPLICATION_STATUS)
        ind.set_icon_theme_path(os.path.join(SHARED, "icons"))
        ind.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        ind.set_title("Ravi")

        menu = Gtk.Menu()
        self.mi_status = Gtk.MenuItem(label="")
        self.mi_status.set_sensitive(False)
        menu.append(self.mi_status)
        menu.append(Gtk.SeparatorMenuItem())
        mi_show = Gtk.MenuItem(label="Show Ravi  (Ctrl+Alt+R)")
        mi_show.connect("activate", lambda *a: self.on_show())
        menu.append(mi_show)
        self.mi_run = Gtk.MenuItem(label="Pause")
        self.mi_run.connect("activate", lambda *a: self.on_toggle_run())
        menu.append(self.mi_run)
        self.mi_meet = Gtk.CheckMenuItem(label="In a meeting")
        self.meet_handler = self.mi_meet.connect("toggled", lambda *a: self.on_toggle_meeting())
        menu.append(self.mi_meet)
        mi_now = Gtk.MenuItem(label="Stretch now")
        mi_now.connect("activate", lambda *a: self.on_stretch_now())
        menu.append(mi_now)

        every = Gtk.MenuItem(label="Every")
        sub = Gtk.Menu()
        group = None
        self.mi_iv = {}
        for m in INTERVALS:
            it = Gtk.RadioMenuItem.new_with_label_from_widget(group, f"{m} minutes")
            group = group or it
            it.connect("toggled", lambda w, m=m: w.get_active() and m != self.interval_min and self.set_interval(m))
            sub.append(it)
            self.mi_iv[m] = it
        every.set_submenu(sub)
        menu.append(every)
        self.mi_sound = Gtk.CheckMenuItem(label="Chime")
        self.sound_handler = self.mi_sound.connect("toggled", lambda w: self.set_sound(w.get_active()))
        menu.append(self.mi_sound)
        self.mi_login = Gtk.CheckMenuItem(label="Start watching when I log in")
        self.mi_login.set_active(self.settings.get("startOnLogin", True))
        self.mi_login.connect("toggled", self._on_login_toggle)
        menu.append(self.mi_login)
        menu.append(Gtk.SeparatorMenuItem())
        self.mi_today = Gtk.MenuItem(label="")
        self.mi_today.set_sensitive(False)
        menu.append(self.mi_today)
        menu.append(Gtk.SeparatorMenuItem())
        mi_quit = Gtk.MenuItem(label="Quit Ravi")
        mi_quit.connect("activate", lambda *a: self.on_quit())
        menu.append(mi_quit)
        menu.show_all()
        ind.set_menu(menu)
        ind.set_secondary_activate_target(mi_show)  # middle-click the icon
        self.ind = ind

    def _on_login_toggle(self, w):
        self.settings["startOnLogin"] = w.get_active()
        self.save()

    def _set(self, key, value, fn):
        if self.ind_cache.get(key) != value:
            self.ind_cache[key] = value
            fn(value)

    def update_indicator(self):
        if not getattr(self, "ind", None):
            return
        r, now = self.run_, time.time()
        s, _ = self.status()
        if s == "due":
            label, line = "stretch!", "Stretch time"
        elif r["running"] and r["held"]:
            label, line = "1 waiting", "In a meeting · 1 stretch waiting"
        elif r["running"] and r["meeting"] and r["nextDueAt"]:
            label, line = "meeting", f"In a meeting · stretch held from {clock(r['nextDueAt'])}"
        elif r["running"] and r["nextDueAt"]:
            label, line = fmt(r["nextDueAt"] - now), f"Next stretch at {clock(r['nextDueAt'])}"
        elif r["running"]:
            label, line = "", "Watching your posture"
        elif r["paused"]:
            rem = r["remaining"] if r["remaining"] is not None else self.interval_min * MIN
            label, line = "paused", f"Paused with {fmt(rem)} left"
        else:
            label, line = "", "Not started"
        self._set("label", label, lambda v: self.ind.set_label(v, "00:00"))
        self._set("icon", "ravi-panel-due" if s == "due" else "ravi-panel",
                  lambda v: self.ind.set_icon_full(v, "Ravi"))
        self._set("status", line, self.mi_status.set_label)
        self._set("run", "Pause" if r["running"] else "Resume" if r["paused"] else "Start my workday",
                  self.mi_run.set_label)
        t = self.day()
        self._set("today", f"Today: {t['done']} done · {t['snoozed']} snoozed · {t['skipped']} skipped",
                  self.mi_today.set_label)
        if self.mi_meet.get_active() != bool(r["meeting"]):
            with self.mi_meet.handler_block(self.meet_handler):
                self.mi_meet.set_active(bool(r["meeting"]))
        if self.mi_sound.get_active() != bool(self.settings.get("sound")):
            with self.mi_sound.handler_block(self.sound_handler):
                self.mi_sound.set_active(bool(self.settings.get("sound")))
        it = self.mi_iv.get(self.interval_min)
        if it and not it.get_active():
            it.set_active(True)

    # ---------- development hooks (RAVI_DEV=1 only)
    def dev_due(self):
        self.run_["nextDueAt"] = time.time() - 1
        self.run_["running"] = True

    def dev_away(self):
        self.came_back(AWAY_RESET + 1)

    def dev_eval(self, code):
        self.js(code)

    def dev_snapshot(self, path):
        def done(wv, res):
            try:
                wv.get_snapshot_finish(res).write_to_png(path)
            except Exception as e:  # noqa: BLE001
                print("snapshot failed", e, file=sys.stderr)
        self.wv.get_snapshot(WebKit2.SnapshotRegion.VISIBLE, WebKit2.SnapshotOptions.TRANSPARENT_BACKGROUND,
                             None, done)


def main():
    app = Ravi()
    return app.run(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
