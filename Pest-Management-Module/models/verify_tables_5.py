#!/usr/bin/env python3
"""Investigate the3-compound Default profit discrepancy."""
import pandas as pd

GRAIN_PRICE = 3000.0
ROOT = "C:/Users/maryz/Desktop/ACROSS/pest-management/Pest-Management-Module/models"

df = pd.read_csv(f"{ROOT}/harvest_grid_output.csv")
df["profit"] = df["grain_tha"] * GRAIN_PRICE - df["spray_count"] * df["cost_per_spray"]

# Check per-run stats
print("Calendar strategy, per-run profit stats:")
cal = df[df["strategy"] == "calendar"]
for season in [1, 2, 3]:
    s = cal[cal["season"] == season]
    run_profits = s.groupby("run_id")["profit"].mean()
    print(f"  S{season}: n={len(run_profits)} runs, "
          f"mean={run_profits.mean():.4f}, "
          f"std={run_profits.std():.4f}, "
          f"min={run_profits.min():.4f}, "
          f"max={run_profits.max():.4f}")

# Check grain and spray per run
print("\nCalendar strategy, per-run grain/spray:")
for season in [1, 2, 3]:
    s = cal[cal["season"] == season]
    rg = s.groupby("run_id")["grain_tha"].mean()
    rs = s.groupby("run_id")["spray_count"].mean()
    print(f"  S{season}: grain mean={rg.mean():.4f}, spray mean={rs.mean():.2f}")

# Check if the doc used a DIFFERENT formula: grain * 3000 - spray * cost
# but with different rounding or a different version of the file
print("\nDoc says for Default:")
print("  calendar S1: 9379.2")
print("  calendar S2: 8886.3")
print("  calendar S3: 7740.7")
print("  threshold S1: 9728.8")
print("  threshold S2: 8663.0")
print("  threshold S3: 6387.2")

# Let me check if the doc profit formula might be grain * 3000 - spray * 100 per plot,
# then summed across all plots (not averaged)
print("\nSum across all plots (n=100):")
for season in [1, 2, 3]:
    s = cal[cal["season"] == season]
    total = s.groupby("run_id")["profit"].sum()
    mean_across_runs = total.mean()
    print(f"  S{season}: total profit (sum 100 plots) per run, mean across runs = {mean_across_runs:.1f}")

# Let me also check if perhaps there's a different harvest_grid_output.csv
# in the 07052026 directory that matches better
import os
arch_files = [f for f in os.listdir(f"{ROOT}/07052026") if "harvest" in f and f.endswith(".csv")]
print(f"\n07052026 harvest files: {arch_files}")

# Check if there's a root-level snapshot
root_files = [f for f in os.listdir(ROOT) if "harvest" in f and f.endswith(".csv")]
print(f"Root harvest files: {root_files}")

# Maybe the doc used a DIFFERENT version that was overwritten.
# Let me check the 07052026 rotation file which should be from a different experiment
df_rot = pd.read_csv(f"{ROOT}/07052026/harvest_grid_output_rotation.csv")
print(f"\nRotation file columns: {list(df_rot.columns)}")
print(f"Rotation file has strategy: {'strategy' in df_rot.columns}")
if "strategy" in df_rot.columns:
    print(f"  strategies: {df_rot['strategy'].unique()}")
