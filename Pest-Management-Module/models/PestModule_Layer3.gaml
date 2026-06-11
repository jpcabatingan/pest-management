/**
 * Name:        PestModule_Layer3
 * Description: Standalone pest management model - Layer 3: Farmer spray decision.
 *              Adds a Farmer agent that observes pest_load and decides to spray
 *              based on one of three strategies: none, calendar, or threshold/EIL.
 *              Completing the full pest-crop-farmer loop.
 *
 * What changed from Layer 2:
 *   Global  : + farmer_strategy, pesticide_threshold, spray_cooldown,
 *               calendar_interval, efficacy, spray_cost, initial_money
 *   Plot    : + days_since_last_spray, spray_count
 *               sow_crop: also resets spray counters
 *             + reflex advance_counters (increments days_since_last_spray daily)
 *               check_maturity: also reports spray count and net money
 *   Farmer  : new species - decide_spray reflex with strategy dispatch
 *   Experiment: + strategy parameters, money chart, spray count monitor
 *
 * Strategies:
 *   "none"      - never spray (Layer 2 baseline - 44.7% yield loss at defaults)
 *   "calendar"  - spray every calendar_interval days regardless of pest_load
 *   "threshold" - spray when pest_load > pesticide_threshold AND cooldown elapsed
 *
 * STAR-FARM alignment:
 *   Spray effect: pest_load *= (1 - efficacy)  vs STAR-FARM: pest_load <- 0.0
 *   Threshold defaults: sustainable 0.30 (Parameters.gaml, sust_pesticide_threshold)
 *   Calendar default: every 14 days ~ BAU Mekong Delta practice (~4 sprays/season)
 *
 * Author: Joanne Maryz Cabatingan
 */

model PestModule_Layer3

global {

    // ---- Synthetic weather (Layer 1) ------------------------------------------
    float t_mean    <- 28.0;
    float solar_rad <- 18.0;
    float humidity  <- 82.0;

    // ---- Thermal time (Layer 1) ------------------------------------------------
    float Tbase <- 10.0;

    // ---- Crop growth (Layer 1) -------------------------------------------------
    float potential_rue <- 0.77; // OM5451/OM6976: variety.RUE (1.2) * rue_efficiency_factor (0.64)
                              // cultivars.csv + Parameters.gaml:106
                              // treat as sensitivity parameter; range 0.64–0.77 across varieties
    float fAPAR_phase1  <- 0.2;
    float fAPAR_phase2  <- 0.7;
    float fAPAR_phase3  <- 0.9;
    float fAPAR_phase4  <- 0.85;

    // ---- Pest parameters (Layer 2) ---------------------------------------------
    float min_k_pest           <- 0.5;
    float pest_humidity_limit  <- 80.0;
    float pest_temp_limit      <- 27.0;
    float pest_infection_prob  <- 0.8;
    float pest_daily_increment <- 0.03;
    float sw_phase1 <- 0.2;
    float sw_phase2 <- 0.9;
    float sw_phase3 <- 0.7;
    float sw_phase4 <- 0.4;
    float pest_decay_coeff <- 0.95;

    // ---- Phenological thresholds (Layer 1) ------------------------------------
    float tt_emergence <- 100.0;
    float tt_veg       <- 700.0;
    float tt_rep       <- 500.0;
    float emergence_threshold <- 100.0;
    float flowering_threshold <- 800.0;
    float maturity_threshold  <- 1300.0;

    // ---- Season control -------------------------------------------------------
    int season      <- 1;
    int max_seasons <- 3;

    // ---- Output helpers -------------------------------------------------------
    float biomass_to_ton_conv <- 0.01;
    float harvest_index       <- 0.45;

    // ---- Farmer decision parameters (Layer 3) ---------------------------------
    // Strategy: "none" (no spray), "calendar" (fixed schedule), "threshold" (EIL-style)
    string farmer_strategy     <- "threshold";
    float  pesticide_threshold <- 0.3;    // spray if pest_load exceeds this (threshold strategy)
                                           // STAR-FARM sustainable = 0.30, BAU ~ 0.20
    int    spray_cooldown      <- 7;       // min days between any two sprays (all strategies)
    int    calendar_interval   <- 14;      // days between sprays (calendar strategy only)
    float  efficacy            <- 0.8;     // fraction of pest_load eliminated per spray
                                           // replaces STAR-FARM's instant pest_load <- 0
    float  spray_cost          <- 100.0;   // cost per spray event (arbitrary units)
    float  initial_money       <- 5000.0;  // farmer starting budget

    init {
        emergence_threshold <- tt_emergence;
        flowering_threshold <- tt_emergence + tt_veg;
        maturity_threshold  <- tt_emergence + tt_veg + tt_rep;
        create Plot number: 1;
        create Farmer number: 1;
    }

    reflex stop_when_done when: season > max_seasons {
        write "All " + max_seasons + " season(s) complete. Strategy: " + farmer_strategy;
        do pause;
    }
}

