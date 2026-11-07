"""Walks the Linux app through the "nobody answers" logic with a fake clock and a fake idle reading, no GTK needed.

    python3 linux/tests/test_backoff.py

Same scenario as the "nobody answers" section of macos/Tests/CoreTests.swift and windows/tests/CoreTests.cs.
"""
import importlib.util
import json
import os
import sys
import tempfile
import types
from unittest import mock

HERE = os.path.dirname(os.path.realpath(__file__))
os.environ["XDG_DATA_HOME"] = tempfile.mkdtemp(prefix="ravi-test-")


# The logic under test never touches GTK, so stand in for the libraries ravi.py imports.
class Stub:
    def __init__(self, **kw):
        self.__dict__.update(kw)
        self._m = mock.MagicMock()

    def __getattr__(self, name):
        return getattr(self._m, name)


class FakeApplication:
    def __init__(self, *a, **k):
        pass


gi = types.ModuleType("gi")
gi.require_version = lambda *a, **k: None
repo = types.ModuleType("gi.repository")
repo.Gtk = Stub(Application=FakeApplication)
repo.GLib = Stub(Error=RuntimeError, VariantType=lambda s: s)
repo.Gio, repo.Gdk, repo.WebKit2 = Stub(), Stub(), Stub()
repo.GdkX11, repo.AyatanaAppIndicator3 = Stub(), Stub()
gi.repository = repo
sys.modules.update({"gi": gi, "gi.repository": repo})

spec = importlib.util.spec_from_file_location("ravi", os.path.join(HERE, "..", "ravi.py"))
ravi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ravi)

clock = {"t": 1_790_000_000.0}
ravi.time = types.SimpleNamespace(time=lambda: clock["t"])

failures = checks = 0


def check(ok, what):
    global failures, checks
    checks += 1
    failures += not ok
    print(("  ok    " if ok else "  FAIL  ") + what)


class App(ravi.Ravi):
    """The real logic, with the window, tray and disk replaced by plain bookkeeping."""

    def present(self, focus=False):
        self.has_focus = self.has_focus or focus

    def hide_card(self):
        self.mode, self.has_focus = "none", False

    def release_focus(self):
        self.has_focus = False

    def push(self):
        pass

    def update_indicator(self):
        pass

    def save(self):
        pass


app = App.__new__(App)
app.st = ravi.default_state()
app.st["settings"]["interval"] = 30
app.mode, app.nudge, app.nudge_phase, app.nudge_seq = "none", None, None, 0
app.snooze_streak = app.ignored_streak = 0
app.ignore_at, app.last_idle, app.idle_bus, app.idle_failures = 0, None, None, 0
app.has_focus = app.want_focus = False
app.away_since, app.last_tick = None, clock["t"]
app.mood_pose, app.mood_until, app.bubble, app.line_at = None, 0, "", 0
app.start_cycle()


def msg(t, **kw):
    app.on_js(None, types.SimpleNamespace(to_string=lambda: json.dumps(dict(kw, t=t))))


def near(a, b):
    return a is not None and abs(a - b) < 0.001


print("idle time from GNOME")
calls = []


class Bus:
    fail = False

    def call_sync(self, *args):
        calls.append(args)
        if self.fail:
            raise RuntimeError("no such service")
        return types.SimpleNamespace(unpack=lambda: (1500,))


app.idle_bus = Bus()
check(near(ravi.Ravi.idle_seconds(app), 1.5), "the idle monitor's milliseconds become seconds")
app.idle_bus.fail = True
check([ravi.Ravi.idle_seconds(app) for _ in range(3)] == [None] * 3, "a desktop that can't say gives None")
before = len(calls)
check(ravi.Ravi.idle_seconds(app) is None and len(calls) == before, "... and after 3 failures it stops asking")
app.idle_bus, app.idle_failures = None, 0

print("nobody answers")
# the PC is left on: time passes and nobody touches it, so the idle reading grows with the clock
idle = {"v": 0, "last_input": clock["t"]}
app.idle_seconds = lambda: idle["v"]


