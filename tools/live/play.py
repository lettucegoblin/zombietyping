"""Scripted playtest helpers: python3 play.py <label> — enter a building and fight to the first room
with options, then screenshot a closed door up close."""
import sys, time, re
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from keys import type_text, tap
from drive import hud, words, shot

def targets(h):
    m = re.search(r"\[color=#94a3b8\](.*?)\[/color\]", h)
    return m.group(1).split() if m else []

def enter(label):
    type_text(label)
    for i in range(240):
        h = hud()
        if "At the door" in h:
            type_text(words(h)[0]); return True
        time.sleep(0.25)
    return False

def settle(max_s=90, stop_words=("up","down")):
    """fight everything in sight; return when standing in a room with prompts."""
    t0 = time.time()
    while time.time() - t0 < max_s:
        h = hud()
        t = targets(h)
        if t:
            type_text(t[0]); continue
        w = words(h)
        if "Inside" in h and w and "moving on" not in h:
            return w
        time.sleep(0.1)
    return []

if __name__ == "__main__":
    label = sys.argv[1]
    print("enter:", enter(label), flush=True)
    w = settle()
    print("options:", w, flush=True)
    print(hud().replace("\n"," | "), flush=True)
    shot("d0.png")
    door = [x for x in w if x not in ("exit","up","down")]
    if door:
        type_text(door[0][0]); time.sleep(0.7); shot("d1.png")
        print("typed", door[0][0], "->", hud().replace("\n"," | "), flush=True)
