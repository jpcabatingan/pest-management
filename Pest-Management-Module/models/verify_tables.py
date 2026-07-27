#!/usr/bin/env python3
"""Verify all tables in tab3_Results.md against actual CSV output files."""
import pandas as pd
import sys

GRAIN_PRICE = 3000.0
ROOT = "C:/Users/maryz/Desktop/ACROSS/pest-management/Pest-Management-Module/models"
ARCH = f"{ROOT}/07052026"

discrepancies = []

def check(label, reported, computed, tol=0.02, is_int=False):
    """Compare reported value to computed. Tol is absolute for ints, relative for floats."""
    if is_int:
        ok = abs(reported - computed) < 0.5
    else:
        if abs(computed) < 1e-6:
            ok = abs(reported) < tol
        else:
            ok = abs(reported - computed) / max(abs(computed), 1e-6) < tol
    status = "OK" if ok else "MISMATCH"
    if not ok:
        discrepancies.append(f"  [{label}] reported={reported}, computed={computed}")
    print(f"  {status}: {label} reported={reported} computed={computed}")
    return ok


print("=" * 80)
print("PHASE 1 VERIFICATION")
print("=" * 80)

# --- Table 1: Baseline mean (lines 11-20) ---
print("\n--- Baseline grain/spray (lines 11-20) ---")
df = pd.read_csv(f"{ARCH}/harvest_output.csv")
baseline = df.groupby(["strategy", "season"]).agg(
    grain_mean=("grain_tha", "mean"), grain_std=("grain_tha", "std"),
    spray_mean=("spray_count", "mean"), spray_std=("spray_count", "std"),
).reset_index()

reported = {
    ("none", 1):      (2.303, 0.043, 0.00, 0.00),
    ("none", 2):      (2.304, 0.041, 0.00, 0.00),
    ("none", 3):      (2.314, 0.037, 0.00, 0.00),
    ("calendar", 1):  (3.323, 0.048, 5.00, 0.00),
    ("calendar", 2):  (3.338, 0.062, 5.00, 0.00),
    ("calendar", 3):  (3.329, 0.054, 5.00, 0.00),
    ("threshold", 1): (3.586, 0.011, 7.83, 0.59),
    ("threshold", 2): (3.585, 0.010, 7.83, 0.59),
    ("threshold", 3): (3.587, 0.009, 7.88, 0.64),
}

for _, r in baseline.iterrows():
    key = (r["strategy"], int(r["season"]))
    if key in reported:
        rg, rs, sg, ss = reported[key]
        check(f"baseline grain {key}", rg, r["grain_mean"], tol=0.01)
        check(f"baseline spray {key}", sg, r["spray_mean"], tol=0.02)

# --- Table 2: Net profit per season (lines 36-46) ---
print("\n--- Net profit per season (lines 36-46) ---")
df["net_profit"] = df["grain_tha"] * GRAIN_PRICE - df["spray_count"] * df["cost_per_spray"]
profit = df.groupby(["strategy", "season"]).agg(
    profit_mean=("net_profit", "mean"), profit_std=("net_profit", "std"),
).reset_index()

reported_profit = {
    ("none", 1): (6908.6, 128.9), ("none", 2): (6910.7, 123.4), ("none", 3): (6941.3, 112.1),
    ("calendar", 1): (9467.5, 142.7), ("calendar", 2): (9514.2, 185.4), ("calendar", 3): (9486.0, 163.1),
    ("threshold", 1): (9974.9, 82.3), ("threshold", 2): (9973.4, 74.6), ("threshold", 3): (9974.1, 82.2),
}

for _, r in profit.iterrows():
    key = (r["strategy"], int(r["season"]))
    if key in reported_profit:
        rp, rs = reported_profit[key]
        check(f"profit {key}", rp, r["profit_mean"], tol=5)

# --- Table 3: Calendar interval sweep (lines 254-262) ---
print("\n--- Calendar interval sweep (lines 254-262) ---")
df_int = pd.read_csv(f"{ARCH}/sensitivity_output_interval.csv")
int_s = df_int.groupby("calendar_interval").agg(
    grain_mean=("grain_tha", "mean"), grain_std=("grain_tha", "std"),
    spray_mean=("spray_count", "mean"),
).reset_index()

reported_int = {7: (3.674, 0.021, 10.0), 10: (3.533, 0.037, 7.0), 14: (3.327, 0.053, 5.0),
                21: (2.987, 0.079, 3.0), 28: (2.767, 0.058, 2.0)}

for _, r in int_s.iterrows():
    iv = int(r["calendar_interval"])
    if iv in reported_int:
        rg, rs, sg = reported_int[iv]
        check(f"interval {iv} grain", rg, r["grain_mean"], tol=0.01)
        check(f"interval {iv} sprays", sg, r["spray_mean"], tol=0.05)

