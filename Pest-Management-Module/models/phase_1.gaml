/**
 * Name:        Phase 1
 * Description: Standalone pest management model simulating a full pest-crop-farmer
 *              loop. A Farmer agent observes pest_load each cycle and decides to
 *              spray based on one of three strategies: none, calendar, or
 *              threshold/EIL. Crop growth is driven by thermal time and RUE;
 *              pest pressure reduces biomass accumulation via a stage-weighted
 *              damage coefficient (k_pest).
 *
 * Agents:
 *   Global  : weather, phenology thresholds, season control, farmer parameters
 *   Crop    : thermal time accumulation, RUE-based growth, k_pest damage
 *   Plot    : pest load dynamics (generation, decay), spray counters, harvest
 *   Farmer  : decide_spray reflex -- dispatches none / calendar / threshold
 *
 * Strategies:
 *   "none"      - never spray (baseline: 43.75% yield loss at defaults, cultivars.csv OM5451)
 *   "calendar"  - spray every calendar_interval days regardless of pest_load
 *   "threshold" - spray when pest_load > pesticide_threshold AND cooldown elapsed
 *
 * STAR-FARM alignment:
 *   Spray effect: pest_load *= (1 - efficacy)  vs STAR-FARM: pest_load <- 0.0
 *   Threshold default 0.30 = sust_pesticide_threshold (Parameters.gaml)
 *   Calendar default 14 days ~ BAU Mekong Delta practice (~4 sprays/season)
 *
 * Author: Joanne Maryz Cabatingan
 */

model phase_1

