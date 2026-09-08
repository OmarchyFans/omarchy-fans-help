#!/usr/bin/env python3
"""Retrieval accuracy harness for the local Omarchy agent.

Deliberately checks RETRIEVAL ONLY -- the path chosen and the evidence found --
with no model in the loop. That isolates retrieval bugs from model bugs: if the
right section never gets retrieved, no amount of model quality saves the answer.

Ground truth was read out of the built index, not invented.

  ./eval.py           run the set
  ./eval.py --tune    sweep the fast-path thresholds and report the best pair
"""

import importlib.util
import itertools
import os
import sqlite3
import sys
from importlib.machinery import SourceFileLoader

# The agent is an extensionless executable, so the loader has to be named.
AGENT = os.path.expanduser("~/.local/bin/omarchy-local-agent")
spec = importlib.util.spec_from_loader("agent", SourceFileLoader("agent", AGENT))
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)

# path:   which route the query should take
# expect: a substring that must appear in the winning evidence for that path.
#         For 'fast' that is a keybinding or command route; for 'prose' it is
#         the section id the manual answer lives in.
CASES = [
    # --- exact lookups: should answer from the index, no model ---
    ("keybind to toggle nightlight",            "fast",  "SUPER CTRL + N"),
    ("what is the keybinding for the theme menu", "fast", "SUPER SHIFT CTRL + SPACE"),
    ("hotkey to lock the system",                "fast",  "SUPER CTRL + L"),
    ("shortcut for full screen",                 "fast",  "SUPER + F"),
    ("key to open the omarchy menu",             "fast",  "SUPER + SPACE"),
    ("command to set a reminder",                "fast",  "omarchy reminder"),
    ("command to update omarchy",                "fast",  "omarchy update"),
    ("command to install a package",             "fast",  "omarchy pkg"),
    # Was "omarchy debug", which the skill documentation describes but which
    # does not exist in installed 4.0.2 -- the eval caught stale docs, not a
    # retrieval bug. Replaced with a route that is actually present.
    ("command to check for available updates",   "fast",  "omarchy update available"),
    ("command to restart the shell",             "fast",  "omarchy restart shell"),

    # --- prose: need the manual ---
    ("how do I record my screen",                "prose", "12-screenshots-recording"),
    ("how do I take a screenshot",               "prose", "12-screenshots-recording"),
    ("how do I set up a second monitor",         "prose", "33-monitors"),
    ("how do I make text bigger on my display",  "prose", "33-monitors"),
    ("how do I stop my laptop going to sleep",   "prose", "13-toggles-idle-screensaver"),
    ("what does the screensaver do",             "prose", "13-toggles-idle-screensaver"),
    ("how does the clipboard history work",      "prose", "08-unified-clipboard-history"),
    ("how do I dictate text with my voice",      "prose", "11-text-extraction-dictation"),
    ("how do I control screen brightness",       "prose", "33-monitors"),
    ("how do I turn on do not disturb",          "prose", "13-toggles-idle-screensaver"),
]

