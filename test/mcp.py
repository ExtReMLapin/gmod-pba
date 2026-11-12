"""Minimal command-line MCP client for the gmod-mcp server (used by every test/*.py script).
Reads the server URL and headers from Claude Code's config (~/.claude.json, or CLAUDE_JSON).
Usage: python -I test/mcp.py list
       python -I test/mcp.py call <tool> '<json args>' [maxchars]     ('@file' = JSON args read from a file)
MCP_INSTANCE=<id> targets one game when several run (instances_list).
MCP_PROJECT=<folder> picks the Claude Code project whose "gmod" MCP server is used.
Without such an entry (gmod-mcp installed as a plugin, a stdio bridge): the game's own HTTP server, at MCP_URL
(default http://127.0.0.1:27080/mcp, the base port) with the token of %APPDATA%/gmod-mcp/token."""
import json
import os, sys, urllib.request

CFG = json.load(open(os.environ.get("CLAUDE_JSON") or os.path.expanduser("~/.claude.json"), encoding="utf-8"))
SRV = CFG["projects"].get(os.environ.get("MCP_PROJECT", "D:/SteamLibrary/steamapps/common/GarrysMod"), {}).get("mcpServers", {}).get("gmod")
if not SRV:
    _tok = os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~/.config"), "gmod-mcp", "token")
    SRV = {"url": os.environ.get("MCP_URL", "http://127.0.0.1:27080/mcp"),
           "headers": {"Authorization": "Bearer " + open(_tok, encoding="utf-8").read().strip()}}
URL = SRV["url"]
HDR = dict(SRV.get("headers", {}))
HDR.update({"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})


def post(payload, sid=None):
    h = dict(HDR)
    if sid:
        h["Mcp-Session-Id"] = sid
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(), headers=h, method="POST")
    with urllib.request.urlopen(req, timeout=600) as r:
        sid = r.headers.get("Mcp-Session-Id") or sid
        body = r.read().decode("utf-8", "replace")
    if body.lstrip().startswith("{"):
        return json.loads(body), sid
    last = None
    for line in body.splitlines():
        if line.startswith("data:"):
            try:
                m = json.loads(line[5:])
            except Exception:
                continue
            if "id" in m and ("result" in m or "error" in m):
                last = m
    return last, sid


def session():
    r, sid = post({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "audioprop-dev", "version": "0"}}})
    try:
        post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    except Exception:
        pass
    return sid


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    sid = session()
    if sys.argv[1] == "list":
        r, _ = post({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, sid)
        for t in r["result"]["tools"]:
            print(t["name"], "-", (t.get("description") or "").split("\n")[0][:150])
        return
    if sys.argv[1] == "schema":
        r, _ = post({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, sid)
        for t in r["result"]["tools"]:
            if t["name"] in sys.argv[2:]:
                print("==", t["name"]); print(t.get("description", "")[:1500])
                print(json.dumps(t["inputSchema"].get("properties"), ensure_ascii=False)[:1500])
        return
    tool = sys.argv[2]
    raw = sys.argv[3] if len(sys.argv) > 3 else "{}"
    if raw.startswith("@"):  # arguments too long for a command line: read from a file
        raw = open(raw[1:], encoding="utf-8").read()
    args = json.loads(raw)
    # several games (gmod-mcp coordinator): MCP_INSTANCE=<id> targets one of them (tests run in parallel)
    if os.environ.get("MCP_INSTANCE") and "instance" not in args and tool != "instances_list":
        args["instance"] = os.environ["MCP_INSTANCE"]
    mx = int(sys.argv[4]) if len(sys.argv) > 4 else 6000
    r, _ = post({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}}, sid)
    if r is None:
        print("no response"); return
    if "error" in r:
        print("ERROR", json.dumps(r["error"], ensure_ascii=False)[:mx]); return
    res = r["result"]
    out = []
    for c in res.get("content", []):
        if c.get("type") == "text":
            out.append(c["text"])
        else:
            out.append(f"<{c.get('type')} {len(json.dumps(c))} bytes>")
            if c.get("type") == "image" and len(sys.argv) > 5:
                import base64
                open(sys.argv[5], "wb").write(base64.b64decode(c["data"]))
                out.append(f"saved {sys.argv[5]}")
    if res.get("isError"):
        out.insert(0, "isError")
    print("\n".join(out)[:mx])


main()