global {

    // ---- Synthetic weather ------------------------------------------
    float t_mean    <- 28.0;
    float solar_rad <- 18.0;
    float humidity  <- 82.0;

    // ---- Thermal time ------------------------------------------------
    float Tbase <- 10.0;

    // ---- Crop growth -------------------------------------------------
    float potential_rue <- 0.768; // OM5451/OM6976: variety.RUE (1.2) * rue_efficiency_factor (0.64)
                                  // cultivars.csv + Parameters.gaml:106
                                  // treat as sensitivity parameter; range 0.64–0.77 across varieties
    float fAPAR_phase1  <- 0.2;		// values from STAR-FARM Parameters.gaml
    float fAPAR_phase2  <- 0.7;
    float fAPAR_phase3  <- 0.9;
    float fAPAR_phase4  <- 0.85;

    // ---- Pest parameters ---------------------------------------------
    float min_k_pest           <- 0.5; 		// inherited from STAR-FARM Parameters.gaml
    float pest_humidity_limit  <- 80.0;
    float pest_temp_limit      <- 27.0;
    float pest_infection_prob  <- 0.8;
    float pest_daily_increment <- 0.03;
    // ---- Life-table-derived proportional growth term (added June 22 2026) ----
    // rm = 0.0677/female/day (Win et al. 2011, Table 3); female_fraction = 0.488
    // (Win et al. 2011: sex ratio M:F = 0.512:0.488; supervisor-approved June 22 2026
    // to apply only the female fraction as reproducers).
    // pest_growth_rate = rm * female_fraction = 0.0677 * 0.488 = 0.033038
    // Update mechanism: pest_load += pest_daily_increment + (pest_load * pest_growth_rate)
    // Keeps the existing flat term (handles cold-start at pest_load=0, matches
    // STAR-FARM's lua_mdModel structure) and adds a proportional term so growth
    // scales with current pest_load, addressing the linear-vs-exponential gap
    // flagged in tab1.md S2.1. NOT a new equation: same additive update, one
    // extra multiplicative term using a literature-sourced rate.
    // TODO: update tab3.md (D3 design decisions, global var table, OPEN
    // CALIBRATION ITEMS, tab1.md S2.1 model implication) to document this change.
    float pest_growth_rate     <- 0.033038;
    
	// stage_weight
	// 		--> to address stage-specific damage
	//		--> using placeholder values inherited from STAR-FARM fAPAR values but rearranged to fit literature findings
    float sw_phase1 <- 0.2;
    float sw_phase2 <- 0.9;
    float sw_phase3 <- 0.7;
    float sw_phase4 <- 0.4;
    
    // pending value references; inherited from STAR-FARM's Parameters.gaml pollution_decay_rate	
    float pest_decay_coeff <- 0.9;

    // ---- Phenological thresholds ------------------------------------
    // inherited from STAR-FARM's OM5451 cultivars.csv
    float tt_emergence <- 70.0;   // cultivars.csv OM5451
	float tt_veg       <- 850.0;  // cultivars.csv OM5451
	float tt_rep       <- 430.0;  // cultivars.csv OM5451
	float harvest_index <- 0.52;
	
    float emergence_threshold <- 70.0;    // = tt_emergence
	float flowering_threshold <- 920.0;   // = tt_emergence + tt_veg
	float maturity_threshold  <- 1350.0;  // = tt_emergence + tt_veg + tt_rep

    // ---- Season control -------------------------------------------------------
    int season      <- 1;
    int max_seasons <- 3;

    // ---- Output helpers -------------------------------------------------------
    float biomass_to_ton_conv <- 0.01;

    // ---- Farmer decision parameters ---------------------------------
    // Strategy: "none" (no spray), "calendar" (fixed schedule), "threshold" (EIL-style)
    string farmer_strategy     <- "threshold";
    float  pesticide_threshold <- 0.3;    // spray if pest_load exceeds this (threshold strategy); STAR-FARM sustainable = 0.30, BAU ~ 0.20
    int    spray_cooldown      <- 7;       // min days between any two sprays (all strategies)
    
    int    calendar_interval   <- 14;      // days between sprays (calendar strategy only)
    float  efficacy            <- 0.8;     // fraction of pest_load eliminated per spray; replaces STAR-FARM's instant pest_load <- 0
    float  spray_cost          <- 100.0;   // cost per spray event (arbitrary units); placeholder
    float  initial_money       <- 5000.0;  // farmer starting budget; placeholder
    float grain_price <- 3000.0; // arbitrary; placeholder for VND/kg calibration

    // ---- Per-pesticide-class parameterization (added June 23 2026, UNCALIBRATED) ----
    // "starfarm" = current global efficacy/selection_pressure_constant behavior, unchanged.
    // "etofenprox"/"neonicotinoid" values below are PLACEHOLDERS for proposed structure only,
    // ordering reflects qualitative Khoa et al. 2018 claims (etofenprox lower resistance/resurgence
    // risk), not measured rates. Do not cite these numbers anywhere.
    string pesticide_choice <- "starfarm" among: ["starfarm", "etofenprox", "neonicotinoid"];

    // ---- Spray event marker (spikes the Pest pressure chart on a spray) -------
    int spray_event_p1 <- 0;

    // ---- Last-harvest snapshot (read by Sensitivity_Sweep batch experiment) ---
    float last_grain_tha   <- 0.0;  // grain yield t/ha of most recent harvest
    int   last_spray_count <- 0;    // spray count of most recent harvested season

    // ---- Batch infrastructure -----------------------------------------------
    bool   batch_mode <- false;   // true only in batch; gates harvest CSV, pause, daily log
    string run_id     <- "";      // unique per simulation
    bool   sweep_mode <- false;   // true only in the 4 Sweep_* experiments; gates sensitivity_output.csv writes

    // ---- Interval / threshold sweep gates (added June 29 2026) ----
    // Task 1: how does grain yield and spray count change across different
    // calendar_interval values, and across different pesticide_threshold values?
    // Each gate writes its own CSV, so there is no rename step needed between runs.
    bool   interval_sweep_mode  <- false;  // true only in Sweep_CalendarInterval; gates sensitivity_output_interval.csv
    bool   threshold_sweep_mode <- false;  // true only in Sweep_Threshold; gates sensitivity_output_threshold.csv

    init {
        emergence_threshold <- tt_emergence;
        flowering_threshold <- tt_emergence + tt_veg;
        maturity_threshold  <- tt_emergence + tt_veg + tt_rep;
        create Plot number: 1;
        create Farmer number: 1;
        run_id <- farmer_strategy + "_" + int(self);

        // Per-pesticide-class instances. PLACEHOLDER values for efficacy/selection_pressure,
        // see comment above pesticide_choice. cost is anchored to real Vietnamese retail
        // prices (see pesticide_class comment below). selection_pressure unused in phase_1
        // (no resistance ratchet here; carried for symmetry with phase_2's pesticide_class).
        create pesticide_class { name <- "etofenprox";   efficacy <- 0.7; resurgence_type <- "none";   selection_pressure <- 0.015; cost <- 110.6; }
        create pesticide_class { name <- "neonicotinoid"; efficacy <- 0.8; resurgence_type <- "chronic"; selection_pressure <- 0.025; cost <- 100.0; }
    }

    // reset the spray marker each cycle; Farmer sets it to 1 when a spray fires
    reflex reset_events { spray_event_p1 <- 0; }

    reflex stop_when_done when: season > max_seasons {
        write "All " + max_seasons + " season(s) complete. Strategy: " + farmer_strategy;
        if (not batch_mode) { do pause; }
    }
    
    reflex log_daily when: not batch_mode {
	    ask Plot where (each.associated_crop != nil) {
	        string f <- "daily_" + farmer_strategy + ".csv";
	        if (cycle = 1) {
	            save "cycle,season,strategy,pest_load,k_pest,spray_count,days_since_last_spray,biomass,cumulative_pest_exposure,days_above_threshold\n" to: f format: "text" rewrite: true;
	        }
	        string row <- "" + cycle + "," + season + "," + farmer_strategy + "," + pest_load + "," + associated_crop.k_pest + "," + spray_count + "," + days_since_last_spray + "," + associated_crop.biomass + "," + cumulative_pest_exposure + "," + days_above_threshold + "\n";
	        save row to: f format: "text" rewrite: false;
	    }
	}
}

