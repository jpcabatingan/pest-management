#!/usr/bin/env python3
"""Investigate 3-compound profit discrepancies and sensitivity spray counts."""
import pandas as pd

GRAIN_PRICE = 3000.0
ROOT = "C:/Users/maryz/Desktop/ACROSS/pest-management/Pest-Management-Module/models"
ARCH = f"{ROOT}/07052026"

# ============================================================
# CHECK A: cost_per_spray in each 3-compound file
# ============================================================
print("=" * 80)
print("3-COMPOUND: cost_per_spray per file")
print("=" * 80)

for f, label in [
    (f"{ROOT}/harvest_grid_output.csv", "Default"),
    (f"{ARCH}/harvest_grid_output_etofenprox.csv", "Etofenprox"),
    (f"{ARCH}/harvest_grid_output_neonic.csv", "Neonicotinoid"),
]:
    df = pd.read_csv(f)
    costs = sorted(df.groupby("run_id")["cost_per_spray"].first().unique())
    seasons = sorted(df["season"].unique())
    strats = df["strategy"].unique()
    print(f"  {label}: cost_per_spray={costs}, seasons={seasons}, strategies={strats}")

# ============================================================
# CHECK B: 3-compound baseline - per-season profit comparison
# Method 1: average of per-plot profits
# Method 2: mean_grain * 3000 - mean_spray * cost (then average across runs)
# ============================================================
print("\n" + "=" * 80)
print("3-COMPOUND: Method 1 (mean of per-plot profits) vs Method 2")
print("=" * 80)

for f, label in [
    (f"{ROOT}/harvest_grid_output.csv", "Default"),
    (f"{ARCH}/harvest_grid_output_etofenprox.csv", "Etofenprox"),
    (f"{ARCH}/harvest_grid_output_neonic.csv", "Neonicotinoid"),
]:
    df = pd.read_csv(f)
    
    # Method 1: per-plot profit, averaged across plots per run, then averaged across runs
    df["profit_per_plot"] = df["grain_tha"] * GRAIN_PRICE - df["spray_count"] * df["cost_per_spray"]
    m1 = df.groupby(["strategy", "season", "run_id"]).agg(
        profit=("profit_per_plot", "mean"),
    ).reset_index().groupby(["strategy", "season"]).agg(
        profit_mean=("profit", "mean"),
    ).reset_index()
    
    # Method 2: use column means directly
    m2 = df.groupby(["strategy", "season", "run_id"]).agg(
        grain=("grain_tha", "mean"), spray=("spray_count", "mean"), cost=("cost_per_spray", "first"),
    ).reset_index()
    m2["profit"] = m2["grain"] * GRAIN_PRICE - m2["spray"] * m2["cost"]
    m2 = m2.groupby(["strategy", "season"]).agg(profit_mean=("profit", "mean")).reset_index()
    
    print(f"\n{label}:")
    for (_, r1), (_, r2) in zip(m1.iterrows(), m2.iterrows()):
        s = r1["strategy"]
        season = int(r1["season"])
        v1, v2 = r1["profit_mean"], r2["profit_mean"]
        print(f"  {s:10s} S{season} method1={v1:.1f}  method2={v2:.1f}  diff={abs(v1-v2):.1f}")

# ============================================================
# CHECK C: Sensitivity sweep spray counts (threshold strategy)
# ============================================================
print("\n" + "=" * 80)
print("SENSITIVITY SWEEP: Threshold spray count per scenario")
print("=" * 80)

for f, label in [
    (f"{ARCH}/sensitivity_output_starfarm_eff60_inc3_cost100.csv", "efficacy=0.6"),
    (f"{ARCH}/sensitivity_output_starfarm_eff90_inc3_cost100.csv", "efficacy=0.9"),
    (f"{ARCH}/sensitivity_output_starfarm_eff80_inc5_cost100.csv", "increment=0.05"),
    (f"{ARCH}/sensitivity_output_starfarm_eff80_inc10_cost100.csv", "increment=0.10"),
]:
    df = pd.read_csv(f)
    thr = df[df["strategy"] == "threshold"]
    agg = thr.groupby("season").agg(
        spray_mean=("spray_count", "mean"),
        spray_std=("spray_count", "std"),
    ).reset_index()
    
    print(f"\n{label}:")
    for _, r in agg.iterrows():
        print(f"  S{int(r['season'])} spray={r['spray_mean']:.2f} +/- {r['spray_std']:.2f}")

# ============================================================
# CHECK D: Threshold grid RF - exact comparison with tighter check
# ============================================================
print("\n" + "=" * 80)
print("THRESHOLD GRID: RF comparison (4-digit precision)")
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
        rep = reported_tg[key]
        comp = r["rf_mean"]
        diff = abs(rep - comp)
        # Check if the reported value could be from a DIFFERENT snapshot
        print(f"  thr={thr} S{season}: reported={rep:.4f} computed={comp:.6f} diff={diff:.6f}")

# ============================================================
# CHECK E: Compare root harvest_grid_output vs 07052026 snapshot
# ============================================================
print("\n" + "=" * 80)
print("FILE COMPARISON: root vs 07052026 snapshot")
print("=" * 80)

df_root = pd.read_csv(f"{ROOT}/harvest_grid_output.csv")

# Find the snapshot file - it might be named differently
import os
arch_files = [f for f in os.listdir(ARCH) if "harvest_grid" in f and f.endswith(".csv")]
print(f"  Snapshot files: {arch_files}")
for af in arch_files:
    df_snap = pd.read_csv(f"{ARCH}/{af}")
    # Compare key stats
    root_means = df_root.groupby(["strategy","season"]).agg(
        grain=("grain_tha","mean"), spray=("spray_count","mean"), rf=("resistant_fraction","mean"),
    ).reset_index()
    snap_means = df_snap.groupby(["strategy","season"]).agg(
        grain=("grain_tha","mean"), spray=("spray_count","mean"), rf=("resistant_fraction","mean"),
    ).reset_index()
    
    print(f"\n  Comparing root vs {af}:")
    for (_, r1), (_, r2) in zip(root_means.iterrows(), snap_means.iterrows()):
        g_diff = abs(r1["grain"] - r2["grain"])
        s_diff = abs(r1["spray"] - r2["spray"])
        rf_diff = abs(r1["rf"] - r2["rf"])
        match = "OK" if g_diff < 0.001 and s_diff < 0.01 and rf_diff < 0.001 else "DIFFER"
        print(f"    {r1['strategy']:10s} S{int(r1['season'])} {match}: grain={g_diff:.4f} spray={s_diff:.4f} rf={rf_diff:.4f}")