def advance_idle(secs):
    t = 0
    while t < secs:
        clock["t"] += min(30, secs - t)
        t += 30
        idle["v"] = clock["t"] - idle["last_input"]
        app.tick()


def touch():
    idle["last_input"], idle["v"] = clock["t"], 0
    app.tick()


def wait_for_nudge():
    n = 0
    while app.nudge is None and n < 400:
        advance_idle(30)
        n += 1


def next_due():
    return app.run_["nextDueAt"]


snoozed_before = app.day()["snoozed"]
wait_for_nudge()
check(app.nudge is not None and app.nudge["intro"] and app.mode == "nudge", "the nudge comes as usual")
ignored = app.nudge["move"]
advance_idle(90)
check(app.nudge is not None, "it waits for an answer (90 s in)")
advance_idle(30)
check(app.nudge is None and app.mode == "none" and not app.has_focus, "2 minutes, no reaction: it tucks itself away")
check(near(next_due(), clock["t"] + 300), "... and tries again in 5 minutes")
check(app.day()["snoozed"] == snoozed_before and app.run_["snoozedMove"] == ignored,
      "... not counted as a snooze, same move comes back")
advance_idle(300)
check(app.nudge is not None and app.nudge["move"] == ignored, "back after 5 minutes")
advance_idle(120)
check(app.nudge is None and near(next_due(), clock["t"] + 600), "ignored again: 10 minutes")
advance_idle(600)
advance_idle(120)
check(app.nudge is None and near(next_due(), clock["t"] + 1800), "and again: 30 minutes")
advance_idle(1800)
advance_idle(120)
check(app.nudge is None and near(next_due(), clock["t"] + 3600), "and again: an hour")
advance_idle(3600)
advance_idle(120)
check(app.nudge is None and near(next_due(), clock["t"] + 3600), "after that it stays at an hour")

touch()
check(app.nudge is None and near(next_due(), clock["t"] + 1800), "you're back at the keyboard: fresh 30 minutes")
wait_for_nudge()
advance_idle(120)
check(app.nudge is None and near(next_due(), clock["t"] + 300), "... and the waits start from 5 minutes again")

advance_idle(300)
check(app.nudge is not None, "next one arrives")
advance_idle(60)
touch()  # you come back while it's on screen, after a long time away
check(app.nudge is not None, "back while it's up: it stays for you")
advance_idle(90)
check(app.nudge is not None, "... and gets a fresh 2 minutes")
advance_idle(30)
check(app.nudge is None and near(next_due(), clock["t"] + 300), "... then the ladder restarts at 5 minutes")

advance_idle(300)
advance_idle(120)
check(near(next_due(), clock["t"] + 600), "10 minutes the second time")
advance_idle(600)
check(app.nudge is not None, "next one arrives")
msg("skip", how="skip")
check(near(next_due(), clock["t"] + 1800), "you react (skip): normal 30 minutes again")
wait_for_nudge()
advance_idle(120)
check(app.nudge is None and near(next_due(), clock["t"] + 300), "... and reacting reset the ladder")

wait_for_nudge()
app.has_focus = True  # you grabbed it with Ctrl+Alt+R and are reading it
advance_idle(600)
check(app.nudge is not None and app.mode == "nudge", "a card you're using is never taken away")
msg("minimize")
advance_idle(1200)
check(app.nudge is not None and app.mode == "pill", "a minimized pill is yours to deal with")
msg("skip", how="skip")
app.on_stretch_now()
app.has_focus = False
advance_idle(1200)
check(app.nudge is not None and app.nudge["manual"], "a stretch you asked for stays put")
msg("skip", how="close")

idle["v"] = None  # a desktop that can't report idle time still gets the ladder
app.idle_seconds = lambda: None
wait_for_nudge()
advance_idle(120)
wait = (next_due() or 0) - clock["t"]
check(app.nudge is None and (near(wait, 300) or near(wait, 600)), "no idle reading: unanswered nudges still back off")

print(f"\n{checks - failures}/{checks} checks passed")
sys.exit(1 if failures else 0)