// ===========================================================================
// pesticide_class: per-compound parameterization (added June 23 2026, UNCALIBRATED).
// See pesticide_choice comment in global{} for sourcing caveat.
// ===========================================================================

species pesticide_class {
    string name;
    float  efficacy;
    string resurgence_type;
    float  selection_pressure;
    // Per-spray cost, same scale as spray_cost=100. See phase_2.gaml's pesticide_class
    // for the full real-price derivation (Trebon 10EC / Actara 25WG, June 2026, MRD
    // retail prices, label doses confirmed for brown planthopper on rice).
    float  cost;
}

// ===========================================================================
// CROP
// ===========================================================================
// represents the single rice crop growing on the plot for one season
species Crop {

    float biomass         <- 0.0;       // total accumulated dry matter in g/m2
    float thermal_time    <- 0.0;       // accumulated heat units since sowing, drives growth stage transitions
    float growth_stage    <- 0.0;       // how far along the crop is from 0 (just sown) to 1 (mature), used for display only
    float pest_yield_loss <- 0.0;       // running total of biomass lost to pest damage across the season, in g/m2
    float k_pest          <- 1.0;       // damage multiplier on daily growth, ranges from min_k_pest to 1.0

    // ACCUMULATE REFLEX
    // runs every cycle to advance the crop through its growth stages
    reflex accumulate {
        // daily thermal time increment: how many degrees above the base temperature today was
        // if t_mean is below Tbase, dTT is 0 - the crop does not develop on cold days
        float dTT <- max(0.0, t_mean - Tbase);
        thermal_time <- thermal_time + dTT;  // add today's heat units to the running total
        growth_stage <- min(1.0, thermal_time / maturity_threshold);  // growth_stage is just thermal_time scaled to [0, 1] for display purposes
    }

    // GROW REFLEX
    // runs every cycle to compute biomass gained today after pest damage is applied
    reflex grow {
        // select fAPAR based on current growth stage
        // fAPAR is the fraction of solar radiation the canopy intercepts
        // it increases as the canopy develops and slightly drops at maturity
        float fAPAR <- fAPAR_phase1;
        if      (thermal_time < emergence_threshold) { fAPAR <- fAPAR_phase1; }
        else if (thermal_time < flowering_threshold) { fAPAR <- fAPAR_phase2; }
        else if (thermal_time < maturity_threshold)  { fAPAR <- fAPAR_phase3; }
        else                                         { fAPAR <- fAPAR_phase4; }

        // select stage_weight based on current growth stage
        // stage_weight controls how sensitive the crop is to pest damage at each phase
        // highest during vegetative (sw_phase2=0.9), lowest during grain fill (sw_phase4=0.4)
        float stage_weight <- sw_phase1;
        if      (thermal_time < emergence_threshold) { stage_weight <- sw_phase1; }
        else if (thermal_time < flowering_threshold) { stage_weight <- sw_phase2; }
        else if (thermal_time < maturity_threshold)  { stage_weight <- sw_phase3; }
        else                                         { stage_weight <- sw_phase4; }

        // read pest_load from the single Plot this crop is growing on
        // if somehow there is no Plot, assume zero pest pressure
        float plot_pest_load <- empty(Plot) ? 0.0 : first(Plot).pest_load;

        // compute the damage multiplier for today
        // higher pest_load and higher stage_weight both reduce k_pest
        // min_k_pest sets a floor so growth never drops to zero
        k_pest <- max(min_k_pest, 1.0 - (stage_weight * plot_pest_load));

        // what the crop would have grown today with no pest pressure
        float daily_growth_potential <- potential_rue * solar_rad * fAPAR;

        // what the crop actually grew today after pest damage
        float daily_growth_actual    <- daily_growth_potential * k_pest;

        // the difference is logged as pest-attributable yield loss
        // accumulates across the whole season and is reported at harvest
        pest_yield_loss <- pest_yield_loss + (daily_growth_potential - daily_growth_actual);

        // add today's actual growth to total biomass
        biomass         <- biomass + daily_growth_actual;
    }
}

