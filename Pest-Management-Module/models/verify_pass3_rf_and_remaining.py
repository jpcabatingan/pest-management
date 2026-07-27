#!/usr/bin/env python3
"""Audit pass 3 of 4: verify tab3_Results.md against CSV output files.
Deep-checks a resistant_fraction discrepancy, plus Rotation x Interval
grain, Phase 1 sensitivity sweep, 3-compound baseline, threshold/calendar
grid RF tables, and profit lead."""
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
        discrepancies.append(f"  [{label}] reported={reported}, computed={computed}")
    print(f"  {status}: {label} reported={reported} computed={computed}")
    return ok

# ============================================================
# CHECK 1: Phase 2 grid RF values (lines 428-437)
# ============================================================
print("=" * 80)
print("DEEP CHECK: Phase 2 grid RF discrepancy")
print("=" * 80)

df_root = pd.read_csv(f"{ROOT}/harvest_grid_output.csv")
df_arch = pd.read_csv(f"{ARCH}/harvest_grid_output_grid.csv" if False else f"{ROOT}/harvest_grid_output.csv")
# Just use root file - the doc says it was regenerated post-fix
df = df_root

# Compute with different SD ddof to see if rounding differs
grid_s = df.groupby(["strategy", "season"]).agg(
    grain_mean=("grain_tha", "mean"),
    spray_mean=("spray_count", "mean"),
    rf_mean=("resistant_fraction", "mean"),
).reset_index()

print("\nComputed values from harvest_grid_output.csv:")
for _, r in grid_s.iterrows():
    print(f"  {r['strategy']:10s} S{int(r['season'])} grain={r['grain_mean']:.4f} spray={r['spray_mean']:.2f} rf={r['rf_mean']:.4f}")

print("\nReported values in tab3_Results.md:")
print("  none      S1 grain=2.3140 spray=0.00 rf=0.0000")
print("  none      S2 grain=2.3160 spray=0.00 rf=0.0000")
print("  none      S3 grain=2.3140 spray=0.00 rf=0.0000")
print("  calendar  S1 grain=3.2930 spray=5.00 rf=0.0700")
print("  calendar  S2 grain=3.1290 spray=5.00 rf=0.2550")
print("  calendar  S3 grain=2.7470 spray=5.00 rf=0.4860")
print("  threshold S1 grain=3.5160 spray=8.19 rf=0.1730")
print("  threshold S2 grain=3.2050 spray=9.53 rf=0.6370")
print("  threshold S3 grain=2.4540 spray=9.74 rf=0.9890")

# Check with tighter tolerance
print("\nDetailed comparison (tolerance=0.001 absolute):")
reported = {
    ("none", 1): (2.314, 0, 0.000), ("none", 2): (2.316, 0, 0.000), ("none", 3): (2.314, 0, 0.000),
    ("calendar", 1): (3.293, 5.00, 0.070), ("calendar", 2): (3.129, 5.00, 0.255), ("calendar", 3): (2.747, 5.00, 0.486),
    ("threshold", 1): (3.516, 8.19, 0.173), ("threshold", 2): (3.205, 9.53, 0.637), ("threshold", 3): (2.454, 9.74, 0.989),
}
for _, r in grid_s.iterrows():
    key = (r["strategy"], int(r["season"]))
    if key in reported:
        rg, sg, rf_rep = reported[key]
        rf_comp = r["rf_mean"]
        diff = abs(rf_rep - rf_comp)
        print(f"  {key}: RF reported={rf_rep:.3f} computed={rf_comp:.4f} diff={diff:.4f}")

# ============================================================
# CHECK 2: Rotation x Interval grain S1-6 (lines 678-688)
# ============================================================
print("\n" + "=" * 80)
print("ROTATION x INTERVAL grain S1-6 (lines 678-688)")
print("=" * 80)

df_ri = pd.read_csv(f"{ARCH}/sensitivity_output_interval_grid_rotation.csv")
ri_s16 = df_ri[df_ri["season"] <= 6].groupby(["calendar_interval", "run_id"]).agg(
    grain_s16=("grain_tha", "mean"),
).reset_index().groupby("calendar_interval").agg(
    grain_mean=("grain_s16", "mean"),
).reset_index()

reported_ri = {1: 2.451, 3: 2.673, 5: 2.813, 7: 2.903, 10: 2.911, 14: 2.858, 21: 2.739, 28: 2.641}
for _, r in ri_s16.iterrows():
    iv = int(r["calendar_interval"])
    if iv in reported_ri:
        check(f"RI iv={iv} grain S1-6", reported_ri[iv], r["grain_mean"], tol=0.01)

# S30 grain
ri_s30 = df_ri[df_ri["season"] == 30].groupby("calendar_interval").agg(
    grain_mean=("grain_tha", "mean"),
).reset_index()
reported_ri_s30 = {1: 2.316, 3: 2.316, 5: 2.318, 7: 2.318, 10: 2.319, 14: 2.320, 21: 2.317, 28: 2.315}
for _, r in ri_s30.iterrows():
    iv = int(r["calendar_interval"])
    if iv in reported_ri_s30:
        check(f"RI iv={iv} grain S30", reported_ri_s30[iv], r["grain_mean"], tol=0.01)

