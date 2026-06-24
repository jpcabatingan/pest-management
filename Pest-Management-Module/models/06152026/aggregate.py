import pandas as pd
import glob
import os

all_files = glob.glob("daily_*.csv")
summary_data = []

for file in all_files:
    filename = os.path.basename(file).replace(".csv", "")
    parts = filename.split("_")
    
    if len(parts) < 3:
        continue
        
    strategy = parts[1]
    param_sweep = parts[2]
    
    try:
        df = pd.read_csv(file)
        
        spray_events = df[(df['days_since_last_spray'] == 1) & (df['spray_count'] > 0)]
        
        for index, row in spray_events.iterrows():
            pest_before = df.loc[index - 1, 'pest_load'] if index > 0 else 0.0
            
            summary_data.append({
                "Parameter Sweep": param_sweep,
                "Strategy": strategy,
                "Season": row['season'],
                "Spray Day (Cycle)": row['cycle'],
                "Pest Load Before": round(pest_before, 3),
                "Pest Load After": round(row['pest_load'], 3),
                "Cumulative Sprays": row['spray_count']
            })
    except Exception as e:
        print(f"Error processing {file}: {e}")

summary_df = pd.DataFrame(summary_data)
summary_df.to_csv("spray_intervals_summary.csv", index=False)
print("Exported spray_intervals_summary.csv with", len(summary_df), "spray events.")