#!/usr/bin/env python3
"""Audit pass 4 of 4 (final): verify tab3_Results.md against CSV output
files. Covers Phase 1 baseline, Phase 1 net profit, and the sensitivity
sweep's per-season grain and spray-count std tables."""
import pandas as pd

GRAIN_PRICE = 3000.0
ROOT = "C:/Users/maryz/Desktop/ACROSS/pest-management/Pest-Management-Module/models"
ARCH = f"{ROOT}/07052026"

discrepancies = []

def check(label, reported, computed, tol=0.02, is_int=False):
    if is_int:
        ok = abs(reported - computed) < 0.5
    elif abs(computed) < 1e-6:
        ok = abs(reported) < tol
    else:
        ok = abs(reported - computed) / max(abs(computed), 1e-6) < tol
    status = "OK" if ok else "MISMATCH"
    if not ok:
        discrepancies.append(f"  [{label}] reported={reported}, computed={computed}, diff={abs(reported-computed):.4f}")
    print(f"  {status}: {label} reported={reported} computed={computed:.4f}")
    return ok

# ============================================================
# Phase 1 baseline (lines 10-20): from harvest_output.csv (non-grid)
# ============================================================
print("=" * 80)
print("PHASE 1 BASELINE (lines 10-20)")
print("=" * 80)

df_base = pd.read_csv(f"{ARCH}/harvest_output.csv")
agg = df_base.groupby(["strategy", "season"]).agg(
    grain_mean=("grain_tha", "mean"),
    grain_std=("grain_tha", "std"),
    spray_mean=("spray_count", "mean"),
    spray_std=("spray_count", "std"),
).reset_index()

reported_base = {
    ("none", 1): (2.303, 0.043, 0.00, 0.00),
    ("none", 2): (2.304, 0.041, 0.00, 0.00),
    ("none", 3): (2.314, 0.037, 0.00, 0.00),
    ("calendar", 1): (3.323, 0.048, 5.00, 0.00),
    ("calendar", 2): (3.338, 0.062, 5.00, 0.00),
    ("calendar", 3): (3.329, 0.054, 5.00, 0.00),
    ("threshold", 1): (3.586, 0.011, 7.83, 0.59),
    ("threshold", 2): (3.585, 0.010, 7.83, 0.59),
    ("threshold", 3): (3.587, 0.009, 7.88, 0.64),
}

for _, r in agg.iterrows():
    key = (r["strategy"], int(r["season"]))
    if key in reported_base:
        rg, rs, sg, ss = reported_base[key]
        check(f"Phase1 {key[0]} S{key[1]} grain", rg, r["grain_mean"], tol=0.005)
        check(f"Phase1 {key[0]} S{key[1]} spray", sg, r["spray_mean"], tol=0.05)

# ============================================================
# Phase 1 net profit (lines 36-46)
# ============================================================
print("\n" + "=" * 80)
print("PHASE 1 NET PROFIT (lines 36-46)")
print("=" * 80)

df_base["profit"] = df_base["grain_tha"] * GRAIN_PRICE - df_base["spray_count"] * df_base["cost_per_spray"]
profit_agg = df_base.groupby(["strategy", "season"]).agg(
    profit_mean=("profit", "mean"),
    profit_std=("profit", "std"),
).reset_index()

reported_profit = {
    ("none", 1): 6908.6, ("none", 2): 6910.7, ("none", 3): 6941.3,
    ("calendar", 1): 9968.3, ("calendar", 2): 10014.3, ("calendar", 3): 9987.9,
    ("threshold", 1): 10024.0, ("threshold", 2): 10022.6, ("threshold", 3): 10024.3,
}

for _, r in profit_agg.iterrows():
    key = (r["strategy"], int(r["season"]))
    if key in reported_profit:
        check(f"Profit {key[0]} S{key[1]}", reported_profit[key], r["profit_mean"], tol=0.5)

# ============================================================
# Sensitivity sweep per-season grain (lines 168-172)
# ============================================================
print("\n" + "=" * 80)
print("SENSITIVITY SWEEP PER-SEASON GRAIN (lines 168-172)")
print("=" * 80)

sweep_files = {
    "eff60": (f"{ARCH}/sensitivity_output_starfarm_eff60_inc3_cost100.csv", "efficacy=0.6"),
    "eff90": (f"{ARCH}/sensitivity_output_starfarm_eff90_inc3_cost100.csv", "efficacy=0.9"),
    "inc05": (f"{ARCH}/sensitivity_output_starfarm_eff80_inc5_cost100.csv", "increment=0.05"),
    "inc10": (f"{ARCH}/sensitivity_output_starfarm_eff80_inc10_cost100.csv", "increment=0.10"),
}