// ---------------------------------------------------------------------------
// Execution order by declaration: Crop -> Plot -> Farmer
// Crop grows first (using previous cycle pest_load), then Plot updates pest,
// then Farmer observes post-update pest_load and decides to spray.
// Spray effect visible in next cycle's crop growth.
// ---------------------------------------------------------------------------

species Crop {

    float biomass         <- 0.0;
    float thermal_time    <- 0.0;
    float growth_stage    <- 0.0;
    float pest_yield_loss <- 0.0;
    float k_pest          <- 1.0;

    reflex accumulate {
        float dTT <- max(0.0, t_mean - Tbase);
        thermal_time <- thermal_time + dTT;
        growth_stage <- min(1.0, thermal_time / maturity_threshold);
    }

    reflex grow {
        float fAPAR <- fAPAR_phase1;
        if      (thermal_time < emergence_threshold) { fAPAR <- fAPAR_phase1; }
        else if (thermal_time < flowering_threshold) { fAPAR <- fAPAR_phase2; }
        else if (thermal_time < maturity_threshold)  { fAPAR <- fAPAR_phase3; }
        else                                         { fAPAR <- fAPAR_phase4; }

        float stage_weight <- sw_phase1;
        if      (thermal_time < emergence_threshold) { stage_weight <- sw_phase1; }
        else if (thermal_time < flowering_threshold) { stage_weight <- sw_phase2; }
        else if (thermal_time < maturity_threshold)  { stage_weight <- sw_phase3; }
        else                                         { stage_weight <- sw_phase4; }

        float plot_pest_load <- empty(Plot) ? 0.0 : first(Plot).pest_load;
        k_pest <- max(min_k_pest, 1.0 - (stage_weight * plot_pest_load));

        float daily_growth_potential <- potential_rue * solar_rad * fAPAR;
        float daily_growth_actual    <- daily_growth_potential * k_pest;
        pest_yield_loss <- pest_yield_loss + (daily_growth_potential - daily_growth_actual);
        biomass         <- biomass + daily_growth_actual;
    }
}

// ---------------------------------------------------------------------------

species Plot {

    Crop  associated_crop     <- nil;
    bool  pending_sow         <- true;
    float pest_load           <- 0.0;
    int   days_since_last_spray <- 0;   // resets to 0 after each spray and at sowing
    int   spray_count         <- 0;     // total sprays this season

    reflex sow_crop when: pending_sow {
        pest_load            <- 0.0;
        days_since_last_spray <- 0;
        spray_count          <- 0;
        create Crop returns: c;
        associated_crop <- first(c);
        pending_sow <- false;
        write "Day " + cycle + " | Season " + season + ": sown. Strategy=" + farmer_strategy;
    }

    reflex update_pest when: associated_crop != nil {
        if (humidity > pest_humidity_limit and t_mean > pest_temp_limit and flip(pest_infection_prob)) {
            pest_load <- pest_load + pest_daily_increment;
        }
        pest_load <- min(1.0, pest_load);
    }

    // Increment cooldown counter each day the crop is alive
    // Farmer's spray reflex may reset this to 0 later in the same cycle
    reflex advance_counters when: associated_crop != nil {
        days_since_last_spray <- days_since_last_spray + 1;
    }

    reflex pest_decay when: associated_crop = nil and pest_load > 0.0 {
        pest_load <- pest_load * pest_decay_coeff;
    }

    reflex check_maturity when: associated_crop != nil and associated_crop.thermal_time >= maturity_threshold {
        float grain_tha      <- associated_crop.biomass * harvest_index * biomass_to_ton_conv;
        float yield_loss_tha <- associated_crop.pest_yield_loss * harvest_index * biomass_to_ton_conv;
        float farmer_money   <- empty(Farmer) ? 0.0 : first(Farmer).money;
        write "Day " + cycle + " | Season " + season + ": harvested. Strategy=" + farmer_strategy + ". Grain=" + (grain_tha with_precision 2) + "t/ha. PestLoss=" + (yield_loss_tha with_precision 2) + "t/ha. Sprays=" + spray_count + ". Money=" + (farmer_money with_precision 0) + ".";
        ask associated_crop { do die; }
        associated_crop <- nil;
        season <- season + 1;
        if (season <= max_seasons) { pending_sow <- true; }
    }
}