# --- Table 4: Threshold sweep (lines 264-272) ---
print("\n--- Threshold sweep (lines 264-272) ---")
df_thr = pd.read_csv(f"{ARCH}/sensitivity_output_threshold.csv")
thr_s = df_thr.groupby("pesticide_threshold").agg(
    grain_mean=("grain_tha", "mean"), grain_std=("grain_tha", "std"),
    spray_mean=("spray_count", "mean"),
).reset_index()

reported_thr = {0.1: (3.673, 0.024, 10.00), 0.2: (3.659, 0.018, 9.77), 0.3: (3.585, 0.011, 7.91),
                0.4: (3.447, 0.014, 5.90), 0.5: (3.315, 0.020, 4.77)}

for _, r in thr_s.iterrows():
    tv = round(r["pesticide_threshold"], 1)
    if tv in reported_thr:
        rg, rs, sg = reported_thr[tv]
        check(f"threshold {tv} grain", rg, r["grain_mean"], tol=0.01)
        check(f"threshold {tv} sprays", sg, r["spray_mean"], tol=0.1)

# --- Table 5: Pesticide class sweep (lines 243-246) ---
print("\n--- Pesticide class sweep (lines 243-246) ---")
for fname, label in [("sensitivity_output_etofenprox_eff70_inc3_cost100.csv", "etofenprox"),
                      ("sensitivity_output_neonicotinoid_eff80_inc3_cost100.csv", "neonicotinoid")]:
    dfx = pd.read_csv(f"{ARCH}/{fname}")
    g = dfx.groupby("strategy").agg(
        grain_mean=("grain_tha", "mean"), grain_std=("grain_tha", "std"),
        spray_mean=("spray_count", "mean"), spray_std=("spray_count", "std"),
    ).reset_index()
    for _, r in g.iterrows():
        print(f"  {label:14s} {r['strategy']:10s} grain={r['grain_mean']:.3f} +/- {r['grain_std']:.3f}  spray={r['spray_mean']:.2f} +/- {r['spray_std']:.2f}")

print("\n" + "=" * 80)
print("PHASE 2 VERIFICATION")
print("=" * 80)

# --- Grid-level summary (lines 428-437) ---
print("\n--- Phase 2 grid-level summary (lines 428-437) ---")
df_grid = pd.read_csv(f"{ROOT}/harvest_grid_output.csv")
grid_s = df_grid.groupby(["strategy", "season"]).agg(
    grain_mean=("grain_tha", "mean"), spray_mean=("spray_count", "mean"),
    rf_mean=("resistant_fraction", "mean"),
).reset_index()

reported_grid = {
    ("none", 1): (2.314, 0, 0.000), ("none", 2): (2.316, 0, 0.000), ("none", 3): (2.314, 0, 0.000),
    ("calendar", 1): (3.293, 5.00, 0.070), ("calendar", 2): (3.129, 5.00, 0.255), ("calendar", 3): (2.747, 5.00, 0.486),
    ("threshold", 1): (3.516, 8.19, 0.173), ("threshold", 2): (3.205, 9.53, 0.637), ("threshold", 3): (2.454, 9.74, 0.989),
}

for _, r in grid_s.iterrows():
    key = (r["strategy"], int(r["season"]))
    if key in reported_grid:
        rg, sg, rf = reported_grid[key]
        check(f"grid grain {key}", rg, r["grain_mean"], tol=0.01)
        check(f"grid spray {key}", sg, r["spray_mean"], tol=0.05)
        check(f"grid RF {key}", rf, r["rf_mean"], tol=0.005)

# --- Phase 2 Net profit per plot (lines 455-465) ---
print("\n--- Phase 2 net profit per plot (lines 455-465) ---")
df_grid["net_profit"] = df_grid["grain_tha"] * GRAIN_PRICE - df_grid["spray_count"] * df_grid["cost_per_spray"]
# Average per (run, strategy, season) first, then across runs
plot_profit = df_grid.groupby(["run_id", "strategy", "season"]).agg(
    profit_per_plot=("net_profit", "mean"),
).reset_index().groupby(["strategy", "season"]).agg(
    profit_mean=("profit_per_plot", "mean"),
).reset_index()

reported_gprofit = {
    ("none", 1): 6942.6, ("none", 2): 6947.0, ("none", 3): 6942.7,
    ("calendar", 1): 9379.2, ("calendar", 2): 8886.3, ("calendar", 3): 7740.7,
    ("threshold", 1): 9728.8, ("threshold", 2): 8663.0, ("threshold", 3): 6387.2,
}

for _, r in plot_profit.iterrows():
    key = (r["strategy"], int(r["season"]))
    if key in reported_gprofit:
        check(f"grid profit {key}", reported_gprofit[key], r["profit_mean"], tol=5)

