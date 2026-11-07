import json, re, sys, collections
sys.stdout.reconfigure(encoding="utf-8")
def lj(p):
    v=json.load(open(p,encoding="utf-8"))["values"][0]; return json.loads(v) if isinstance(v,str) else (v or [])
sv=lj("sv.json"); cl=lj("cl.json"); con=json.load(open("con.json",encoding="utf-8"))["lines"]
rx=re.compile(r"^(\w+Sound)\s+(\S+)\s*:\s*src\s+(-?\d+)\s*:\s*channel\s+(-?\d+)")
def norm(n): return (n or "").replace("\\","/").lower().lstrip("^)*#@<>!?").removeprefix("sound/")
H=collections.Counter(); HT={}
for l in con:
    m=rx.match(l["text"])
    if m: n=norm(m.group(2)); H[n]+=1; HT[n]=m.group(1)
def cnt(log,kind): 
    c=collections.Counter()
    for x in log:
        if x["kind"]==kind: c[norm(x["name"])]+=1
    return c
SH=cnt(sv,"hook"); CH=cnt(cl,"hook")
oth=collections.Counter((x["kind"]+"@"+r,norm(x["name"])) for r,log in (("sv",sv),("cl",cl)) for x in log if x["kind"]!="hook")
names=sorted(set(H)|set(SH)|set(CH), key=lambda n:-H[n])
print(f"{'name':52s} heard type          svhook clhook")
for n in names: print(f"{n:52s} {H[n]:5d} {HT.get(n,''):13s} {SH[n]:6d} {CH[n]:6d}")
print("detours:",dict(oth))