// ===========================================================================
// PLOT
// the single farm plot in phase_1 (no spatial grid, no neighbors)
// ===========================================================================
species Plot {

    Crop  associated_crop     <- nil;   // the crop currently growing on this plot, nil if the plot is fallow
    bool  pending_sow         <- true;  // flag that tells the plot to sow a new crop on the next cycle
    float pest_load           <- 0.0;   // current pest pressure on this plot, normalized between 0 (none) and 1 (maximum)
    int   days_since_last_spray <- 0;   // resets to 0 after each spray and at sowing
    int   spray_count         <- 0;     // total sprays this season

    // ---- Daily-log indicators (added June 23 2026) ----
    float cumulative_pest_exposure <- 0.0;  // running sum of daily pest_load across the season
    int   days_above_threshold     <- 0;    // running count of days pest_load > pesticide_threshold

    // SOW CROP REFLEX
    // fires when pending_sow is true - creates a new crop and resets plot state for the new season
    reflex sow_crop when: pending_sow {
        // reset pest, spray, and daily-log state at the start of each season
        pest_load            <- 0.0;
        days_since_last_spray <- 0;
        spray_count          <- 0;
        cumulative_pest_exposure <- 0.0;
        days_above_threshold     <- 0;

        // create a new crop agent and attach it to this plot
        create Crop returns: c;
        associated_crop <- first(c);

        // clear the flag so this reflex does not fire again until the next season
        pending_sow <- false;
        write "Day " + cycle + " | Season " + season + ": sown. Strategy=" + farmer_strategy;
    }

    // UPDATE PEST REFLEX
    // runs every cycle while a crop is present to grow today's pest pressure
    reflex update_pest when: associated_crop != nil {
        // three conditions must all pass before pest_load increments:
        //      1. Humidity exceeds the minimum threshold for BPH activity  (humidity > pest_humidity_limit)
        //      2. Temperature exceeds the minimum threshold for BPH activity  (t_mean > pest_temp_limit)
        //      3. A probabilistic flip weighted by pest_infection_prob succeeds  (flip(pest_infection_prob))
        // this models the stochastic, weather-dependent nature of daily BPH infection events.
        if (humidity > pest_humidity_limit and t_mean > pest_temp_limit and flip(pest_infection_prob)) {
            pest_load <- pest_load + pest_daily_increment + (pest_load * pest_growth_rate);
        }

        // pest_load is a normalized scalar, not a population count
        pest_load <- min(1.0, pest_load);

        // daily-log indicators: accumulate exposure and count days over threshold
        cumulative_pest_exposure <- cumulative_pest_exposure + pest_load;
        if (pest_load > pesticide_threshold) { days_above_threshold <- days_above_threshold + 1; }
    }

    // ADVANCE COUNTERS REFLEX
    // runs every cycle while a crop is present
    // increments the spray cooldown counter each day
    // Farmer's spray reflex may reset this to 0 later in the same cycle
    reflex advance_counters when: associated_crop != nil {
        days_since_last_spray <- days_since_last_spray + 1;
    }

    // PEST DECAY REFLEX
    // runs on the fallow plot (no crop) that still has residual pest pressure
    // models natural pest die-off between seasons
    // pest_decay_coeff controls how fast it drops: 0.0 means instant wipeout, 1.0 means no decay
    reflex pest_decay when: associated_crop = nil and pest_load > 0.0 {
        pest_load <- pest_load * pest_decay_coeff;
    }

    // CHECK MATURITY REFLEX
    // fires once the crop's thermal_time reaches maturity_threshold
    // harvests the crop, pays the farmer, logs results, and advances the season
    reflex check_maturity when: associated_crop != nil and associated_crop.thermal_time >= maturity_threshold {
        // convert accumulated biomass to grain yield in tonnes per hectare
        // harvest_index is the fraction of total biomass that becomes grain
        // biomass_to_ton_conv scales from g/m2 to t/ha
        float grain_tha      <- associated_crop.biomass * harvest_index * biomass_to_ton_conv;

        // convert accumulated pest damage to yield loss in the same units
        // pest_yield_loss tracks the biomass that was lost to pests each day
        float yield_loss_tha <- associated_crop.pest_yield_loss * harvest_index * biomass_to_ton_conv;

        float farmer_money   <- empty(Farmer) ? 0.0 : first(Farmer).money;
        last_grain_tha   <- grain_tha;     // snapshot before the crop dies, so the batch can read it
        last_spray_count <- spray_count;
        write "Day " + cycle + " | Season " + season + ": harvested. Strategy=" + farmer_strategy + ". Grain=" + (grain_tha with_precision 2) + "t/ha. PestLoss=" + (yield_loss_tha with_precision 2) + "t/ha. Sprays=" + spray_count + ". Money=" + (farmer_money with_precision 0) + ".";

        // active compound's cost, for the cost_per_spray CSV column below. pesticide_choice
        // is fixed for the whole run, so this mirrors the lookup in Farmer.decide_spray.
        float logged_cost <- spray_cost;
        if (pesticide_choice != "starfarm") {
            pesticide_class pcc <- pesticide_class first_with (each.name = pesticide_choice);
            if (pcc != nil) { logged_cost <- pcc.cost; }
        }

        // compute revenue from grain yield at the current grain price
        // grain_price is an arbitrary placeholder unit, relative rankings are meaningful, absolute values are not
        float revenue <- grain_tha * grain_price;
		ask Farmer { money <- money + revenue; }

        // log harvest summary to harvest_output.csv, one row per season per run
        if (batch_mode) {
            float end_money <- empty(Farmer) ? 0.0 : first(Farmer).money;
            string hrow <- "" + run_id + "," + farmer_strategy + "," + season + ","
                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + end_money + "," + logged_cost + "\n";
            save hrow to: "harvest_output.csv" format: "text" rewrite: false;
        }

        // log sensitivity-sweep summary to sensitivity_output.csv, gated separately from batch_mode
        // logged_efficacy resolves to the active pesticide_class's efficacy when pesticide_choice != "starfarm"
        if (sweep_mode) {
            float end_money2 <- empty(Farmer) ? 0.0 : first(Farmer).money;
            float logged_efficacy <- efficacy;
            if (pesticide_choice != "starfarm") {
                pesticide_class pc2 <- pesticide_class first_with (each.name = pesticide_choice);
                if (pc2 != nil) { logged_efficacy <- pc2.efficacy; }
            }
            string srow <- "" + run_id + "," + farmer_strategy + "," + logged_efficacy + "," + pest_daily_increment + "," + season + ","
                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + end_money2 + "," + logged_cost + "\n";
            save srow to: "sensitivity_output.csv" format: "text" rewrite: false;
        }

        // log interval-sweep summary (Task 1, added June 29 2026): how spray count
        // and yield change across different calendar_interval values
        if (interval_sweep_mode) {
            float end_money3 <- empty(Farmer) ? 0.0 : first(Farmer).money;
            string irow <- "" + run_id + "," + farmer_strategy + "," + calendar_interval + "," + season + ","
                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + end_money3 + "," + logged_cost + "\n";
            save irow to: "sensitivity_output_interval.csv" format: "text" rewrite: false;
        }

        // log threshold-sweep summary (Task 1, added June 29 2026): how spray count
        // and yield change across different pesticide_threshold values
        if (threshold_sweep_mode) {
            float end_money4 <- empty(Farmer) ? 0.0 : first(Farmer).money;
            string trow <- "" + run_id + "," + farmer_strategy + "," + pesticide_threshold + "," + season + ","
                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + end_money4 + "," + logged_cost + "\n";
            save trow to: "sensitivity_output_threshold.csv" format: "text" rewrite: false;
        }

        // remove the crop agent from the simulation, it has served its purpose
        ask associated_crop { do die; }

        // detach the crop reference from this plot so the plot is ready to sow again
        associated_crop <- nil;

        // advance the season counter
        season <- season + 1;

        // if more seasons remain, flag the plot to sow a new crop next cycle
        if (season <= max_seasons) { pending_sow <- true; }
    }
}

