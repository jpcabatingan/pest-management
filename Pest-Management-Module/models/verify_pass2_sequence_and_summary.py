#!/usr/bin/env python3
"""Audit pass 2 of 4: verify tab3_Results.md against CSV output files.
Covers Rotation x Threshold, Compound-Sequence, Interval x Immigration
cross-sweep, Heterogeneous Landscape, and the Summary Ranking table."""
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

print("=" * 80)
print("PHASE 2 ROTATION x THRESHOLD (lines 694-720)")
print("=" * 80)

df_rt = pd.read_csv(f"{ARCH}/sensitivity_output_threshold_grid_rotation.csv")
rt_season = df_rt.groupby(["pesticide_threshold", "pesticide_choice", "season"]).agg(
    rf_mean=("resistant_fraction", "mean"), grain_mean=("grain_tha", "mean"),
).reset_index()

# Reported fixation seasons (lines 700-706)
print("\n--- Fixation season by compound (lines 700-706) ---")
reported_fix_rt = {
    0.1: ("etofenprox", 7), 0.1: ("neonicotinoid", 4),
    0.2: ("etofenprox", 7), 0.2: ("neonicotinoid", 4),
    0.3: ("etofenprox", 7), 0.3: ("neonicotinoid", 4),
    0.4: ("etofenprox", 9), 0.4: ("neonicotinoid", 6),
    0.5: ("etofenprox", 11), 0.5: ("neonicotinoid", 6),
}
# Fix the dict - need tuples
reported_fix_rt = {
    (0.1, "etofenprox"): 7, (0.1, "neonicotinoid"): 4,
    (0.2, "etofenprox"): 7, (0.2, "neonicotinoid"): 4,
    (0.3, "etofenprox"): 7, (0.3, "neonicotinoid"): 4,
    (0.4, "etofenprox"): 9, (0.4, "neonicotinoid"): 6,
    (0.5, "etofenprox"): 11, (0.5, "neonicotinoid"): 6,
}

for thr in [0.1, 0.2, 0.3, 0.4, 0.5]:
    for cpd in ["etofenprox", "neonicotinoid"]:
        sub = rt_season[(rt_season["pesticide_threshold"] == thr) & (rt_season["pesticide_choice"] == cpd)]
        fix = sub[sub["rf_mean"] >= 0.99]
        fix_s = int(fix["season"].min()) if len(fix) > 0 else 99
        reported = reported_fix_rt.get((thr, cpd), None)
        if reported is not None:
            check(f"RT thr={thr} {cpd} fix", reported, fix_s, is_int=True)
        else:
            print(f"  thr={thr} {cpd} fix={fix_s}")

# Mean grain S1-6 (lines 710-716)
print("\n--- Mean grain S1-6 (lines 710-716) ---")
df_rt_s16 = df_rt[df_rt["season"] <= 6].groupby(["pesticide_threshold", "run_id"]).agg(
    grain_s16=("grain_tha", "mean"),
).reset_index().groupby("pesticide_threshold").agg(
    grain_mean=("grain_s16", "mean"),
).reset_index()

reported_grain_rt = {0.1: 2.903, 0.2: 2.896, 0.3: 2.912, 0.4: 2.927, 0.5: 2.918}
for _, r in df_rt_s16.iterrows():
    thr = round(r["pesticide_threshold"], 1)
    if thr in reported_grain_rt:
        check(f"RT thr={thr} grain S1-6", reported_grain_rt[thr], r["grain_mean"], tol=0.01)

# S30 grain
print("\n--- Grain S30 (lines 710-716) ---")
rt_s30 = df_rt[df_rt["season"] == 30].groupby("pesticide_threshold").agg(
    grain_mean=("grain_tha", "mean"),
).reset_index()
reported_s30_rt = {0.1: 2.318, 0.2: 2.320, 0.3: 2.319, 0.4: 2.320, 0.5: 2.317}
for _, r in rt_s30.iterrows():
    thr = round(r["pesticide_threshold"], 1)
    if thr in reported_s30_rt:
        check(f"RT thr={thr} grain S30", reported_s30_rt[thr], r["grain_mean"], tol=0.01)

