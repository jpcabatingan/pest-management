/**
 * Name:        phase_2
 * Description: 10x10 spatial pest model with BPH sprite visuals.
 *
 *              SIMULATION:
 *                - 10x10 Plot grid, Moore neighbours (8)
 *                - Layer 1 crop growth (thermal time, fAPAR, RUE)
 *                - Layer 2 pest generation + synchronous diffusion (pest_step)
 *                - Layer 3 farmer strategies (none / calendar / threshold)
 *                - resistance ratchet (realized_efficacy = efficacy * (1 - resist))
 *                - multi-season harvest loop
 *
 *              VISUALS (borrowed from pest_hunting_game Model 2.1):
 *                - rice-field 4-step damage palette on each plot (aspect field)
 *                - BPH sprite agents (bph.png) that crawl on the plots, with
 *                  count per plot proportional to pest_load (create/die sync),
 *                  tinted red -> magenta as that plot's resistance climbs
 *                - overlay HUD with day / season / strategy / pest / money
 *                - population / resistance / money charts
 *
 *              The Bph agents are PURELY COSMETIC. They carry no model state and
 *              do not feed back into pest_load. The science is unchanged; only
 *              the rendering differs. The original continuous heatmap is kept as
 *              a second display ("Pest map (raw)") for side-by-side comparison.
 *
 * Author: Joanne Maryz Cabatingan
 */

model phase_2

