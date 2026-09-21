import sys, json, time, re, base64
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcpcall
from keys import tap, type_text
def txt(m):
    out=[]
    for x in m:
        r = x.get("result") or x.get("error")
        if isinstance(r, dict) and "content" in r:
            for c in r["content"]:
                if c.get("type")=="image": out.append("<image>")
                else: out.append(c.get("text",""))
        else: out.append(json.dumps(r))
    return "\n".join(out)
def shot(fn):
    m = mcpcall.call("editor_screenshot", {"source":"game","max_resolution":1280})
    for x in m:
        r = x.get("result") or {}
        for c in r.get("content", []):
            if c.get("type")=="image": open(fn,"wb").write(base64.b64decode(c["data"])); print("saved", fn)
def hud():
    d = json.loads(txt(mcpcall.call("game_manage", {"op":"get_node_info","params":{"path":"/root/Main/UI/HUD","include_properties":True}})))
    return d["properties"].get("text","")
def words(h):
    # prompts are rendered as [color=#ffd166][b]typed[/b][/color]rest
    return [a+b for a,b in re.findall(r"\[color=#ffd166\]\[b\](.*?)\[/b\]\[/color\]([a-z]*)", h)]
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "hud": print(hud())
elif cmd == "words": print(words(hud()))
elif cmd == "typeword":
    # type the first prompt word (or the given one if present)
    want = sys.argv[2] if len(sys.argv) > 2 else None
    w = words(hud())
    pick = want if want in w else (w[0] if w else None)
    print("prompts:", w, "-> typing", pick)
    if pick: type_text(pick)
elif cmd == "shot": shot(sys.argv[2])
elif cmd == "waitdoor":
    # poll until the HUD shows a door prompt, then type it immediately
    for i in range(80):
        h = hud()
        if "At the door" in h:
            w = words(h); print("door prompts:", w); type_text(w[0]); print("typed", w[0]); break
        time.sleep(0.25)
elif cmd == "waitidle":
    # poll until inside and prompts are shown (player stopped in a room)
    for i in range(80):
        h = hud()
        if "Inside" in h and words(h):
            print(h.replace("\n"," | ")); break
        time.sleep(0.25)
if cmd == "fight":
    # wait for a targetable zombie, type its (remaining) word, screenshot mid-word and after
    import re as _re
    for i in range(120):
        h = hud()
        m = _re.search(r"\[color=#94a3b8\](.*?)\[/color\]", h)
        if m and m.group(1).strip():
            words = m.group(1).split()
            w = words[0]; print("targets:", words, "-> typing", w)
            type_text(w[:2]); shot(sys.argv[2] + "_mid.png")
            type_text(w[2:]); time.sleep(0.4); shot(sys.argv[2] + "_kill.png")
            print(hud().replace("\n"," | "))
            break
        time.sleep(0.5)