print("\n" + "=" * 80)
print("PHASE 2 COMPOUND-SEQUENCE (lines 724-765)")
print("=" * 80)

# Use the 07052026 snapshot
df_cal = pd.read_csv(f"{ARCH}/sensitivity_output_compound_sequence_grid_calendar.csv")
df_thr = pd.read_csv(f"{ARCH}/sensitivity_output_compound_sequence_grid_threshold.csv")

def compute_profit_rankings(df, label):
    """Compute per-pattern cumulative profit."""
    GRAIN_PRICE = 3000.0
    df["net_profit"] = df["grain_tha"] * GRAIN_PRICE - df["spray_count"] * df["cost_per_spray"]
    
    # Per (pattern, run_id, season) profit
    season_p = df.groupby(["rotation_pattern", "run_id", "season"]).agg(
        np=("net_profit", "mean"),
    ).reset_index()
    
    # Per (pattern, season) profit, then cumulative
    pattern_season = season_p.groupby(["rotation_pattern", "season"]).agg(
        np_mean=("np", "mean"),
    ).reset_index()
    
    # Fixation: per pattern, first season where mean RF >= 0.99
    fix_data = df.groupby(["rotation_pattern", "season"]).agg(
        rf_mean=("resistant_fraction", "mean"),
    ).reset_index()
    
    results = []
    for pat in df["rotation_pattern"].unique():
        ps = pattern_season[pattern_season["rotation_pattern"] == pat]
        cum_profit = ps["np_mean"].sum()
        profit_std = ps["np_mean"].std(ddof=0)
        mean_profit = ps["np_mean"].mean()
        
        fd = fix_data[fix_data["rotation_pattern"] == pat]
        fix = fd[fd["rf_mean"] >= 0.99]
        fix_s = int(fix["season"].min()) if len(fix) > 0 else 99
        
        s30_grain = df[(df["rotation_pattern"] == pat) & (df["season"] == 30)]["grain_tha"].mean()
        
        results.append({
            "pattern": pat, "cum_profit": cum_profit, "profit_std": profit_std,
            "mean_profit": mean_profit, "fixation": fix_s, "s30_grain": s30_grain,
        })
    
    rdf = pd.DataFrame(results).sort_values("cum_profit", ascending=False).reset_index(drop=True)
    print(f"\n--- {label} strategy, ranked by cumulative profit ---")
    for i, r in rdf.iterrows():
        rank = i + 1
        print(f"  #{rank:2d} {r['pattern']:8s} cum={r['cum_profit']:,.1f} std={r['profit_std']:.1f} "
              f"mean={r['mean_profit']:,.1f} fix={r['fixation']} s30={r['s30_grain']:.3f}")
    return rdf

cal_rankings = compute_profit_rankings(df_cal, "Calendar")
thr_rankings = compute_profit_rankings(df_thr, "Threshold")

# Verify key reported values
print("\n--- Checking reported calendar rankings ---")
reported_cal = {
    "ABBB": (205332.9, 6), "BBBA": (205330.2, 6), "BBAB": (205293.1, 6),
    "BABB": (205169.5, 7), "ABB": (204855.0, 6), "AB": (204201.1, 8),
    "REACTIVE": (204071.3, 12), "AAAB": (203685.1, 10), "BAA": (203639.3, 11),
}
for pat, (rc, rf) in reported_cal.items():
    row = cal_rankings[cal_rankings["pattern"] == pat]
    if len(row) > 0:
        check(f"cal {pat} cum_profit", rc, row.iloc[0]["cum_profit"], tol=0.005)
        check(f"cal {pat} fixation", rf, row.iloc[0]["fixation"], is_int=True)

