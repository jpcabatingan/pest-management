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
 * Author: Joanne Maryz Cabatingan (visuals scaffold)
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
	                // this is the synchronization mechanism — buffers are committed in Pass 3.
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
	        
        // Fires only when no sweep/experiment gate is active, so harvest_grid_output.csv
        // stays the clean output of Batch_Harvest_Grid alone.
        // Records the active compound's cost for cost_per_spray; reads plot_pesticide
        // (per-plot in heterogeneous_mode, mirrors pesticide_choice otherwise).
	        float logged_cost <- spray_cost;
	        if (plot_pesticide != "starfarm") {
	        pesticide_class pcc <- pesticide_class first_with (each.name = plot_pesticide);
	        if (pcc != nil) { logged_cost <- pcc.cost; }
	        }

	        if (batch_mode and not (interval_sweep_mode or threshold_sweep_mode
	                or threshold_sweep_mode_etofenprox or threshold_sweep_mode_neonic
	                or compound_baseline_etofenprox or compound_baseline_neonic
	                or longterm_mode or rotation_mode or heterogeneous_mode
	                or log_plot_position)) {
	            string hrow <- "" + run_id + "," + farmer_strategy + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save hrow to: "harvest_grid_output.csv" format: "text" rewrite: false;
	        }

        // log interval-sweep summary: same shape as harvest_grid_output.csv plus
        // calendar_interval, tracking resistant_fraction per season per interval
        if (interval_sweep_mode) {
	            string irow <- "" + run_id + "," + farmer_strategy + "," + calendar_interval + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save irow to: "sensitivity_output_interval_grid.csv" format: "text" rewrite: false;
	        }

        // log threshold-sweep summary: same shape, for pesticide_threshold
        if (threshold_sweep_mode) {
	            string trow <- "" + run_id + "," + farmer_strategy + "," + pesticide_threshold + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save trow to: "sensitivity_output_threshold_grid.csv" format: "text" rewrite: false;
	        }

        // log per-compound threshold-sweep: pesticide_choice fixed to a specific compound
        // so spray cadence and resistance reflect that compound's efficacy and selection_pressure
        if (threshold_sweep_mode_etofenprox) {
	            string terow <- "" + run_id + "," + farmer_strategy + "," + pesticide_threshold + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save terow to: "sensitivity_output_threshold_grid_etofenprox.csv" format: "text" rewrite: false;
	        }

	        if (threshold_sweep_mode_neonic) {
	            string tnrow <- "" + run_id + "," + farmer_strategy + "," + pesticide_threshold + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save tnrow to: "sensitivity_output_threshold_grid_neonic.csv" format: "text" rewrite: false;
	        }

        // log compound-baseline: same shape as harvest_grid_output.csv, run with
        // pesticide_choice fixed to etofenprox or neonicotinoid
        if (compound_baseline_etofenprox) {
	            string berow <- "" + run_id + "," + farmer_strategy + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save berow to: "harvest_grid_output_etofenprox.csv" format: "text" rewrite: false;
	        }

	        if (compound_baseline_neonic) {
	            string bnrow <- "" + run_id + "," + farmer_strategy + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save bnrow to: "harvest_grid_output_neonic.csv" format: "text" rewrite: false;
	        }

        // log long-term run summary: same shape as harvest_grid_output.csv plus
        // pesticide_choice column so one CSV covers all 3 compounds
        if (longterm_mode) {
	         string ltrow <- "" + run_id + "," + farmer_strategy + "," + pesticide_choice + "," + season + "," + grid_x + "," + grid_y + ","
	         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	         save ltrow to: "harvest_grid_output_longterm.csv" format: "text" rewrite: false;
	         }

        // log rotation run summary: same shape as harvest_grid_output_longterm.csv.
        // pesticide_choice reflects the compound active this season (already flipped
        // at the previous season boundary).
        if (rotation_mode) {
	            string rtrow <- "" + run_id + "," + farmer_strategy + "," + pesticide_choice + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save rtrow to: "harvest_grid_output_rotation.csv" format: "text" rewrite: false;
	        }

        // log heterogeneous run summary: adds plot_strategy and plot_pesticide columns
        // so each row records the individual plot's assignment, not the global defaults
        if (heterogeneous_mode) {
	            string htrow <- "" + run_id + "," + plot_strategy + "," + plot_pesticide + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save htrow to: "harvest_grid_output_heterogeneous.csv" format: "text" rewrite: false;
	        }

        // log spatial breakdown: adds plot_position column so results can be grouped
        // by corner / edge / interior
        if (log_plot_position) {
	            string sprow <- "" + run_id + "," + farmer_strategy + "," + plot_position + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save sprow to: "harvest_grid_output_spatial.csv" format: "text" rewrite: false;
	        }

        // log immigration sweep summary: each row includes immigration_rate so
        // per-season RF decay strength is recorded
        if (sweep_immigration_mode) {
	            string imrow <- "" + run_id + "," + farmer_strategy + "," + immigration_rate + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save imrow to: "sensitivity_output_immigration_grid.csv" format: "text" rewrite: false;
	        }

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
        // apply inter-season resistance decay via immigration: a fraction (immigration_rate)
        // of the local pest population is replaced by susceptible immigrants, reducing RF.
        // Fires once per season boundary. immigration_rate=0.0 = no decay.
        // Both pools decay independently (per-compound pools).
        if (immigration_rate > 0.0) {
            ask Plot {
                rf_etofenprox <- rf_etofenprox * (1.0 - immigration_rate);
                rf_neonicotinoid <- rf_neonicotinoid * (1.0 - immigration_rate);
                // sync backward-compat field: effective RF = max of both pools at season boundary
                resistant_fraction <- max(rf_etofenprox, rf_neonicotinoid);
            }
        }
        // rotation: alternate pesticide_choice at every season boundary.
        // Odd seasons use compound_a, even seasons use compound_b.
        // pesticide_choice is a global, so flipping it affects all plots next season.
        // season has already been incremented, so the new value is used to decide.
	        if (rotation_mode) {
	            pesticide_choice <- (season mod 2 = 1) ? rotation_compound_a : rotation_compound_b;
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
    // Ratio (etofenprox:neonicotinoid) = 1.106. Neonicotinoid anchored at 100 to match the
    // model's existing spray_cost default; etofenprox scaled by the same ratio.
    // starfarm keeps using the global spray_cost (100), unchanged, since it has no real
    // compound to anchor to.
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
    // fires when pending_sow is true — creates a new crop and resets plot state for the new season
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
            if      (pest_load < 0.1)  { c <- rgb(0, 112, 48); }     // dark green  — healthy, low pressure
            else if (pest_load <= 0.4) { c <- rgb(198, 239, 206); }  // light green — mild pressure
            else if (pest_load <= 0.7) { c <- rgb(255, 255, 0); }    // yellow      — moderate pressure
            else                      { c <- rgb(88, 57, 39); }     // brown       — severe, crop overwhelmed
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
    // no image asset is used — the shape is drawn directly in code
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
// directly rather than combined from separate experiments. max_seasons bumped
// from 3 to 6 for enough resistance buildup to read a real trend.
// Each experiment writes its own dedicated CSV.
// ===========================================================================
experiment Sweep_CalendarInterval_Grid type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"             var: farmer_strategy        among: ["calendar"];
    parameter "Batch mode"           var: batch_mode             among: [true];
    parameter "Interval sweep mode"  var: interval_sweep_mode    among: [true];
    parameter "calendar_interval"    var: calendar_interval      among: [1, 3, 5, 7, 10, 14, 21, 28];
    parameter "Seasons to simulate"  var: max_seasons            among: [6];

    init {
        save "run_id,strategy,calendar_interval,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
             to: "sensitivity_output_interval_grid.csv" format: "text" rewrite: true;
    }
}

experiment Sweep_Threshold_Grid type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"             var: farmer_strategy        among: ["threshold"];
    parameter "Batch mode"           var: batch_mode             among: [true];
    parameter "Threshold sweep mode" var: threshold_sweep_mode   among: [true];
    parameter "pesticide_threshold"  var: pesticide_threshold    among: [0.1, 0.2, 0.3, 0.4, 0.5];
    parameter "Seasons to simulate"  var: max_seasons            among: [6];

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
        save "run_id,strategy,pesticide_choice,season,plot_x,plot_y,grain_tha,pest_loss_tha,spray_count,resistant_fraction,cost_per_spray\n"
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
        // seed season 1 with compound A so rotation starts correctly from the first spray
        // without this, season 1 would use the global default ("starfarm") until the
        // first harvest fires the season-boundary flip.
        pesticide_choice <- rotation_compound_a;
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
	