// ===========================================================================
// FARMER
// the single farmer agent that manages the plot each cycle
// ===========================================================================
species Farmer {

    // running total of money across all seasons
    // starts at initial_money and changes with spray costs and harvest revenue
    float money <- initial_money;

    // DECIDE SPRAY REFLEX
    // runs every cycle and checks the plot to decide whether to spray
    // executes after Plot's update_pest, so it observes today's post-update pest_load.
    // spray effect (reduced pest_load) is seen in next cycle's Crop growth.
    reflex decide_spray when: not empty(Plot) and first(Plot).associated_crop != nil {
        Plot the_plot <- first(Plot);

        // check if enough days have passed since the last spray
        bool cooldown_ok <- the_plot.days_since_last_spray >= spray_cooldown;
        bool should_spray <- false;

        // spray decision depends on the current strategy:
        // none      - never spray
        // calendar  - spray whenever the fixed interval has elapsed, ignoring pest levels
        // threshold - spray only when cooldown is satisfied AND pest_load exceeds the threshold
        if (farmer_strategy = "none") {
            should_spray <- false;
        } else if (farmer_strategy = "calendar") {
            should_spray <- the_plot.days_since_last_spray >= calendar_interval;
        } else {
            should_spray <- cooldown_ok and (the_plot.pest_load > pesticide_threshold);
        }

        if (should_spray) {
		    float pest_before <- the_plot.pest_load;  // snapshot pest_load before spraying for the console log

		    // active compound's efficacy and cost (starfarm = unchanged globals)
		    float active_efficacy <- efficacy;
		    float active_cost <- spray_cost;
		    if (pesticide_choice != "starfarm") {
		        pesticide_class pc <- pesticide_class first_with (each.name = pesticide_choice);
		        if (pc != nil) { active_efficacy <- pc.efficacy; active_cost <- pc.cost; }
		    }

		    // apply the spray: reduce pest_load by the active efficacy fraction
		    // pest_load is not zeroed out - partial suppression keeps the sawtooth dynamics realistic
		    the_plot.pest_load <- the_plot.pest_load * (1.0 - active_efficacy);
		    the_plot.days_since_last_spray <- 0;      // reset the cooldown counter
		    the_plot.spray_count <- the_plot.spray_count + 1;  // increment this plot's spray count for the season
		    money <- money - active_cost;              // deduct spray cost from the farmer's money, compound-specific

		    // flag that a spray happened this cycle, used by the Pest pressure chart
	    	world.spray_event_p1 <- 1;

		    // log spray details to the console
		    write "  -> Spray " + the_plot.spray_count + " on day " + cycle + 
		          ". pest_load_before=" + (pest_before with_precision 3) + 
		          ". pest_load_after=" + (the_plot.pest_load with_precision 3) + 
		          ". Money=" + (money with_precision 0);
		}
    }
}

