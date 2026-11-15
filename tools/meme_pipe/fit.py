"""Fits params.json (gen.py's model) so that what the player HEARS fits a reference recording.

Needs torch (CUDA recommended), numpy, scipy, soundfile (a venv outside the repository). The reference recording
is never part of the repository: pass it with --target. Nothing it holds is kept, only the fitted synth parameters.

What is fitted: a stack of four pipes dropped in game gives a handful of clangs (schedules.json: the impacts
recorded on a server: time, tier, variant, volume). Each is rendered with the synth (pitch +-2 % like the game's random
pitch), the sum is convolved with measured impulse responses of pba's real rendering chain (--ir: an .npz of
stereo responses per scene, measured by playing an exponential sweep from a pipe in game and recording the module's
final output with pba_native.CaptureStart / CaptureStop, then deconvolving it) and compared with the target on:
  - the long-term spectrum at fine resolution (the modal lines), as mean power and as mean log,
  - 1/3-octave band levels in time (envelope and timbre evolution),
both after matching the overall RMS. The first loud onset of each is aligned (the target's trimmed at its onset).

Usage:
  python fit.py --target meme.wav --ir irs.npz [--params params.json] [--out params_fit.json] [--steps 2500] [--init]
      --init   build the starting modes from the target's spectral peaks (else start from --params)
  python fit.py --selftest      (numpy and torch renders agree; a fit recovers a synthetic target)
"""
import argparse
import json
import math
import os
import sys
import time

import numpy as np
import scipy.signal as ss
import soundfile as sf

import gen

FS = 48000
HERE = os.path.dirname(os.path.abspath(__file__))
WIN = 2.5      # s of the target compared, from its onset
LEAD = 0.15    # s of silence kept before the onset
ENV_W = 3.0    # weight of the level-in-time term
EDGES = [100.0 * 2 ** (k / 3) for k in range(0, 23)]  # 1/3-octave band edges 100 Hz .. 12.7 kHz


def torch_mod():
    import torch
    return torch


def load_target(path):
    x, fs = sf.read(path)
    m = x.mean(1) if x.ndim > 1 else x
    if fs != FS:
        m = ss.resample_poly(m, FS, fs)
    env = np.convolve(m ** 2, np.ones(480) / 480, mode="same")
    on = int(np.argmax(env > 1e-3 * env.max()))
    on = max(0, on - 48)
    seg = m[on:on + int(WIN * FS)]
    seg = np.concatenate([np.zeros(int(LEAD * FS)), seg])
    return seg


def init_bed(f, P, k=24):
    kn = 100.0 * (13000.0 / 100.0) ** (np.arange(k) / (k - 1))
    sm = []
    for c in kn:
        sel = (f > c / 2 ** (1 / 4)) & (f < c * 2 ** (1 / 4))
        sm.append(float(np.median(P[sel])) if sel.any() else 1e-12)
    g = np.sqrt(np.array(sm) * FS / 2) * 0.5
    return {"knots_hz": [float(x) for x in kn], "gain": [float(x) for x in g], "tau": [1.0] * k}


def init_params(target_seg, n_modes=96):
    """Modes at the strongest peaks of the target's long-term spectrum (frequency and level), long decays."""
    f, P = ss.welch(target_seg[int(LEAD * FS):], FS, nperseg=16384, noverlap=8192)
    Pdb = 10 * np.log10(P + 1e-20)
    pk, props = ss.find_peaks(Pdb, prominence=5, distance=4)
    pk = pk[(f[pk] > 60) & (f[pk] < 12000)]
    pk = pk[np.argsort(-Pdb[pk])][:n_modes]
    rng = np.random.RandomState(5)
    modes = [{"f": float(f[i]), "tau": 1.5, "a": float(10 ** (Pdb[i] / 20.0) * 4.0), "phase": float(rng.uniform(0, 2 * np.pi))} for i in sorted(pk)]
    return {
        "sample_rate": 44100, "master_gain": 1.0, "noise_len": 24000, "tail_fade_ms": 120,
        "variants": {"count": 4, "seed": 17, "amp_jitter_db": 2.5, "detune": 0.0012},
        "tiers": {
            "hard": {"gain": 1.0, "tilt_db_oct": 0.0, "strike_gain": 0.25, "strike_tau_ms": 6.0, "strike_lp_hz": 9000.0, "length_s": 4.0},
            "medium": {"gain": 0.6, "tilt_db_oct": 3.0, "strike_gain": 0.12, "strike_tau_ms": 5.0, "strike_lp_hz": 6000.0, "length_s": 3.2},
            "soft": {"gain": 0.3, "tilt_db_oct": 6.0, "strike_gain": 0.05, "strike_tau_ms": 4.0, "strike_lp_hz": 4000.0, "length_s": 2.4},
        },
        "modes": modes,
        "bed": init_bed(f, P),
    }