# --- 30-season long-term table (lines 527-534) ---
print("\n--- Phase 2 long-term 30-season (lines 527-534) ---")
df_lt = pd.read_csv(f"{ARCH}/harvest_grid_output_longterm.csv")
# Get unique run_ids and their strategy/pesticide_choice
lt_info = df_lt.groupby(["run_id", "strategy", "pesticide_choice"]).agg(
    seasons=("season", "max"), n_rows=("season", "count"),
).reset_index()
print(f"  Long-term CSV: {len(df_lt)} rows, {df_lt['run_id'].nunique()} run_ids")
print(f"  Strategies: {df_lt['strategy'].unique()}")
print(f"  Compounds: {df_lt['pesticide_choice'].unique()}")
print(f"  Max season: {df_lt['season'].max()}")

# Compute fixation season and S30 grain
lt_groups = df_lt.groupby(["strategy", "pesticide_choice", "run_id"])
season_means = df_lt.groupby(["strategy", "pesticide_choice", "run_id", "season"]).agg(
    grain_mean=("grain_tha", "mean"), rf_mean=("resistant_fraction", "mean"),
).reset_index()

# Aggregate across runs for season-level means
lt_season = season_means.groupby(["strategy", "pesticide_choice", "season"]).agg(
    grain_mean=("grain_mean", "mean"), rf_mean=("rf_mean", "mean"),
).reset_index()

for strat in ["threshold", "calendar", "none"]:
    if strat == "none":
        compounds = ["etofenprox"]  # dummy
    else:
        compounds = df_lt[df_lt["strategy"] == strat]["pesticide_choice"].unique()
    for cpd in compounds:
        if strat == "none":
            subset = lt_season[lt_season["strategy"] == strat]
        else:
            subset = lt_season[(lt_season["strategy"] == strat) & (lt_season["pesticide_choice"] == cpd)]
        if len(subset) == 0:
            continue
        fix = subset[subset["rf_mean"] >= 0.99]
        fix_s = int(fix["season"].min()) if len(fix) > 0 else "never"
        s30 = subset[subset["season"] == subset["season"].max()]["grain_mean"].values
        s30_val = s30[0] if len(s30) > 0 else None
        print(f"  {strat:10s} {cpd:15s} fixation={fix_s}  S30_grain={s30_val:.3f}" if s30_val else f"  {strat:10s} {cpd:15s} fixation={fix_s}")

# --- Extended Immigration Sweep (lines 577-583) ---
print("\n--- Extended Immigration Sweep (lines 577-583) ---")
df_imm = pd.read_csv(f"{ARCH}/sensitivity_output_immigration_grid_extended.csv")
imm_groups = df_imm.groupby(["immigration_rate", "season"]).agg(
    rf_mean=("resistant_fraction", "mean"), grain_mean=("grain_tha", "mean"),
).reset_index()

imm_s30 = imm_groups[imm_groups["season"] == 30].sort_values("immigration_rate")
for _, r in imm_s30.iterrows():
    print(f"  imm={r['immigration_rate']:.1f}  RF_S30={r['rf_mean']:.3f}  grain_S30={r['grain_mean']:.3f}")

reported_imm = {0.3: (0.833, 2.405), 0.5: (0.500, 2.726), 0.7: (0.357, 2.964), 0.9: (0.278, 3.104), 1.0: (0.250, 3.148)}
for _, r in imm_s30.iterrows():
    ir = r["immigration_rate"]
    if ir in reported_imm:
        rrf, rg = reported_imm[ir]
        check(f"imm {ir:.1f} RF", rrf, r["rf_mean"], tol=0.01)
        check(f"imm {ir:.1f} grain", rg, r["grain_mean"], tol=0.01)

# --- Decay sweep (lines 597-603) ---
print("\n--- Resistance Decay sweep (lines 597-603) ---")
df_dec = pd.read_csv(f"{ARCH}/sensitivity_output_decay_grid.csv")
dec_groups = df_dec.groupby(["resistance_fitness_cost", "season"]).agg(
    rf_mean=("resistant_fraction", "mean"), grain_mean=("grain_tha", "mean"),
).reset_index()

for cost in [0.0, 0.01, 0.02, 0.05, 0.10]:
    sub = dec_groups[dec_groups["resistance_fitness_cost"] == cost]
    fix = sub[sub["rf_mean"] >= 0.99]
    fix_s = int(fix["season"].min()) if len(fix) > 0 else "never"
    s30 = sub[sub["season"] == sub["season"].max()]["grain_mean"].values
    s30_val = s30[0] if len(s30) > 0 else None
    print(f"  cost={cost:.2f}  fixation={fix_s}  S30_grain={s30_val:.3f}" if s30_val else f"  cost={cost:.2f}  fixation={fix_s}")