global {

    // ---- Synthetic weather ------------------------------------------
    float t_mean    <- 28.0;
    float solar_rad <- 18.0;
    float humidity  <- 82.0;

    // ---- Thermal time ------------------------------------------------
    float Tbase <- 10.0;

    // ---- Crop growth -------------------------------------------------
    float potential_rue <- 0.768;  // OM5451: RUE (1.2) * rue_efficiency_factor (0.64), cultivars.csv

    // inherited from STAR-FARM's Parameters.gaml
    float fAPAR_phase1  <- 0.2;
    float fAPAR_phase2  <- 0.7;
    float fAPAR_phase3  <- 0.9;
    float fAPAR_phase4  <- 0.85;

    // ---- Pest parameters ---------------------------------------------
    float min_k_pest           <- 0.5;
    float pest_humidity_limit  <- 80.0;
    float pest_temp_limit      <- 27.0;
    float pest_infection_prob  <- 0.8;
    float pest_daily_increment <- 0.03;
    
    // ---- Life-table-derived proportional growth term ----
    // rm = 0.0677/female/day (Win et al. 2011, Table 3); female_fraction = 0.488
    // (Win et al. 2011: sex ratio M:F = 0.512:0.488; female fraction only as reproducers).
    // pest_growth_rate = rm * female_fraction = 0.0677 * 0.488 = 0.033038
    // Update mechanism: pest_load += pest_daily_increment + (pest_load * pest_growth_rate)
    // The flat term handles cold-start at pest_load=0; the proportional term scales
    // growth with current pest_load using a literature-sourced rate.
    float pest_growth_rate     <- 0.033038;

	// placeholder values: literature supports damage ranking but not actual values

    float sw_phase1 <- 0.7;
    float sw_phase2 <- 0.6;
    float sw_phase3 <- 0.5;
    float sw_phase4 <- 0.3;

    float pest_decay_coeff <- 0.9;

    // ---- Phenological thresholds ------------------------------------
    float tt_emergence <- 70.0;    // cultivars.csv OM5451
    float tt_veg       <- 850.0;   // cultivars.csv OM5451
    float tt_rep       <- 430.0;   // cultivars.csv OM5451
    float emergence_threshold <- 70.0;    // = tt_emergence
    float flowering_threshold <- 920.0;   // = tt_emergence + tt_veg
    float maturity_threshold  <- 1350.0;  // = tt_emergence + tt_veg + tt_rep

    // ---- Season control -------------------------------------------------------
    int season      <- 1;
    int max_seasons <- 3;

    // ---- Output helpers -------------------------------------------------------
    float biomass_to_ton_conv <- 0.01;
    float harvest_index       <- 0.52;   // cultivars.csv OM5451

    // ---- Farmer decision parameters ---------------------------------
    string farmer_strategy     <- "threshold";   			// can be modified in simulation
    float  pesticide_threshold <- 0.3;
    int    spray_cooldown      <- 7; 						// placeholder
    int    calendar_interval   <- 14;  						// literature-backed
    float  efficacy            <- 0.8;  					// placeholder

	// farmer money
    float  spray_cost          <- 100.0;					// placeholder
    float  initial_money       <- 5000.0;					// placeholder
    float grain_price <- 3000.0; 							// arbitrary units per t/ha; placeholder for VND/kg calibration

    // to track what events happened for reference to other graphs
    int spray_event   <- 0;  								// 1 on any cycle where any plot is sprayed, else 0
	int harvest_event <- 0;  								// 1 on the cycle harvest occurs, else 0

    // ---- Phase 2 extended parameters ------------------------------------------
	// placeholders
    float diffusion_prop              <- 0.1;
    float selection_pressure_constant <- 0.02;

    // ---- Per-pesticide-class parameterization (UNCALIBRATED) ----
    // "starfarm" = global efficacy/selection_pressure_constant behavior, unchanged.
    // "etofenprox"/"neonicotinoid" values are PLACEHOLDERS for proposed structure only:
    // ordering reflects qualitative Khoa et al. (2018) claims (etofenprox lower resistance/resurgence
    // risk), not measured rates. Do not cite these numbers.
    string pesticide_choice <- "starfarm" among: ["starfarm", "etofenprox", "neonicotinoid"];

    // ---- Outbreak / diffusion demo controls -----------------------------------
    bool  localized_infection <- false;
    float outbreak_seed       <- 0.5;
    int   outbreak_cx         <- 4;
    int   outbreak_cy         <- 4;

    // ---- VISUAL layer ---------------------------------------------------------
    // note: bph sprites are for visual presentation purposes only
    int   max_bph_per_plot <- 18;   // sprites shown when a plot is fully infested

    // ---- Batch infrastructure -------------------------------------------------
    bool   batch_mode <- false;   // true only in batch; gates sprites, pause, grid CSV
    string run_id     <- "";      // unique per simulation

    // ---- Interval / threshold sweep gates ----
    // phase_2-native version: tracks resistant_fraction in the same run, unlike phase_1
    // where resistance has to be combined afterward from separate experiments.
    bool   interval_sweep_mode  <- false;  // true only in Sweep_CalendarInterval_Grid
    bool   threshold_sweep_mode <- false;  // true only in Sweep_Threshold_Grid

    // ---- Per-compound threshold sweep gates ----
    // Same as the threshold sweep above, but with pesticide_choice fixed to a specific
    // compound so resistant_fraction reflects that compound's own selection_pressure
    // and efficacy. The starfarm-only sweep cannot be rescaled because threshold
    // spray cadence depends on efficacy, which differs per compound.
    bool   threshold_sweep_mode_etofenprox <- false;  // true only in Sweep_Threshold_Grid_Etofenprox
    bool   threshold_sweep_mode_neonic     <- false;  // true only in Sweep_Threshold_Grid_Neonicotinoid

    // ---- Compound baseline gates ----
    // Standard 3-strategy baseline with pesticide_choice fixed to a specific compound,
    // so etofenprox and neonicotinoid have a side-by-side baseline comparison,
    // not just the threshold sweep.
    bool   compound_baseline_etofenprox <- false;  // true only in Batch_Harvest_Grid_Etofenprox
    bool   compound_baseline_neonic     <- false;  // true only in Batch_Harvest_Grid_Neonicotinoid

    // ---- Long-term resistance experiment gate ----
    // Runs all 3 strategies x all 3 compounds for 30 seasons (10 years).
    // Tracks resistant_fraction trajectory to identify which strategy and compound
    // combination reaches 90% resistance fastest and whether any strategy stays
    // profitable long-term despite resistance buildup.
    bool   longterm_mode <- false;  // true only in Batch_LongTerm_Grid

    // ---- Resistance decay via immigration (UNCALIBRATED) ----
    // BPH is a long-distance wind-borne migrant. Between seasons, susceptible
    // individuals from unsprayed source populations (including MRD as an
    // overwintering source for East Asian migration) dilute local resistant
    // allele frequencies. Modeled as proportional decay applied once per season
    // boundary: resistant_fraction *= (1 - immigration_rate).
    // Literature: Daly et al. 1988 (Genetica); BPH migration confirmed for MRD
    // (Khoa et al. 2018; genomic migration study PMC12542306).
    // Default 0.05 = 5% replaced by susceptible immigrants per inter-season period.
    // PLACEHOLDER: not empirically calibrated. Set to 0.0 for no decay.
    float  immigration_rate <- 0.05;

    // ---- Resistance decay via fitness cost (UNCALIBRATED) ----
    // Distinct mechanism from immigration_rate above. immigration_rate dilutes RF
    // with susceptible individuals arriving FROM OUTSIDE the grid. This term instead
    // models an INTRINSIC decline in the resistant allele's frequency even with zero
    // immigration, because resistant individuals carry a fitness cost and are
    // out-competed by susceptible individuals already in the local population.
    // Literature: Yu et al. (2018) found that under density pressure, susceptible
    // N. lugens individuals (HZ-S) outcompeted imidacloprid-resistant individuals
    // (HZ-R, RR 227.10) from the same source population: a direct fitness-cost
    // finding, confirmed via abstract (see tab1_Pesticide Practices & Risk.md Section 3).
    // Applied once per season boundary, same point as immigration decay, but
    // multiplicatively independent so the two mechanisms can be swept separately:
    // resistant_fraction *= (1 - immigration_rate) * (1 - resistance_fitness_cost).
    // Default 0.0 = off (matches pre-existing behavior when this parameter is unused).
    // PLACEHOLDER: no per-season fitness-cost rate is available in the literature found;
    // Yu (2018) establishes the mechanism qualitatively, not a decay rate.
    float  resistance_fitness_cost <- 0.0;

    // ---- Cross-resistance spillover (PLACEHOLDER) ----
    // When > 0.0, a fraction of the other compound's resistant_fraction spills over
    // into the effective resistance for this compound's spray. 0.0 = no cross-resistance
    // (fully independent pools). 1.0 = complete spillover (old single-pool behavior).
    // Default 0.0 follows Zhang et al. (2022): no cross-resistance at moderate levels.
    float  spillover_k <- 0.0;

    // ---- Pesticide rotation (UNCALIBRATED) ----
    // Alternates between two compound classes each season to slow resistance buildup.
    // When rotation_mode=true, pesticide_choice is overwritten at each season boundary:
    // rotation_compound_a on odd seasons (1, 3, 5, ...), rotation_compound_b on
    // even seasons (2, 4, 6, ...).
    // Literature: Zhang et al. (2022) found no cross-resistance between acetamiprid-resistant
    // BPH and etofenprox at low levels, supporting rotation early in selection history.
    // Set rotation_mode=false for single-compound behavior across all seasons.
    bool   rotation_mode       <- false;
    string rotation_compound_a <- "etofenprox";
    string rotation_compound_b <- "neonicotinoid";

    // ---- Compound sequence sweep (farmer-adaptation exploration) ----
    // Generalizes rotation_mode beyond strict A-B alternation. rotation_pattern is a
    // string over {A, B} that repeats every length(rotation_pattern) seasons: 'A' maps
    // to rotation_compound_a, 'B' to rotation_compound_b. Default "AB" reproduces the
    // exact old odd/even alternation (season-boundary logic below), so existing
    // experiments (Batch_Rotation_Grid, Sweep_CalendarInterval_Grid_Rotation,
    // Sweep_Threshold_Grid_Rotation) are unaffected by this change.
    // Special value "REACTIVE" switches from a fixed pattern to a non-deterministic
    // rule: at each season boundary, spray whichever compound's grid-mean
    // resistant_fraction pool is currently lower. This is a simple greedy
    // farmer-adaptation policy, not a fixed schedule; the choice depends on
    // simulation state.
    // ASSUMES rotation_compound_a="etofenprox" and rotation_compound_b="neonicotinoid"
    // (true for every experiment using this so far); the REACTIVE branch hardcodes the
    // rf_etofenprox/rf_neonicotinoid pool lookup accordingly rather than doing a
    // generic name-based lookup.
    string rotation_pattern    <- "AB";
    bool   sequence_sweep_mode_calendar  <- false;  // true only in Sweep_CompoundSequence_Grid_Calendar
    bool   sequence_sweep_mode_threshold <- false;  // true only in Sweep_CompoundSequence_Grid_Threshold

    // ---- Farmer heterogeneity (PLACEHOLDER distributions) ----
    // When heterogeneous_mode=true, each plot is independently assigned a strategy
    // and pesticide class at init from the distribution below, rather than sharing
    // the global farmer_strategy and pesticide_choice. Assignment persists for the
    // plot's lifetime (not re-drawn at sow_crop).
    // Used to test cross-farmer dynamics: does a minority of threshold farmers
    // benefit from calendar-spraying neighbors? Do non-sprayers free-ride?
    // Fractions must sum to 1.0 per distribution. PLACEHOLDER: no empirical MRD adoption data.
    bool   heterogeneous_mode        <- false;
    float  hetero_frac_none          <- 0.2;
    float  hetero_frac_calendar      <- 0.4;
    float  hetero_frac_etofenprox    <- 0.5;

    // ---- Immigration rate sweep gate ----
    // Varies immigration_rate across [0.0, 0.01, 0.05, 0.1, 0.2] to isolate the
    // effect of seasonal resistance dilution by susceptible migrants.
    // Uses starfarm compound, 30 seasons, all 3 strategies.
    bool   sweep_immigration_mode <- false;  // true only in Sweep_Immigration_Grid

    // ---- Extended immigration rate sweep gate ----
    // Covers the high range [0.30, 0.50, 0.70, 0.90, 1.00] that Sweep_Immigration_Rate
    // does not, to find the rate above which resistance never fixates. Writes to a
    // separate CSV so the existing 0.0-0.20 data in sensitivity_output_immigration_grid.csv
    // is not overwritten.
    bool   sweep_immigration_mode_extended <- false;  // true only in Sweep_Immigration_Rate_Extended

    // ---- Resistance decay (fitness cost) sweep gate ----
    // Varies resistance_fitness_cost independently of immigration_rate, to look for a
    // long-term stability "sweet spot" (season-to-season profit stability).
    // immigration_rate held at its default (0.05) so the decay term's effect can
    // be isolated.
    bool   sweep_decay_mode <- false;  // true only in Sweep_ResistanceDecay_Grid

    // ---- Pest reproduction sweep gate ----
    // Tests sensitivity to pest_growth_rate, the other hard-to-evaluate pest
    // parameter alongside immigration_rate. pest_growth_rate is otherwise held
    // fixed at its literature-derived value (Win et al. 2011) in every experiment
    // in this file; this is the first one that varies it.
    bool   sweep_reproduction_mode <- false;  // true only in Sweep_PestGrowthRate_Grid

    // ---- Interval/threshold x immigration_rate sweep gates ----
    // Answers "spray-delay threshold as a function of dilution rate": neither
    // existing sweep crosses spray timing with immigration_rate directly.
    // Sweep_CalendarInterval_Grid fixes immigration_rate at 0.05, and
    // Sweep_Immigration_Rate_Extended fixes the interval at its default. These
    // two experiments cross them properly. Single compound (starfarm/Default),
    // no rotation.
    bool   interval_immigration_sweep_mode  <- false;  // true only in Sweep_Interval_Immigration_Grid
    bool   threshold_immigration_sweep_mode <- false;  // true only in Sweep_Threshold_Immigration_Grid

    // ---- Rotation x interval / threshold sweep gates ----
    // Combines rotation_mode with the existing calendar_interval / pesticide_threshold
    // sweeps, which previously only ran with pesticide_choice fixed (no rotation).
    // Answers "how many days, what threshold, under rotation."
    bool   interval_sweep_mode_rotation  <- false;  // true only in Sweep_CalendarInterval_Grid_Rotation
    bool   threshold_sweep_mode_rotation <- false;  // true only in Sweep_Threshold_Grid_Rotation

    // ---- Rotation x immigration_rate sweep gate ----
    // Batch_Rotation_Grid only ever ran at immigration_rate=0.05. Answers "does
    // rotation's fixation delay still hold once immigration is already doing
    // most of the work on its own, or only at the low-immigration default."
    // Same 8-value immigration_rate list as the interval/threshold x immigration
    // sweeps below, so all three can be compared on the same footing.
    bool   rotation_immigration_sweep_mode <- false;  // true only in Sweep_Rotation_Immigration_Grid

    // ---- Adaptive farmer: profit-triggered backoff + REACTIVE compound choice ----
    // Answers "can we do both REACTIVE and strategy-level switching?" -- yes, they are
    // independent: REACTIVE (above) decides pesticide_choice; this decides whether/how hard
    // to keep spraying (calendar_interval / pesticide_threshold). Both fire at the same
    // season boundary without conflict, since they set different variables.
    // Trigger: profit-based, chosen over a resistance-fraction trigger because it matches
    // the project's profit-maximization priority and is what a real farmer would notice.
    // Response: continuous backoff (lengthen interval / raise threshold), not a categorical
    // strategy swap -- monotonic, never re-tightens even if profit later recovers.
    bool  adaptive_profit_mode       <- false;  // true = this run's farmer eases off on declining profit
    bool  adaptive_farmer_sweep_mode <- false;  // true only in Sweep_AdaptiveFarmer_Grid (CSV-routing gate)

    // ---- Adaptive-backoff x immigration_rate coverage gap ----
    // Backoff (above) was only ever tested at the default immigration_rate=0.05.
    // Does backoff still add value once immigration_rate is already high enough to
    // help resistance on its own, or is its benefit specific to the low-immigration
    // regime? rotation_mode pinned false here (no REACTIVE) to isolate backoff alone,
    // strategy pinned to calendar (where backoff's effect was cleanest).
    // Own dedicated gate, not reused from adaptive_farmer_sweep_mode, since the CSV
    // shape differs (immigration_rate column added, rotation_reactive column dropped).
    bool  adaptive_farmer_immigration_sweep_mode <- false;  // true only in Sweep_AdaptiveFarmer_Immigration_Grid

    // ---- Long-horizon confirmation of the standout no-fixation finding ----
    // The main Adaptive Farmer Sweep found calendar + REACTIVE + backoff never reaches
    // RF=0.99 within 30 seasons at the default immigration_rate (final RF=0.825, still
    // climbing). That's ambiguous: does it genuinely plateau below fixation, or does it
    // just take longer than 30 seasons to get there? This experiment re-runs that one
    // standout condition alone, at n=40 (confirmatory, not screening) and max_seasons=60
    // (double the horizon) to tell the difference. Own dedicated gate + CSV, does not
    // touch sensitivity_output_adaptive_farmer_grid.csv (would collide with the
    // already-verified 8-condition dataset otherwise).
    bool  adaptive_farmer_longhorizon_mode <- false;  // true only in Sweep_AdaptiveFarmer_LongHorizon

    // ---- Backoff x plain rotation (AB), not REACTIVE ----
    // The main Adaptive Farmer Sweep only ever combined backoff with REACTIVE
    // (adaptive compound choice), never with plain fixed A/B alternation
    // (rotation_mode=true, rotation_pattern="AB", the mechanism tested standalone
    // in Batch_Rotation_Grid). Does backoff's benefit generalize to a simpler,
    // non-adaptive rotation schedule, or is it specific to REACTIVE's adaptive
    // compound choice? Own dedicated gate + CSV, since the existing
    // adaptive_farmer_sweep_mode gate always pins rotation_pattern to "REACTIVE"
    // when rotation_mode is true, this experiment pins it to "AB" instead.
    bool  adaptive_farmer_rotation_sweep_mode <- false;  // true only in Sweep_AdaptiveFarmer_Rotation_Grid
    float last_season_money          <- 0.0;    // Farmer.money recorded at the previous season boundary
    float prev_season_profit         <- 0.0;    // profit realized in the season before last, for comparison
    int   backoff_interval_step      <- 2;      // days added to calendar_interval per declining-profit season (int: calendar_interval is int)
    float backoff_threshold_step     <- 0.05;   // added to pesticide_threshold per declining-profit season
    int   backoff_interval_cap       <- 28;     // cap at the longest interval already tested elsewhere
    float backoff_threshold_cap      <- 0.5;    // cap at the highest threshold already tested elsewhere

    // Escalation: mirror of the backoff mechanism above, testing the
    // opposite hypothesis. Literature review (farmer behavior under perceived pesticide
    // resistance) found real farmers often respond to declining performance by spraying
    // MORE, not less -- the reverse of the backoff assumption. Same trigger (this season's
    // profit fell short of the last), same step sizes, but tightens instead of loosens,
    // floored at the shortest interval / lowest threshold already tested elsewhere (rather
    // than backoff's cap at the longest/highest). Mutually exclusive with adaptive_profit_mode
    // in practice -- never swept true together in the same experiment.
    bool  adaptive_escalate_mode        <- false;  // true = this run's farmer sprays harder on declining profit
    bool  adaptive_escalate_sweep_mode  <- false;  // true only in Sweep_AdaptiveFarmer_Escalate_Grid (CSV-routing gate)
    int   escalate_interval_floor       <- 1;      // floor at the shortest interval already tested elsewhere
    float escalate_threshold_floor      <- 0.1;    // floor at the lowest threshold already tested elsewhere

    // Categorical strategy swap: a bigger farmer-adaptation mechanism, tested
    // as its own pair of experiments alongside backoff/escalation. Where
    // backoff/escalation adjust *how hard* a farmer sprays
    // within their current strategy, this swaps the farmer's entire strategy
    // family -- calendar -> threshold -> none -> calendar -- when triggered.
    // Two independent trigger definitions are tested as separate experiments, not
    // composed together: profit-based (same shortfall trigger as backoff/escalation)
    // and resistance-based (tab4 Section 3 sketch: "if resistant_fraction > 0.5,
    // switch"). Reversible: unlike backoff/escalation's one-way cap/floor, the
    // cycle keeps advancing every time the trigger fires again, so a farmer can
    // complete a full loop back to their starting strategy. Standalone mechanism
    // (not composed with backoff/escalation, and not crossed with rotation/REACTIVE)
    // to keep the comparison clean -- mirrors how escalation was kept separate
    // from backoff. Mutually exclusive with adaptive_profit_mode/adaptive_escalate_mode
    // in practice; reuses last_season_money/prev_season_profit the same way those
    // two already do for its own profit-trigger variant.
    bool  adaptive_strategyswap_profit_mode     <- false;  // true = profit-shortfall trigger variant
    bool  adaptive_strategyswap_resistance_mode <- false;  // true = resistance-threshold trigger variant
    bool  strategyswap_profit_sweep_mode        <- false;  // true only in Sweep_StrategySwap_Profit_Grid (CSV-routing gate)
    bool  strategyswap_resistance_sweep_mode    <- false;  // true only in Sweep_StrategySwap_Resistance_Grid (CSV-routing gate)
    float strategyswap_resistance_threshold     <- 0.5;    // grid-mean resistant_fraction level that triggers a swap (tab4 Sec.3 sketch value)
    int   strategyswap_count                    <- 0;      // lifetime count of swaps so far this run, logged per row for trajectory analysis

    // ---- Spatial position breakdown ----
    // Classifies each plot as corner / edge / interior based on grid position.
    // Corner plots have 3 Moore neighbors, edge plots 5, interior plots 8.
    // Under uniform local pest generation (localized_infection=false), any
    // gradient reflects diffusion asymmetry: interior plots receive diffused
    // pest from 8 neighbors, corner plots from only 3. Assigned once at global
    // init (geometry is static across seasons).
    bool   log_plot_position <- false;  // true only in Batch_Spatial_Grid; adds plot_position column to CSV

    init {
        emergence_threshold <- tt_emergence;
        flowering_threshold <- tt_emergence + tt_veg;
        maturity_threshold  <- tt_emergence + tt_veg + tt_rep;
        create Farmer number: 1;
        run_id <- farmer_strategy + "_" + int(self);

        create pesticide_class { name <- "etofenprox";   efficacy <- 0.7; selection_pressure <- 0.015; cost <- 110.6; }
        create pesticide_class { name <- "neonicotinoid"; efficacy <- 0.8; selection_pressure <- 0.025; cost <- 100.0; }

        // Seed season-1 pesticide_choice when rotation is active.
        // Moved here from each experiment's own init{} block: GAMA batch experiments'
        // init{} runs before that instance's swept parameters are bound, so reading a
        // swept variable (like rotation_pattern) there silently returns its class-
        // declared default, not the actual value for this run. Confirmed bug: all 21
        // compound-sequence patterns showed identical season-1 pesticide_choice
        // regardless of intended starting compound. This global init IS per-instance
        // and runs after parameter binding, so it seeds correctly. Single unified rule
        // replaces the six separate (and silently non-functional) per-experiment seed
        // lines that used to live in Batch_Rotation_Grid, Sweep_CalendarInterval_Grid_
        // Rotation, Sweep_Threshold_Grid_Rotation, Sweep_CompoundSequence_Grid_Calendar/
        // Threshold, and Sweep_AdaptiveFarmer_Grid.
        if (rotation_mode) {
            if (rotation_pattern != "REACTIVE" and copy_between(rotation_pattern, 0, 1) = "B") {
                pesticide_choice <- rotation_compound_b;
            } else {
                pesticide_choice <- rotation_compound_a;
            }
        }

        // classify each plot's spatial position once at init (static across seasons).
        // corner: both x and y are on the border -> 3 Moore neighbors
        // edge:   one of x or y is on the border (but not both) -> 5 Moore neighbors
        // interior: neither x nor y on the border -> 8 Moore neighbors
        ask Plot {
            bool on_x_border <- (grid_x = 0 or grid_x = 9);
            bool on_y_border <- (grid_y = 0 or grid_y = 9);
            if (on_x_border and on_y_border)      { plot_position <- "corner"; }
            else if (on_x_border or on_y_border)  { plot_position <- "edge"; }
            else                                  { plot_position <- "interior"; }
        }
    }

    reflex reset_events {
	    spray_event   <- 0;
	    harvest_event <- 0;
	}

    // ---- Pest dynamics: generation + diffusion --------
    reflex pest_step {

        // Pass 1: generation
        // each plot independently generates new pest pressure based on local conditions.
        ask Plot where (each.associated_crop != nil) {

        	// determine if this plot is a valid pest source
	        // if localized_infection=true, only the outbreak center generates pest
	        // if false, all plots can generate pest independently
            bool is_source <- (not localized_infection) or (grid_x = outbreak_cx and grid_y = outbreak_cy);

            // three conditions must all pass before pest_load increments:
	        // 		1. This plot is a valid source (is_source)
	        // 		2. Humidity exceeds the minimum threshold for BPH activity  (humidity > pest_humidity_limit)
	        // 		3. Temperature exceeds the minimum threshold for BPH activity  (t_mean > pest_temp_limit)
	        // 		4. A probabilistic flip weighted by pest_infection_prob succeeds  (flip(pest_infection_prob))
	        // this models the stochastic, weather-dependent nature of daily BPH infection events.
            if (is_source and humidity > pest_humidity_limit and t_mean > pest_temp_limit and flip(pest_infection_prob)) {
                pest_load <- pest_load + pest_daily_increment + (pest_load * pest_growth_rate);
            }

            // pest_load is a normalized scalar, not a population count.
            pest_load <- min(1.0, pest_load);
        }

        // Pass 2: emigrate into neighbours' tmp buffers
        // 		- each plot donates a fraction of its pest_load to neighbors
	    // 		- incoming amounts are staged in pest_load_tmp, NOT written directly to pest_load
	    // 		- this ensures all plots read from the same starting state this cycle,
	    // 				preventing order-dependent artifacts where early-updated plots spread further than late ones.
        ask Plot {
            if (pest_load > 0.0 and diffusion_prop > 0.0) {
                list<Plot> nbrs <- self.neighbors;
                if (not empty(nbrs)) {
                    // total amount to donate is a fixed proportion of current pest_load.
	                float to_share <- pest_load * diffusion_prop;

	                // split equally across all neighbors (Moore: up to 8).
	                // edge and corner plots have fewer neighbors, so each neighbor receives more.
	                float share_each <- to_share / length(nbrs);

	                // subtract the donated amount from the source plot immediately.
	                pest_load <- pest_load - to_share;

	                // write incoming amounts to each neighbor's tmp buffer, not pest_load directly.
	                // this is the synchronization mechanism; buffers are committed in Pass 3.
	                ask nbrs {
	                    pest_load_tmp <- pest_load_tmp + share_each;
	                }
                }
            }
        }

        // Pass 3: commit incoming migrants
        // 		all plots simultaneously absorb the pest pressure that arrived this cycle.
	    // 		separating this from Pass 2 guarantees synchronous update:
	    // 			no plot can receive and then re-spread in the same cycle.
        ask Plot {
        	// add buffered incoming pest to current pest_load.
            pest_load <- min(1.0, pest_load + pest_load_tmp);

            // reset buffer to zero, ready for the next cycle.
            pest_load_tmp <- 0.0;
        }
    }

    // ---- Season / harvest management -----------------
    // fires every cycle, but only triggers when at least one plot has a living crop
	// 		that has reached maturity (thermal_time >= maturity_threshold)
	// uses first_with to check the condition without looping over all plots
	reflex manage_harvest when: (Plot first_with (each.associated_crop != nil)) != nil
	        and (Plot first_with (each.associated_crop != nil)).associated_crop.thermal_time >= maturity_threshold {

	    // harvest every plot that still has a living crop attached
	    ask Plot where (each.associated_crop != nil) {

	        // convert accumulated biomass to grain yield in tonnes per hectare
	        // harvest_index is the fraction of total biomass that becomes grain
	        // biomass_to_ton_conv scales from g/m2 to t/ha
	        float grain_tha <- associated_crop.biomass * harvest_index * biomass_to_ton_conv;

	        // convert accumulated pest damage to yield loss in the same units
	        // pest_yield_loss tracks the biomass that was lost to pests each day
	        float yield_loss_tha <- associated_crop.pest_yield_loss * harvest_index * biomass_to_ton_conv;

	        // compute revenue from grain yield at the current grain price
	        // grain_price is an arbitrary placeholder unit-relative rankings are meaningful, absolute values are not
	        float revenue <- grain_tha * grain_price;

	        // pay the farmer. money accumulates across seasons
	        ask Farmer { money <- money + revenue; }

	        // log per-plot harvest summary to the console
	        // includes grain, pest loss, spray count, revenue, and resistance level at harvest
	        if (not batch_mode) {
	        write "  Plot " + grid_x + "," + grid_y + " harvested. Grain=" + (grain_tha with_precision 2)
	            + "t/ha. PestLoss=" + (yield_loss_tha with_precision 2) + "t/ha. Sprays=" + spray_count
	            + ". Revenue=" + (revenue with_precision 0)
	            + ". resist=" + (resistant_fraction with_precision 3);
	        }

        // Records the active compound's cost for cost_per_spray; reads plot_pesticide
        // (per-plot in heterogeneous_mode, mirrors pesticide_choice otherwise).
	        float logged_cost <- spray_cost;
	        if (plot_pesticide != "starfarm") {
	        pesticide_class pcc <- pesticide_class first_with (each.name = plot_pesticide);
	        if (pcc != nil) { logged_cost <- pcc.cost; }
	        }

	        // ===================================================================
	        // CSV routing: single if/else-if chain.
	        //
	        // Previously each destination CSV had its own independent, unconditional
	        // `if (gate) { save ... }` block, and harvest_grid_output.csv's block used
	        // a hand-maintained "and not (all other gates)" exclusion list. Every new
	        // experiment gate had to be remembered and added to that list, or its rows
	        // would silently bleed into harvest_grid_output.csv too. This is exactly
	        // what happened: Sweep_Immigration_Rate was never added, and 600,000 of its
	        // rows ended up mixed into harvest_grid_output.csv (confirmed: 636,000 rows
	        // on disk vs 36,000 expected for Batch_Harvest_Grid alone). The same bleed
	        // was about to recur for harvest_grid_output_rotation.csv once the new
	        // rotation x interval/threshold sweeps were added, since both also set
	        // rotation_mode=true.
	        //
	        // An if/else-if chain makes that whole bug class structurally impossible:
	        // exactly one branch can fire per row (the first whose gate is true), no
	        // matter how many booleans happen to be true at once, and no exclusion list
	        // needs to exist or be kept up to date. Adding a new experiment just means
	        // adding one more `else if` branch; it can never silently double-write.
	        //
	        // Ordering rule: the two rotation-sub-sweep branches (interval/threshold x
	        // rotation) are checked BEFORE the plain rotation_mode branch, since both
	        // also set rotation_mode=true. Being earlier in the chain means they win,
	        // so the plain rotation branch only ever fires for Batch_Rotation_Grid itself.
	        // The bare harvest_grid_output.csv write is the final `else`, so it now fires
	        // exactly when batch_mode=true and none of the other gates matched; no
	        // exclusion list to maintain, ever.
	        // ===================================================================

	        if (interval_sweep_mode) {
	            // log interval-sweep summary: same shape as harvest_grid_output.csv plus
	            // calendar_interval, tracking resistant_fraction per season per interval
	            string irow <- "" + run_id + "," + farmer_strategy + "," + calendar_interval + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save irow to: "sensitivity_output_interval_grid.csv" format: "text" rewrite: false;

	        } else if (threshold_sweep_mode) {
	            // log threshold-sweep summary: same shape, for pesticide_threshold
	            string trow <- "" + run_id + "," + farmer_strategy + "," + pesticide_threshold + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save trow to: "sensitivity_output_threshold_grid.csv" format: "text" rewrite: false;

	        } else if (threshold_sweep_mode_etofenprox) {
	            // log per-compound threshold-sweep: pesticide_choice fixed to a specific compound
	            // so spray cadence and resistance reflect that compound's efficacy and selection_pressure
	            string terow <- "" + run_id + "," + farmer_strategy + "," + pesticide_threshold + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save terow to: "sensitivity_output_threshold_grid_etofenprox.csv" format: "text" rewrite: false;

	        } else if (threshold_sweep_mode_neonic) {
	            string tnrow <- "" + run_id + "," + farmer_strategy + "," + pesticide_threshold + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save tnrow to: "sensitivity_output_threshold_grid_neonic.csv" format: "text" rewrite: false;

	        } else if (compound_baseline_etofenprox) {
	            // log compound-baseline: same shape as harvest_grid_output.csv, run with
	            // pesticide_choice fixed to etofenprox or neonicotinoid
	            string berow <- "" + run_id + "," + farmer_strategy + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save berow to: "harvest_grid_output_etofenprox.csv" format: "text" rewrite: false;

	        } else if (compound_baseline_neonic) {
	            string bnrow <- "" + run_id + "," + farmer_strategy + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save bnrow to: "harvest_grid_output_neonic.csv" format: "text" rewrite: false;

	        } else if (longterm_mode) {
	            // log long-term run summary: same shape as harvest_grid_output.csv plus
	            // pesticide_choice column so one CSV covers all 3 compounds
	            string ltrow <- "" + run_id + "," + farmer_strategy + "," + pesticide_choice + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + pest_load + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save ltrow to: "harvest_grid_output_longterm.csv" format: "text" rewrite: false;

	        } else if (interval_sweep_mode_rotation) {
	            // log rotation x interval sweep: calendar_interval + pesticide_choice
	            // both recorded, since rotation flips pesticide_choice at season boundaries.
	            // Checked before the plain rotation_mode branch (see ordering rule above).
	            string irrow <- "" + run_id + "," + farmer_strategy + "," + calendar_interval + "," + pesticide_choice + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save irrow to: "sensitivity_output_interval_grid_rotation.csv" format: "text" rewrite: false;

	        } else if (threshold_sweep_mode_rotation) {
	            // log rotation x threshold sweep: pesticide_threshold + pesticide_choice
	            // both recorded, same reasoning as above. Also checked before plain rotation_mode.
	            string trrow <- "" + run_id + "," + farmer_strategy + "," + pesticide_threshold + "," + pesticide_choice + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save trrow to: "sensitivity_output_threshold_grid_rotation.csv" format: "text" rewrite: false;

	        } else if (rotation_immigration_sweep_mode) {
	            // log rotation x immigration_rate sweep: pesticide_choice + immigration_rate
	            // both recorded. Checked before the plain rotation_mode branch, same
	            // reasoning as the interval/threshold x rotation branches above.
	            string rirow <- "" + run_id + "," + farmer_strategy + "," + pesticide_choice + "," + immigration_rate + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save rirow to: "sensitivity_output_rotation_immigration_grid.csv" format: "text" rewrite: false;

	        } else if (sequence_sweep_mode_calendar or sequence_sweep_mode_threshold) {
	            // log compound-sequence sweep: rotation_pattern + pesticide_choice
	            // both recorded, since the pattern (or "REACTIVE") determines which compound
	            // is active each season. Checked before the plain rotation_mode branch, since
	            // this also sets rotation_mode=true (see ordering rule above).
	            // Routed to strategy-specific files (not a shared file) so each experiment's
	            // own rewrite:true init does not collide with the other's header row.
	            // Each experiment checks its own dedicated gate directly rather than
	            // routing off farmer_strategy's value: farmer_strategy is pinned constant
	            // per experiment here, but keying routing off a value that could in
	            // principle be swept within an experiment is a risky shape (see the
	            // strategy-swap routing note below), so a per-experiment gate is used
	            // consistently instead.
	            string seqrow <- "" + run_id + "," + farmer_strategy + "," + rotation_pattern + "," + pesticide_choice + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            if (sequence_sweep_mode_calendar) {
	                save seqrow to: "sensitivity_output_compound_sequence_grid_calendar.csv" format: "text" rewrite: false;
	            } else {
	                save seqrow to: "sensitivity_output_compound_sequence_grid_threshold.csv" format: "text" rewrite: false;
	            }

	        } else if (adaptive_farmer_sweep_mode) {
	            // log adaptive-farmer sweep: both the profit-backoff toggle
	            // (adaptive_profit_mode) and whether REACTIVE compound-choice is layered
	            // on top (rotation_mode true = REACTIVE active, since rotation_pattern is
	            // fixed to "REACTIVE" for every run of this experiment) are recorded.
	            // calendar_interval/pesticide_threshold are logged live since
	            // adaptive_profit_mode may have changed them mid-run -- that trajectory is
	            // the whole point of this sweep. Checked before the plain rotation_mode
	            // branch, since some rows here also have rotation_mode=true.
	            string afrow <- "" + run_id + "," + farmer_strategy + "," + adaptive_profit_mode + "," + rotation_mode + "," + calendar_interval + "," + pesticide_threshold + "," + pesticide_choice + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save afrow to: "sensitivity_output_adaptive_farmer_grid.csv" format: "text" rewrite: false;

	        } else if (adaptive_farmer_immigration_sweep_mode) {
	            // log adaptive-backoff x immigration_rate coverage-gap sweep:
	            // tests whether backoff still helps once immigration_rate is already
	            // substantial, not just at the default 0.05. rotation_mode pinned false
	            // for every run of this experiment (isolating backoff alone), so no
	            // rotation_reactive column here, unlike adaptive_farmer_sweep_mode's row
	            // shape. Checked before adaptive_farmer_sweep_mode's own branch would be
	            // reached, own dedicated gate, no collision possible.
	            string afirow <- "" + run_id + "," + farmer_strategy + "," + adaptive_profit_mode + "," + immigration_rate + "," + calendar_interval + "," + pesticide_choice + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save afirow to: "sensitivity_output_adaptive_farmer_immigration_grid.csv" format: "text" rewrite: false;

	        } else if (adaptive_farmer_longhorizon_mode) {
	            // log long-horizon confirmation run: the single standout
	            // calendar + REACTIVE + backoff condition, run at n=40 and
	            // max_seasons=60 to check whether it genuinely plateaus below fixation
	            // or just takes longer than 30 seasons to get there. Own dedicated
	            // gate + file, kept separate from sensitivity_output_adaptive_farmer_grid.csv
	            // so this does not collide with the already-verified 8-condition
	            // dataset. Row shape matches adaptive_farmer_sweep_mode's (rotation_reactive
	            // included, since REACTIVE is pinned true for every run of this experiment).
	            string alhrow <- "" + run_id + "," + farmer_strategy + "," + adaptive_profit_mode + "," + rotation_mode + "," + calendar_interval + "," + pesticide_threshold + "," + pesticide_choice + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save alhrow to: "sensitivity_output_adaptive_farmer_longhorizon.csv" format: "text" rewrite: false;

	        } else if (adaptive_farmer_rotation_sweep_mode) {
	            // log backoff x plain-rotation (AB) coverage-gap sweep: tests
	            // whether backoff's benefit generalizes to fixed A/B alternation, not
	            // just REACTIVE's adaptive compound choice. rotation_mode here means
	            // plain AB rotation (rotation_pattern pinned "AB" for this experiment),
	            // unlike adaptive_farmer_sweep_mode's rotation_mode which always means
	            // REACTIVE. Own dedicated gate, checked before the plain rotation_mode
	            // branch since some rows here also have rotation_mode=true.
	            string arrow <- "" + run_id + "," + farmer_strategy + "," + adaptive_profit_mode + "," + rotation_mode + "," + calendar_interval + "," + pesticide_choice + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save arrow to: "sensitivity_output_adaptive_farmer_rotation_grid.csv" format: "text" rewrite: false;

	        } else if (adaptive_escalate_sweep_mode) {
	            // log adaptive-farmer escalate sweep: mirror of the
	            // adaptive_farmer_sweep_mode branch above, but for adaptive_escalate_mode
	            // instead of adaptive_profit_mode -- tests the literature-documented
	            // "spray harder under perceived resistance" hypothesis as an alternative to
	            // the backoff assumption. Same column shape, separate file since it is a
	            // separate experiment. Checked before the plain rotation_mode branch, since
	            // some rows here also have rotation_mode=true.
	            string aerow <- "" + run_id + "," + farmer_strategy + "," + adaptive_escalate_mode + "," + rotation_mode + "," + calendar_interval + "," + pesticide_threshold + "," + pesticide_choice + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save aerow to: "sensitivity_output_adaptive_farmer_escalate_grid.csv" format: "text" rewrite: false;

	        } else if (strategyswap_profit_sweep_mode or strategyswap_resistance_sweep_mode) {
	            // log categorical strategy-swap sweep: farmer_strategy itself is
	            // mutable mid-run (calendar -> threshold -> none -> calendar), so it
	            // is logged live each row, same reasoning as calendar_interval /
	            // pesticide_threshold in the backoff/escalate branches above.
	            // strategyswap_count gives the trajectory of how many swaps have
	            // happened so far -- the main new thing this experiment reveals.
	            // Routed to trigger-specific files (not a shared file) so each
	            // experiment's own rewrite:true init does not collide with the other's
	            // header row; same reasoning as the compound-sequence branch above.
	            // Routing keys off which experiment is running (its own sweep-mode
	            // gate), not off adaptive_strategyswap_resistance_mode's value: that
	            // value is itself swept true/false within the resistance experiment,
	            // so keying on it would misroute that experiment's false-condition
	            // rows into the profit file.
	            string ssrow <- "" + run_id + "," + farmer_strategy + "," + adaptive_strategyswap_profit_mode + "," + adaptive_strategyswap_resistance_mode + "," + strategyswap_count + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            if (strategyswap_resistance_sweep_mode) {
	                save ssrow to: "sensitivity_output_strategyswap_grid_resistance.csv" format: "text" rewrite: false;
	            } else {
	                save ssrow to: "sensitivity_output_strategyswap_grid_profit.csv" format: "text" rewrite: false;
	            }

	        } else if (rotation_mode) {
	            // log rotation run summary: same shape as harvest_grid_output_longterm.csv.
	            // pesticide_choice reflects the compound active this season (already flipped
	            // at the previous season boundary). Only reaches here for Batch_Rotation_Grid
	            // itself, since the rotation-sub-sweep branches (interval, threshold, and
	            // compound-sequence) are all checked earlier.
	            string rtrow <- "" + run_id + "," + farmer_strategy + "," + pesticide_choice + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save rtrow to: "harvest_grid_output_rotation.csv" format: "text" rewrite: false;

	        } else if (heterogeneous_mode) {
	            // log heterogeneous run summary: adds plot_strategy and plot_pesticide columns
	            // so each row records the individual plot's assignment, not the global defaults
	            string htrow <- "" + run_id + "," + plot_strategy + "," + plot_pesticide + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save htrow to: "harvest_grid_output_heterogeneous.csv" format: "text" rewrite: false;

	        } else if (log_plot_position) {
	            // log spatial breakdown: adds plot_position column so results can be grouped
	            // by corner / edge / interior
	            string sprow <- "" + run_id + "," + farmer_strategy + "," + plot_position + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save sprow to: "harvest_grid_output_spatial.csv" format: "text" rewrite: false;

	        } else if (sweep_immigration_mode) {
	            // log immigration sweep summary: each row includes immigration_rate so
	            // per-season RF decay strength is recorded
	            string imrow <- "" + run_id + "," + farmer_strategy + "," + immigration_rate + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save imrow to: "sensitivity_output_immigration_grid.csv" format: "text" rewrite: false;

	        } else if (sweep_immigration_mode_extended) {
	            // log extended immigration sweep (high range): separate file, same shape.
	            string imexrow <- "" + run_id + "," + farmer_strategy + "," + immigration_rate + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save imexrow to: "sensitivity_output_immigration_grid_extended.csv" format: "text" rewrite: false;

	        } else if (sweep_decay_mode) {
	            // log resistance-decay (fitness cost) sweep: each row includes
	            // resistance_fitness_cost so the season-to-season profit stability sweet spot
	            // can be identified.
	            string decrow <- "" + run_id + "," + farmer_strategy + "," + resistance_fitness_cost + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save decrow to: "sensitivity_output_decay_grid.csv" format: "text" rewrite: false;

	        } else if (sweep_reproduction_mode) {
	            // log pest reproduction (pest_growth_rate) sweep: each row includes
	            // pest_growth_rate so its effect on fixation timing/profit can be compared
	            // against the immigration_rate sweep on the same axes.
	            string reprow <- "" + run_id + "," + farmer_strategy + "," + pest_growth_rate + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save reprow to: "sensitivity_output_reproduction_grid.csv" format: "text" rewrite: false;

	        } else if (interval_immigration_sweep_mode) {
	            // log interval x immigration_rate cross-sweep: both swept columns
	            // recorded so spray-delay-vs-dilution-rate can be read directly.
	            string iirow <- "" + run_id + "," + farmer_strategy + "," + calendar_interval + "," + immigration_rate + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save iirow to: "sensitivity_output_interval_immigration_grid.csv" format: "text" rewrite: false;

	        } else if (threshold_immigration_sweep_mode) {
	            // log threshold x immigration_rate cross-sweep: same reasoning,
	            // for the threshold strategy.
	            string tirow <- "" + run_id + "," + farmer_strategy + "," + pesticide_threshold + "," + immigration_rate + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save tirow to: "sensitivity_output_threshold_immigration_grid.csv" format: "text" rewrite: false;

	        } else if (batch_mode) {
	            // Default: Batch_Harvest_Grid, and only Batch_Harvest_Grid, since every other
	            // experiment's gate is checked above and would have already matched.
	            string hrow <- "" + run_id + "," + farmer_strategy + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save hrow to: "harvest_grid_output.csv" format: "text" rewrite: false;
	        }
	        // GUI runs (batch_mode=false) fall through with no CSV write, as before.

	        // remove the crop agent from the simulation. it has served its purpose
	        ask associated_crop { do die; }

	        // detach the crop reference from this plot so the plot is ready to sow again
	        associated_crop <- nil;
	    }

	    // read the farmer's total money after all plot revenues have been added
	    // the empty check guards against the farmer agent not existing
	    float farmer_money <- empty(Farmer) ? 0.0 : first(Farmer).money;

	    // log the season-level summary to the console.
	    if (not batch_mode) {
	    write "Day " + cycle + " | Season " + season + " harvested. Strategy=" + farmer_strategy
	        + ". Money=" + (farmer_money with_precision 0) + ".";
	    }

	    // advance the season counter
	    season <- season + 1;

	    // flag that a harvest happened this cycle, used by the events chart to place a harvest marker
	    harvest_event <- 1;

	    // if more seasons remain, flag all plots to sow a new crop next cycle
	    if (season <= max_seasons) {
        // apply inter-season resistance decay: two independent multiplicative terms.
        // immigration_rate: external dilution by susceptible immigrants arriving from
        //   outside the grid (Daly et al. 1988; Choi et al. 2025 for MRD source-population context).
        // resistance_fitness_cost: intrinsic decline from resistant individuals being
        //   out-competed by susceptible individuals already present (Yu et al. 2018).
        // Fires once per season boundary. Both default such that 0.0 = no decay from that term.
        // Both pools decay independently (per-compound pools).
        if (immigration_rate > 0.0 or resistance_fitness_cost > 0.0) {
            ask Plot {
                rf_etofenprox <- rf_etofenprox * (1.0 - immigration_rate) * (1.0 - resistance_fitness_cost);
                rf_neonicotinoid <- rf_neonicotinoid * (1.0 - immigration_rate) * (1.0 - resistance_fitness_cost);
                // sync backward-compat field: effective RF = max of both pools at season boundary
                resistant_fraction <- max(rf_etofenprox, rf_neonicotinoid);
            }
        }
        // rotation: update pesticide_choice at every season boundary.
        // pesticide_choice is a global, so this affects all plots next season.
        // season has already been incremented, so the new value is used to decide.
	        if (rotation_mode) {
	            if (rotation_pattern = "REACTIVE") {
	                // Non-deterministic: spray whichever compound's grid-mean pool is
	                // currently lower. At season 1 both pools are 0.0 (tie), which
	                // defaults to rotation_compound_a below.
	                float mean_rf_a <- mean(Plot collect each.rf_etofenprox);
	                float mean_rf_b <- mean(Plot collect each.rf_neonicotinoid);
	                pesticide_choice <- (mean_rf_b < mean_rf_a) ? rotation_compound_b : rotation_compound_a;
	            } else {
	                // Fixed pattern: cycle through rotation_pattern's characters by season.
	                // Default "AB" reproduces the old odd=compound_a / even=compound_b
	                // behavior exactly (index 0 -> 'A' on season 1, index 1 -> 'B' on
	                // season 2, index 0 -> 'A' on season 3, ...).
	                int pat_len <- length(rotation_pattern);
	                int idx <- (season - 1) mod pat_len;
	                string ch <- copy_between(rotation_pattern, idx, idx + 1);
	                pesticide_choice <- (ch = "B") ? rotation_compound_b : rotation_compound_a;
	            }
	        }
	        // Adaptive profit-based backoff: a farmer who notices this season's
	        // profit fell short of the previous season's eases off -- lengthening
	        // calendar_interval or raising pesticide_threshold -- rather than continuing
	        // to spray at an increasingly unprofitable rate. Independent of the rotation
	        // block above: this decides whether/how hard to keep spraying, REACTIVE (if
	        // active) separately decides which compound. Monotonic: once eased off, never
	        // re-tightens even if profit later recovers ("burned once, more cautious going
	        // forward", tab4 Section 3 framing). Capped at the longest interval / highest
	        // threshold already validated elsewhere in this document, so backoff never
	        // wanders into untested territory.
	        if (adaptive_profit_mode or adaptive_escalate_mode) {
	            float current_money <- empty(Farmer) ? 0.0 : first(Farmer).money;
	            float this_season_profit <- current_money - last_season_money;
	            if (this_season_profit < prev_season_profit) {
	                if (adaptive_profit_mode) {
	                    if (farmer_strategy = "calendar" and calendar_interval < backoff_interval_cap) {
	                        calendar_interval <- min(backoff_interval_cap, calendar_interval + backoff_interval_step);
	                    } else if (farmer_strategy = "threshold" and pesticide_threshold < backoff_threshold_cap) {
	                        pesticide_threshold <- min(backoff_threshold_cap, pesticide_threshold + backoff_threshold_step);
	                    }
	                } else if (adaptive_escalate_mode) {
	                    // Mirror of the backoff branch above: same step sizes, but tightens
	                    // (sprays harder) instead of loosening, floored instead of capped.
	                    if (farmer_strategy = "calendar" and calendar_interval > escalate_interval_floor) {
	                        calendar_interval <- max(escalate_interval_floor, calendar_interval - backoff_interval_step);
	                    } else if (farmer_strategy = "threshold" and pesticide_threshold > escalate_threshold_floor) {
	                        pesticide_threshold <- max(escalate_threshold_floor, pesticide_threshold - backoff_threshold_step);
	                    }
	                }
	            }
	            prev_season_profit <- this_season_profit;
	            last_season_money <- current_money;
	        }
	        // Categorical strategy swap: mirrors the block above's
	        // season-boundary timing, but swaps farmer_strategy itself instead of
	        // tuning a parameter within it. Two mutually-exclusive trigger variants,
	        // never both true in the same run. Reversible cycle: calendar -> threshold
	        // -> none -> calendar, one step per trigger firing, with no cap/floor --
	        // a farmer can complete a full loop back to where they started.
	        if (adaptive_strategyswap_profit_mode or adaptive_strategyswap_resistance_mode) {
	            bool swap_triggered <- false;
	            if (adaptive_strategyswap_profit_mode) {
	                float current_money <- empty(Farmer) ? 0.0 : first(Farmer).money;
	                float this_season_profit <- current_money - last_season_money;
	                swap_triggered <- (this_season_profit < prev_season_profit);
	                prev_season_profit <- this_season_profit;
	                last_season_money <- current_money;
	            } else if (adaptive_strategyswap_resistance_mode) {
	                float grid_mean_rf <- mean(Plot collect each.resistant_fraction);
	                swap_triggered <- (grid_mean_rf > strategyswap_resistance_threshold);
	            }
	            if (swap_triggered) {
	                if (farmer_strategy = "calendar") {
	                    farmer_strategy <- "threshold";
	                } else if (farmer_strategy = "threshold") {
	                    farmer_strategy <- "none";
	                } else {
	                    farmer_strategy <- "calendar";
	                }
	                strategyswap_count <- strategyswap_count + 1;
	            }
	        }
	        ask Plot { pending_sow <- true; }
	    }
	}

	// stop simulation when season number limit reached
    reflex stop_when_done when: season > max_seasons {
        write "All " + max_seasons + " season(s) complete. Strategy: " + farmer_strategy;
        if (not batch_mode) { do pause; }
    }

    // ---- VISUAL sync: pest_load density -> crawling BPH sprites ----------------
    // Cosmetic only. Each cycle, reconcile the number of Bph on each plot to
    // round(pest_load * max_bph_per_plot) via create/die (same pattern the
    // pest_hunting model uses to keep its sprite count matching the formula).
	reflex sync_bph_visuals when: not batch_mode {
	    ask Plot {

	        // figure out how many bph sprites this plot should have
	        // scales pest_load (0 to 1) up to a max sprite count
	        int target <- round(pest_load * max_bph_per_plot);

	        // get the list of bph sprites currently assigned to this plot
	        list<Bph> mine <- Bph where (each.home = self);

	        // compare how many we have vs how many we need
	        int diff <- target - length(mine);

	        // if we need more sprites, create the missing ones
	        // assign them to this plot and place them at a random spot within it
	        if (diff > 0) {
	            create Bph number: diff {
	                home <- myself;
	                location <- any_location_in(myself.shape);
	            }

	        // if we have too many sprites, remove the excess ones
	        } else if (diff < 0) {
	            ask (-diff) among mine {
	                do die;
	            }
	        }

	        // if diff = 0, nothing changes
	    }
	}
}