// ---------------------------------------------------------------------------
// Farmer declared after Plot: executes after Plot's update_pest each cycle.
// Farmer observes today's post-update pest_load and sprays if conditions met.
// Spray effect (reduced pest_load) is seen in next cycle's Crop growth.
// ---------------------------------------------------------------------------

species Farmer {

    float money <- initial_money;

    reflex decide_spray when: not empty(Plot) and first(Plot).associated_crop != nil {
        Plot the_plot <- first(Plot);
        bool cooldown_ok <- the_plot.days_since_last_spray >= spray_cooldown;
        bool should_spray <- false;

        if (farmer_strategy = "none") {
            should_spray <- false;
        } else if (farmer_strategy = "calendar") {
            // Spray on a fixed schedule regardless of pest pressure
            should_spray <- the_plot.days_since_last_spray >= calendar_interval;
        } else {
            // Threshold strategy: spray when pest_load exceeds the economic threshold
            should_spray <- cooldown_ok and (the_plot.pest_load > pesticide_threshold);
        }

        if (should_spray) {
		    float pest_before <- the_plot.pest_load;  // capture before spray
		    the_plot.pest_load <- the_plot.pest_load * (1.0 - efficacy);
		    the_plot.days_since_last_spray <- 0;
		    the_plot.spray_count <- the_plot.spray_count + 1;
		    money <- money - spray_cost;
		    write "  -> Spray " + the_plot.spray_count + " on day " + cycle + 
		          ". pest_load_before=" + (pest_before with_precision 3) + 
		          ". pest_load_after=" + (the_plot.pest_load with_precision 3) + 
		          ". Money=" + (money with_precision 0);
		}
    }
}

// ---------------------------------------------------------------------------

experiment Layer3_FarmerDecision type: gui {

    // Layer 1 and 2 parameters
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
    parameter "min_k_pest"                   var: min_k_pest          min: 0.1   max: 1.0;

    // Layer 3 parameters
    parameter "Strategy (none/calendar/threshold)" var: farmer_strategy among: ["none", "calendar", "threshold"];
    parameter "pesticide_threshold"          var: pesticide_threshold min: 0.05  max: 1.0;
    parameter "spray_cooldown (days)"        var: spray_cooldown      min: 1     max: 30;
    parameter "calendar_interval (days)"     var: calendar_interval   min: 7     max: 30;
    parameter "efficacy (0 to 1)"            var: efficacy            min: 0.1   max: 1.0;
    parameter "spray_cost"                   var: spray_cost          min: 0.0   max: 1000.0;
    parameter "initial_money"                var: initial_money       min: 0.0   max: 50000.0;

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

        // Biomass: should rise faster than Layer 2 when spray reduces pest pressure
        display "Biomass" {
            chart "Biomass (g/m2)" type: series background: #white {
                data "Biomass" value: empty(Crop) ? 0.0 : first(Crop).biomass color: #darkgreen style: line marker: false;
            }
        }

        // Pest load: spray events visible as sharp drops, then regrowth
        // "none" strategy: same monotonic rise as Layer 2
        // "threshold/calendar": sawtooth pattern (grow -> spray -> drop -> grow)
        display "Pest pressure" {
            chart "Pest load (0 to 1)" type: series background: #white {
                data "Pest load" value: empty(Plot) ? 0.0 : first(Plot).pest_load color: #red style: line marker: false;
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
