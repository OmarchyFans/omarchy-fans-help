#!/usr/bin/env python3
"""Head-to-head navigation, per item, so the margin can be tested rather than asserted."""
import importlib.util, json, os, subprocess, sqlite3, sys, time, urllib.request, urllib.error
from importlib.machinery import SourceFileLoader
ROOT=os.path.expanduser("~/.local/share/omarchy-local-agent"); MODELS=os.path.join(ROOT,"models"); PORT=8097
spec=importlib.util.spec_from_loader("agent",SourceFileLoader("agent",os.path.expanduser("~/.local/bin/omarchy-local-agent")))
agent=importlib.util.module_from_spec(spec); spec.loader.exec_module(agent)
sys.path.insert(0,ROOT); import eval as E
CASES=[(q,w) for q,p,w in E.HELDOUT+E.CASES if p=="prose"]
def ready(pr,t=180):
    for _ in range(t):
        if pr.poll() is not None: return False
        try: urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health",timeout=2); return True
        except Exception: time.sleep(1)
    return False
cfg=dict(agent.load_config(),server=f"http://127.0.0.1:{PORT}",timeout=90)
db=sqlite3.connect(f"file:{agent.DB}?mode=ro",uri=True); system=agent.build_system()
out={}
for g in sys.argv[1:]:
    p=os.path.join(MODELS,g)
    pr=subprocess.Popen(["llama-server","--model",p,"--host","127.0.0.1","--port",str(PORT),
        "--ctx-size","8192","--threads","8","--n-gpu-layers","99","--no-webui"],
        stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
    if not ready(pr): print(f"{g}: no server"); pr.kill(); continue
    res=[]
    for q,want in CASES:
        r=agent.retrieve(db,q,cfg)
        try:
            sec,_=agent.navigate(db,cfg,system,q,r["sections"])
            res.append(1 if (sec and sec["sid"].startswith(want)) else 0)
        except Exception: res.append(0)
    out[g]=res; print(f"  {g:<32} {sum(res)}/{len(res)}")
    pr.kill(); pr.wait(); time.sleep(3)
json.dump({"cases":[c[0] for c in CASES],"results":out},open(os.path.join(ROOT,"headtohead.json"),"w"),indent=1)