# ------------------------------------------------------------------ torch model (same maths as gen.render)
class Model:
    def __init__(self, p, device):
        torch = torch_mod()
        self.t = torch
        self.p, self.dev = p, device
        n = len(p["modes"])
        f, tau, a, ph = gen.mode_arrays(p)
        T = lambda x: torch.tensor(np.asarray(x), dtype=torch.float32, device=device)
        self.logf = T(np.log(f)).requires_grad_()
        self.logtau = T(np.log(tau)).requires_grad_()
        self.loga = T(np.log(a)).requires_grad_()
        self.phase = T(ph)
        bed = p["bed"]
        self.bed_g = T(np.log(bed["gain"])).requires_grad_()
        self.bed_tau = T(np.log(bed["tau"])).requires_grad_()
        self.bed_knots = T(bed["knots_hz"])
        self.bed_noise = {}
        self.tier = {}
        for k, v in p["tiers"].items():
            self.tier[k] = {n_: T(np.log(v[n_]) if n_ in ("gain", "strike_gain", "strike_tau_ms", "strike_lp_hz") else v[n_]).requires_grad_()
                            for n_ in ("gain", "tilt_db_oct", "strike_gain", "strike_tau_ms", "strike_lp_hz")}
            self.tier[k]["length_s"] = float(v["length_s"])
        self.draws = {}
        for tier in gen.TIERS:
            for var in range(1, int(p["variants"]["count"]) + 1):
                jit, det, noise = gen.variant_draws(p, tier, var, n)
                self.draws[(tier, var)] = (T(jit), T(det), T(noise))
        self.n = n
        self.params = [self.logf, self.logtau, self.loga, self.bed_g, self.bed_tau] + [x for d in self.tier.values() for kk, x in d.items() if kk != "length_s"]

    def event(self, tier, var, pitch, N):
        """One dry event (N samples at FS), differentiable."""
        torch = self.t
        td = self.tier[tier]
        jit, det, noise = self.draws[(tier, var)]
        f = torch.exp(self.logf)
        fi = f * (1 + det) * pitch
        tilt = 10.0 ** (-td["tilt_db_oct"] * torch.log2(torch.clamp(f, min=20.0) / 1000.0) / 20.0)
        amp = torch.exp(self.loga) * torch.exp(td["gain"]) * tilt * 10.0 ** (jit / 20.0)
        amp = torch.where(fi < 0.45 * FS, amp, torch.zeros_like(amp))
        tau = torch.exp(self.logtau) / pitch
        t = torch.arange(N, device=self.dev, dtype=torch.float32) / FS
        y = torch.zeros(N, device=self.dev)
        for s in range(0, self.n, 32):
            sl = slice(s, s + 32)
            y = y + (amp[sl, None] * torch.exp(-t[None, :] / tau[sl, None]) * torch.sin(2 * math.pi * fi[sl, None] * t[None, :] + self.phase[sl, None])).sum(0)
        key = var
        if key not in self.bed_noise:
            self.bed_noise[key] = torch.tensor(gen.bed_noise(self.p, var, int(4.1 * FS), FS), dtype=torch.float32, device=self.dev)
        bg = torch.exp(self.bed_g) * torch.exp(td["gain"]) * 10.0 ** (-td["tilt_db_oct"] * torch.log2(self.bed_knots / 1000.0) / 20.0)
        y = y + (bg[:, None] * torch.exp(-t[None, :] / (torch.exp(self.bed_tau)[:, None] / pitch)) * self.bed_noise[key][:, :N]).sum(0)
        nl = noise.shape[0]
        X = torch.fft.rfft(noise)
        fr = torch.fft.rfftfreq(nl, 1.0 / FS).to(self.dev)
        X = X / torch.sqrt(1.0 + (fr / torch.exp(td["strike_lp_hz"])) ** 2)
        nz = torch.fft.irfft(X, nl)
        nz = nz / (torch.sqrt(torch.mean(nz ** 2)) + 1e-12)
        ne = min(nl, N)
        env = torch.exp(-t[:ne] / (torch.exp(td["strike_tau_ms"]) * 1e-3))
        y = torch.cat([y[:ne] + torch.exp(td["strike_gain"]) * nz[:ne] * env, y[ne:]])
        fin = max(1, int(0.001 * FS))
        ramp = torch.ones(N, device=self.dev)
        ramp[:fin] = torch.linspace(0, 1, fin, device=self.dev)
        return y * ramp

    def to_params(self):
        torch = self.t
        p = json.loads(json.dumps(self.p))
        f, tau, a = [torch.exp(x).detach().cpu().numpy() for x in (self.logf, self.logtau, self.loga)]
        for i, m in enumerate(p["modes"]):
            m["f"], m["tau"], m["a"] = float(f[i]), float(tau[i]), float(a[i])
        p["bed"]["gain"] = [float(x) for x in torch.exp(self.bed_g).detach().cpu().numpy()]
        p["bed"]["tau"] = [float(x) for x in torch.exp(self.bed_tau).detach().cpu().numpy()]
        for k, d in self.tier.items():
            for n_ in ("gain", "strike_gain", "strike_tau_ms", "strike_lp_hz"):
                p["tiers"][k][n_] = float(torch.exp(d[n_]).item())
            p["tiers"][k]["tilt_db_oct"] = float(d["tilt_db_oct"].item())
        return p