print("\n--- Checking reported threshold rankings ---")
reported_thr = {
    "ABBB": (190298.7, 3), "BBAB": (190189.6, 4), "BBBA": (190186.3, 3),
    "AB": (189059.5, 4), "REACTIVE": (188917.5, 5), "AAAB": (188265.2, 5),
    "BAAA": (188227.0, 4),
}
for pat, (rc, rf) in reported_thr.items():
    row = thr_rankings[thr_rankings["pattern"] == pat]
    if len(row) > 0:
        check(f"thr {pat} cum_profit", rc, row.iloc[0]["cum_profit"], tol=0.005)
        check(f"thr {pat} fixation", rf, row.iloc[0]["fixation"], is_int=True)

print("\n" + "=" * 80)
print("PHASE 2 INTERVAL x IMMIGRATION CROSS-SWEEP (lines 767-802)")
print("=" * 80)

df_xi = pd.read_csv(f"{ARCH}/sensitivity_output_interval_immigration_grid.csv")
df_xt = pd.read_csv(f"{ARCH}/sensitivity_output_threshold_immigration_grid.csv")

# Calendar minimum interval that avoids fixation (lines 773-778)
print("\n--- Calendar minimum interval avoiding fixation (lines 773-778) ---")
xi_fix = df_xi.groupby(["calendar_interval", "immigration_rate", "season"]).agg(
    rf_mean=("resistant_fraction", "mean"),
).reset_index()

# For each immigration rate, find the minimum interval that avoids fixation
for imm in [0.05, 0.20, 0.40, 0.70]:
    print(f"\n  imm={imm}:")
    for iv in [1, 3, 5, 7, 10, 14, 21, 28]:
        sub = xi_fix[(xi_fix["immigration_rate"] == imm) & (xi_fix["calendar_interval"] == iv)]
        fix = sub[sub["rf_mean"] >= 0.99]
        fix_s = int(fix["season"].min()) if len(fix) > 0 else "never"
        print(f"    interval={iv:2d} fixation={fix_s}")

# Reported values (lines 773-778):
# imm=0.05: none tested (still fixates by S16 at interval=28), fix at iv=1 is S1, iv=7 is S3
# imm=0.20: interval>=21 avoids, fix at iv=1 is S1, iv=7 is S3
# imm=0.40: interval>=10 avoids, fix at iv=1 is S1, iv=7 is S4
# imm=0.70: interval>=7 avoids, fix at iv=1 is S1, iv=7 is "never (fixates by S3 at interval=5, avoided at 7)"

print("\n--- Threshold fixation outcome (lines 782-787) ---")
xt_fix = df_xt.groupby(["pesticide_threshold", "immigration_rate", "season"]).agg(
    rf_mean=("resistant_fraction", "mean"),
).reset_index()

for imm in [0.05, 0.20, 0.40, 0.70]:
    print(f"\n  imm={imm}:")
    for thr in [0.1, 0.2, 0.3, 0.4, 0.5]:
        sub = xt_fix[(xt_fix["immigration_rate"] == imm) & (xt_fix["pesticide_threshold"] == thr)]
        fix = sub[sub["rf_mean"] >= 0.99]
        fix_s = int(fix["season"].min()) if len(fix) > 0 else "never"
        final_rf = sub["rf_mean"].max() if len(sub) > 0 else 0
        if fix_s == "never":
            print(f"    thr={thr:.1f} fixation={fix_s} (final RF={final_rf:.3f})")
        else:
            print(f"    thr={thr:.1f} fixation=S{fix_s}")

print("\n" + "=" * 80)
print("PHASE 2 HETEROGENEOUS LANDSCAPE (lines 806-835)")
print("=" * 80)

df_het = pd.read_csv(f"{ARCH}/harvest_grid_output_heterogeneous.csv")
het_season = df_het.groupby(["plot_strategy", "season"]).agg(
    grain_mean=("grain_tha", "mean"),
).reset_index()