// ===========================================================================
// pesticide_class: per-compound parameterization (UNCALIBRATED).
// See pesticide_choice comment in global{} for sourcing caveat.
// ===========================================================================

species pesticide_class {
    string name;
    float  efficacy;
    float  selection_pressure;
    // Per-spray cost in the model's arbitrary cost units (same scale as spray_cost=100).
    // Anchored to real Vietnamese retail prices (June 2026), converted to cost per hectare
    // per spray using each product's confirmed brown planthopper label dose:
    //   etofenprox (Trebon 10EC): 135,000 VND / 480mL bottle, label dose 700mL/ha
    //     -> 196,875 VND/ha/spray
    //   neonicotinoid (Actara 25WG, thiamethoxam): 593,300 VND / 100g packet, label dose 30g/ha
    //     -> 177,990 VND/ha/spray
    // Ratio etofenprox:neonicotinoid = 1.106, neonicotinoid anchored at 100 (= spray_cost default).
    // starfarm uses global spray_cost directly.
    float  cost;
}

// ===========================================================================
// CROP (unchanged from phase_2)
// ===========================================================================
// represents a single rice crop growing on a plot for one season
species Crop {
    Plot myPlot <- nil; 	// the plot this crop is growing on
    float biomass <- 0.0; 	// total accumulated dry matter in g/m2
    float thermal_time <- 0.0; 		// accumulated heat units since sowing, drives growth stage transitions
    float growth_stage <- 0.0;		// how far along the crop is from 0 (just sown) to 1 (mature), used for display only
    float pest_yield_loss <- 0.0; 	// running total of biomass lost to pest damage across the season, in g/m2
    float k_pest <- 1.0; 		// damage multiplier on daily growth, ranges from min_k_pest to 1.0

    // ACCUMULATE REFLEX
    // runs every cycle to advance the crop through its growth stages
    reflex accumulate {
        // daily thermal time increment: how many degrees above the base temperature today was
        // if t_mean is below Tbase, dTT is 0 - the crop does not develop on cold days
        float dTT <- max(0.0, t_mean - Tbase);
        thermal_time <- thermal_time + dTT; 	// add today's heat units to the running total
        growth_stage <- min(1.0, thermal_time / maturity_threshold);	// growth_stage is just thermal_time scaled to [0, 1] for display purposes
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
        // highest during emergence (sw_phase1=0.7), lowest during grain fill (sw_phase4=0.3)
        float stage_weight <- sw_phase1;
        if      (thermal_time < emergence_threshold) { stage_weight <- sw_phase1; }
        else if (thermal_time < flowering_threshold) { stage_weight <- sw_phase2; }
        else if (thermal_time < maturity_threshold)  { stage_weight <- sw_phase3; }
        else                                         { stage_weight <- sw_phase4; }

        // read pest_load from the plot this crop is growing on
        // if somehow the crop has no plot, assume zero pest pressure
        float plot_pest_load <- (myPlot = nil) ? 0.0 : myPlot.pest_load;

        // compute the damage multiplier for today
        // higher pest_load and higher stage_weight both reduce k_pest
        // min_k_pest sets a floor so growth never drops to zero
        k_pest <- max(min_k_pest, 1.0 - (stage_weight * plot_pest_load));

        // what the crop would have grown today with no pest pressure
        float daily_growth_potential <- potential_rue * solar_rad * fAPAR;

        // what the crop actually grew today after pest damage
        float daily_growth_actual <- daily_growth_potential * k_pest;

        // the difference is logged as pest-attributable yield loss
        // accumulates across the whole season and is reported at harvest
        pest_yield_loss <- pest_yield_loss + (daily_growth_potential - daily_growth_actual);

        // add today's actual growth to total biomass
        biomass <- biomass + daily_growth_actual;
    }
}