def render_scenario(model, events, irs_t, N, rng):
    """events: [(t, tier, var, vol)], returns [len(irs)] mixes convolved with each IR, aligned so the first event is at LEAD."""
    torch = model.t
    t0 = min(e[0] for e in events)
    mix = torch.zeros(N + irs_t[0].shape[0], device=model.dev)
    for (t, tier, var, vol) in events:
        pitch = 1.0  # the game plays the files at pitch 100: lines stay sharp
        n_ev = min(int(model.tier[tier]["length_s"] * FS), N)
        d = int((LEAD + t - t0) * FS)
        n_use = min(n_ev, N - d)
        if n_use <= 0:
            continue
        y = model.event(tier, var, pitch, n_use) * vol
        mix = mix + torch.nn.functional.pad(y, (d, mix.shape[0] - d - n_use))
    outs = []
    for ir in irs_t:
        nfft = 1 << int(math.ceil(math.log2(mix.shape[0] + ir.shape[0])))
        o = torch.fft.irfft(torch.fft.rfft(mix, nfft) * torch.fft.rfft(ir, nfft), nfft)[:N]
        outs.append(o)
    return outs


# ------------------------------------------------------------------ features / loss
def band_matrix(nfft, dev, torch):
    fr = np.fft.rfftfreq(nfft, 1.0 / FS)
    B = np.zeros((len(EDGES) - 1, len(fr)), dtype=np.float32)
    for b in range(len(EDGES) - 1):
        B[b, (fr >= EDGES[b]) & (fr < EDGES[b + 1])] = 1.0
    return torch.tensor(B, device=dev)


