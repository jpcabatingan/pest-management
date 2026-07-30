#!/usr/bin/env python3
"""Worked hypothesis tests for four claims made in tab3_Results.md /
tab4_Recommendations.md. Each block states H0/H1 in a comment, aggregates
to the correct unit of replication (the RUN, not the individual plot-row --
see the pseudoreplication note in hypothesis_testing_guide.md), then runs
the appropriate test. This is a worked-example script, not an audit script
like verify_pass1-4 -- extend it with your own claims using the same
pattern (state H0/H1, group by run_id before testing, report effect size
alongside the p-value).
"""
import pandas as pd
from scipy import stats

ROOT = "C:/Users/maryz/Desktop/ACROSS/pest-management-data/models"
ARCH = f"{ROOT}/07052026"
GRAIN_PRICE = 3000.0
ALPHA = 0.05

def verdict(p):
    return "REJECT H0 (significant)" if p < ALPHA else "FAIL TO REJECT H0 (not significant)"

print("=" * 78)
print("H1a: Threshold gives higher season-1 grain yield than calendar")
print("     H0: mean season-1 grain_tha is equal for threshold and calendar")
print("     H1: mean season-1 grain_tha is higher for threshold")
print("=" * 78)
df = pd.read_csv(f"{ARCH}/harvest_output.csv")
s1 = df[df["season"] == 1]
thr = s1[s1["strategy"] == "threshold"]["grain_tha"]
cal = s1[s1["strategy"] == "calendar"]["grain_tha"]
print(f"n(threshold)={len(thr)} runs, n(calendar)={len(cal)} runs (unit = run, already 1 row/run in this file)")
t_stat, p_val = stats.ttest_ind(thr, cal, equal_var=False)  # Welch's t-test, unequal variance assumed
u_stat, p_mw = stats.mannwhitneyu(thr, cal, alternative="greater")
print(f"Welch t-test: t={t_stat:.3f}, p={p_val:.6f} -> {verdict(p_val)}")
print(f"Mann-Whitney U (one-sided, threshold > calendar): p={p_mw:.6f} -> {verdict(p_mw)}")
print(f"Effect size (mean diff): {thr.mean() - cal.mean():.4f} t/ha  (threshold={thr.mean():.4f}, calendar={cal.mean():.4f})")

print()
print("=" * 78)
print("H1b: Backoff (adaptive_profit_mode) raises cumulative 30-season profit")
print("     under calendar+REACTIVE, at the default immigration_rate (0.05)")
print("     H0: mean per-run cumulative profit is equal with/without backoff")
print("     H1: mean per-run cumulative profit is higher with backoff")
print("=" * 78)
df2 = pd.read_csv(f"{ROOT}/sensitivity_output_adaptive_farmer_grid.csv")  # top-level = the verified n=40 rerun, not the n=20 screening copy archived under 07052026/
df2["profit"] = df2["grain_tha"] * GRAIN_PRICE - df2["spray_count"] * df2["cost_per_spray"]
sub = df2[(df2["strategy"] == "calendar") & (df2["rotation_reactive"] == True)]
# aggregate to run-level: sum profit across all plots and seasons for that run_id
per_run = sub.groupby(["run_id", "adaptive_profit_mode"])["profit"].sum().reset_index()
backoff_on = per_run[per_run["adaptive_profit_mode"] == True]["profit"]
backoff_off = per_run[per_run["adaptive_profit_mode"] == False]["profit"]
print(f"n(backoff on)={len(backoff_on)} runs, n(backoff off)={len(backoff_off)} runs (unit = run, aggregated from plot x season rows)")
t_stat, p_val = stats.ttest_ind(backoff_on, backoff_off, equal_var=False)
u_stat, p_mw = stats.mannwhitneyu(backoff_on, backoff_off, alternative="greater")
print(f"Welch t-test: t={t_stat:.3f}, p={p_val:.6f} -> {verdict(p_val)}")
print(f"Mann-Whitney U (one-sided, backoff > no backoff): p={p_mw:.6f} -> {verdict(p_mw)}")
print(f"Effect size (mean diff): {backoff_on.mean() - backoff_off.mean():.1f}  (on={backoff_on.mean():.1f}, off={backoff_off.mean():.1f})")

print()
print("=" * 78)
print("H1c: Rotation gives higher season-30 grain yield than single compound")
print("     (calendar strategy, starfarm baseline)")
print("     H0: mean season-30 grain_tha is equal for rotation and single-compound")
print("     H1: mean season-30 grain_tha is higher for rotation")
print("=" * 78)
rot = pd.read_csv(f"{ARCH}/harvest_grid_output_rotation.csv")
lt = pd.read_csv(f"{ARCH}/harvest_grid_output_longterm.csv")
rot_s30 = rot[(rot["strategy"] == "calendar") & (rot["season"] == 30)]
lt_s30 = lt[(lt["strategy"] == "calendar") & (lt["pesticide_choice"] == "starfarm") & (lt["season"] == 30)]
rot_per_run = rot_s30.groupby("run_id")["grain_tha"].mean()
lt_per_run = lt_s30.groupby("run_id")["grain_tha"].mean()
print(f"n(rotation)={len(rot_per_run)} runs, n(single-compound)={len(lt_per_run)} runs (unit = run, mean grain across 100 plots)")
t_stat, p_val = stats.ttest_ind(rot_per_run, lt_per_run, equal_var=False)
u_stat, p_mw = stats.mannwhitneyu(rot_per_run, lt_per_run, alternative="greater")
print(f"Welch t-test: t={t_stat:.3f}, p={p_val:.6f} -> {verdict(p_val)}")
print(f"Mann-Whitney U (one-sided, rotation > single-compound): p={p_mw:.6f} -> {verdict(p_mw)}")
print(f"Effect size (mean diff): {rot_per_run.mean() - lt_per_run.mean():.4f} t/ha  (rotation={rot_per_run.mean():.4f}, single={lt_per_run.mean():.4f})")
print("NOTE: p-value is significant but the effect size is tiny (~0.0035 t/ha) --")
print("      statistically real, practically negligible. See guide section 4.")

print()
print("=" * 78)
print("H1d (CAUTION -- descriptive only, not a controlled experiment):")
print("    Is immigration_rate correlated with cumulative profit?")
print("    H0: no monotonic relationship (Spearman rho = 0)")
print("    H1: rho != 0")
print("    NOTE: immigration_rate is swept by the experiment design, not")
print("    randomly assigned outside of it -- this tells you the model's")
print("    behavior under the tested values, it is not evidence that a farmer")
print("    could 'increase immigration to raise profit' in the real world.")
print("    Immigration is not farmer-controllable regardless of what this shows.")
print("=" * 78)
ext = pd.read_csv(f"{ARCH}/sensitivity_output_immigration_grid_extended.csv")
ext["profit"] = ext["grain_tha"] * GRAIN_PRICE - ext["spray_count"] * ext["cost_per_spray"]
per_run3 = ext.groupby(["run_id", "immigration_rate"])["profit"].sum().reset_index()
rho, p_val = stats.spearmanr(per_run3["immigration_rate"], per_run3["profit"])
print(f"n={len(per_run3)} runs across {per_run3['immigration_rate'].nunique()} immigration_rate values")
print(f"Spearman rho={rho:.4f}, p={p_val:.6f} -> {verdict(p_val)}")
print("Interpretation: statistically real within this model, at these tested values.")
print("Treat as a caveat/observation in the writeup, not a recommendation (see meeting notes).")