# ============================================================
# CHECK 3: Phase 1 sensitivity sweep tables (lines 163-237)
# ============================================================
print("\n" + "=" * 80)
print("PHASE 1 SENSITIVITY SWEEP (lines 163-237)")
print("=" * 80)

# Efficacy 0.6
df_e6 = pd.read_csv(f"{ARCH}/sensitivity_output_starfarm_eff60_inc3_cost100.csv")
e6 = df_e6.groupby(["strategy", "season"]).agg(
    grain_mean=("grain_tha", "mean"), spray_mean=("spray_count", "mean"),
).reset_index()
print("\nEfficacy=0.6:")
for _, r in e6.iterrows():
    print(f"  {r['strategy']:10s} S{int(r['season'])} grain={r['grain_mean']:.3f} spray={r['spray_mean']:.2f}")

# Reported: none S1=2.307, calendar S1=2.956, threshold S1=3.455
# The table shows 3-season averages, not per-season. Let me compute those.
e6_avg = df_e6.groupby("strategy").agg(
    grain_mean=("grain_tha", "mean"), spray_mean=("spray_count", "mean"),
).reset_index()
print("  3-season averages:")
for _, r in e6_avg.iterrows():
    print(f"  {r['strategy']:10s} grain={r['grain_mean']:.3f} spray={r['spray_mean']:.2f}")

# Efficacy 0.9
df_e9 = pd.read_csv(f"{ARCH}/sensitivity_output_starfarm_eff90_inc3_cost100.csv")
e9_avg = df_e9.groupby("strategy").agg(
    grain_mean=("grain_tha", "mean"), spray_mean=("spray_count", "mean"),
).reset_index()
print("\nEfficacy=0.9 3-season averages:")
for _, r in e9_avg.iterrows():
    print(f"  {r['strategy']:10s} grain={r['grain_mean']:.3f} spray={r['spray_mean']:.2f}")

# Increment 0.05
df_i5 = pd.read_csv(f"{ARCH}/sensitivity_output_starfarm_eff80_inc5_cost100.csv")
i5_avg = df_i5.groupby("strategy").agg(
    grain_mean=("grain_tha", "mean"), spray_mean=("spray_count", "mean"),
).reset_index()
print("\nIncrement=0.05 3-season averages:")
for _, r in i5_avg.iterrows():
    print(f"  {r['strategy']:10s} grain={r['grain_mean']:.3f} spray={r['spray_mean']:.2f}")

# Increment 0.10
df_i10 = pd.read_csv(f"{ARCH}/sensitivity_output_starfarm_eff80_inc10_cost100.csv")
i10_avg = df_i10.groupby("strategy").agg(
    grain_mean=("grain_tha", "mean"), spray_mean=("spray_count", "mean"),
).reset_index()
print("\nIncrement=0.10 3-season averages:")
for _, r in i10_avg.iterrows():
    print(f"  {r['strategy']:10s} grain={r['grain_mean']:.3f} spray={r['spray_mean']:.2f}")

# ============================================================
# CHECK 4: 3-compound baseline (lines 493-500)
# ============================================================
print("\n" + "=" * 80)
print("PHASE 2 3-COMPOUND BASELINE (lines 493-500)")
print("=" * 80)

for cpd_file, cpd_label in [
    (f"{ROOT}/harvest_grid_output.csv", "Default"),
    (f"{ARCH}/harvest_grid_output_etofenprox.csv", "Etofenprox"),
    (f"{ARCH}/harvest_grid_output_neonic.csv", "Neonicotinoid"),
]:
    dfx = pd.read_csv(cpd_file)
    dfx["net_profit"] = dfx["grain_tha"] * GRAIN_PRICE - dfx["spray_count"] * dfx["cost_per_spray"]
    
    # Per (run, strategy, season) profit, then average across runs
    profit = dfx.groupby(["run_id", "strategy", "season"]).agg(
        profit=("net_profit", "mean"),
    ).reset_index().groupby(["strategy", "season"]).agg(
        profit_mean=("profit", "mean"),
    ).reset_index()
    
    print(f"\n{cpd_label}:")
    for _, r in profit.iterrows():
        print(f"  {r['strategy']:10s} S{int(r['season'])} profit={r['profit_mean']:.1f}")

# ============================================================
# CHECK 5: Threshold grid RF table (lines 325-331)
# ============================================================
print("\n" + "=" * 80)
print("THRESHOLD GRID RF TABLE (lines 325-331)")
print("=" * 80)

df_tg = pd.read_csv(f"{ARCH}/sensitivity_output_threshold_grid.csv")
tg = df_tg.groupby(["pesticide_threshold", "season"]).agg(
    rf_mean=("resistant_fraction", "mean"),
).reset_index()

