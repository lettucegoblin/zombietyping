import json, sys, urllib.request
URL="http://127.0.0.1:8000/mcp"
SID_FILE="mcp_session_id.txt"
def post(payload, sid=None):
    h={"Content-Type":"application/json","Accept":"application/json, text/event-stream"}
    if sid: h["Mcp-Session-Id"]=sid
    req=urllib.request.Request(URL,data=json.dumps(payload).encode(),headers=h,method="POST")
    with urllib.request.urlopen(req,timeout=60) as r:
        new_sid=r.headers.get("Mcp-Session-Id"); body=r.read().decode()
    msgs=[]
    for line in body.splitlines():
        if line.startswith("data: "): line=line[6:]
        line=line.strip()
        if line.startswith("{"):
            try: msgs.append(json.loads(line))
            except: pass
    return new_sid, msgs
def session():
    try: return open(SID_FILE).read().strip() or None
    except: return None
def init():
    sid,m=post({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}})
    open(SID_FILE,"w").write(sid or "")
    post({"jsonrpc":"2.0","method":"notifications/initialized"},sid)
    return sid, m
def call(name, args=None, sid=None):
    sid=sid or session()
    try:
        _,m=post({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":name,"arguments":args or {}}},sid)
    except urllib.error.HTTPError as e:
        if e.code not in (404,400): raise
        sid,_=init()
        _,m=post({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":name,"arguments":args or {}}},sid)
    return m
def tools():
    try:
        _,m=post({"jsonrpc":"2.0","id":2,"method":"tools/list"},session())
    except urllib.error.HTTPError:
        init(); _,m=post({"jsonrpc":"2.0","id":2,"method":"tools/list"},session())
    return {t["name"]:t for t in m[0]["result"]["tools"]}
if __name__=="__main__":
    cmd=sys.argv[1]
    if cmd=="init":
        sid,m=init(); print("session:",sid); print(json.dumps(m[0].get("result",{}).get("serverInfo"),indent=0) if m else m)
    elif cmd=="tools":
        _,m=post({"jsonrpc":"2.0","id":2,"method":"tools/list"},session())
        t=m[0]["result"]["tools"]; print(len(t),"tools"); print(", ".join(x["name"] for x in t))
    elif cmd=="call":
        m=call(sys.argv[2], json.loads(sys.argv[3]) if len(sys.argv)>3 else {})
        for x in m:
            r=x.get("result") or x.get("error")
            if isinstance(r,dict) and "content" in r:
                for c in r["content"]:
                    print(c.get("text","")[:4000] if c.get("type")=="text" else f"<{c.get('type')}>")
            else: print(json.dumps(r,indent=1)[:4000])