# --- Decay profit (lines 609-615) ---
print("\n--- Decay profit (lines 609-615) ---")
GRAIN_PRICE = 3000.0
df_dec["net_profit"] = df_dec["grain_tha"] * GRAIN_PRICE - df_dec["spray_count"] * df_dec["cost_per_spray"]
dec_profit = df_dec.groupby(["resistance_fitness_cost", "run_id", "season"]).agg(
    np=("net_profit", "mean"),
).reset_index().groupby(["resistance_fitness_cost", "season"]).agg(
    np_mean=("np", "mean"),
).reset_index().groupby(["resistance_fitness_cost"]).agg(
    cum_profit=("np_mean", "sum"), mean_profit=("np_mean", "mean"), std_profit=("np_mean", "std"),
).reset_index().sort_values("resistance_fitness_cost", ascending=False)
print(dec_profit.to_string(index=False))

print("\n" + "=" * 80)
print("PHASE 2 ROTATION VERIFICATION")
print("=" * 80)

# --- Rotation key results (lines 629-632) ---
print("\n--- Rotation key results (lines 629-632) ---")
df_rot = pd.read_csv(f"{ARCH}/harvest_grid_output_rotation.csv")
# Check unique strategies and compounds
print(f"  Rotation CSV: {len(df_rot)} rows")
print(f"  Strategies: {df_rot['strategy'].unique()}")
print(f"  Compounds: {df_rot['pesticide_choice'].unique()}")

rot_season = df_rot.groupby(["strategy", "pesticide_choice", "season"]).agg(
    rf_mean=("resistant_fraction", "mean"),
).reset_index()

for strat in ["calendar", "threshold"]:
    for cpd in ["etofenprox", "neonicotinoid"]:
        sub = rot_season[(rot_season["strategy"] == strat) & (rot_season["pesticide_choice"] == cpd)]
        fix = sub[sub["rf_mean"] >= 0.99]
        fix_s = int(fix["season"].min()) if len(fix) > 0 else "never"
        print(f"  {strat:10s} {cpd:15s} fixation={fix_s}")

# Rotation-only (where pesticide_choice flips each season)
rot_only = rot_season[rot_season["strategy"].isin(["calendar", "threshold"])].copy()
print("\n  Rotation RF by season (active compound):")
for strat in ["calendar", "threshold"]:
    sub = rot_only[rot_only["strategy"] == strat].sort_values("season")
    print(f"  {strat}:")
    for _, r in sub.iterrows():
        print(f"    S{int(r['season'])} {r['pesticide_choice']:15s} RF={r['rf_mean']:.3f}")

# --- Rotation x Interval (lines 666-688) ---
print("\n--- Rotation x Calendar Interval sweep (lines 666-688) ---")
df_ri = pd.read_csv(f"{ARCH}/sensitivity_output_interval_grid_rotation.csv")
ri_season = df_ri.groupby(["calendar_interval", "pesticide_choice", "season"]).agg(
    rf_mean=("resistant_fraction", "mean"), grain_mean=("grain_tha", "mean"),
).reset_index()

for iv in [1, 3, 5, 7, 10, 14, 21, 28]:
    for cpd in ["etofenprox", "neonicotinoid"]:
        sub = ri_season[(ri_season["calendar_interval"] == iv) & (ri_season["pesticide_choice"] == cpd)]
        fix = sub[sub["rf_mean"] >= 0.99]
        fix_s = int(fix["season"].min()) if len(fix) > 0 else "never"
        print(f"  interval={iv:2d} {cpd:15s} fixation={fix_s}")

# Mean grain S1-6
ri_grain = df_ri.groupby(["calendar_interval", "run_id"]).agg(
    grain_s1_6=("grain_tha", lambda x: x[df_ri.loc[x.index, "season"] <= 6].mean()),
).reset_index().groupby("calendar_interval").agg(
    grain_mean=("grain_s1_6", "mean"), grain_s30=("grain_tha", "last"),
).reset_index()
print("\n  Mean grain S1-6 by interval:")
for _, r in ri_grain.iterrows():
    print(f"  interval={int(r['calendar_interval']):2d}  grain_S1-6={r['grain_mean']:.3f}")

# S30 grain
ri_s30 = df_ri[df_ri["season"] == 30].groupby("calendar_interval").agg(
    grain_mean=("grain_tha", "mean"),
).reset_index()
print("\n  Grain S30 by interval:")
for _, r in ri_s30.iterrows():
    print(f"  interval={int(r['calendar_interval']):2d}  grain_S30={r['grain_mean']:.3f}")

print("\n" + "=" * 80)
print("SUMMARY")
print("=" * 80)
if discrepancies:
    print(f"\nFOUND {len(discrepancies)} DISCREPANCIES:")
    for d in discrepancies:
        print(d)
else:
    print("\nAll checks passed within tolerance.")