class Feats:
    def __init__(self, torch, dev):
        self.torch, self.dev = torch, dev
        self.w8 = torch.hann_window(8192, device=dev)
        self.w2 = torch.hann_window(2048, device=dev)
        self.B = band_matrix(2048, dev, torch)
        fr = np.fft.rfftfreq(8192, 1.0 / FS)
        self.fine = torch.tensor(((fr > 80) & (fr < 12000)).astype(np.float32), device=dev)

    def __call__(self, x):
        torch = self.torch
        x = x / (torch.sqrt(torch.mean(x ** 2)) + 1e-9)  # level-free: the overall RMS is matched
        S8 = torch.stft(x, 8192, 2048, window=self.w8, return_complex=True, center=True).abs() ** 2
        ltas = torch.log10(S8.mean(1) + 1e-10) * 10
        mlog = (torch.log10(S8 + 1e-10) * 10).mean(1)
        S2 = torch.stft(x, 2048, 1024, window=self.w2, return_complex=True, center=True).abs() ** 2
        bands = 10 * torch.log10(self.B @ S2 + 1e-9)       # [bands, frames]
        nf = (x.shape[0] // 4800) * 4800
        env = 10 * torch.log10((x[:nf].reshape(-1, 4800) ** 2).mean(1) + 1e-9)  # level per 100 ms
        return ltas, mlog, bands, env


def loss_fn(fa, fb, fine):
    torch = fa[0].new_zeros(0)  # type anchor only
    ltas_a, mlog_a, bands_a, env_a = fa
    ltas_b, mlog_b, bands_b, env_b = fb
    w = fine / fine.sum()
    l1 = ((ltas_a - ltas_b).abs() * w).sum()
    l2 = ((mlog_a - mlog_b).abs() * w).sum()
    n = min(bands_a.shape[1], bands_b.shape[1])
    l3 = (bands_a[:, :n] - bands_b[:, :n]).abs().mean()
    m = min(env_a.shape[0], env_b.shape[0])
    l4 = (env_a[:m] - env_b[:m]).abs().mean()  # the overall level in time: the plateau (a sustained ring, not a decay)
    return l1 + l2 + l3 + ENV_W * l4, (float(l1), float(l2), float(l3), float(l4))


def run_fit(p, target_seg, irs, sched, steps, lr_scale, dev, log):
    torch = torch_mod()
    model = Model(p, dev)
    feats = Feats(torch, dev)
    N = len(target_seg)
    tgt = torch.tensor(target_seg, dtype=torch.float32, device=dev)
    ft = [t.detach() for t in feats(tgt)]
    irs_t = [torch.tensor(i, dtype=torch.float32, device=dev) for i, _ in irs]
    wts = [w for _, w in irs]
    groups = [{"params": [model.logf], "lr": 3e-4 * lr_scale}, {"params": [model.logtau, model.bed_tau], "lr": 1.5e-2 * lr_scale},
              {"params": [model.loga, model.bed_g], "lr": 3e-2 * lr_scale},
              {"params": [x for d in model.tier.values() for kk, x in d.items() if kk != "length_s"], "lr": 1e-2 * lr_scale}]
    opt = torch.optim.Adam(groups)
    sch = torch.optim.lr_scheduler.CosineAnnealingLR(opt, steps, eta_min=0.05 * 1.0)
    rng = np.random.RandomState(11)
    t0 = time.time()
    best = (1e9, None)
    ema = None
    for it in range(steps):
        run = sched[rng.randint(len(sched))]
        events = [(e[0], e[1], e[2], e[3]) for e in run]
        outs = render_scenario(model, events, irs_t, N, rng)
        tot = 0.0
        parts = None
        for o, w in zip(outs, wts):
            l, parts = loss_fn(feats(o), ft, feats.fine)
            tot = tot + w * l
        tot = tot / sum(wts)
        if not torch.isfinite(tot):
            print("non-finite loss at step", it, "- back to the best parameters")
            if best[1] is not None:
                for q, b in zip(model.params, best[1]):
                    q.data.copy_(b)
            opt.zero_grad()
            continue
        opt.zero_grad()
        tot.backward()
        torch.nn.utils.clip_grad_norm_(model.params, 5.0)
        opt.step()
        sch.step()
        with torch.no_grad():
            model.logtau.clamp_(math.log(0.03), math.log(8.0))
            model.bed_tau.clamp_(math.log(0.03), math.log(8.0))
            model.logf.clamp_(math.log(40.0), math.log(14000.0))
        v = float(tot)
        ema = v if ema is None else 0.97 * ema + 0.03 * v
        if it > 100 and ema < best[0]:
            best = (ema, [q.detach().clone() for q in model.params])
        if it % 50 == 0 or it == steps - 1:
            log("step %4d  loss %.3f (ema %.3f)  ltas %.2f mlog %.2f bands %.2f env %.2f  %.0fs" % (it, v, ema, parts[0], parts[1], parts[2], parts[3], time.time() - t0))
    if best[1] is not None:
        for q, b in zip(model.params, best[1]):
            q.data.copy_(b)
        log("restored the best parameters (ema loss %.3f)" % best[0])
    return model


def evaluate(model, target_seg, irs, sched, dev, seeds=3):
    """Mean loss parts over every recorded schedule, at the model's current parameters."""
    torch = torch_mod()
    feats = Feats(torch, dev)
    N = len(target_seg)
    tgt = torch.tensor(target_seg, dtype=torch.float32, device=dev)
    ft = feats(tgt)
    irs_t = [torch.tensor(i, dtype=torch.float32, device=dev) for i, _ in irs]
    rng = np.random.RandomState(99)
    acc = []
    with torch.no_grad():
        for run in sched:
            for _ in range(seeds):
                outs = render_scenario(model, [(e[0], e[1], e[2], e[3]) for e in run], irs_t, N, rng)
                for o in outs:
                    acc.append(loss_fn(feats(o), ft, feats.fine)[1])
    a = np.array(acc)
    return a.mean(0), a.std(0)


def load_irs(path, scenes):
    z = np.load(path)
    out = []
    for name, w in scenes:
        h = z[name]
        h = h.mean(0)
        out.append((np.ascontiguousarray(h[:int(2.0 * FS)]).astype(np.float32), w))
    return out


def selftest():
    torch = torch_mod()
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    p = json.load(open(os.path.join(HERE, "params.json")))
    m = Model(p, dev)
    worst = 0
    for tier, var, pitch in (("hard", 1, 1.0), ("medium", 3, 1.017), ("soft", 4, 0.983)):
        N = int(1.0 * FS)
        a = gen.render(p, tier, var, FS, length=1.0, pitch=pitch)
        # gen applies a tail fade and master gain; compare the part before the fade
        a_cut = a[:int(0.8 * FS)] / p["master_gain"]
        b = m.event(tier, var, pitch, N)[:int(0.8 * FS)].detach().cpu().numpy()
        err = np.abs(a_cut - b).max() / (np.abs(a_cut).max() + 1e-12)
        worst = max(worst, err)
        print("selftest render %s_%d pitch %.3f: max rel error %.2e" % (tier, var, pitch, err))
    ok1 = worst < 2e-3
    print("numpy == torch:", "PASS" if ok1 else "FAIL")
    return ok1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target")
    ap.add_argument("--ir")
    ap.add_argument("--params", default=os.path.join(HERE, "params.json"))
    ap.add_argument("--out", default=None)
    ap.add_argument("--steps", type=int, default=2500)
    ap.add_argument("--init", action="store_true")
    ap.add_argument("--modes", type=int, default=96)
    ap.add_argument("--lr", type=float, default=1.0)
    ap.add_argument("--scenes", default="room:1,open:1,big:0.5")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--diag-dir", default=None, help="writes the fitted stack mixes through each scene (WAV) here")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(0 if selftest() else 1)
    torch = torch_mod()
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    seg = load_target(a.target)
    p = init_params(seg, a.modes) if a.init else json.load(open(a.params))
    if a.diag_dir:
        os.makedirs(a.diag_dir, exist_ok=True)
    irs = load_irs(a.ir, [(s.split(":")[0], float(s.split(":")[1])) for s in a.scenes.split(",")])
    sched = json.load(open(os.path.join(HERE, "schedules.json")))["runs"]
    model = run_fit(p, seg, irs, sched, a.steps, a.lr, dev, print)
    mean, std = evaluate(model, seg, irs, sched, dev)
    print("final loss parts ltas / mlog / bands (mean over schedules x pitch draws): ", np.round(mean, 2), "+-", np.round(std, 2))
    if a.diag_dir:
        with torch.no_grad():
            rng = np.random.RandomState(3)
            irs_t = [torch.tensor(i, dtype=torch.float32, device=dev) for i, _ in irs]
            for k in range(min(3, len(sched))):
                outs = render_scenario(model, [(e[0], e[1], e[2], e[3]) for e in sched[k]], irs_t, len(seg), rng)
                for j, o in enumerate(outs):
                    sf.write(os.path.join(a.diag_dir, "run%d_scene%d.wav" % (k, j)), o.cpu().numpy() / max(1e-9, float(o.abs().max())) * 0.5, FS, subtype="PCM_16")
    out = a.out or a.params
    json.dump(model.to_params(), open(out, "w"), indent=1)
    print("wrote", out)


if __name__ == "__main__":
    main()
