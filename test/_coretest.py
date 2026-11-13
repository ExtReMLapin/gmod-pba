"""Shared helpers of the core tests (core_model.py, vanilla_parity.py, propagation_delay.py): the MCP
call, map loading, doors set to a state and waited for, and a small assertion collector.

    T = Core(sys.argv[1])           # also takes the _cvsnap snapshot: every pba_* setting is restored at exit
    T.load("pba_tworooms")
    T.door("door1", "ajar")
    T.check("same room: 0 dB", abs(x) <= 0.1, f"got {x}")
    T.finish()                      # prints the FAIL lines and the final JSON { "pass": ... }, exits 0 / 1
"""
import json
import os
import subprocess
import sys
import time

TEST = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TEST)
import _cvsnap  # noqa: E402


class Core:
    def __init__(self, mcp):
        self.mcp = mcp
        self.fails = []
        self.measured = {}
        _cvsnap.guard(self.call)

    # ------------------------------------------------------------------ MCP
    def call(self, tool, args, mx=2_000_000, timeout=300):
        a = json.dumps(args)
        tmp = None
        if len(a) > 20000:  # Windows command line limit
            import tempfile
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
                f.write(a)
            tmp = f.name
            a = "@" + tmp
        out = subprocess.run([sys.executable, "-I", self.mcp, "call", tool, a, str(mx)],
                             capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout).stdout
        if tmp:
            os.remove(tmp)
        try:
            return json.loads(out)
        except ValueError:
            return {"raw": out}

    def lua(self, realm, code):
        r = self.call("lua_exec", {"realm": realm, "code": code})
        v = r.get("values")
        return v[0] if v else None

    def job(self, realm, code, timeout_s=120):
        r = self.call("lua_job", {"realm": realm, "code": code, "timeout_s": timeout_s}, timeout=timeout_s + 60)
        v = r.get("values")
        return v[0] if v else r

    def run_file(self, realm, name, prelude="", timeout_s=120):
        """A Lua file of test/ run as a job, `prelude` (global inputs) in front; its JSON result decoded."""
        code = prelude + open(os.path.join(TEST, name), encoding="utf-8").read()
        v = self.job(realm, code, timeout_s)
        if not isinstance(v, str):
            raise RuntimeError(f"{name}: no result: {v}")
        return json.loads(v)

    def con(self, realm, cmd):
        self.call("console_exec", {"realm": realm, "cmd": cmd})

    def wait_lua(self, realm, code, timeout=15.0):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if self.lua(realm, code) is True:
                return True
            time.sleep(0.5)
        return False

    # ------------------------------------------------------------------ state
    def load(self, m, mp=4):
        """Map m loaded (maxplayers mp) and pba's client ready (native module built, or absent)."""
        st = self.call("status", {})
        if st.get("map") != m or st.get("maxplayers") != mp:
            self.call("map_load", {"map": m, "maxplayers": mp}, timeout=300)
            time.sleep(4)
        for _ in range(60):
            r = self.call("lua_exec", {"realm": "client", "code": "local N = pba.Native return N == nil or pba_native == nil or (not N.building and (N.ready == true or N.pba_demoHeld == true))"})
            if r.get("values") == [True]:
                break
            time.sleep(2)
        if self.call("status", {}).get("map") != m:
            raise RuntimeError(f"map {m} not loaded")
        # the host dead (an earlier test) would listen from the death camera
        self.lua("server", "for _, p in ipairs(player.GetHumans()) do if not p:Alive() then p:Spawn() end end return true")
        time.sleep(1)

    def place(self, feet, yaw=0):
        """The host at `feet`, looking along yaw; waits until the client's listener is there."""
        self.lua("server", "local p = player.GetHumans()[1] p:SetPos(Vector(%g, %g, %g)) p:SetEyeAngles(Angle(0, %g, 0)) p:SetVelocity(-p:GetVelocity()) return true"
                 % (feet[0], feet[1], feet[2], yaw))
        self.wait_lua("client", "return pba.ListenerPos():Distance(Vector(%g, %g, %g + 64)) < 8" % (feet[0], feet[1], feet[2]), 8)

    def door(self, name, state):
        """Door `name` (a prop_door_rotating, func_door_rotating or func_door of the test maps) closed / open / ajar
        (a rotating door turned 10 degrees: the leaf's gap; fraction ~0.11), then waited for on the client (the
        fractions of every door stable for 1 s). Returns the fractions of the map's doors, sorted."""
        fire = {
            "closed": "d:Fire('Close')",
            "open": "d:Fire('Close') d:Fire('SetRotationDistance', '90', 0.1) d:Fire('Open', '', 0.2)",
            "ajar": "d:Fire('Close') d:Fire('SetRotationDistance', '10', 0.1) d:Fire('Open', '', 0.2)",
        }[state]
        self.lua("server", "for _, d in ipairs(ents.FindByName('%s')) do %s end return true" % (name, fire))
        t0, last, since = time.time(), None, time.time()
        while time.time() - t0 < (14 if state == "ajar" else 10):
            fr = self.lua("client", "local t = {} for e, st in pairs(pba.Doors.byEnt) do t[#t + 1] = string.format('%.3f', st.frac or 0) end table.sort(t) return table.concat(t, ',')")
            if fr != last:
                last, since = fr, time.time()
            elif time.time() - since >= 1.0:
                break
            time.sleep(0.4)
        return [float(x) for x in last.split(",")] if last else []

    def doors_state(self):
        return self.lua("client", "local t = {} for e, st in pairs(pba.Doors.byEnt) do t[#t + 1] = { f = st.frac, db = st.closedDb } end return util.TableToJSON(t)")

    # ------------------------------------------------------------------ verdict
    def check(self, name, ok, detail=""):
        if not ok:
            self.fails.append(f"{name}: {detail}")
            print(f"FAIL {name}: {detail}", flush=True)
        else:
            print(f"ok   {name}" + (f" ({detail})" if detail else ""), flush=True)
        return ok

    def finish(self):
        res = {"pass": not self.fails, "fails": self.fails, "measured": self.measured}
        print(json.dumps(res, ensure_ascii=False))
        sys.exit(0 if not self.fails else 1)
