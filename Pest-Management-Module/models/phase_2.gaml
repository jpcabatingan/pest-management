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
    // extra multiplicative term using a literature-sourced rate. See phase_1.gaml
    // for the same change applied to the single-plot model.
    // TODO: update tab3.md (D3 design decisions, global var table, OPEN
    // CALIBRATION ITEMS, tab1.md S2.1 model implication) to document this change.
    float pest_growth_rate     <- 0.033038;
    
	// placeholder values only; literature backs damage ranking but not actual values   
    float sw_phase1 <- 0.2;
    float sw_phase2 <- 0.9;
    float sw_phase3 <- 0.7;
    float sw_phase4 <- 0.4;
    
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

    // ---- Per-pesticide-class parameterization (added June 23 2026, UNCALIBRATED) ----
    // "starfarm" = current global efficacy/selection_pressure_constant behavior, unchanged.
    // "etofenprox"/"neonicotinoid" values below are PLACEHOLDERS for proposed structure only,
    // ordering reflects qualitative Khoa et al. 2018 claims (etofenprox lower resistance/resurgence
    // risk), not measured rates. Do not cite these numbers anywhere. See phase_1.gaml for same change.
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

    // ---- Interval / threshold sweep gates (added June 29 2026) ----
    // Task 1, phase\_2-native version: same question as the phase\_1 sweep (how does
    // yield and spray count change across calendar_interval and pesticide_threshold
    // values), but run here so resistant_fraction is tracked in the same run instead
    // of being combined afterward from two separate experiments.
    bool   interval_sweep_mode  <- false;  // true only in Sweep_CalendarInterval_Grid
    bool   threshold_sweep_mode <- false;  // true only in Sweep_Threshold_Grid

    // ---- Per-compound threshold sweep gates (added June 29 2026) ----
    // Same threshold sweep as above, but with pesticide_choice fixed to a specific
    // compound, so resistant_fraction reflects that compound's own selection_pressure
    // and efficacy instead of starfarm's. Needed because threshold's spray cadence
    // depends on efficacy, which differs per compound, so the starfarm-only sweep
    // above cannot be rescaled to get real etofenprox/neonicotinoid numbers.
    bool   threshold_sweep_mode_etofenprox <- false;  // true only in Sweep_Threshold_Grid_Etofenprox
    bool   threshold_sweep_mode_neonic     <- false;  // true only in Sweep_Threshold_Grid_Neonicotinoid

    // ---- Compound baseline gates (added June 29 2026) ----
    // Run the standard 3-strategy baseline (same as Batch_Harvest_Grid) but with
    // pesticide_choice fixed to a specific compound, so etofenprox and neonicotinoid
    // get a real side-by-side baseline comparison, not just the threshold sweep.
    bool   compound_baseline_etofenprox <- false;  // true only in Batch_Harvest_Grid_Etofenprox
    bool   compound_baseline_neonic     <- false;  // true only in Batch_Harvest_Grid_Neonicotinoid

    init {
        emergence_threshold <- tt_emergence;
        flowering_threshold <- tt_emergence + tt_veg;
        maturity_threshold  <- tt_emergence + tt_veg + tt_rep;
        create Farmer number: 1;
        run_id <- farmer_strategy + "_" + int(self);

        // Per-pesticide-class instances. PLACEHOLDER values, see comment above
        // pesticide_choice. selection_pressure here replaces selection_pressure_constant
        // when pesticide_choice != "starfarm".
        create pesticide_class { name <- "etofenprox";   efficacy <- 0.7; resurgence_type <- "none";   selection_pressure <- 0.015; cost <- 110.6; }
        create pesticide_class { name <- "neonicotinoid"; efficacy <- 0.8; resurgence_type <- "chronic"; selection_pressure <- 0.025; cost <- 100.0; }
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
	        
	        // Bug fix (added June 29 2026): this write used to fire on ANY batch_mode run,
	        // including the interval/threshold/compound sweep experiments below, which
	        // silently appended their rows on top of the baseline file every time they ran.
	        // Restricted to fire only when no sweep gate is active, so this file stays the
	        // clean output of Batch_Harvest_Grid alone, as originally intended.
	        // active compound's cost, for the cost_per_spray CSV column below. pesticide_choice
	        // is fixed for the whole run, so this mirrors the lookup in Farmer.decide_spray.
	        float logged_cost <- spray_cost;
	        if (pesticide_choice != "starfarm") {
	            pesticide_class pcc <- pesticide_class first_with (each.name = pesticide_choice);
	            if (pcc != nil) { logged_cost <- pcc.cost; }
	        }

	        if (batch_mode and not (interval_sweep_mode or threshold_sweep_mode
	                or threshold_sweep_mode_etofenprox or threshold_sweep_mode_neonic
	                or compound_baseline_etofenprox or compound_baseline_neonic)) {
	            string hrow <- "" + run_id + "," + farmer_strategy + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save hrow to: "harvest_grid_output.csv" format: "text" rewrite: false;
	        }

	        // log interval-sweep summary (Task 1, added June 29 2026): same row shape as
	        // harvest_grid_output.csv, plus calendar_interval, so resistant_fraction is
	        // tracked season by season for each interval value in one run
	        if (interval_sweep_mode) {
	            string irow <- "" + run_id + "," + farmer_strategy + "," + calendar_interval + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save irow to: "sensitivity_output_interval_grid.csv" format: "text" rewrite: false;
	        }

	        // log threshold-sweep summary (Task 1, added June 29 2026): same idea, for
	        // pesticide_threshold instead of calendar_interval
	        if (threshold_sweep_mode) {
	            string trow <- "" + run_id + "," + farmer_strategy + "," + pesticide_threshold + "," + season + "," + grid_x + "," + grid_y + ","
	                         + grain_tha + "," + yield_loss_tha + "," + spray_count + "," + resistant_fraction + "," + logged_cost + "\n";
	            save trow to: "sensitivity_output_threshold_grid.csv" format: "text" rewrite: false;
	        }

	        // log per-compound threshold-sweep summary (added June 29 2026): same row shape,
	        // run with pesticide_choice fixed to etofenprox or neonicotinoid so spray cadence
	        // and resistance both reflect that compound's own efficacy and selection_pressure
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

	        // log compound-baseline summary (added June 29 2026): same row shape as
	        // harvest_grid_output.csv, run with pesticide_choice fixed to etofenprox or
	        // neonicotinoid. This block was missing before, which is why the first runs
	        // of Batch_Harvest_Grid_Etofenprox/Neonicotinoid produced header-only CSVs.
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
// pesticide_class: per-compound parameterization (added June 23 2026, UNCALIBRATED).
// See pesticide_choice comment in global{} for sourcing caveat.
// ===========================================================================

species pesticide_class {
    string name;
    float  efficacy;
    string resurgence_type;
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
        // highest during vegetative (sw_phase2=0.9), lowest during grain fill (sw_phase4=0.4)
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
    
    // fraction of the local pest population that is resistant to the current pesticide
    // increases by selection_pressure_constant with every spray
    float resistant_fraction <- 0.0;
    
    // how many days have passed since the last spray on this plot
    // used to enforce the spray cooldown
    int days_since_last_spray <- 0;
    int spray_count <- 0; // total number of sprays applied to this plot across the current season

    // total number of sprays ever applied to this plot, across all seasons. Unlike
    // spray_count, this does NOT reset at sow_crop. Drives the piecewise resistance
    // stage trigger in Farmer.decide_spray (added June 30 2026, see D9 update):
    // resistance is an allele-frequency shift in the pest population, inherited by
    // each new season's population from the survivors of the last, so the stage a
    // plot is "in" should reflect its full spray history, not just this season's count.
    int lifetime_spray_count <- 0;


    // SOW CROP REFLEX
    // fires when pending_sow is true — creates a new crop and resets plot state for the new season
    reflex sow_crop when: pending_sow {
    
        // reset pest and spray state at the start of each season
        pest_load <- 0.0;
        days_since_last_spray <- 0;
        spray_count <- 0;
        
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
            if      (pest_load < 0.1) { c <- rgb(0, 112, 48); }     // dark green  — healthy, low pressure
            else if (pest_load < 0.4) { c <- rgb(198, 239, 206); }  // light green — mild pressure
            else if (pest_load < 0.7) { c <- rgb(255, 255, 0); }    // yellow      — moderate pressure
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
// one farmer agent manages all plots each cycle
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

            // spray decision depends on the current strategy:
            // none     	- never spray
            // calendar 	- spray whenever the fixed interval has elapsed, ignoring pest levels
            // threshold 	- spray only when cooldown is satisfied AND pest_load exceeds the threshold
            if (farmer_strategy = "none") {
                should_spray <- false;
            } else if (farmer_strategy = "calendar") {
                should_spray <- days_since_last_spray >= calendar_interval;
            } else {
                should_spray <- cooldown_ok and (pest_load > pesticide_threshold);
            }

            if (should_spray) {
            
                float pest_before <- pest_load; // snapshot pest_load before spraying for the console log

                // active compound's efficacy, selection_pressure, and cost (starfarm = unchanged globals)
                float active_efficacy <- efficacy;
                float active_selection_pressure <- selection_pressure_constant;
                float active_cost <- spray_cost;
                if (pesticide_choice != "starfarm") {
                    pesticide_class pc <- pesticide_class first_with (each.name = pesticide_choice);
                    if (pc != nil) {
                        active_efficacy <- pc.efficacy;
                        active_selection_pressure <- pc.selection_pressure;
                        active_cost <- pc.cost;
                    }
                }
                
                // realized efficacy is reduced by how resistant the local pest population already is
                // as resistant_fraction increases, each spray removes less pest pressure
                float realized_efficacy <- active_efficacy * (1.0 - resistant_fraction);
                
                // apply the spray: reduce pest_load by the realized efficacy fraction
                // pest_load is not zeroed out — partial suppression keeps the sawtooth dynamics realistic
                pest_load <- pest_load * (1.0 - realized_efficacy);
                
                // ---- Piecewise resistance ratchet (added June 29 2026, UNCALIBRATED;
                // stage trigger switched from season spray_count to lifetime_spray_count
                // June 30 2026, see D9 update) ----
                // 3-stage rate by THIS PLOT's LIFETIME spray count (spray_number, 1-indexed,
                // computed before lifetime_spray_count increments below): 1-3 / 4-7 / 8+.
                // Stage boundaries + shape (slow -> moderate -> steep) follow Khoa et al.
                // (2018)'s 3-stage resistance profile (tab3.md D9 / Open Calibration Items:
                // "points to 3 resistance stages, not steady linear growth... ends steep,
                // not flat"). Stage multipliers (0.5x / 1.0x / 2.5x on active_selection_pressure)
                // are placeholders -- stage count/shape is literature-motivated, magnitudes
                // are not. Scales whichever active_selection_pressure is in effect, so
                // per-compound differences (starfarm/etofenprox/neonicotinoid) still apply.
                //
                // Uses lifetime_spray_count, not the season-resetting spray_count: resistance
                // is an allele-frequency shift inherited across seasons by the survivors of
                // each season's spraying (same reason resistant_fraction itself never resets
                // at sow_crop). A plot sprayed 5 times a season for 3 straight seasons has
                // genuinely endured more cumulative selection pressure than a plot in its
                // first season, and should be further along the stage curve, not reset to
                // "slow" every harvest regardless of history.
                int spray_number <- lifetime_spray_count + 1;
                float resistance_increment <- active_selection_pressure;      // stage 2 (sprays 4-7): baseline rate
                if (spray_number <= 3) {
                    resistance_increment <- active_selection_pressure * 0.5;  // stage 1 (sprays 1-3): slow
                } else if (spray_number > 7) {
                    resistance_increment <- active_selection_pressure * 2.5;  // stage 3 (sprays 8+): steep
                }

                // ratchet up resistance on this plot
                // each spray selects for resistant individuals, so resistant_fraction only ever increases
                resistant_fraction <- min(1.0, resistant_fraction + resistance_increment);
                
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
    parameter "Seasons to simulate"          var: max_seasons         min: 1     max: 5;
    parameter "pest_daily_increment"         var: pest_daily_increment min: 0.01 max: 0.1;
    parameter "pest_growth_rate (life-table)" var: pest_growth_rate    min: 0.0   max: 0.1;
    parameter "min_k_pest"                   var: min_k_pest          min: 0.1   max: 1.0;

    parameter "Strategy"                     var: farmer_strategy among: ["none", "calendar", "threshold"];
    parameter "Pesticide class"              var: pesticide_choice    among: ["starfarm", "etofenprox", "neonicotinoid"];
    parameter "pesticide_threshold"          var: pesticide_threshold min: 0.05  max: 1.0;
    parameter "spray_cooldown (days)"        var: spray_cooldown      min: 1     max: 30;
    parameter "calendar_interval (days)"     var: calendar_interval   min: 7     max: 30;
    parameter "efficacy (0 to 1)"            var: efficacy            min: 0.1   max: 1.0;
    parameter "spray_cost"                   var: spray_cost          min: 0.0   max: 1000.0;
    parameter "initial_money"                var: initial_money       min: 0.0   max: 50000.0;
    parameter "grain_price (per t/ha)" var: grain_price min: 0.0 max: 10000.0;

    parameter "diffusion_prop"               var: diffusion_prop      min: 0.0   max: 0.5;
    parameter "selection_pressure_constant"  var: selection_pressure_constant min: 0.0 max: 0.5;
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
// SWEEP: calendar interval and pesticide threshold, phase\_2-native (Task 1,
// added June 29 2026). Same question as the phase\_1 sweep, but resistant_fraction
// is tracked here directly instead of being combined afterward from two separate
// experiments. max_seasons is bumped from 3 to 6 so there is enough resistance
// buildup to read a real trend and extrapolate to 90% resistance, instead of
// only seeing the first 3 seasons. Each experiment writes its own dedicated CSV,
// so there is no rename step needed between runs.
// ===========================================================================
experiment Sweep_CalendarInterval_Grid type: batch repeat: 40 keep_seed: false until: season > max_seasons {
    parameter "Strategy"             var: farmer_strategy        among: ["calendar"];
    parameter "Batch mode"           var: batch_mode             among: [true];
    parameter "Interval sweep mode"  var: interval_sweep_mode    among: [true];
    parameter "calendar_interval"    var: calendar_interval      among: [7, 10, 14, 21, 28];
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
// SWEEP: per-compound threshold sweep (added June 29 2026). Same as
// Sweep_Threshold_Grid above, but with pesticide_choice fixed to a specific
// compound. Needed because threshold's spray cadence depends on efficacy,
// which differs per compound (etofenprox 0.7 vs starfarm/neonicotinoid 0.8),
// so a simple rescale of the starfarm-only sweep above is not reliable.
// Each writes its own dedicated CSV, so there is no rename step needed.
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
// compound (added June 29 2026). Same shape as Batch_Harvest_Grid, default
// max_seasons (3), so this lines up directly with the existing starfarm baseline
// in tab3.md. Each writes its own dedicated CSV.
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
	