"""Runs shared/card.html in Chromium (the engine inside WebView2) the way the Windows app drives it.

Feeds it the states the C# core produced (RAVI_DUMP from CoreTests), clicks and types through a stretch,
and checks every message the card sends back. Sizes the page like the window Windows would make.
    python3 card_test.py <shared dir> <dump dir> <screenshot dir>
"""
import json
import re
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

shared, dump, shots = (Path(a).resolve() for a in sys.argv[1:4])
shots.mkdir(parents=True, exist_ok=True)
nudge_state = json.loads((dump / "nudge.json").read_text())
home_state = json.loads((dump / "home.json").read_text())

STUB = """
window.__posted = [];
window.chrome = window.chrome || {};
window.chrome.webview = { postMessage: m => window.__posted.push(JSON.parse(m)) };
"""
fails = []


def check(ok, what):
    print(("  ok    " if ok else "  FAIL  ") + what)
    if not ok:
        fails.append(what)


def posted(pg, t=None):
    msgs = pg.evaluate("window.__posted")
    return [m for m in msgs if t is None or m["t"] == t]


def fit(pg, mode):
    sizes = [m for m in posted(pg, "size") if m["mode"] == mode]
    if sizes:
        pg.set_viewport_size({"width": sizes[-1]["w"], "height": sizes[-1]["h"]})
    return sizes[-1] if sizes else None


with sync_playwright() as p:
    browser = p.chromium.launch()
    for theme in ("light", "dark"):
        print(theme)
        ctx = browser.new_context(viewport={"width": 460, "height": 640}, device_scale_factor=2)
        pg = ctx.new_page()
        errors = []
        pg.on("pageerror", lambda e: errors.append(str(e)))
        pg.on("console", lambda m: m.type == "error" and errors.append(m.text))
        pg.add_init_script(STUB)
        pg.goto((shared / "card.html").as_uri())
        pg.wait_for_function("window.Ravi && window.__posted.length > 0")
        check(posted(pg, "ready") != [], "card says ready over chrome.webview")

        st = dict(nudge_state, theme=theme)
        pg.evaluate("s => Ravi.update(s)", st)
        size = fit(pg, "nudge")
        check(size is not None and size["w"] == 416, f"reports the nudge size for the window ({size})")
        check(pg.evaluate("document.body.classList.contains('win')"), "Windows look: the OS draws the corners")
        pg.wait_for_timeout(700)
        pg.screenshot(path=str(shots / f"{theme}-1-intro.png"))
        pg.wait_for_timeout(2300)
        phases = [m["phase"] for m in posted(pg, "phase")]
        check(phases[:2] == ["intro", "due"], f"intro, then the move ({phases})")
        fit(pg, "nudge")
        pg.screenshot(path=str(shots / f"{theme}-2-due.png"))

        # Ctrl+Alt+R gave it focus: keyboard through the stretch
        pg.evaluate("s => Ravi.update(s)", dict(st, focused=True))
        check("Enter" in pg.inner_text("#nKeys"), "key hints appear once focused")
        pg.keyboard.press("h")
        check(pg.is_visible("#nHow"), "H opens how-to")
        fit(pg, "nudge")
        pg.screenshot(path=str(shots / f"{theme}-3-howto.png"))
        pg.keyboard.press("h")
        pg.keyboard.press("Enter")
        pg.wait_for_timeout(1300)
        check(posted(pg, "phase")[-1]["phase"] == "active", "Enter starts the rep timer")
        cue = pg.inner_text("#nCue")
        check(re.fullmatch(r"\w+ \d+ of \d+|First side|Switch sides|Hold it|Keep walking", cue) is not None, f"rep cue shows ({cue})")
        fit(pg, "nudge")
        pg.screenshot(path=str(shots / f"{theme}-4-active.png"))
        pg.keyboard.press("m")
        check(posted(pg, "minimize") != [], "M asks to minimize")
        pg.evaluate("s => Ravi.update(s)", dict(st, mode="pill", focused=False))
        pill = fit(pg, "pill")
        check(pill is not None and pill["w"] < 340 and pill["h"] < 80, f"pill is small ({pill})")
        pg.wait_for_timeout(1200)
        check("left" in pg.inner_text("#pSub"), "pill shows the time left")
        pg.screenshot(path=str(shots / f"{theme}-5-pill.png"))
        pg.click("#pill")
        check(posted(pg, "restore") != [], "clicking the pill restores")
        pg.evaluate("s => Ravi.update(s)", dict(st, focused=True))
        fit(pg, "nudge")
        pg.keyboard.press("d")
        check(posted(pg, "finish") != [], "D finishes")
        pg.wait_for_timeout(300)
        fit(pg, "nudge")
        pg.screenshot(path=str(shots / f"{theme}-6-done.png"))
        pg.wait_for_timeout(4800)
        check(posted(pg, "closed") != [], "closes itself after done")

        # home card
        pg.evaluate("s => Ravi.update(s)", dict(st, nudge=None, mode="none"))
        pg.evaluate("s => Ravi.update(s)", dict(home_state, theme=theme, focused=True))
        home = fit(pg, "home")
        check(home is not None and home["h"] < 740, f"home card fits a 768-px-high screen ({home})")
        check(pg.inner_text("#hCount").count(":") == 1, "countdown shows")
        pg.wait_for_timeout(500)
        pg.screenshot(path=str(shots / f"{theme}-7-home.png"))
        pg.keyboard.press("3")
        check(posted(pg, "interval")[-1]["m"] == 30, "3 picks every 30 min")
        pg.keyboard.press("v")
        moves = fit(pg, "home")
        check(moves is not None and moves["h"] < 740, f"moves view fits too ({moves})")
        pg.keyboard.press("ArrowDown")
        pg.keyboard.press(" ")
        last = posted(pg, "moveOn")[-1]
        check(last["id"] == "thoracic" and last["on"] is False, f"Space switches a move off ({last})")
        pg.screenshot(path=str(shots / f"{theme}-8-moves.png"))
        pg.keyboard.press("Escape")
        pg.keyboard.press("Escape")
        check(posted(pg, "hide") != [], "Esc hides the home card")
        check(not errors, f"no script errors ({errors[:2]})")
        ctx.close()
    browser.close()

print(f"\n{'all passed' if not fails else str(len(fails)) + ' failed'}")
sys.exit(1 if fails else 0)