// ===========================================================================
// EXPERIMENT
// ===========================================================================
experiment FarmerDecision type: gui {

    parameter "t_mean (deg C)"               var: t_mean              min: 20.0  max: 40.0;
    parameter "solar_rad (MJ/m2/day)"        var: solar_rad           min: 5.0   max: 30.0;
    parameter "humidity (%)"                 var: humidity            min: 50.0  max: 100.0;
    parameter "Tbase (deg C)"                var: Tbase               min: 5.0   max: 15.0;
    parameter "potential_rue (g/MJ)"         var: potential_rue       min: 0.5   max: 3.0;
    parameter "tt_veg (deg-C*day)"           var: tt_veg              min: 300.0 max: 1200.0;
    parameter "tt_rep (deg-C*day)"           var: tt_rep              min: 200.0 max: 800.0;
    parameter "harvest_index"                var: harvest_index       min: 0.3   max: 0.6;
    parameter "Seasons to simulate"          var: max_seasons         min: 1     max: 5;
    parameter "pest_daily_increment"         var: pest_daily_increment min: 0.01 max: 0.1;
    parameter "pest_growth_rate (life-table)" var: pest_growth_rate    min: 0.0   max: 0.1;
    parameter "min_k_pest"                   var: min_k_pest          min: 0.1   max: 1.0;
    parameter "pest_decay_coeff"             var: pest_decay_coeff    min: 0.0   max: 1.0;

    // Farmer Decision parameters
    parameter "Strategy (none/calendar/threshold)" var: farmer_strategy among: ["none", "calendar", "threshold"];
    parameter "Pesticide class"              var: pesticide_choice    among: ["starfarm", "etofenprox", "neonicotinoid"];
    parameter "pesticide_threshold"          var: pesticide_threshold min: 0.05  max: 1.0;
    parameter "spray_cooldown (days)"        var: spray_cooldown      min: 1     max: 30;
    parameter "calendar_interval (days)"     var: calendar_interval   min: 7     max: 30;
    parameter "efficacy (0 to 1)"            var: efficacy            min: 0.1   max: 1.0;
    parameter "spray_cost"                   var: spray_cost          min: 0.0   max: 1000.0;
    parameter "initial_money"                var: initial_money       min: 0.0   max: 50000.0;
    parameter "grain_price (per t/ha)"       var: grain_price         min: 0.0   max: 10000.0;

    output {
        monitor "Day"                value: cycle;
        monitor "Season"             value: season;
        monitor "Strategy"           value: farmer_strategy;
        monitor "Biomass (g/m2)"     value: empty(Crop) ? 0.0 : first(Crop).biomass;
        monitor "Pest load"          value: empty(Plot) ? 0.0 : first(Plot).pest_load;
        monitor "k_pest"             value: empty(Crop) ? 1.0 : first(Crop).k_pest;
        monitor "Spray count"        value: empty(Plot) ? 0   : first(Plot).spray_count;
        monitor "Money"              value: empty(Farmer) ? 0.0 : first(Farmer).money;
        monitor "Grain yield t/ha"   value: empty(Crop) ? 0.0 : first(Crop).biomass * harvest_index * biomass_to_ton_conv;
        monitor "Pest yield loss t/ha" value: empty(Crop) ? 0.0 : first(Crop).pest_yield_loss * harvest_index * biomass_to_ton_conv;

        display "Biomass" {
            chart "Biomass (g/m2)" type: series background: #white {
                data "Biomass" value: empty(Crop) ? 0.0 : first(Crop).biomass color: #darkgreen style: line marker: false;
            }
        }

        // Pest load: spray events visible as sharp drops, then regrowth
        // "none" strategy
        // "threshold/calendar": sawtooth pattern (grow -> spray -> drop -> grow)
        display "Pest pressure" {
            chart "Pest load (0 to 1)" type: series background: #white {
                data "Pest load" value: empty(Plot) ? 0.0 : first(Plot).pest_load color: #red style: line marker: false;
                data "Spray" value: spray_event_p1 * (empty(Plot) ? 0.0 : first(Plot).pest_load) color: #red style: bar marker: false;
            }
        }

        // k_pest: recovers after each spray (pest_load drops -> k_pest rises)
        display "Damage multiplier" {
            chart "k_pest (1 = no damage)" type: series background: #white {
                data "k_pest" value: empty(Crop) ? 1.0 : first(Crop).k_pest color: #darkred style: line marker: false;
            }
        }

        // Farmer money: flat for "none", decreases in steps for calendar and threshold
        // Each step = one spray event costing spray_cost units
        display "Farmer" {
            chart "Farmer money" type: series background: #white {
                data "Money" value: empty(Farmer) ? 0.0 : first(Farmer).money color: #blue style: line marker: false;
            }
        }
    }
}

