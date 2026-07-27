#!/usr/bin/env python3
"""Check if harvest_output.csv (non-grid) matches better."""
import pandas as pd

GRAIN_PRICE = 3000.0
ROOT = "C:/Users/maryz/Desktop/ACROSS/pest-management/Pest-Management-Module/models"
ARCH = f"{ROOT}/07052026"

# Check harvest_output.csv
df = pd.read_csv(f"{ARCH}/harvest_output.csv")
print(f"harvest_output.csv columns: {list(df.columns)}")
print(f"rows: {len(df)}, runs: {df['run_id'].nunique()}")
print(f"strategies: {df['strategy'].unique()}")
print(f"seasons: {sorted(df['season'].unique())}")
print(f"cost_per_spray: {df['cost_per_spray'].unique()}")

# Compute profits
df["profit"] = df["grain_tha"] * GRAIN_PRICE - df["spray_count"] * df["cost_per_spray"]

for strat in ["calendar", "threshold", "none"]:
    s = df[df["strategy"] == strat]
    agg = s.groupby("season").agg(
        grain=("grain_tha", "mean"),
        spray=("spray_count", "mean"),
        profit=("profit", "mean"),
    ).reset_index()
    print(f"\n{strat}:")
    for _, r in agg.iterrows():
        print(f"  S{int(r['season'])} grain={r['grain']:.3f} spray={r['spray']:.2f} profit={r['profit']:.1f}")

# Now check the3-compound files in 07052026
print("\n" + "=" * 60)
print("3-COMPOUND BASELINE: checking etofenprox and neonic in 07052026")

for fname, label, cost in [
    ("harvest_grid_output_etofenprox.csv", "Etofenprox", 110.6),
    ("harvest_grid_output_neonic.csv", "Neonicotinoid", 100.0),
]:
    dfx = pd.read_csv(f"{ARCH}/{fname}")
    dfx["profit"] = dfx["grain_tha"] * GRAIN_PRICE - dfx["spray_count"] * dfx["cost_per_spray"]
    agg = dfx.groupby(["strategy", "season"]).agg(
        profit=("profit", "mean"),
    ).reset_index()
    print(f"\n{label} (07052026):")
    for _, r in agg.iterrows():
        print(f"  {r['strategy']:10s} S{int(r['season'])} profit={r['profit']:.1f}")

# Check if the doc's3-compound values might match the etofenprox or neonic
# for the DEFAULT column
print("\n" + "=" * 60)
print("Doc says for Default column:")
print("  calendar S1: 9379.2, S2: 8886.3, S3: 7740.7")
print("  threshold S1: 9728.8, S2: 8663.0, S3: 6387.2")

# Maybe the doc was computed from a DIFFERENT version of harvest_grid_output.csv
# that no longer exists. Let me check the Phase 2 net profit table which also has issues.
print("\n" + "=" * 60)
print("Checking if Phase 2 net profit table (lines 455-465) values are consistent")
print("with 3-compound baseline")
print()

# From the3-compound table, the Default calendar S1 profit = 9379.2 (doc)
# From the Phase 2 net profit table, the calendar S1 profit = 9379.2 (doc)
# These should be the same number. Let me verify.
df_root = pd.read_csv(f"{ROOT}/harvest_grid_output.csv")
df_root["profit"] = df_root["grain_tha"] * GRAIN_PRICE - df_root["spray_count"] * df_root["cost_per_spray"]

# Phase 2 net profit per plot (averaged across all plots)
phase2 = df_root.groupby(["strategy", "season"]).agg(
    profit=("profit", "mean"),
).reset_index()
print("Phase 2 net profit per plot:")
for _, r in phase2.iterrows():
    print(f"  {r['strategy']:10s} S{int(r['season'])} profit={r['profit']:.1f}")