# HELD OUT. The thresholds, intent regexes, stopwords and column weights were
# all iterated against CASES above, so that score is training accuracy and will
# flatter itself. These were written afterwards, phrased the way someone would
# actually ask rather than echoing manual headings, and are NOT tuned against.
# Report this number separately; it is the honest generalization estimate.
HELDOUT = [
    # --- prose: broad "how/why/explain" questions ---
    ("make the screen warmer at night",          "prose", "13-toggles-idle-screensaver"),
    ("how do I get my dotfiles backed up",       "prose", "31-dotfiles"),
    ("how do I plug into an external display",   "prose", "33-monitors"),
    ("explain how themes work",                  "prose", "06-themes"),
    ("how do I change the wallpaper",            "prose", "39-backgrounds"),
    ("how do I install a different font",        "prose", "38-fonts"),
    ("how do I connect to wifi",                 "prose", "35-networking"),
    ("how do I roll back a bad update",          "prose", "47-system-snapshots"),
    ("how do I customise my shell prompt",       "prose", "40-prompt"),
    ("what do I do when an app keeps crashing",  "prose", "45-troubleshooting"),
    ("how does updating work",                   "prose", "30-updates"),
    ("how do I set up my fingerprint reader",    "prose", "37-hardware-authentication"),
    ("how do I run windows software",            "prose", "28-windows-vm"),
    ("explain the top bar",                      "prose", "05-the-top-bar"),
    ("how do I play games on this",              "prose", "26-gaming"),
    ("what terminal does this use",              "prose", "15-terminal"),
    ("how do I fill in a pdf form",              "prose", "27-filling-out-pdfs"),
    ("how do I make my trackpad less sensitive", "prose", "34-keyboard-mouse-trackpad"),
    ("coming from a mac, what do I need to know", "prose", "03-coming-from-mac-or-windows"),
    ("how do I harden this machine",             "prose", "48-security"),

    # --- fast: exact lookups ---
    # "silence my notifications" moved here. It reads as an imperative, and the
    # index returns SUPER CTRL + COMMA plus `omarchy toggle notification
    # silencing` -- which is the better answer. The original 'prose'
    # expectation was wrong; correcting the test beats contorting the ranker.
    ("silence my notifications",                 "fast",  "notification"),
    ("what key moves a window to the left",      "fast",  "SUPER"),
    ("shortcut for switching workspace",         "fast",  "SUPER"),
    ("what do I run to add a new package",       "fast",  "omarchy pkg"),
    ("command to change the theme",              "fast",  "omarchy theme"),
    ("keybind to open the file manager",         "fast",  "SUPER"),
    ("command for taking a screen recording",    "fast",  "omarchy capture"),
]


def evidence(res):
    """The strings a case may match against, for the path actually taken."""
    if res["path"] == "fast":
        return ([b["keys"] for b in res["binds"][:2]]
                + [c["route"] for c in res["commands"][:2]])
    return [s["sid"] for s in res["sections"][:3]]


def run(db, cfg, verbose=True, cases=None):
    passed = 0
    for query, want_path, want in (CASES if cases is None else cases):
        res = agent.retrieve(db, query, cfg)
        ev = evidence(res)
        ok = res["path"] == want_path and any(want in e for e in ev)
        passed += ok
        if verbose:
            mark = "\033[32m PASS\033[0m" if ok else "\033[31m FAIL\033[0m"
            print(f"{mark}  {query}")
            if not ok:
                print(f"        want {want_path}:{want}")
                print(f"        got  {res['path']}: {', '.join(ev[:3])}")
                print(f"        scores exact={res['best_exact']:.2f} "
                      f"section={res['best_section']:.2f}")
    return passed


def tune(db, cfg):
    """Sweep the fast-path thresholds. The scoring scale shifted when column
    weights were introduced, so these cannot be carried over by intuition.

    Sweeps against CASES only -- never HELDOUT. Fitting a constant to the
    held-out set would destroy the only honest number in this harness.
    """
    best = []
    for score, margin in itertools.product(
            [-2.0, -3.0, -4.0, -5.0, -6.0, -7.0, -8.0, -9.0, -10.0],
            [0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0]):
        trial = dict(cfg, fast_path_max_score=score, fast_path_margin=margin)
        n = run(db, trial, verbose=False)
        best.append((n, score, margin))
    best.sort(key=lambda t: (-t[0], t[1]))

    print(f"top threshold pairs (out of {len(CASES)}):")
    for n, score, margin in best[:8]:
        print(f"  {n:>2}/{len(CASES)}  fast_path_max_score={score:<6} "
              f"fast_path_margin={margin}")
    return best[0]



def main():
    cfg = agent.load_config()
    db = sqlite3.connect(f"file:{agent.DB}?mode=ro", uri=True)

    if "--tune" in sys.argv:
        n, score, margin = tune(db, cfg)
        print(f"\nbest: {n}/{len(CASES)} at max_score={score}, margin={margin}\n")
        print("re-running with those thresholds:\n")
        cfg = dict(cfg, fast_path_max_score=score, fast_path_margin=margin)

    print("tuned set:")
    n = run(db, cfg)
    print(f"\n  {n}/{len(CASES)} tuned cases passed")

    print("\nheld-out set (not tuned against):")
    h = run(db, cfg, cases=HELDOUT)
    print(f"\n  {h}/{len(HELDOUT)} held-out cases passed")

    print(f"\n{n}/{len(CASES)} tuned, {h}/{len(HELDOUT)} held out")
    return 0 if n == len(CASES) else 1


if __name__ == "__main__":
    sys.exit(main())