reported_sweep_grain = {
    # efficacy=0.6
    ("eff60", "none", 1): 2.307, ("eff60", "none", 2): 2.299, ("eff60", "none", 3): 2.311,
    ("eff60", "calendar", 1): 2.956, ("eff60", "calendar", 2): 2.965, ("eff60", "calendar", 3): 2.969,
    ("eff60", "threshold", 1): 3.455, ("eff60", "threshold", 2): 3.461, ("eff60", "threshold", 3): 3.456,
    # efficacy=0.9
    ("eff90", "none", 1): 2.305, ("eff90", "none", 2): 2.302, ("eff90", "none", 3): 2.304,
    ("eff90", "calendar", 1): 3.450, ("eff90", "calendar", 2): 3.452, ("eff90", "calendar", 3): 3.458,
    ("eff90", "threshold", 1): 3.621, ("eff90", "threshold", 2): 3.620, ("eff90", "threshold", 3): 3.623,
    # increment=0.05
    ("inc05", "none", 1): 2.190, ("inc05", "none", 2): 2.180, ("inc05", "none", 3): 2.192,
    ("inc05", "calendar", 1): 2.901, ("inc05", "calendar", 2): 2.880, ("inc05", "calendar", 3): 2.892,
    ("inc05", "threshold", 1): 3.449, ("inc05", "threshold", 2): 3.440, ("inc05", "threshold", 3): 3.440,
    # increment=0.10
    ("inc10", "none", 1): 2.081, ("inc10", "none", 2): 2.082, ("inc10", "none", 3): 2.086,
    ("inc10", "calendar", 1): 2.447, ("inc10", "calendar", 2): 2.460, ("inc10", "calendar", 3): 2.449,
    ("inc10", "threshold", 1): 2.902, ("inc10", "threshold", 2): 2.904, ("inc10", "threshold", 3): 2.907,
}

for sweep_key, (fpath, label) in sweep_files.items():
    df = pd.read_csv(fpath)
    agg = df.groupby(["strategy", "season"]).agg(
        grain_mean=("grain_tha", "mean"),
    ).reset_index()
    print(f"\n{label}:")
    for _, r in agg.iterrows():
        key = (sweep_key, r["strategy"], int(r["season"]))
        if key in reported_sweep_grain:
            check(f"{label} {r['strategy']} S{int(r['season'])}", reported_sweep_grain[key], r["grain_mean"], tol=0.005)

# ============================================================
# Sensitivity sweep spray std (lines 234-237)
# ============================================================
print("\n" + "=" * 80)
print("SENSITIVITY SWEEP SPRAY STD (lines 234-237)")
print("=" * 80)

reported_spray_std = {
    ("eff60", "threshold"): (9.51, 0.55),
    ("eff90", "threshold"): (6.96, 0.51),
    ("inc05", "threshold"): (9.91, 0.29),
    ("inc10", "threshold"): (10.00, 0.00),
}

for sweep_key, (fpath, label) in sweep_files.items():
    df = pd.read_csv(fpath)
    thr = df[df["strategy"] == "threshold"]
    avg_spray = thr["spray_count"].mean()
    avg_std = thr.groupby("season")["spray_count"].std().mean()
    print(f"\n{label}:")
    if (sweep_key, "threshold") in reported_spray_std:
        rm, rs = reported_spray_std[(sweep_key, "threshold")]
        check(f"{label} avg spray", rm, avg_spray, tol=0.05)
        check(f"{label} avg std", rs, avg_std, tol=0.05)

# ============================================================
# 3-COMPOUND: Default compound check
# ============================================================
print("\n" + "=" * 80)
print("3-COMPOUND DEFAULT (lines 493-500)")
print("=" * 80)

df_d = pd.read_csv(f"{ROOT}/harvest_grid_output.csv")
df_d["profit"] = df_d["grain_tha"] * GRAIN_PRICE - df_d["spray_count"] * df_d["cost_per_spray"]
d_agg = df_d.groupby(["strategy", "season"]).agg(
    profit=("profit", "mean"),
).reset_index()

reported_3c = {
    ("calendar", 1): 9379.2, ("calendar", 2): 8886.3, ("calendar", 3): 7740.7,
    ("threshold", 1): 9728.8, ("threshold", 2): 8663.0, ("threshold", 3): 6387.2,
    ("none", 1): 6942.6, ("none", 2): 6947.0, ("none", 3): 6942.7,
}

for _, r in d_agg.iterrows():
    key = (r["strategy"], int(r["season"]))
    if key in reported_3c:
        check(f"3C Default {key[0]} S{key[1]}", reported_3c[key], r["profit"], tol=50)

# ============================================================
# FINAL SUMMARY
# ============================================================
print("\n" + "=" * 80)
print("FINAL SUMMARY OF ALL REMAINING CHECKS")
print("=" * 80)
if discrepancies:
    print(f"\nFOUND {len(discrepancies)} DISCREPANCIES:")
    for d in discrepancies:
        print(d)
else:
    print("\nAll checks passed within tolerance.")