// ===========================================================================
// PLOT (two aspects: rice-field palette + raw heatmap)
// the 10x10 grid of plots: each cell is one farm plot
// neighbors: 8 means each plot connects to its 8 surrounding neighbors (Moore, includes diagonals)
// ===========================================================================
grid Plot width: 10 height: 10 neighbors: 8 {

    Crop associated_crop <- nil;	// the crop currently growing on this plot, nil if the plot is fallow
    bool pending_sow <- true;		// flag that tells the plot to sow a new crop on the next cycle
    float pest_load <- 0.0;			// current pest pressure on this plot, normalized between 0 (none) and 1 (maximum)

    // temporary buffer that holds incoming pest from neighbors during diffusion
    // committed to pest_load at the end of each cycle in pest_step pass 3
    float pest_load_tmp <- 0.0;

    // fraction of the local pest population that is resistant to etofenprox
    // increases only when etofenprox is sprayed on this plot
    float rf_etofenprox <- 0.0;
    // fraction of the local pest population that is resistant to neonicotinoid
    // increases only when neonicotinoid is sprayed on this plot
    float rf_neonicotinoid <- 0.0;
    // effective resistance for the active compound, computed after each spray
    // and at immigration decay. Backward-compatible for CSV/GUI output.
    // For starfarm: max(rf_etofenprox, rf_neonicotinoid).
    // For a specific compound: <own_RF> + rf_other * spillover_k.
    float resistant_fraction <- 0.0;

    // how many days have passed since the last spray on this plot
    // used to enforce the spray cooldown
    int days_since_last_spray <- 0;
    int spray_count <- 0; // total number of sprays applied to this plot across the current season

    // total number of sprays ever applied to this plot, across all seasons. Unlike
    // spray_count, this does NOT reset at sow_crop. Drives the piecewise resistance
    // stage trigger in Farmer.decide_spray: resistance is an allele-frequency shift
    // inherited by each new season from survivors of the last, so the stage reflects
    // the plot's full spray history, not just this season's count.
    int lifetime_spray_count <- 0;

    // per-plot strategy and pesticide (heterogeneous_mode only).
    // In homogeneous runs these mirror globals; in heterogeneous_mode they are
    // independently assigned at init and fixed for the plot's lifetime.
    string plot_strategy   <- "threshold";
    string plot_pesticide  <- "starfarm";
    string plot_position   <- "interior";  // corner / edge / interior; assigned at global init, static

    // heterogeneous assignment: runs once at plot creation.
    // each plot draws a fixed strategy and pesticide from the configured distribution
    // that persists across all seasons, matching the original experimental intent.
    init {
        if (heterogeneous_mode) {
            float r <- rnd(1.0);
            if      (r < hetero_frac_none)                        { plot_strategy <- "none"; }
            else if (r < hetero_frac_none + hetero_frac_calendar) { plot_strategy <- "calendar"; }
            else                                                  { plot_strategy <- "threshold"; }
            float rp <- rnd(1.0);
            plot_pesticide <- (rp < hetero_frac_etofenprox) ? "etofenprox" : "neonicotinoid";
        }
    }

    // SOW CROP REFLEX
    // fires when pending_sow is true; creates a new crop and resets plot state for the new season
    reflex sow_crop when: pending_sow {

        // reset pest and spray state at the start of each season
        pest_load <- 0.0;
        days_since_last_spray <- 0;
        spray_count <- 0;

        // mirror globals each season in homogeneous mode (needed for rotation).
        // heterogeneous_mode plots retain their init-time assignment unchanged.
        if (not heterogeneous_mode) {
            plot_strategy  <- farmer_strategy;
            plot_pesticide <- pesticide_choice;
        }

        // if localized infection is on and this is the outbreak center,
        // seed it with an initial pest load instead of starting clean
        if (localized_infection and grid_x = outbreak_cx and grid_y = outbreak_cy) {
            pest_load <- outbreak_seed;
        }

        // create a new crop agent and attach it to this plot
        create Crop returns: c;
        associated_crop <- first(c);
        ask associated_crop { myPlot <- myself; }

        // clear the flag so this reflex does not fire again until the next season
        pending_sow <- false;
    }


    // ADVANCE COUNTERS REFLEX
    // runs every cycle while a crop is present
    // increments the spray cooldown counter each day
    reflex advance_counters when: associated_crop != nil {
        days_since_last_spray <- days_since_last_spray + 1;
    }


    // PEST DECAY REFLEX
    // runs on fallow plots (no crop) that still have residual pest pressure
    // models natural pest die-off between seasons
    // pest_decay_coeff controls how fast it drops: 0.0 means instant wipeout, 1.0 means no decay
    reflex pest_decay when: associated_crop = nil and pest_load > 0.0 {
        pest_load <- pest_load * pest_decay_coeff;
    }


    // FIELD ASPECT
    // visual display using a 4-color palette based on pest pressure
    // meant to be readable at a glance, similar to pest hunting game style
    aspect field {
        rgb c <- rgb(120, 90, 60);  // default: bare soil for fallow plots
        if (associated_crop != nil) {
            if      (pest_load < 0.1)  { c <- rgb(0, 112, 48); }     // dark green: healthy, low pressure
            else if (pest_load <= 0.4) { c <- rgb(198, 239, 206); }  // light green: mild pressure
            else if (pest_load <= 0.7) { c <- rgb(255, 255, 0); }    // yellow: moderate pressure
            else                      { c <- rgb(88, 57, 39); }     // brown: severe, crop overwhelmed
        }
        draw shape color: c border: rgb(255, 255, 255, 0.35);
    }
}