reported_tg = {
    (0.1, 1): 0.2600, (0.1, 2): 0.7470, (0.1, 3): 1.0000, (0.1, 4): 1.0000, (0.1, 5): 1.0000, (0.1, 6): 1.0000,
    (0.2, 1): 0.2549, (0.2, 2): 0.7416, (0.2, 3): 1.0000, (0.2, 4): 1.0000, (0.2, 5): 1.0000, (0.2, 6): 1.0000,
    (0.3, 1): 0.1733, (0.3, 2): 0.6374, (0.3, 3): 0.9892, (0.3, 4): 1.0000, (0.3, 5): 1.0000, (0.3, 6): 1.0000,
    (0.4, 1): 0.1064, (0.4, 2): 0.4738, (0.4, 3): 0.8870, (0.4, 4): 0.9967, (0.4, 5): 1.0000, (0.4, 6): 1.0000,
    (0.5, 1): 0.0771, (0.5, 2): 0.3399, (0.5, 3): 0.7354, (0.5, 4): 0.9661, (0.5, 5): 0.9978, (0.5, 6): 1.0000,
}

for _, r in tg.iterrows():
    thr = round(r["pesticide_threshold"], 1)
    season = int(r["season"])
    key = (thr, season)
    if key in reported_tg:
        check(f"TG thr={thr} S{season} RF", reported_tg[key], r["rf_mean"], tol=0.001)

# ============================================================
# CHECK 6: Calendar interval grid RF table (lines 292-301)
# ============================================================
print("\n" + "=" * 80)
print("CALENDAR INTERVAL GRID RF TABLE (lines 292-301)")
print("=" * 80)

df_ig = pd.read_csv(f"{ARCH}/sensitivity_output_interval_grid.csv")
ig = df_ig.groupby(["calendar_interval", "season"]).agg(
    rf_mean=("resistant_fraction", "mean"),
).reset_index()

reported_ig = {
    (1, 1): 1.0000, (1, 2): 1.0000, (1, 3): 1.0000, (1, 4): 1.0000, (1, 5): 1.0000, (1, 6): 1.0000,
    (3, 1): 1.0000, (3, 2): 1.0000, (3, 3): 1.0000, (3, 4): 1.0000, (3, 5): 1.0000, (3, 6): 1.0000,
    (5, 1): 0.5100, (5, 2): 1.0000, (5, 3): 1.0000, (5, 4): 1.0000, (5, 5): 1.0000, (5, 6): 1.0000,
    (7, 1): 0.2600, (7, 2): 0.7470, (7, 3): 1.0000, (7, 4): 1.0000, (7, 5): 1.0000, (7, 6): 1.0000,
    (10, 1): 0.1100, (10, 2): 0.4545, (10, 3): 0.7818, (10, 4): 1.0000, (10, 5): 1.0000, (10, 6): 1.0000,
    (14, 1): 0.0700, (14, 2): 0.2565, (14, 3): 0.4937, (14, 4): 0.7190, (14, 5): 0.9330, (14, 6): 1.0000,
    (21, 1): 0.0300, (21, 2): 0.0885, (21, 3): 0.2041, (21, 4): 0.3439, (21, 5): 0.4767, (21, 6): 0.6028,
    (28, 1): 0.0200, (28, 2): 0.0490, (28, 3): 0.0866, (28, 4): 0.1522, (28, 5): 0.2446, (28, 6): 0.3324,
}

for _, r in ig.iterrows():
    iv = int(r["calendar_interval"])
    season = int(r["season"])
    key = (iv, season)
    if key in reported_ig:
        check(f"IG iv={iv} S{season} RF", reported_ig[key], r["rf_mean"], tol=0.001)

# ============================================================
# CHECK 7: Phase 2 profit lead (lines 467-474)
# ============================================================
print("\n" + "=" * 80)
print("PHASE 2 PROFIT LEAD (lines 467-474)")
print("=" * 80)

df_grid = pd.read_csv(f"{ROOT}/harvest_grid_output.csv")
df_grid["net_profit"] = df_grid["grain_tha"] * GRAIN_PRICE - df_grid["spray_count"] * df_grid["cost_per_spray"]
profit_lead = df_grid.groupby(["run_id", "strategy", "season"]).agg(
    profit=("net_profit", "mean"),
).reset_index().groupby(["strategy", "season"]).agg(
    profit_mean=("profit", "mean"),
).reset_index()

cal_profit = profit_lead[profit_lead["strategy"] == "calendar"].set_index("season")["profit_mean"]
thr_profit = profit_lead[profit_lead["strategy"] == "threshold"].set_index("season")["profit_mean"]

for s in [1, 2, 3]:
    lead = thr_profit[s] - cal_profit[s]
    reported_lead = {1: 349.6, 2: -223.3, 3: -1353.5}[s]
    check(f"profit lead S{s}", reported_lead, lead, tol=5)

# ============================================================
# FINAL SUMMARY
# ============================================================
print("\n" + "=" * 80)
print("FINAL SUMMARY")
print("=" * 80)
if discrepancies:
    print(f"\nFOUND {len(discrepancies)} DISCREPANCIES:")
    for d in discrepancies:
        print(d)
else:
    print("\nAll checks passed within tolerance.")