// ===========================================================================
// BATCH: one row per harvest (season) per run -> harvest_output.csv
// runs each strategy `repeat` times with different seeds (flip variance)
// ===========================================================================
experiment Batch_Harvest type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"   var: farmer_strategy among: ["none", "calendar", "threshold"];
    parameter "Batch mode" var: batch_mode      among: [true];

    init {
        // header once + clears old file (auto-handles the delete-CSV step)
        save "run_id,strategy,season,grain_tha,pest_loss_tha,spray_count,end_money,cost_per_spray\n"
             to: "harvest_output.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// SWEEP: one-at-a-time sensitivity sweep, run #1 of 4 -- efficacy=0.6
// all other params at model default (pest_daily_increment=0.03, threshold=0.3)
// crosses with all 3 strategies, repeat 15 each. Separate CSV per sweep value
// so results never mix; rename/move sensitivity_output.csv between runs
// or it will be overwritten by the next sweep experiment's init.
// ===========================================================================
experiment Sweep_Efficacy_06 type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"   var: farmer_strategy among: ["none", "calendar", "threshold"];
    parameter "Batch mode" var: batch_mode      among: [true];
    parameter "Sweep mode" var: sweep_mode      among: [true];
    parameter "efficacy"   var: efficacy        among: [0.6];

    init {
        save "run_id,strategy,efficacy,increment,season,grain_tha,pest_loss_tha,spray_count,end_money,cost_per_spray\n"
             to: "sensitivity_output.csv" format: "text" rewrite: true;
    }
}

// Run #2 of 4 -- efficacy=0.9.
experiment Sweep_Efficacy_09 type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"   var: farmer_strategy among: ["none", "calendar", "threshold"];
    parameter "Batch mode" var: batch_mode      among: [true];
    parameter "Sweep mode" var: sweep_mode      among: [true];
    parameter "efficacy"   var: efficacy        among: [0.9];

    init {
        save "run_id,strategy,efficacy,increment,season,grain_tha,pest_loss_tha,spray_count,end_money,cost_per_spray\n"
             to: "sensitivity_output.csv" format: "text" rewrite: true;
    }
}

// Run #3 of 4 -- pest_daily_increment=0.05.
experiment Sweep_Increment_05 type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"   var: farmer_strategy      among: ["none", "calendar", "threshold"];
    parameter "Batch mode" var: batch_mode           among: [true];
    parameter "Sweep mode" var: sweep_mode           among: [true];
    parameter "increment"  var: pest_daily_increment among: [0.05];

    init {
        save "run_id,strategy,efficacy,increment,season,grain_tha,pest_loss_tha,spray_count,end_money,cost_per_spray\n"
             to: "sensitivity_output.csv" format: "text" rewrite: true;
    }
}