// ===========================================================================
// BPH SPRITE (cosmetic only; visualizes pest_load density)
// these agents carry no model state and do not affect pest_load or any simulation variable
// they exist purely to make pest pressure visible on the field display
// ===========================================================================
species Bph skills: [moving] {

    Plot home;
    float speed <- 2.0; // how fast the sprite moves around its plot each cycle

    // place the sprite at a random spot inside its home plot when created
    init {
        if (home != nil) { location <- any_location_in(home.shape); }
    }

    // CRAWL REFLEX
    // moves the sprite around randomly within its home plot each cycle
    reflex crawl {

        // wander randomly with a wide turning angle so movement looks natural
        do wander speed: speed amplitude: 110.0;

        // if the sprite has drifted too far from its plot center, snap it back
        // this prevents sprites from visually crossing into neighboring plots
        if (home != nil and (self.location distance_to home.location) > 14.0) {
            location <- any_location_in(home.shape);
        }
    }

    // DEFAULT ASPECT
    // draws the sprite as a small rectangle (body) with a circle (head) pointing in the direction of movement
    // no image asset is used; the shape is drawn directly in code
    aspect default {

        // body color shifts from red to orange as the host plot's resistant_fraction increases
        // this makes resistance buildup visible at a glance without reading the chart
        // if the sprite has no home plot for some reason, default to plain red
		rgb body <- (home = nil) ? rgb(139, 90, 43) : rgb(139 - int(129 * home.resistant_fraction), 90 - int(85 * home.resistant_fraction), 43 - int(40 * home.resistant_fraction));

        // compute head position slightly ahead of the body in the direction of travel
        point head_pos <- location + {cos(heading) * 1.6, sin(heading) * 1.6};

        // draw the body as a rotated rectangle aligned to the heading
        draw rectangle(3.0, 1.4) color: body border: rgb(60, 0, 0) rotate: heading;

        // draw the head as a small circle at the front of the body
        draw circle(0.9) at: head_pos color: body border: rgb(60, 0, 0);
    }
}

// ===========================================================================
// FARMER
// one farmer agent manages all plots each cycle.
// NOTE: single Farmer = single wallet. In heterogeneous_mode, costs for all 100
// plots' sprays and revenue from all 100 plots' harvests are pooled into one
// budget. Per-plot profit tracking is not possible without per-plot financial
// state. This is unrealistic for a landscape of independent farms. If per-plot
// economics are needed, each Plot would need its own money variable.
// ===========================================================================
species Farmer {

    // running total of money across all seasons
    // starts at initial_money and changes with spray costs and harvest revenue
    float money <- initial_money;

    // DECIDE SPRAY REFLEX
    // runs every cycle and checks each active plot to decide whether to spray
    reflex decide_spray {

        ask Plot where (each.associated_crop != nil) {

            // check if enough days have passed since the last spray
            bool cooldown_ok <- days_since_last_spray >= spray_cooldown;
            bool should_spray <- false;

            // spray decision uses plot_strategy (mirrors farmer_strategy in homogeneous mode;
            // independently assigned per-plot in heterogeneous_mode).
            // NOTE: calendar does NOT check spray_cooldown. At interval=1 it can spray
            // ~75 times/season (every day). This is an undocumented asymmetry vs threshold,
            // which respects spray_cooldown as a binding constraint.
            if (plot_strategy = "none") {
                should_spray <- false;
            } else if (plot_strategy = "calendar") {
                should_spray <- days_since_last_spray >= calendar_interval;
            } else {
                should_spray <- cooldown_ok and (pest_load > pesticide_threshold);
            }

            if (should_spray) {

                float pest_before <- pest_load; // snapshot pest_load before spraying for the console log

                // active compound's efficacy, selection_pressure, and cost.
                // uses plot_pesticide (mirrors pesticide_choice in homogeneous mode;
                // independently assigned per-plot in heterogeneous_mode).
                float active_efficacy <- efficacy;
                float active_selection_pressure <- selection_pressure_constant;
                float active_cost <- spray_cost;
                if (plot_pesticide != "starfarm") {
                    pesticide_class pc <- pesticide_class first_with (each.name = plot_pesticide);
                    if (pc != nil) {
                        active_efficacy <- pc.efficacy;
                        active_selection_pressure <- pc.selection_pressure;
                        active_cost <- pc.cost;
                    }
                }

                // ---- Per-compound resistance ratchet ----
                // Each compound has its own resistant_fraction pool (rf_etofenprox,
                // rf_neonicotinoid). Sprays increment only their own pool.
                // Effective resistance for realized_efficacy includes a spillover term
                // from the other compound (spillover_k * other_RF), following the
                // cross-resistance pattern in Zhang et al. (2022) (no cross at low RF)
                // and Yu et al. (2018) (spillover appears at high RF).
                //
                // 3-stage piecewise rate (uses lifetime_spray_count, not the
                // season-resetting spray_count): 1-3 / 4-7 / 8+.
                // Stage boundaries follow Khoa et al. (2018)'s 3-stage profile.
                // Stage multipliers (0.5x / 1.0x / 2.5x) are PLACEHOLDERS.
                int spray_number <- lifetime_spray_count + 1;
                float resistance_increment <- active_selection_pressure;
                if (spray_number <= 3) {
                    resistance_increment <- active_selection_pressure * 0.5;
                } else if (spray_number > 7) {
                    resistance_increment <- active_selection_pressure * 2.5;
                }

                // increment the correct pool for this spray
                if (plot_pesticide = "etofenprox") {
                    rf_etofenprox <- min(1.0, rf_etofenprox + resistance_increment);
                } else if (plot_pesticide = "neonicotinoid") {
                    rf_neonicotinoid <- min(1.0, rf_neonicotinoid + resistance_increment);
                } else {
                    // starfarm: no real compound, increment both pools equally
                    rf_etofenprox <- min(1.0, rf_etofenprox + resistance_increment);
                    rf_neonicotinoid <- min(1.0, rf_neonicotinoid + resistance_increment);
                }

                // compute effective resistance for realized_efficacy
                float effective_rf <- 0.0;
                if (plot_pesticide = "etofenprox") {
                    effective_rf <- min(1.0, rf_etofenprox + rf_neonicotinoid * spillover_k);
                } else if (plot_pesticide = "neonicotinoid") {
                    effective_rf <- min(1.0, rf_neonicotinoid + rf_etofenprox * spillover_k);
                } else {
                    // starfarm: use max of both pools
                    effective_rf <- max(rf_etofenprox, rf_neonicotinoid);
                }
                resistant_fraction <- effective_rf; // sync backward-compat field

                // realized efficacy is reduced by effective resistance
                float realized_efficacy <- active_efficacy * (1.0 - effective_rf);

                // apply the spray: reduce pest_load by the realized efficacy fraction
                pest_load <- pest_load * (1.0 - realized_efficacy);

                days_since_last_spray <- 0;		// reset the cooldown counter
                spray_count <- spray_count + 1;		// increment this plot's spray count for the season
                lifetime_spray_count <- lifetime_spray_count + 1;	// increment this plot's spray count across all seasons
                myself.money <- myself.money - active_cost;	// deduct spray cost from the farmer's money, compound-specific

                // flag that a spray happened this cycle, used by the events chart
                spray_event <- 1;

                // log spray details to the console
                if (not batch_mode) {
                write "  -> Spray on plot " + grid_x + "," + grid_y + " day " + cycle
                    + ". before=" + (pest_before with_precision 3)
                    + " after=" + (pest_load with_precision 3)
                    + " realized_eff=" + (realized_efficacy with_precision 3)
                    + " resist=" + (resistant_fraction with_precision 3);
                }
            }
        }
    }
}