# Reported values (lines 812-823)
reported_het = {
    ("none", 1): 2.515, ("none", 2): 2.408, ("none", 3): 2.347, ("none", 4): 2.329,
    ("none", 5): 2.321, ("none", 6): 2.318, ("none", 7): 2.317, ("none", 8): 2.315,
    ("none", 9): 2.313, ("none", 10): 2.316,
    ("calendar", 1): 3.098, ("calendar", 2): 2.849, ("calendar", 3): 2.557,
    ("calendar", 4): 2.420, ("calendar", 5): 2.361, ("calendar", 6): 2.335,
    ("calendar", 7): 2.322, ("calendar", 8): 2.314, ("calendar", 9): 2.314,
    ("calendar", 10): 2.317,
    ("threshold", 1): 3.315, ("threshold", 2): 2.836, ("threshold", 3): 2.422,
    ("threshold", 4): 2.340, ("threshold", 5): 2.323, ("threshold", 6): 2.321,
    ("threshold", 7): 2.319, ("threshold", 8): 2.317, ("threshold", 9): 2.316,
    ("threshold", 10): 2.318,
}

for _, r in het_season.iterrows():
    key = (r["plot_strategy"], int(r["season"]))
    if key in reported_het:
        check(f"het {key}", reported_het[key], r["grain_mean"], tol=0.01)

print("\n" + "=" * 80)
print("SUMMARY RANKING TABLE (lines 845-878)")
print("=" * 80)

# This requires computing cumulative profit from multiple CSVs.
# Key conditions to verify:
# Row 1: Calendar, Default, imm=1.00 -> 268,791.7
# Row 2: Calendar, Default, imm=0.90 -> 265,091.9
# Row 5: Calendar, Default, imm=0.70 -> 253,732.1
# Row 6: Calendar, Default, imm=0.50 -> 234,604.2
# Row 9: Calendar, Default, imm=0.30 -> 209,861.9
# Row 11: None -> ~208,340
# Row 15: Calendar, interval=14 -> ~200,643

# Extended Immigration Sweep values
print("\n--- Extended Immigration Sweep profit (rows 1-2, 5-6, 9) ---")
df_imm = pd.read_csv(f"{ARCH}/sensitivity_output_immigration_grid_extended.csv")
df_imm["net_profit"] = df_imm["grain_tha"] * GRAIN_PRICE - df_imm["spray_count"] * df_imm["cost_per_spray"]

imm_profit = df_imm.groupby(["immigration_rate", "run_id", "season"]).agg(
    np=("net_profit", "mean"),
).reset_index().groupby(["immigration_rate", "season"]).agg(
    np_mean=("np", "mean"),
).reset_index().groupby("immigration_rate").agg(
    cum_profit=("np_mean", "sum"),
).reset_index().sort_values("cum_profit", ascending=False)

print(imm_profit.to_string(index=False))

reported_imm_profit = {1.0: 268791.7, 0.9: 265091.9, 0.7: 253732.1, 0.5: 234604.2, 0.3: 209861.9}
for _, r in imm_profit.iterrows():
    ir = r["immigration_rate"]
    if ir in reported_imm_profit:
        check(f"imm profit {ir}", reported_imm_profit[ir], r["cum_profit"], tol=0.002)

# No-spray profit (row 11: ~208,340)
print("\n--- No-spray profit (row 11) ---")
df_lt = pd.read_csv(f"{ARCH}/harvest_grid_output_longterm.csv")
none_df = df_lt[df_lt["strategy"] == "none"]
none_df_calc = none_df.copy()
none_df_calc["net_profit"] = none_df_calc["grain_tha"] * GRAIN_PRICE - none_df_calc["spray_count"] * none_df_calc["cost_per_spray"]
none_profit = none_df_calc.groupby(["run_id", "season"]).agg(np=("net_profit", "mean")).reset_index()
none_cum = none_profit.groupby("season").agg(np_mean=("np", "mean")).reset_index()["np_mean"].sum()
print(f"  None cumulative profit: {none_cum:,.1f} (reported: ~208,340)")
check("none profit", 208340, none_cum, tol=0.005)

