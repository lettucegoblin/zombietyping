import json, sys, time, base64
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcpcall
def show(m, limit=3000):
    for x in m:
        r = x.get("result") or x.get("error")
        if isinstance(r, dict) and "content" in r:
            for c in r["content"]:
                if c.get("type") == "image":
                    fn = sys.argv[2] if len(sys.argv) > 2 else "game.png"
                    open(fn, "wb").write(base64.b64decode(c["data"])); print("saved", fn)
                else: print(c.get("text","")[:limit])
        else: print(json.dumps(r)[:limit])
cmd = sys.argv[1]
if cmd == "run":
    show(mcpcall.call("project_manage", {"op": "stop"}), 300)
    time.sleep(1.0)
    show(mcpcall.call("project_run", {"mode": "main"}))
elif cmd == "stop":
    show(mcpcall.call("project_manage", {"op": "stop"}))
elif cmd == "logs":
    show(mcpcall.call("logs_read", {"source": "game", "count": 80}), 6000)
elif cmd == "shot":
    show(mcpcall.call("editor_screenshot", {"source": "game", "max_resolution": 1280}))
elif cmd == "key":
    show(mcpcall.call("game_manage", {"op": "input_key", "params": json.loads(sys.argv[2])}))
elif cmd == "state":
    show(mcpcall.call("editor_state", {}))
elif cmd == "tree":
    show(mcpcall.call("game_manage", {"op": "get_scene_tree", "params": {"depth": 4}}), 3000)
