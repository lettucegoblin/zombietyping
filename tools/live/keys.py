import sys, json, time
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcpcall
def key(k, pressed=True):
    m = mcpcall.call("game_manage", {"op":"input_key","params":{"key":k,"pressed":pressed}})
    for x in m:
        r = x.get("result") or x.get("error")
        if isinstance(r, dict) and "content" in r:
            t = r["content"][0].get("text","")
            if "error" in t.lower() and "ok" not in t.lower(): print(k, "->", t[:300])
        else: print(k, "->", json.dumps(r)[:300])
def tap(k):
    key(k, True); key(k, False)
def type_text(s):
    # the game acts on key PRESSES only, so skip the release round-trips (twice as fast)
    for ch in s:
        if ch == " ": key("Space", True)
        else: key(ch.upper() if ch.isalpha() else ch, True)
if __name__ == "__main__":
    for arg in sys.argv[1:]:
        if arg.startswith("type:"): type_text(arg[5:])
        else: tap(arg)
        time.sleep(0.15)