# Calendar interval=14 profit (row 15: ~200,643)
print("\n--- Calendar interval=14 profit (row 15) ---")
df_ig = pd.read_csv(f"{ARCH}/sensitivity_output_interval_grid.csv")
df_ig14 = df_ig[df_ig["calendar_interval"] == 14].copy()
df_ig14["net_profit"] = df_ig14["grain_tha"] * GRAIN_PRICE - df_ig14["spray_count"] * df_ig14["cost_per_spray"]
ig14_profit = df_ig14.groupby(["run_id", "season"]).agg(np=("net_profit", "mean")).reset_index()
ig14_cum = ig14_profit.groupby("season").agg(np_mean=("np", "mean")).reset_index()["np_mean"].sum()
print(f"  Calendar interval=14 cumulative profit (6 seasons): {ig14_cum:,.1f}")
print(f"  Note: doc says ~200,643 which may come from the 30-season extended run")

# Check the 07052026 interval_grid for 30-season data
df_ig_full = df_ig.copy()
max_season = df_ig_full["season"].max()
print(f"  sensitivity_output_interval_grid.csv max season: {max_season}")

# Cross-sweep profit values (lines 789-793)
print("\n--- Cross-sweep profit values (lines 789-793) ---")
# Calendar: interval=10/imm=0.70 -> 260,333.4
xi_profit = df_xi.copy()
xi_profit["net_profit"] = xi_profit["grain_tha"] * GRAIN_PRICE - xi_profit["spray_count"] * xi_profit["cost_per_spray"]
xi_p = xi_profit.groupby(["calendar_interval", "immigration_rate", "run_id", "season"]).agg(
    np=("net_profit", "mean"),
).reset_index().groupby(["calendar_interval", "immigration_rate", "season"]).agg(
    np_mean=("np", "mean"),
).reset_index().groupby(["calendar_interval", "immigration_rate"]).agg(
    cum_profit=("np_mean", "sum"),
).reset_index()

# Top profit: interval=10/imm=0.70 -> 260,333.4
top_cal = xi_p[(xi_p["calendar_interval"] == 10) & (xi_p["immigration_rate"] == 0.70)]
if len(top_cal) > 0:
    check("cross-sweep cal iv=10 imm=0.70", 260333.4, top_cal.iloc[0]["cum_profit"], tol=0.002)

# Worst: interval=1/imm=0.05 -> -15,330.3
worst_cal = xi_p[(xi_p["calendar_interval"] == 1) & (xi_p["immigration_rate"] == 0.05)]
if len(worst_cal) > 0:
    check("cross-sweep cal iv=1 imm=0.05", -15330.3, worst_cal.iloc[0]["cum_profit"], tol=0.005)

# Threshold: threshold=0.4/imm=0.70 -> 259,860.0
xt_profit = df_xt.copy()
xt_profit["net_profit"] = xt_profit["grain_tha"] * GRAIN_PRICE - xt_profit["spray_count"] * xt_profit["cost_per_spray"]
xt_p = xt_profit.groupby(["pesticide_threshold", "immigration_rate", "run_id", "season"]).agg(
    np=("net_profit", "mean"),
).reset_index().groupby(["pesticide_threshold", "immigration_rate", "season"]).agg(
    np_mean=("np", "mean"),
).reset_index().groupby(["pesticide_threshold", "immigration_rate"]).agg(
    cum_profit=("np_mean", "sum"),
).reset_index()

top_thr = xt_p[(xt_p["pesticide_threshold"] == 0.4) & (xt_p["immigration_rate"] == 0.70)]
if len(top_thr) > 0:
    check("cross-sweep thr=0.4 imm=0.70", 259860.0, top_thr.iloc[0]["cum_profit"], tol=0.002)

print("\n" + "=" * 80)
print("FINAL SUMMARY")
print("=" * 80)
if discrepancies:
    print(f"\nFOUND {len(discrepancies)} DISCREPANCIES:")
    for d in discrepancies:
        print(d)
else:
    print("\nAll checks passed within tolerance.")
