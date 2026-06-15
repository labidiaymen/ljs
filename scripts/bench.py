#!/usr/bin/env python3
"""ljs-vs-Node benchmark runner (constitution v1.1.0, Principle IV: performance measured
from day one). Times each bench/cases/*.js on ljs and Node, reports the ljs-vs-Node ratio,
and gates on ljs-vs-*self* regression against bench/baseline.json. Node is optional.

Exit codes: 0 = ok, 1 = ljs perf regression vs baseline, 2 = setup error.
Invoked by `zig build bench` (which builds ljs first). See contracts/cli.md.
"""
import argparse
import glob
import json
import os
import shutil
import statistics
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def measure(cmd, reps, warmup):
    for _ in range(warmup):
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    samples = []
    for _ in range(reps):
        t = time.perf_counter()
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        samples.append((time.perf_counter() - t) * 1000.0)
    return min(samples), statistics.median(samples)


def main():
    ap = argparse.ArgumentParser(description="Benchmark ljs against Node.js.")
    ap.add_argument("--reps", type=int, default=15)
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--tolerance", type=float, default=15.0, help="ljs-vs-self regression band (%%)")
    ap.add_argument("--node", default="node")
    ap.add_argument("--baseline", default=os.path.join(ROOT, "bench", "baseline.json"))
    ap.add_argument("--cases-dir", default=os.path.join(ROOT, "bench", "cases"))
    ap.add_argument("--update-baseline", action="store_true")
    args = ap.parse_args()

    ljs = os.path.join(ROOT, "zig-out", "bin", "ljs")
    if not os.path.exists(ljs):
        print(f"setup error: ljs binary not found at {ljs} (run `zig build`)", file=sys.stderr)
        return 2
    cases = sorted(glob.glob(os.path.join(args.cases_dir, "*.js")))
    if not cases:
        print(f"setup error: no benchmark cases in {args.cases_dir}", file=sys.stderr)
        return 2

    node = shutil.which(args.node)
    baseline = {}
    if os.path.exists(args.baseline):
        try:
            baseline = json.load(open(args.baseline)).get("cases", {})
        except Exception:
            baseline = {}

    print(f"Benchmark (reps={args.reps}, warmup={args.warmup}, tolerance=±{args.tolerance:.0f}%)")
    print(f"  node: {node or 'NOT FOUND — ljs-only run'}")
    print(f"  {'case':<16}{'ljs ms(min/med)':>18}{'node ms(min/med)':>18}{'ratio':>9}{'vs base':>10}  status")

    results, regressed = {}, []
    for c in cases:
        name = os.path.basename(c)
        lmin, lmed = measure([ljs, "run", c], args.reps, args.warmup)
        results[name] = {"ljs_ms_median": round(lmed, 3), "ljs_ms_min": round(lmin, 3)}
        if node:
            nmin, nmed = measure([node, c], args.reps, args.warmup)
            nstr = f"{nmin:.1f}/{nmed:.1f}"
            ratio = f"{lmed / nmed:.1f}x" if nmed > 0 else "n/a"
        else:
            nstr, ratio = "n/a", "n/a"

        base = baseline.get(name, {}).get("ljs_ms_median")
        status, vsbase = "ok", "-"
        if base:
            delta = (lmed - base) / base * 100.0
            vsbase = f"{delta:+.1f}%"
            if delta > args.tolerance:
                status = "REGRESSION"
                regressed.append(name)
        print(f"  {name:<16}{f'{lmin:.1f}/{lmed:.1f}':>18}{nstr:>18}{ratio:>9}{vsbase:>10}  {status}")

    if args.update_baseline:
        os.makedirs(os.path.dirname(args.baseline), exist_ok=True)
        with open(args.baseline, "w") as f:
            json.dump({"tolerance_pct": args.tolerance, "cases": results}, f, indent=2)
            f.write("\n")
        print(f"\n  baseline written: {os.path.relpath(args.baseline, ROOT)}")
        return 0

    if regressed:
        print(f"\n  PERF REGRESSION vs baseline: {', '.join(regressed)}", file=sys.stderr)
        return 1
    print("\n  perf: ok (no ljs-vs-self regression)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