// Run #4 of 4 -- pest_daily_increment=0.10.
experiment Sweep_Increment_10 type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"   var: farmer_strategy      among: ["none", "calendar", "threshold"];
    parameter "Batch mode" var: batch_mode           among: [true];
    parameter "Sweep mode" var: sweep_mode           among: [true];
    parameter "increment"  var: pest_daily_increment among: [0.10];

    init {
        save "run_id,strategy,efficacy,increment,season,grain_tha,pest_loss_tha,spray_count,end_money,cost_per_spray\n"
             to: "sensitivity_output.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// SWEEP: per-pesticide-class comparison sweeps (added June 23 2026). UNCALIBRATED
// placeholder values, see pesticide_choice comment in global{}. Separate CSV
// per compound, same pattern as Sweep_Efficacy_*
// ===========================================================================
experiment Sweep_Pesticide_Etofenprox type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"         var: farmer_strategy among: ["none", "calendar", "threshold"];
    parameter "Batch mode"       var: batch_mode      among: [true];
    parameter "Sweep mode"       var: sweep_mode      among: [true];
    parameter "Pesticide class"  var: pesticide_choice among: ["etofenprox"];

    init {
        save "run_id,strategy,efficacy,increment,season,grain_tha,pest_loss_tha,spray_count,end_money,cost_per_spray\n"
             to: "sensitivity_output.csv" format: "text" rewrite: true;
    }
}

experiment Sweep_Pesticide_Neonicotinoid type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"         var: farmer_strategy among: ["none", "calendar", "threshold"];
    parameter "Batch mode"       var: batch_mode      among: [true];
    parameter "Sweep mode"       var: sweep_mode      among: [true];
    parameter "Pesticide class"  var: pesticide_choice among: ["neonicotinoid"];

    init {
        save "run_id,strategy,efficacy,increment,season,grain_tha,pest_loss_tha,spray_count,end_money,cost_per_spray\n"
             to: "sensitivity_output.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// SWEEP: spray_cost sensitivity sweep (added June 23 2026). Bracket 50/150 around
// the current placeholder default of 100. spray_cost doesn't change spray
// decisions (threshold/calendar don't check cost), but changes net profit
// outcomes for a fixed spray pattern -- tests whether the existing
// season-over-season profit decline (driven by resistance eroding efficacy)
// is sensitive to the cost assumption or robust regardless of it.
// ===========================================================================
experiment Sweep_SprayCost_50 type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"    var: farmer_strategy among: ["none", "calendar", "threshold"];
    parameter "Batch mode"  var: batch_mode      among: [true];
    parameter "Sweep mode"  var: sweep_mode      among: [true];
    parameter "spray_cost"  var: spray_cost      among: [50.0];

    init {
        save "run_id,strategy,efficacy,increment,season,grain_tha,pest_loss_tha,spray_count,end_money,cost_per_spray\n"
             to: "sensitivity_output.csv" format: "text" rewrite: true;
    }
}

experiment Sweep_SprayCost_150 type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"    var: farmer_strategy among: ["none", "calendar", "threshold"];
    parameter "Batch mode"  var: batch_mode      among: [true];
    parameter "Sweep mode"  var: sweep_mode      among: [true];
    parameter "spray_cost"  var: spray_cost      among: [150.0];

    init {
        save "run_id,strategy,efficacy,increment,season,grain_tha,pest_loss_tha,spray_count,end_money,cost_per_spray\n"
             to: "sensitivity_output.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// SWEEP: calendar interval and pesticide threshold (Task 1, added June 29 2026).
// Each writes its own dedicated CSV, so there is no rename step needed between
// the two runs, unlike the pesticide-class sweeps above. Strategy is held fixed
// per experiment since the swept parameter only matters for that one strategy:
// calendar_interval only affects "calendar", pesticide_threshold only affects
// "threshold".
// ===========================================================================
experiment Sweep_CalendarInterval type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"            var: farmer_strategy      among: ["calendar"];
    parameter "Batch mode"          var: batch_mode           among: [true];
    parameter "Interval sweep mode" var: interval_sweep_mode  among: [true];
    parameter "calendar_interval"   var: calendar_interval    among: [7, 10, 14, 21, 28];

    init {
        save "run_id,strategy,calendar_interval,season,grain_tha,pest_loss_tha,spray_count,end_money,cost_per_spray\n"
             to: "sensitivity_output_interval.csv" format: "text" rewrite: true;
    }
}

experiment Sweep_Threshold type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"             var: farmer_strategy        among: ["threshold"];
    parameter "Batch mode"           var: batch_mode             among: [true];
    parameter "Threshold sweep mode" var: threshold_sweep_mode   among: [true];
    parameter "pesticide_threshold"  var: pesticide_threshold    among: [0.1, 0.2, 0.3, 0.4, 0.5];

    init {
        save "run_id,strategy,pesticide_threshold,season,grain_tha,pest_loss_tha,spray_count,end_money,cost_per_spray\n"
             to: "sensitivity_output_threshold.csv" format: "text" rewrite: true;
    }
}