// ===========================================================================
// EXPERIMENT
// ===========================================================================
experiment pest_spatial type: gui {

    parameter "t_mean (deg C)"               var: t_mean              min: 20.0  max: 40.0;
    parameter "solar_rad (MJ/m2/day)"        var: solar_rad           min: 5.0   max: 30.0;
    parameter "humidity (%)"                 var: humidity            min: 50.0  max: 100.0;
    parameter "potential_rue (g/MJ)"         var: potential_rue       min: 0.5   max: 3.0;
    parameter "Seasons to simulate"          var: max_seasons         min: 1     max: 30;
    parameter "pest_daily_increment"         var: pest_daily_increment min: 0.01 max: 0.1;
    parameter "pest_growth_rate (life-table)" var: pest_growth_rate    min: 0.0   max: 0.1;
    parameter "min_k_pest"                   var: min_k_pest          min: 0.1   max: 1.0;

    parameter "Strategy"                     var: farmer_strategy among: ["none", "calendar", "threshold"];
    parameter "Pesticide class"              var: pesticide_choice    among: ["starfarm", "etofenprox", "neonicotinoid"];
    parameter "pesticide_threshold"          var: pesticide_threshold min: 0.05  max: 1.0;
    parameter "spray_cooldown (days)"        var: spray_cooldown      min: 1     max: 30;
    parameter "calendar_interval (days)"     var: calendar_interval   min: 1     max: 30;
    parameter "efficacy (0 to 1)"            var: efficacy            min: 0.1   max: 1.0;
    parameter "spray_cost"                   var: spray_cost          min: 0.0   max: 1000.0;
    parameter "initial_money"                var: initial_money       min: 0.0   max: 50000.0;
    parameter "grain_price (per t/ha)" var: grain_price min: 0.0 max: 10000.0;

    parameter "diffusion_prop"               var: diffusion_prop      min: 0.0   max: 0.5;
    parameter "selection_pressure_constant"  var: selection_pressure_constant min: 0.0 max: 0.5;
    parameter "immigration_rate (0=no decay)" var: immigration_rate   min: 0.0   max: 1.0;
    parameter "resistance_fitness_cost (0=no decay)" var: resistance_fitness_cost min: 0.0 max: 0.5;
    parameter "Cross-resistance spillover (0=none, 1=full)" var: spillover_k min: 0.0 max: 1.0;
    parameter "Localized infection (centre source)" var: localized_infection;
    parameter "outbreak_seed (centre start load)"   var: outbreak_seed min: 0.0 max: 1.0;
    parameter "Max BPH sprites per plot"     category: "Visuals" var: max_bph_per_plot min: 1 max: 40;

    output {
        // Layout: col 1 = Field; col 2 = [pest pressure | resistance] over [money | events]
        // Display indices (declaration order, raw map commented out):
        //   0 Field | 1 Mean pest pressure | 2 Resistance | 3 Farmer money | 4 Events
        layout horizontal([
            0::5000,
            vertical([
                horizontal([1::5000, 2::5000])::5000,
                horizontal([3::5000, 4::5000])::5000
            ])::5000
        ]) tabs: false toolbars: true;

        monitor "Day"                value: cycle;
        monitor "Season"             value: season;
        monitor "Strategy"           value: farmer_strategy;
        monitor "Mean pest load"     value: Plot mean_of each.pest_load;
        monitor "Max pest load"      value: Plot max_of each.pest_load;
        monitor "Mean resist frac"   value: Plot mean_of each.resistant_fraction;
        monitor "Total sprays"       value: Plot sum_of each.spray_count;
        monitor "Money"              value: empty(Farmer) ? 0.0 : first(Farmer).money;

        // ---- Main field: rice palette + crawling BPH sprites + HUD ----------
        display "Field" type: 2d {
            species Plot aspect: field;
            species Bph;

            overlay position: { 5, 5 } size: { 250 #px, 360 #px } background: #black transparency: 0.5 border: #black rounded: true {
                float y <- 26 #px;
                draw "Day " + cycle + "   Season " + season + "/" + max_seasons at: { 15 #px, y } color: #white font: font("Helvetica", 15, #bold);
                y <- y + 26 #px;
                draw "Strategy: " + farmer_strategy at: { 15 #px, y } color: #white font: font("Helvetica", 14, #plain);
                y <- y + 23 #px;
                draw "Mean pest load: " + ((Plot mean_of each.pest_load) with_precision 2) at: { 15 #px, y } color: #white font: font("Helvetica", 14, #plain);
                y <- y + 23 #px;
                draw "Max pest load: " + ((Plot max_of each.pest_load) with_precision 2) at: { 15 #px, y } color: #white font: font("Helvetica", 14, #plain);
                y <- y + 23 #px;
                draw "Mean resistance: " + ((Plot mean_of each.resistant_fraction) with_precision 2) at: { 15 #px, y } color: #white font: font("Helvetica", 14, #plain);
                y <- y + 23 #px;
                draw "Total sprays: " + (Plot sum_of each.spray_count) at: { 15 #px, y } color: #white font: font("Helvetica", 14, #plain);
                y <- y + 23 #px;
                draw "Money: " + ((empty(Farmer) ? 0.0 : first(Farmer).money) with_precision 0) at: { 15 #px, y } color: #white font: font("Helvetica", 14, #plain);

                // ---- plot colour legend (matches aspect field bands) ----
                y <- y + 30 #px;
                draw "Plot colour = pest load" at: { 15 #px, y } color: #white font: font("Helvetica", 13, #bold);
                y <- y + 22 #px;
                draw square(12 #px) at: { 22 #px, y } color: rgb(0, 112, 48)    border: #white;
                draw "Healthy  (< 0.1)"        at: { 40 #px, y + 4 #px } color: #white font: font("Helvetica", 12, #plain);
                y <- y + 21 #px;
                draw square(12 #px) at: { 22 #px, y } color: rgb(198, 239, 206) border: #white;
                draw "Light  (0.1 - 0.4)"      at: { 40 #px, y + 4 #px } color: #white font: font("Helvetica", 12, #plain);
                y <- y + 21 #px;
                draw square(12 #px) at: { 22 #px, y } color: rgb(255, 255, 0)   border: #white;
                draw "Moderate  (0.4 - 0.7)"   at: { 40 #px, y + 4 #px } color: #white font: font("Helvetica", 12, #plain);
                y <- y + 21 #px;
                draw square(12 #px) at: { 22 #px, y } color: rgb(88, 57, 39)    border: #white;
                draw "Overwhelmed  (> 0.7)"    at: { 40 #px, y + 4 #px } color: #white font: font("Helvetica", 12, #plain);
                y <- y + 21 #px;
                draw square(12 #px) at: { 22 #px, y } color: rgb(120, 90, 60)   border: #white;
                draw "Fallow  (no crop)"       at: { 40 #px, y + 4 #px } color: #white font: font("Helvetica", 12, #plain);
                y <- y + 24 #px;
                draw "Bugs = pest density"      at: { 15 #px, y } color: #white font: font("Helvetica", 12, #plain);
            }
        }

        display "Mean pest pressure" {
            chart "Grid mean pest load" type: series background: #white {
                data "Mean pest load" value: Plot mean_of each.pest_load color: #red    style: line marker: false;
                data "Max pest load"  value: Plot max_of each.pest_load  color: #orange style: line marker: false;
            }
        }

        display "Resistance" {
            chart "Mean resistant fraction" type: series background: #white {
                data "Mean resistant fraction" value: Plot mean_of each.resistant_fraction color: #purple style: line marker: false;
            }
        }

        display "Farmer money" {
            chart "Money" type: series background: #white {
                data "Money" value: empty(Farmer) ? 0.0 : first(Farmer).money color: #blue style: line marker: false;
            }
        }
        display "Events" {
    		chart "Spray / Harvest events" type: series background: #white {
	        data "Spray"   value: spray_event   color: #red    style: bar marker: false;
	        data "Harvest" value: harvest_event color: #yellow style: bar marker: false;
    	}
}
    }
}

// ===========================================================================
// BATCH: one row per plot per season per run -> harvest_grid_output.csv
// runs each strategy `repeat` times with different seeds (flip + diffusion variance)
// ===========================================================================
experiment Batch_Harvest_Grid type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"   var: farmer_strategy among: ["none", "calendar", "threshold"];
    parameter "Batch mode" var: batch_mode      among: [true];

    init {
        // header once + clears old file (auto-handles the delete-CSV step)
        save "run_id,strategy,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "harvest_grid_output.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// SWEEP: calendar interval and pesticide threshold, phase_2-native.
// Same question as the phase_1 sweep, but resistant_fraction is tracked here
// directly rather than combined from separate experiments. Runs the full 30
// seasons so cumulative profit is comparable to every other 30-season condition
// in the Summary ranking table (tab3_Results.md), not just early yield.
// keep_seed:false means results vary slightly (~0.01-0.015 t/ha) run to run.
// Each experiment writes its own dedicated CSV.
// ===========================================================================
experiment Sweep_CalendarInterval_Grid type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"             var: farmer_strategy        among: ["calendar"];
    parameter "Batch mode"           var: batch_mode             among: [true];
    parameter "Interval sweep mode"  var: interval_sweep_mode    among: [true];
    parameter "calendar_interval"    var: calendar_interval      among: [1, 3, 5, 7, 10, 14, 21, 28];
    parameter "Seasons to simulate"  var: max_seasons            among: [30];

    init {
        save "run_id,strategy,calendar_interval,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_interval_grid.csv" format: "text" rewrite: true;
    }
}

experiment Sweep_Threshold_Grid type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    // Same reasoning as Sweep_CalendarInterval_Grid above: runs the full 30
    // seasons so cumulative profit is comparable to every other entry in the
    // Summary ranking table.
    parameter "Strategy"             var: farmer_strategy        among: ["threshold"];
    parameter "Batch mode"           var: batch_mode             among: [true];
    parameter "Threshold sweep mode" var: threshold_sweep_mode   among: [true];
    parameter "pesticide_threshold"  var: pesticide_threshold    among: [0.1, 0.2, 0.3, 0.4, 0.5];
    parameter "Seasons to simulate"  var: max_seasons            among: [30];

    init {
        save "run_id,strategy,pesticide_threshold,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_threshold_grid.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// SWEEP: per-compound threshold sweep.
// Same as Sweep_Threshold_Grid, but with pesticide_choice fixed to a specific
// compound. Threshold spray cadence depends on efficacy, which differs per
// compound (etofenprox 0.7 vs starfarm/neonicotinoid 0.8), so a simple rescale
// of the starfarm-only sweep is not reliable. Each writes its own CSV.
// ===========================================================================
experiment Sweep_Threshold_Grid_Etofenprox type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"                          var: farmer_strategy                  among: ["threshold"];
    parameter "Batch mode"                         var: batch_mode                       among: [true];
    parameter "Threshold sweep mode (etofenprox)"  var: threshold_sweep_mode_etofenprox  among: [true];
    parameter "Pesticide"                          var: pesticide_choice                 among: ["etofenprox"];
    parameter "pesticide_threshold"                var: pesticide_threshold              among: [0.1, 0.2, 0.3, 0.4, 0.5];
    parameter "Seasons to simulate"                var: max_seasons                      among: [6];

    init {
        save "run_id,strategy,pesticide_threshold,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_threshold_grid_etofenprox.csv" format: "text" rewrite: true;
    }
}

experiment Sweep_Threshold_Grid_Neonicotinoid type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"                      var: farmer_strategy              among: ["threshold"];
    parameter "Batch mode"                     var: batch_mode                   among: [true];
    parameter "Threshold sweep mode (neonic)"  var: threshold_sweep_mode_neonic  among: [true];
    parameter "Pesticide"                      var: pesticide_choice             among: ["neonicotinoid"];
    parameter "pesticide_threshold"            var: pesticide_threshold          among: [0.1, 0.2, 0.3, 0.4, 0.5];
    parameter "Seasons to simulate"            var: max_seasons                  among: [6];

    init {
        save "run_id,strategy,pesticide_threshold,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_threshold_grid_neonic.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// BASELINE: full 3-strategy comparison with pesticide_choice fixed to a specific
// compound. Same shape as Batch_Harvest_Grid, default max_seasons (3), so results
// line up directly with the starfarm baseline. Each writes its own CSV.
// ===========================================================================
experiment Batch_Harvest_Grid_Etofenprox type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"                            var: farmer_strategy                among: ["none", "calendar", "threshold"];
    parameter "Batch mode"                           var: batch_mode                     among: [true];
    parameter "Compound baseline mode (etofenprox)"  var: compound_baseline_etofenprox   among: [true];
    parameter "Pesticide"                            var: pesticide_choice               among: ["etofenprox"];

    init {
        save "run_id,strategy,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "harvest_grid_output_etofenprox.csv" format: "text" rewrite: true;
    }
}

experiment Batch_Harvest_Grid_Neonicotinoid type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"                        var: farmer_strategy            among: ["none", "calendar", "threshold"];
    parameter "Batch mode"                       var: batch_mode                 among: [true];
    parameter "Compound baseline mode (neonic)"  var: compound_baseline_neonic   among: [true];
    parameter "Pesticide"                        var: pesticide_choice           among: ["neonicotinoid"];

    init {
        save "run_id,strategy,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "harvest_grid_output_neonic.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// LONG-TERM: 30-season (10-year) resistance trajectory across all 3 strategies
// and all 3 compound choices. CSV has pesticide_choice column so one file covers
// all compounds. repeat=40 matches all other batch experiments.
// ===========================================================================
experiment Batch_LongTerm_Grid type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"          var: farmer_strategy  among: ["none", "calendar", "threshold"];
    parameter "Pesticide"         var: pesticide_choice among: ["starfarm", "etofenprox", "neonicotinoid"];
    parameter "Batch mode"        var: batch_mode       among: [true];
    parameter "Long-term mode"    var: longterm_mode    among: [true];
    parameter "immigration_rate"  var: immigration_rate among: [0.05];
    parameter "Seasons to simulate" var: max_seasons    among: [30];

    init {
        save "run_id,strategy,pesticide_choice,season,plot_x,plot_y,grain_tha,pest_load,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "harvest_grid_output_longterm.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// ROTATION: etofenprox/neonicotinoid alternation across 30 seasons.
// Tests whether alternating compounds slows resistance buildup vs. a single
// compound (compare against Batch_LongTerm_Grid). pesticide_choice is overwritten
// at each season boundary by the rotation flip in manage_harvest. CSV shape
// matches harvest_grid_output_longterm.csv for direct comparison.
// immigration_rate = 0.05, repeat = 40.
// ===========================================================================
experiment Batch_Rotation_Grid type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"             var: farmer_strategy       among: ["none", "calendar", "threshold"];
    parameter "Batch mode"           var: batch_mode            among: [true];
    parameter "Rotation mode"        var: rotation_mode         among: [true];
    parameter "Compound A (odd)"     var: rotation_compound_a   among: ["etofenprox"];
    parameter "Compound B (even)"    var: rotation_compound_b   among: ["neonicotinoid"];
    parameter "immigration_rate"     var: immigration_rate      among: [0.05];
    parameter "Seasons to simulate"  var: max_seasons           among: [30];

    init {
        // season-1 pesticide_choice seeding now handled centrally in the model's
        // global init -- see comment there.
        save "run_id,strategy,pesticide_choice,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "harvest_grid_output_rotation.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// HETEROGENEOUS: mixed-strategy landscape.
// Each plot independently draws a strategy (none/calendar/threshold) and pesticide
// (etofenprox/neonicotinoid) from the configured distribution (default: 20% none,
// 40% calendar, 40% threshold; 50/50 compound split). CSV adds plot_strategy and
// plot_pesticide columns for per-plot analysis. immigration_rate = 0.05,
// max_seasons = 30, repeat = 40.
// ===========================================================================
experiment Batch_Heterogeneous_Grid type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Batch mode"             var: batch_mode           among: [true];
    parameter "Heterogeneous mode"     var: heterogeneous_mode   among: [true];
    parameter "Frac none"              var: hetero_frac_none        among: [0.2];
    parameter "Frac calendar"          var: hetero_frac_calendar    among: [0.4];
    parameter "Frac etofenprox"        var: hetero_frac_etofenprox  among: [0.5];
    parameter "immigration_rate"       var: immigration_rate        among: [0.05];
    parameter "Seasons to simulate"    var: max_seasons             among: [30];

    init {
        save "run_id,plot_strategy,plot_pesticide,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "harvest_grid_output_heterogeneous.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// SPATIAL: per-plot position breakdown (corner / edge / interior).
// Under uniform local pest generation all plots generate independently, so any
// gradient reflects diffusion asymmetry: interior plots (8 Moore neighbours)
// receive more diffused pest than corners (3 neighbours). Quantifies this
// gradient at n = 40. All 3 strategies, default 3 seasons.
// Output: harvest_grid_output_spatial.csv
// ===========================================================================
experiment Batch_Spatial_Grid type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"           var: farmer_strategy  among: ["none", "calendar", "threshold"];
    parameter "Batch mode"         var: batch_mode       among: [true];
    parameter "Log plot position"  var: log_plot_position     among: [true];

    init {
        save "run_id,strategy,plot_position,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "harvest_grid_output_spatial.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// SWEEP: immigration_rate sensitivity.
// Tests how sensitive long-term resistance trajectories are to the
// immigration_rate placeholder. 0.0 = pure ratchet (no dilution); 0.05 matches
// Batch_LongTerm_Grid for cross-check. Strategy fixed to calendar (fixed spray
// cadence unaffected by resistance state) and compound fixed to starfarm.
// CSV writes immigration_rate per row. repeat = 40.
// ===========================================================================
experiment Sweep_Immigration_Rate type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"                var: farmer_strategy      among: ["calendar"];
    parameter "Pesticide"               var: pesticide_choice      among: ["starfarm"];
    parameter "Batch mode"              var: batch_mode           among: [true];
    parameter "Immigration sweep mode"  var: sweep_immigration_mode among: [true];
    parameter "Seasons to simulate"     var: max_seasons          among: [30];
    parameter "immigration_rate"        var: immigration_rate     among: [0.0, 0.01, 0.05, 0.10, 0.20];

    init {
        save "run_id,strategy,immigration_rate,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_immigration_grid.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// Extended immigration sweep, high range (0.30-1.00). Separate CSV from
// Sweep_Immigration_Rate so the existing 0.0-0.20 data is preserved;
// concatenate for the full range (0.0 to 1.00) when analyzing with
// analyze_grid.py.
// ===========================================================================
experiment Sweep_Immigration_Rate_Extended type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"                         var: farmer_strategy              among: ["calendar"];
    parameter "Pesticide"                        var: pesticide_choice             among: ["starfarm"];
    parameter "Batch mode"                       var: batch_mode                   among: [true];
    parameter "Immigration sweep mode (ext.)"    var: sweep_immigration_mode_extended among: [true];
    parameter "Seasons to simulate"              var: max_seasons                  among: [30];
    parameter "immigration_rate"                 var: immigration_rate             among: [0.30, 0.50, 0.70, 0.90, 1.00];

    init {
        save "run_id,strategy,immigration_rate,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_immigration_grid_extended.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// Resistance decay (fitness cost) sweep. New mechanism, separate from
// immigration_rate (see resistance_fitness_cost comment in global{}, grounded in
// Yu et al. 2018's density-pressure fitness-cost finding). immigration_rate held
// at its default (0.05) so the decay term's effect is isolated, looking for a
// long-term stability "sweet spot" (season-to-season profit stability).
// Crosses both calendar and threshold strategy with resistance_fitness_cost
// (10 conditions total), not just calendar alone, so the decay term's effect
// can be compared across strategies. parallel: false, per the standing rule
// for any experiment logging incrementally to a shared CSV.
// ===========================================================================
experiment Sweep_ResistanceDecay_Grid type: batch repeat: 40 keep_seed: false parallel: false until: season > max_seasons {
    parameter "Strategy"                  var: farmer_strategy         among: ["calendar", "threshold"];
    parameter "Pesticide"                 var: pesticide_choice        among: ["starfarm"];
    parameter "Batch mode"                var: batch_mode              among: [true];
    parameter "Decay sweep mode"          var: sweep_decay_mode        among: [true];
    parameter "Seasons to simulate"       var: max_seasons             among: [30];
    parameter "immigration_rate"          var: immigration_rate        among: [0.05];
    parameter "resistance_fitness_cost"   var: resistance_fitness_cost among: [0.0, 0.01, 0.02, 0.05, 0.10];

    init {
        save "run_id,strategy,resistance_fitness_cost,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_decay_grid.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// Pest reproduction (pest_growth_rate) sensitivity sweep. Mirrors
// Sweep_ResistanceDecay_Grid: immigration_rate held at default (0.05) so the
// reproduction term's effect is isolated. Range brackets the literature
// estimate (0.033038, Win et al. 2011) from 0 (no density-dependent growth,
// flat increment only) to roughly 3x baseline. Crosses calendar and threshold
// strategies. parallel: false, per the standing rule for shared-CSV logging.
// ===========================================================================
experiment Sweep_PestGrowthRate_Grid type: batch repeat: 40 keep_seed: false parallel: false until: season > max_seasons {
    parameter "Strategy"                var: farmer_strategy        among: ["calendar", "threshold"];
    parameter "Pesticide"               var: pesticide_choice       among: ["starfarm"];
    parameter "Batch mode"              var: batch_mode             among: [true];
    parameter "Reproduction sweep mode" var: sweep_reproduction_mode among: [true];
    parameter "Seasons to simulate"     var: max_seasons            among: [30];
    parameter "immigration_rate"        var: immigration_rate       among: [0.05];
    parameter "pest_growth_rate"        var: pest_growth_rate       among: [0.0, 0.0165, 0.033038, 0.05, 0.10];

    init {
        save "run_id,strategy,pest_growth_rate,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_reproduction_grid.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// Rotation x calendar_interval sweep. Repeats the Sweep_CalendarInterval_Grid
// question ("how many days") but with rotation_mode=true instead of a fixed
// compound. Runs 30 seasons (matches Batch_Rotation_Grid), since the long-term
// rotation benefit (delayed fixation to ~S8) only shows up over a longer
// horizon. CSV logs pesticide_choice per row since rotation flips it each
// season.
// ===========================================================================
experiment Sweep_CalendarInterval_Grid_Rotation type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"                       var: farmer_strategy             among: ["calendar"];
    parameter "Batch mode"                     var: batch_mode                  among: [true];
    parameter "Rotation mode"                  var: rotation_mode               among: [true];
    parameter "Interval sweep mode (rotation)" var: interval_sweep_mode_rotation among: [true];
    parameter "Compound A (odd)"               var: rotation_compound_a         among: ["etofenprox"];
    parameter "Compound B (even)"              var: rotation_compound_b         among: ["neonicotinoid"];
    parameter "immigration_rate"               var: immigration_rate            among: [0.05];
    parameter "calendar_interval"              var: calendar_interval           among: [1, 3, 5, 7, 10, 14, 21, 28];
    parameter "Seasons to simulate"            var: max_seasons                 among: [30];

    init {
        // season-1 pesticide_choice seeding now handled centrally in the model's
        // global init -- see comment there.
        save "run_id,strategy,calendar_interval,pesticide_choice,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_interval_grid_rotation.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// Rotation x pesticide_threshold sweep. Same reasoning as the interval sweep
// above, but for the threshold strategy.
// ===========================================================================
experiment Sweep_Threshold_Grid_Rotation type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"                        var: farmer_strategy              among: ["threshold"];
    parameter "Batch mode"                      var: batch_mode                   among: [true];
    parameter "Rotation mode"                   var: rotation_mode                among: [true];
    parameter "Threshold sweep mode (rotation)" var: threshold_sweep_mode_rotation among: [true];
    parameter "Compound A (odd)"                var: rotation_compound_a          among: ["etofenprox"];
    parameter "Compound B (even)"               var: rotation_compound_b          among: ["neonicotinoid"];
    parameter "immigration_rate"                var: immigration_rate             among: [0.05];
    parameter "pesticide_threshold"             var: pesticide_threshold          among: [0.1, 0.2, 0.3, 0.4, 0.5];
    parameter "Seasons to simulate"             var: max_seasons                  among: [30];

    init {
        // season-1 pesticide_choice seeding now handled centrally in the model's
        // global init -- see comment there.
        save "run_id,strategy,pesticide_threshold,pesticide_choice,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_threshold_grid_rotation.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// Compound-sequence exploration. Generalizes rotation beyond strict A-B
// alternation to find whether a different fixed season-by-season compound
// sequence, or a non-deterministic reactive rule, beats plain rotation on
// long-term profit. Doubles as a farmer-adaptation sketch (the "REACTIVE"
// pattern is a real, if simple, adaptive policy).
//
// Pattern space: every distinct, non-constant, period<=4 binary sequence over
// {A=etofenprox, B=neonicotinoid} whose minimal period equals its length (so
// e.g. "ABAB" is excluded, since it is identical in effect to period-2 "AB",
// already covered): 2 period-2 + 6 period-3 + 12 period-4 = 20 patterns,
// plus "REACTIVE" (spray whichever pool has the lower grid-mean RF that
// season). 21 conditions total.
//
// repeat=20 (not the usual 40): this is a screening sweep across 21 conditions
// per strategy (42 conditions total across both experiments below); halving
// repeat keeps total runtime manageable while still giving a reasonable
// per-condition mean. Rerun at repeat=40 for whichever pattern(s) come out on
// top, if tighter confidence is needed.
//
// Analysis: use analyze_grid.py (extended with --profit) to rank patterns by
// cumulative 30-season net profit AND season-to-season profit stability, both
// reported side by side with no single metric picked in advance.
// ===========================================================================
experiment Sweep_CompoundSequence_Grid_Calendar type: batch repeat: 20 keep_seed: false parallel: false until: season > max_seasons {
    parameter "Strategy"                var: farmer_strategy   among: ["calendar"];
    parameter "Batch mode"              var: batch_mode        among: [true];
    parameter "Rotation mode"           var: rotation_mode     among: [true];
    parameter "Sequence sweep mode"     var: sequence_sweep_mode_calendar among: [true];
    parameter "Compound A"              var: rotation_compound_a among: ["etofenprox"];
    parameter "Compound B"              var: rotation_compound_b among: ["neonicotinoid"];
    parameter "immigration_rate"        var: immigration_rate  among: [0.05];
    parameter "Seasons to simulate"     var: max_seasons       among: [30];
    parameter "rotation_pattern"        var: rotation_pattern  among: [
        "AB", "BA",
        "AAB", "ABA", "ABB", "BAA", "BAB", "BBA",
        "AAAB", "AABA", "AABB", "ABAA", "ABBA", "ABBB",
        "BAAA", "BAAB", "BABB", "BBAA", "BBAB", "BBBA",
        "REACTIVE"
    ];

    init {
        // season-1 pesticide_choice seeding now handled centrally in the model's
        // global init -- see comment there (each per-experiment init{} runs
        // before that instance's swept parameters are bound, so seeding here
        // instead of in this block is what makes rotation_pattern read correctly).
        save "run_id,strategy,rotation_pattern,pesticide_choice,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_compound_sequence_grid_calendar.csv" format: "text" rewrite: true;
    }
}

experiment Sweep_CompoundSequence_Grid_Threshold type: batch repeat: 20 keep_seed: false parallel: false until: season > max_seasons {
    parameter "Strategy"                var: farmer_strategy   among: ["threshold"];
    parameter "Batch mode"              var: batch_mode        among: [true];
    parameter "Rotation mode"           var: rotation_mode     among: [true];
    parameter "Sequence sweep mode"     var: sequence_sweep_mode_threshold among: [true];
    parameter "Compound A"              var: rotation_compound_a among: ["etofenprox"];
    parameter "Compound B"              var: rotation_compound_b among: ["neonicotinoid"];
    parameter "immigration_rate"        var: immigration_rate  among: [0.05];
    parameter "Seasons to simulate"     var: max_seasons       among: [30];
    parameter "rotation_pattern"        var: rotation_pattern  among: [
        "AB", "BA",
        "AAB", "ABA", "ABB", "BAA", "BAB", "BBA",
        "AAAB", "AABA", "AABB", "ABAA", "ABBA", "ABBB",
        "BAAA", "BAAB", "BABB", "BBAA", "BBAB", "BBBA",
        "REACTIVE"
    ];

    init {
        // season-1 pesticide_choice seeding now handled centrally in the model's
        // global init -- see comment there.
        save "run_id,strategy,rotation_pattern,pesticide_choice,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_compound_sequence_grid_threshold.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// Interval/threshold x immigration_rate cross-sweeps. Answers "spray-delay
// threshold as a function of dilution rate": neither Sweep_CalendarInterval_Grid
// (fixes immigration_rate=0.05) nor Sweep_Immigration_Rate_Extended (fixes the
// interval at its default) crosses spray timing with dilution rate directly.
// Single compound (starfarm/Default), no rotation -- kept simple to isolate the
// interval/threshold x immigration_rate interaction on its own.
//
// immigration_rate levels: 8 values spanning 0.05-0.90 (0.05 = current model
// default, 0.10/0.20/0.30/0.40/0.50 fill out the mid range, 0.70/0.90 cover
// the high range where Sweep_Immigration_Rate_Extended showed fixation can be
// prevented entirely under calendar at the default interval -- this sweep
// checks whether that still holds once interval/threshold also varies).
// 8 intervals/thresholds x 8 immigration rates fills the full grid (64 cells
// for interval, 40 for threshold), and both experiments share the same
// immigration_rate list so they can be compared on the same footing.
//
// repeat=15 (lower than the repeat=20 used for the compound-sequence sweep):
// screening sweeps; rerun any decision-relevant condition at repeat=40 for
// tighter confidence.
// ===========================================================================
experiment Sweep_Interval_Immigration_Grid type: batch repeat: 15 keep_seed: false parallel: false until: season > max_seasons {
    parameter "Strategy"                    var: farmer_strategy             among: ["calendar"];
    parameter "Pesticide"                   var: pesticide_choice            among: ["starfarm"];
    parameter "Batch mode"                  var: batch_mode                  among: [true];
    parameter "Interval x immigration mode" var: interval_immigration_sweep_mode among: [true];
    parameter "calendar_interval"           var: calendar_interval           among: [1, 3, 5, 7, 10, 14, 21, 28];
    parameter "immigration_rate"            var: immigration_rate            among: [0.05, 0.10, 0.20, 0.30, 0.40, 0.50, 0.70, 0.90];
    parameter "Seasons to simulate"         var: max_seasons                 among: [30];

    init {
        save "run_id,strategy,calendar_interval,immigration_rate,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_interval_immigration_grid.csv" format: "text" rewrite: true;
    }
}

experiment Sweep_Threshold_Immigration_Grid type: batch repeat: 15 keep_seed: false parallel: false until: season > max_seasons {
    parameter "Strategy"                     var: farmer_strategy              among: ["threshold"];
    parameter "Pesticide"                    var: pesticide_choice             among: ["starfarm"];
    parameter "Batch mode"                   var: batch_mode                   among: [true];
    parameter "Threshold x immigration mode" var: threshold_immigration_sweep_mode among: [true];
    parameter "pesticide_threshold"          var: pesticide_threshold          among: [0.1, 0.2, 0.3, 0.4, 0.5];
    parameter "immigration_rate"             var: immigration_rate             among: [0.05, 0.10, 0.20, 0.30, 0.40, 0.50, 0.70, 0.90];
    parameter "Seasons to simulate"          var: max_seasons                  among: [30];

    init {
        save "run_id,strategy,pesticide_threshold,immigration_rate,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_threshold_immigration_grid.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// Rotation x immigration_rate sweep. Batch_Rotation_Grid only ever ran at
// immigration_rate=0.05 -- never tested against elevated immigration. Uses
// the same 8-value immigration_rate list as the interval/threshold x
// immigration sweeps above so all three are directly comparable. All 3
// strategies (matches Batch_Rotation_Grid), fixed A/B alternation (not
// REACTIVE -- that combination is covered separately by the Adaptive Farmer
// sweeps). repeat=15, screening sweep, parallel:false (shared CSV).
// ===========================================================================
experiment Sweep_Rotation_Immigration_Grid type: batch repeat: 15 keep_seed: false parallel: false until: season > max_seasons {
    parameter "Strategy"                     var: farmer_strategy              among: ["none", "calendar", "threshold"];
    parameter "Batch mode"                   var: batch_mode                   among: [true];
    parameter "Rotation mode"                var: rotation_mode                among: [true];
    parameter "Rotation x immigration mode"  var: rotation_immigration_sweep_mode among: [true];
    parameter "Compound A (odd)"             var: rotation_compound_a          among: ["etofenprox"];
    parameter "Compound B (even)"            var: rotation_compound_b          among: ["neonicotinoid"];
    parameter "immigration_rate"             var: immigration_rate             among: [0.05, 0.10, 0.20, 0.30, 0.40, 0.50, 0.70, 0.90];
    parameter "Seasons to simulate"          var: max_seasons                  among: [30];

    init {
        // season-1 pesticide_choice seeding now handled centrally in the model's
        // global init -- see comment there.
        save "run_id,strategy,pesticide_choice,immigration_rate,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_rotation_immigration_grid.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// Combined farmer adaptation. Answers "can REACTIVE and strategy-level
// switching run together?" -- yes: REACTIVE (rotation_mode=true,
// rotation_pattern="REACTIVE") decides pesticide_choice each season boundary;
// adaptive_profit_mode independently decides whether/how hard to keep spraying
// (calendar_interval / pesticide_threshold), via a monotonic backoff triggered
// when this season's Farmer.money delta falls short of the season before's.
// Profit-triggered (not resistance-triggered), matching the project's
// profit-maximization priority; continuous backoff (not a categorical
// calendar<->threshold<->none swap).
// 2x2x2 factorial: farmer_strategy x adaptive_profit_mode x rotation_mode
// (REACTIVE on/off). rotation_pattern is fixed to "REACTIVE" -- irrelevant
// when rotation_mode=false, since the whole rotation update block is skipped
// and pesticide_choice stays at its single global default (Default/starfarm).
// ===========================================================================
experiment Sweep_AdaptiveFarmer_Grid type: batch repeat: 40 keep_seed: false parallel: false until: season > max_seasons {
    parameter "Strategy"                   var: farmer_strategy            among: ["calendar", "threshold"];
    parameter "Batch mode"                 var: batch_mode                 among: [true];
    parameter "Adaptive farmer sweep mode" var: adaptive_farmer_sweep_mode among: [true];
    parameter "Adaptive profit backoff"    var: adaptive_profit_mode       among: [true, false];
    parameter "Rotation mode (REACTIVE)"   var: rotation_mode              among: [true, false];
    parameter "rotation_pattern"           var: rotation_pattern           among: ["REACTIVE"];
    parameter "Compound A"                 var: rotation_compound_a        among: ["etofenprox"];
    parameter "Compound B"                 var: rotation_compound_b        among: ["neonicotinoid"];
    parameter "immigration_rate"           var: immigration_rate           among: [0.05];
    parameter "Seasons to simulate"        var: max_seasons                among: [30];

    init {
        // season-1 pesticide_choice seeding now handled centrally in the model's
        // global init -- see comment there.
        last_season_money <- 0.0;
        prev_season_profit <- 0.0;
        save "run_id,strategy,adaptive_profit_mode,rotation_reactive,calendar_interval,pesticide_threshold,pesticide_choice,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_adaptive_farmer_grid.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// Sweep_AdaptiveFarmer_Grid above only tests backoff at the default
// immigration_rate (0.05). Does backoff still add value once immigration_rate
// is already substantial enough to help resistance on its own, or is its
// benefit specific to the low-immigration regime this model has mostly been
// calibrated against? rotation_mode pinned false throughout (no REACTIVE) to
// isolate the backoff mechanism alone; strategy pinned to calendar, where
// backoff's effect is cleanest. 2x4 factorial (8 conditions). parallel: false,
// per the standing rule for any experiment that logs incrementally per-row to
// a shared CSV.
// ===========================================================================
experiment Sweep_AdaptiveFarmer_Immigration_Grid type: batch repeat: 40 keep_seed: false parallel: false until: season > max_seasons {
    parameter "Strategy"                          var: farmer_strategy                     among: ["calendar"];
    parameter "Batch mode"                        var: batch_mode                          among: [true];
    parameter "Adaptive farmer x immigration mode" var: adaptive_farmer_immigration_sweep_mode among: [true];
    parameter "Adaptive profit backoff"           var: adaptive_profit_mode                among: [true, false];
    parameter "Rotation mode"                     var: rotation_mode                       among: [false];
    parameter "immigration_rate"                  var: immigration_rate                    among: [0.05, 0.20, 0.40, 0.70];
    parameter "Seasons to simulate"                var: max_seasons                         among: [30];

    init {
        last_season_money <- 0.0;
        prev_season_profit <- 0.0;
        save "run_id,strategy,adaptive_profit_mode,immigration_rate,calendar_interval,pesticide_choice,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_adaptive_farmer_immigration_grid.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// The main Adaptive Farmer Sweep found calendar + REACTIVE + backoff never
// reaches RF=0.99 within 30 seasons at the default immigration_rate (final
// RF=0.825, still climbing at S30). The first run of this experiment (60
// seasons) confirmed the climb continues rather than plateauing: RF went
// 0.826 -> 0.955 with no sign of leveling off by S60. Still ambiguous
// whether it genuinely never fixates or just needs more seasons -- extended
// to max_seasons=120 (double the 60-season horizon) to find out. Every
// parameter below is pinned to a single value (not swept), so this is a
// pure replication run for statistical confidence at a longer horizon, not
// a factorial. Own dedicated gate + CSV, does not touch
// sensitivity_output_adaptive_farmer_grid.csv.
// ===========================================================================
experiment Sweep_AdaptiveFarmer_LongHorizon type: batch repeat: 40 keep_seed: false parallel: false until: season > max_seasons {
    parameter "Strategy"                  var: farmer_strategy                  among: ["calendar"];
    parameter "Batch mode"                var: batch_mode                       among: [true];
    parameter "Long-horizon confirm mode" var: adaptive_farmer_longhorizon_mode among: [true];
    parameter "Adaptive profit backoff"   var: adaptive_profit_mode             among: [true];
    parameter "Rotation mode (REACTIVE)"  var: rotation_mode                    among: [true];
    parameter "rotation_pattern"          var: rotation_pattern                 among: ["REACTIVE"];
    parameter "Compound A"                var: rotation_compound_a              among: ["etofenprox"];
    parameter "Compound B"                var: rotation_compound_b              among: ["neonicotinoid"];
    parameter "immigration_rate"          var: immigration_rate                 among: [0.05];
    parameter "Seasons to simulate"       var: max_seasons                      among: [120];

    init {
        last_season_money <- 0.0;
        prev_season_profit <- 0.0;
        save "run_id,strategy,adaptive_profit_mode,rotation_reactive,calendar_interval,pesticide_threshold,pesticide_choice,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_adaptive_farmer_longhorizon.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// Does backoff's benefit generalize to plain, fixed A/B rotation, not just
// REACTIVE's adaptive compound choice? The main Adaptive Farmer Sweep only
// crosses backoff with REACTIVE; this crosses it with the simpler mechanism
// tested standalone in Batch_Rotation_Grid instead. 2x2 factorial (backoff x
// plain-rotation), strategy pinned to calendar (where backoff's effect is
// cleanest), same 30-season horizon as the original factorial, for direct
// comparability.
// ===========================================================================
experiment Sweep_AdaptiveFarmer_Rotation_Grid type: batch repeat: 40 keep_seed: false parallel: false until: season > max_seasons {
    parameter "Strategy"                     var: farmer_strategy                    among: ["calendar"];
    parameter "Batch mode"                   var: batch_mode                         among: [true];
    parameter "Backoff x rotation sweep mode" var: adaptive_farmer_rotation_sweep_mode among: [true];
    parameter "Adaptive profit backoff"      var: adaptive_profit_mode               among: [true, false];
    parameter "Rotation mode (plain AB)"     var: rotation_mode                      among: [true, false];
    parameter "rotation_pattern"             var: rotation_pattern                   among: ["AB"];
    parameter "Compound A"                   var: rotation_compound_a                among: ["etofenprox"];
    parameter "Compound B"                   var: rotation_compound_b                among: ["neonicotinoid"];
    parameter "immigration_rate"             var: immigration_rate                   among: [0.05];
    parameter "Seasons to simulate"          var: max_seasons                        among: [30];

    init {
        last_season_money <- 0.0;
        prev_season_profit <- 0.0;
        save "run_id,strategy,adaptive_profit_mode,rotation_mode,calendar_interval,pesticide_choice,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_adaptive_farmer_rotation_grid.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// Mirror of Sweep_AdaptiveFarmer_Grid above, testing the escalation hypothesis
// instead of backoff. Literature review (farmer behavior under perceived
// pesticide resistance) found real farmers often respond to declining
// performance by spraying MORE, not less -- this experiment tests that
// alternative directly under the same factorial structure, so results are
// directly comparable row-for-row against the backoff sweep.
// 2x2x2 factorial: farmer_strategy x adaptive_escalate_mode x rotation_mode
// (REACTIVE on/off).
// ===========================================================================
experiment Sweep_AdaptiveFarmer_Escalate_Grid type: batch repeat: 40 keep_seed: false parallel: false until: season > max_seasons {
    parameter "Strategy"                     var: farmer_strategy              among: ["calendar", "threshold"];
    parameter "Batch mode"                   var: batch_mode                   among: [true];
    parameter "Adaptive escalate sweep mode" var: adaptive_escalate_sweep_mode among: [true];
    parameter "Adaptive profit escalation"   var: adaptive_escalate_mode       among: [true, false];
    parameter "Rotation mode (REACTIVE)"     var: rotation_mode                among: [true, false];
    parameter "rotation_pattern"             var: rotation_pattern             among: ["REACTIVE"];
    parameter "Compound A"                   var: rotation_compound_a          among: ["etofenprox"];
    parameter "Compound B"                   var: rotation_compound_b          among: ["neonicotinoid"];
    parameter "immigration_rate"             var: immigration_rate             among: [0.05];
    parameter "Seasons to simulate"          var: max_seasons                  among: [30];

    init {
        // season-1 pesticide_choice seeding handled centrally in the model's
        // global init -- see comment there.
        last_season_money <- 0.0;
        prev_season_profit <- 0.0;
        save "run_id,strategy,adaptive_escalate_mode,rotation_reactive,calendar_interval,pesticide_threshold,pesticide_choice,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_adaptive_farmer_escalate_grid.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// Categorical strategy-swap mechanism: a bigger follow-up to backoff/
// escalation. Where backoff/escalation adjust *how hard* the farmer sprays
// within one strategy, this swaps the farmer's whole strategy family --
// calendar -> threshold -> none -> calendar -- when triggered. Two trigger
// definitions, tested as two separate experiments (not composed): profit-based
// (mirrors backoff/escalation's trigger) and resistance-based (tab4 Section 3
// sketch: "if resistant_fraction > 0.5, switch"). Reversible cycle, no
// cap/floor -- a farmer can complete a full loop back to their starting
// strategy if the trigger keeps firing. Standalone: not crossed with
// rotation/REACTIVE and not composed with adaptive_profit_mode/
// adaptive_escalate_mode, to keep the comparison clean (same reasoning as
// keeping escalation separate from backoff). "none" is included as a starting
// strategy alongside calendar/threshold: a farmer who starts by not spraying
// can still get pulled into the cycle once yield-loss profit or resistance
// (via others' diffusion) crosses the trigger, so it is a meaningful
// condition, not a dead one.
// ===========================================================================
experiment Sweep_StrategySwap_Profit_Grid type: batch repeat: 40 keep_seed: false parallel: false until: season > max_seasons {
    parameter "Strategy"                       var: farmer_strategy                   among: ["calendar", "threshold", "none"];
    parameter "Batch mode"                     var: batch_mode                        among: [true];
    parameter "Strategy swap sweep mode"       var: strategyswap_profit_sweep_mode    among: [true];
    parameter "Strategy swap (profit trigger)" var: adaptive_strategyswap_profit_mode among: [true, false];
    parameter "immigration_rate"               var: immigration_rate                  among: [0.05];
    parameter "Seasons to simulate"            var: max_seasons                       among: [30];

    init {
        last_season_money <- 0.0;
        prev_season_profit <- 0.0;
        strategyswap_count <- 0;
        save "run_id,strategy,adaptive_strategyswap_profit_mode,adaptive_strategyswap_resistance_mode,strategyswap_count,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_strategyswap_grid_profit.csv" format: "text" rewrite: true;
    }
}

// ===========================================================================
// Mirror of Sweep_StrategySwap_Profit_Grid above, using the resistance-
// threshold trigger (tab4 Section 3 sketch) instead of profit. Separate
// output file from the profit-trigger experiment (both trigger-mode booleans
// are still logged per row, for a clean header, but the two experiments' own
// rewrite:true inits would otherwise collide on a shared file -- same
// reasoning as the compound-sequence calendar/threshold split), same column
// shape.
// ===========================================================================
experiment Sweep_StrategySwap_Resistance_Grid type: batch repeat: 40 keep_seed: false parallel: false until: season > max_seasons {
    parameter "Strategy"                           var: farmer_strategy                       among: ["calendar", "threshold", "none"];
    parameter "Batch mode"                         var: batch_mode                            among: [true];
    parameter "Strategy swap sweep mode"           var: strategyswap_resistance_sweep_mode    among: [true];
    parameter "Strategy swap (resistance trigger)" var: adaptive_strategyswap_resistance_mode among: [true, false];
    parameter "strategyswap_resistance_threshold"  var: strategyswap_resistance_threshold     among: [0.5];
    parameter "immigration_rate"                   var: immigration_rate                      among: [0.05];
    parameter "Seasons to simulate"                var: max_seasons                            among: [30];

    init {
        strategyswap_count <- 0;
        save "run_id,strategy,adaptive_strategyswap_profit_mode,adaptive_strategyswap_resistance_mode,strategyswap_count,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_strategyswap_grid_resistance.csv" format: "text" rewrite: true;
    }
}
