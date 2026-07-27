#!/usr/bin/env python3
"""
Grid CSV analyzer for the Pest Management Module.

Purpose: compute exact aggregates from large per-plot per-season grid CSVs
(hundreds of thousands to millions of rows) so results can be pasted into
tab3_Results.md verbatim, instead of being read/transcribed by eye. This
exists because manual reading of large CSVs produced fabricated values
(Week 7 incident).

Usage:
    python3 analyze_grid.py <csv_path> [--fixation-rf 0.99] [--out summary.csv] [--profit]

Prints a season-level summary (mean grain_tha, pest_loss_tha,
resistant_fraction, spray_count, cost_per_spray) grouped by whatever
identifier columns are present (strategy, pesticide_choice,
immigration_rate, rotation_pattern, ...), plus the first season each
group's mean RF crosses the fixation threshold. Every number printed
comes from pandas aggregation over the full file, not from sampling or
eyeballing.

--profit adds a per-group profit summary: cumulative net profit over all
seasons in the file (sum of season-mean net profit per plot, per group)
and profit_std (population std dev of season-mean net profit across
seasons, a season-to-season stability measure -- lower means more
consistent profit season over season, per the Jul 8 "more or less same
profit every season" note). Net profit per plot per season is computed as
grain_tha * GRAIN_PRICE - spray_count * cost_per_spray, matching the
"Net profit" formula already used throughout tab3_Results.md. Requires
grain_tha, spray_count, and cost_per_spray columns.
"""
import argparse
import sys
import pandas as pd


# Columns that identify a distinct experimental condition, if present.
# NOTE: this list must be kept in sync with every sweep column any experiment logs.
# Missing one here silently collapses that sweep's distinct conditions into a single
# averaged group instead of breaking them out (caught Week 8: resistance_fitness_cost
# was missing, which averaged sensitivity_output_decay_grid.csv's 5 decay conditions
# together instead of reporting each separately).
CANDIDATE_ID_COLS = ["strategy", "pesticide_choice", "immigration_rate",
                     "resistance_fitness_cost", "calendar_interval", "pesticide_threshold",
                     "rotation_pattern", "adaptive_profit_mode"]

# grain_price placeholder used consistently across tab3_Results.md's "Net profit"
# tables (see that doc's "Money caveat" note: grain_price=3000, arbitrary units --
# relative ranking is meaningful, absolute values are not).
GRAIN_PRICE = 3000.0


def load(csv_path: str) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    missing = {"season", "resistant_fraction"} - set(df.columns)
    if missing:
        raise ValueError(f"{csv_path} is missing expected columns: {missing}")
    return df


def summarize(df: pd.DataFrame, fixation_rf: float) -> tuple[pd.DataFrame, pd.DataFrame]:
    id_cols = [c for c in CANDIDATE_ID_COLS if c in df.columns]
    group_cols = id_cols + ["season"]

    agg_map = {}
    for col in ["grain_tha", "pest_loss_tha", "resistant_fraction", "spray_count", "cost_per_spray"]:
        if col in df.columns:
            agg_map[col] = "mean"

    season_summary = df.groupby(group_cols, as_index=False).agg(agg_map)
    season_summary = season_summary.sort_values(group_cols).reset_index(drop=True)

    # Fixation season: first season where mean resistant_fraction >= threshold,
    # per identifier group. If a group never crosses it within the data, reported as None.
    fixation_rows = []
    key_cols = id_cols if id_cols else None
    if key_cols:
        groups = season_summary.groupby(key_cols)
    else:
        groups = [((), season_summary)]

    for key, g in groups:
        g = g.sort_values("season")
        hit = g[g["resistant_fraction"] >= fixation_rf]
        fixation_season = int(hit["season"].iloc[0]) if not hit.empty else None
        row = {}
        if key_cols:
            if isinstance(key, tuple):
                row.update(dict(zip(key_cols, key)))
            else:
                row[key_cols[0]] = key
        row["fixation_season"] = fixation_season
        row["max_season_in_data"] = int(g["season"].max())
        row["final_mean_rf"] = round(float(g["resistant_fraction"].iloc[-1]), 4)
        fixation_rows.append(row)

    fixation_summary = pd.DataFrame(fixation_rows)
    return season_summary, fixation_summary


def summarize_profit(df: pd.DataFrame) -> pd.DataFrame:
    """Per-group cumulative profit and season-to-season profit stability.

    net_profit_per_plot per row = grain_tha * GRAIN_PRICE - spray_count * cost_per_spray.
    Averaged per (group, season) first, matching every other season-level
    aggregation in this script, then:
      - cumulative_profit = sum of those season-mean profits across all seasons present
      - profit_std = population std dev of the season-mean profits across seasons
        (season-to-season stability; lower = more consistent profit season over season)
    """
    required = {"grain_tha", "spray_count", "cost_per_spray"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"--profit requires columns {required}, missing: {missing}")

    id_cols = [c for c in CANDIDATE_ID_COLS if c in df.columns]
    work = df.copy()
    work["net_profit"] = work["grain_tha"] * GRAIN_PRICE - work["spray_count"] * work["cost_per_spray"]

    group_cols = id_cols + ["season"]
    season_profit = work.groupby(group_cols, as_index=False).agg(net_profit=("net_profit", "mean"))

    key_cols = id_cols if id_cols else None
    rows = []
    if key_cols:
        groups = season_profit.groupby(key_cols)
    else:
        groups = [((), season_profit)]

    for key, g in groups:
        g = g.sort_values("season")
        row = {}
        if key_cols:
            if isinstance(key, tuple):
                row.update(dict(zip(key_cols, key)))
            else:
                row[key_cols[0]] = key
        row["n_seasons"] = int(len(g))
        row["cumulative_profit"] = round(float(g["net_profit"].sum()), 1)
        row["profit_std"] = round(float(g["net_profit"].std(ddof=0)), 1)
        row["mean_profit_per_season"] = round(float(g["net_profit"].mean()), 1)
        rows.append(row)

    profit_summary = pd.DataFrame(rows)
    if key_cols:
        profit_summary = profit_summary.sort_values(by="cumulative_profit", ascending=False).reset_index(drop=True)
    return profit_summary


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("csv_path")
    parser.add_argument("--fixation-rf", type=float, default=0.99,
                         help="RF threshold counted as fixation (default 0.99, matches Week 7 changelog convention)")
    parser.add_argument("--out", default=None, help="optional path to write the season summary CSV")
    parser.add_argument("--profit", action="store_true",
                         help="also compute per-group cumulative profit and season-to-season profit stability")
    args = parser.parse_args()

    df = load(args.csv_path)
    n_rows = len(df)
    n_runs = df["run_id"].nunique() if "run_id" in df.columns else None

    season_summary, fixation_summary = summarize(df, args.fixation_rf)

    print(f"# Source: {args.csv_path}")
    print(f"# Rows: {n_rows}" + (f" | distinct run_ids: {n_runs}" if n_runs else ""))
    print()
    print("## Season-level means")
    print(season_summary.to_string(index=False))
    print()
    print(f"## Fixation summary (RF >= {args.fixation_rf})")
    print(fixation_summary.to_string(index=False))

    if args.profit:
        profit_summary = summarize_profit(df)
        print()
        print(f"## Profit summary (grain_price={GRAIN_PRICE}, sorted by cumulative_profit desc)")
        print(profit_summary.to_string(index=False))

    if args.out:
        season_summary.to_csv(args.out, index=False)
        print(f"\nWrote season summary to {args.out}")


if __name__ == "__main__":
    main()
