/**
 * Name:        PestModule_Layer2
 * Description: Standalone pest management model - Layer 2: BPH pest dynamics.
 *              Adds pest_load scalar to Plot, stage-weighted k_pest damage
 *              multiplier to Crop growth, and pest_yield_loss tracking.
 *              No farmer spray decision (Layer 3).
 *
 * What changed from Layer 1:
 *   Global  : + humidity, pest threshold params, min_k_pest, pest_decay_coeff
 *   Crop    : + pest_yield_loss, k_pest (stored for charting)
 *             grow reflex: k_pest now multiplies daily_growth
 *   Plot    : + pest_load
 *             sow_crop: resets pest_load to 0 (fixes STAR-FARM gap)
 *             + reflex update_pest  (in-season weather-driven growth)
 *             + reflex pest_decay   (off-season natural decay)
 *   Experiment: + pest_load, k_pest, pest_yield_loss charts
 *
 * STAR-FARM parameter alignment:
 *   min_k_pest         = 0.5   (Parameters.gaml:151)
 *   pest_humidity_limit= 80.0  (Parameters.gaml:152)
 *   pest_temp_limit    = 27.0  (Parameters.gaml:153)
 *   pest_infection_prob= 0.8   (Parameters.gaml:154)
 *   pest_daily_increment=0.03  (Parameters.gaml:155)
 *   stage_weight values: placeholder - calibrate before integration
 *
 * Layer 3 extension points are marked with: // [LAYER 3]
 *
 * Author: Joanne Maryz Cabatingan
 */

model PestModule_Layer2

global {

    // ---- Synthetic weather ----------------------------------------------------
    float t_mean    <- 28.0;   // mean daily temperature (deg C)
    float solar_rad <- 18.0;   // daily solar radiation (MJ/m2/day)
    float humidity  <- 82.0;   // mean daily relative humidity (%)
                                // set below pest_humidity_limit (80) to suppress all pest pressure
                                // set above to enable weather-triggered pest growth

    // ---- Thermal time ---------------------------------------------------------
    float Tbase <- 10.0;        // matches Plant_growth_models.gaml:93

    // ---- Crop growth ----------------------------------------------------------
    float potential_rue <- 0.77; // OM5451/OM6976: variety.RUE (1.2) * rue_efficiency_factor (0.64)
                              // cultivars.csv + Parameters.gaml:106
                              // treat as sensitivity parameter; range 0.64–0.77 across varieties

    float fAPAR_phase1 <- 0.2;   // germination / emergence   (Parameters.gaml:136)
    float fAPAR_phase2 <- 0.7;   // vegetative / tillering    (Parameters.gaml:137)
    float fAPAR_phase3 <- 0.9;   // reproductive / flowering  (Parameters.gaml:138)
    float fAPAR_phase4 <- 0.85;  // grain fill / senescence   (Parameters.gaml:139)

    // ---- Pest parameters (all from STAR-FARM Parameters.gaml) ----------------
    float min_k_pest          <- 0.5;   // floor on damage multiplier  (:151)
    float pest_humidity_limit <- 80.0;  // humidity threshold for infection (:152)
    float pest_temp_limit     <- 27.0;  // temperature threshold for infection (:153)
    float pest_infection_prob <- 0.8;   // daily infection probability (:154)
    float pest_daily_increment<- 0.03;  // pest_load increase per triggered day (:155)

    // stage_weight: BPH vulnerability by phenological phase
    // Placeholder values - calibrate against Win et al. 2011 / IRRI BPH Knowledge Bank
    float sw_phase1 <- 0.2;   // germination: low vulnerability
    float sw_phase2 <- 0.9;   // vegetative/tillering: primary BPH damage window
    float sw_phase3 <- 0.7;   // reproductive/flowering: significant damage
    float sw_phase4 <- 0.4;   // grain fill/senescence: declining vulnerability

    // Off-season pest decay coefficient (no host plant present)
    // Tune to implicitly represent natural enemy pressure (see Part 5 Q2)
    float pest_decay_coeff <- 0.95;  // pest_load *= coeff each off-season day

    // ---- Phenological thresholds ----------------------------------------------
    float tt_emergence <- 100.0;
    float tt_veg       <- 700.0;
    float tt_rep       <- 500.0;

    float emergence_threshold <- 100.0;
    float flowering_threshold <- 800.0;
    float maturity_threshold  <- 1300.0;

    // ---- Season control -------------------------------------------------------
    int season      <- 1;
    int max_seasons <- 2;

    // ---- Output helpers -------------------------------------------------------
    float biomass_to_ton_conv <- 0.01;
    float harvest_index       <- 0.45;

    init {
        emergence_threshold <- tt_emergence;
        flowering_threshold <- tt_emergence + tt_veg;
        maturity_threshold  <- tt_emergence + tt_veg + tt_rep;
        create Plot number: 1;
    }

    reflex stop_when_done when: season > max_seasons {
        write "All " + max_seasons + " season(s) complete.";
        do pause;
    }
}

// ---------------------------------------------------------------------------
// Crop declared before Plot: Crop accumulates first, then Plot checks maturity.
// ---------------------------------------------------------------------------

species Crop {

    float biomass         <- 0.0;   // accumulated plant mass (g/m2)
    float thermal_time    <- 0.0;   // growing degree days (deg C * day)
    float growth_stage    <- 0.0;   // normalised development (0 to 1)
    float pest_yield_loss <- 0.0;   // cumulative biomass lost to pest (g/m2)
    float k_pest          <- 1.0;   // stored each cycle for charting

    // Step 1: accumulate thermal time and update development stage (unchanged from Layer 1)
    reflex accumulate {
        float dTT <- max(0.0, t_mean - Tbase);
        thermal_time <- thermal_time + dTT;
        growth_stage <- min(1.0, thermal_time / maturity_threshold);
    }

    // Step 2: grow with stage-weighted pest damage
    // k_pest = max(min_k_pest, 1 - stage_weight * pest_load)
    // Matches STAR-FARM line 391 structure; k_pest replaces the scalar k_pest there
    reflex grow {
        // fAPAR by phase (unchanged from Layer 1)
        float fAPAR <- fAPAR_phase1;
        if      (thermal_time < emergence_threshold) { fAPAR <- fAPAR_phase1; }
        else if (thermal_time < flowering_threshold) { fAPAR <- fAPAR_phase2; }
        else if (thermal_time < maturity_threshold)  { fAPAR <- fAPAR_phase3; }
        else                                         { fAPAR <- fAPAR_phase4; }

        // stage_weight: vulnerability multiplier for current phenological phase
        float stage_weight <- sw_phase1;
        if      (thermal_time < emergence_threshold) { stage_weight <- sw_phase1; }
        else if (thermal_time < flowering_threshold) { stage_weight <- sw_phase2; }
        else if (thermal_time < maturity_threshold)  { stage_weight <- sw_phase3; }
        else                                         { stage_weight <- sw_phase4; }

        // Damage multiplier: higher pest_load + higher stage_weight = more suppression
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

    Crop  associated_crop <- nil;
    bool  pending_sow     <- true;
    float pest_load       <- 0.0;   // BPH pressure scalar (0 = healthy, 1 = overwhelmed)
    // [LAYER 3] add: int days_since_last_spray <- 0;
    // [LAYER 3] add: int spray_count <- 0;

    // Sow: resets pest_load to 0 at the start of each season (fixes STAR-FARM gap)
    reflex sow_crop when: pending_sow {
        pest_load <- 0.0;
        create Crop returns: c;
        associated_crop <- first(c);
        pending_sow <- false;
        write "Day " + cycle + " | Season " + season + ": sown. pest_load reset to 0.";
    }

    // In-season pest pressure: weather-driven daily increment
    // Mirrors Plant_growth_models.gaml:337-341
    // Note: no in-season natural decay here (matching STAR-FARM); pest grows monotonically
    // Spray resets pest_load in Layer 3. Tune pest_decay_coeff for implicit enemy control (Part 5 Q2).
    // [LAYER 3] farmer spray decision fires after this reflex
    reflex update_pest when: associated_crop != nil {
        if (humidity > pest_humidity_limit and t_mean > pest_temp_limit and flip(pest_infection_prob)) {
            pest_load <- pest_load + pest_daily_increment;
        }
        pest_load <- min(1.0, pest_load);
    }

    // Off-season: pest pressure decays without a host plant
    reflex pest_decay when: associated_crop = nil and pest_load > 0.0 {
        pest_load <- pest_load * pest_decay_coeff;
    }

    // Check maturity (fires after Crop has already accumulated this cycle)
    reflex check_maturity when: associated_crop != nil and associated_crop.thermal_time >= maturity_threshold {
        float grain_tha      <- associated_crop.biomass * harvest_index * biomass_to_ton_conv;
        float yield_loss_tha <- associated_crop.pest_yield_loss * harvest_index * biomass_to_ton_conv;
        write "Day " + cycle + " | Season " + season + ": harvested. Biomass=" + (associated_crop.biomass with_precision 1) + "g/m2. Grain=" + (grain_tha with_precision 2) + "t/ha. PestLoss=" + (yield_loss_tha with_precision 2) + "t/ha. PestLoad=" + (pest_load with_precision 2) + ".";
        ask associated_crop { do die; }
        associated_crop <- nil;
        season <- season + 1;
        if (season <= max_seasons) { pending_sow <- true; }
    }
}

// ---------------------------------------------------------------------------

experiment Layer2_PestDynamics type: gui {

    // Layer 1 parameters (unchanged)
    parameter "t_mean (deg C)"              var: t_mean          min: 20.0  max: 40.0;
    parameter "solar_rad (MJ/m2/day)"       var: solar_rad       min: 5.0   max: 30.0;
    parameter "Tbase (deg C)"               var: Tbase           min: 5.0   max: 15.0;
    parameter "potential_rue (g/MJ)"        var: potential_rue   min: 0.5   max: 3.0;
    parameter "tt_emergence (deg-C*day)"    var: tt_emergence    min: 50.0  max: 300.0;
    parameter "tt_veg (deg-C*day)"          var: tt_veg          min: 300.0 max: 1200.0;
    parameter "tt_rep (deg-C*day)"          var: tt_rep          min: 200.0 max: 800.0;
    parameter "harvest_index"               var: harvest_index   min: 0.3   max: 0.6;
    parameter "Seasons to simulate"         var: max_seasons     min: 1     max: 5;

    // Layer 2 parameters (new)
    parameter "humidity (%)"                var: humidity            min: 50.0 max: 100.0;
    parameter "pest_humidity_limit (%)"     var: pest_humidity_limit min: 60.0 max: 95.0;
    parameter "pest_temp_limit (deg C)"     var: pest_temp_limit     min: 20.0 max: 35.0;
    parameter "pest_infection_prob"         var: pest_infection_prob min: 0.0  max: 1.0;
    parameter "pest_daily_increment"        var: pest_daily_increment min: 0.01 max: 0.1;
    parameter "min_k_pest (damage floor)"   var: min_k_pest          min: 0.1  max: 1.0;
    parameter "pest_decay_coeff (off-season)" var: pest_decay_coeff  min: 0.8  max: 1.0;

    output {
        monitor "Day"              value: cycle;
        monitor "Season"           value: season;
        monitor "Biomass (g/m2)"   value: empty(Crop) ? 0.0 : first(Crop).biomass;
        monitor "Growth stage"     value: empty(Crop) ? 0.0 : first(Crop).growth_stage;
        monitor "Pest load"        value: empty(Plot) ? 0.0 : first(Plot).pest_load;
        monitor "k_pest"           value: empty(Crop) ? 1.0 : first(Crop).k_pest;
        monitor "Pest yield loss"  value: empty(Crop) ? 0.0 : first(Crop).pest_yield_loss * harvest_index * biomass_to_ton_conv;
        monitor "Grain yield t/ha" value: empty(Crop) ? 0.0 : first(Crop).biomass * harvest_index * biomass_to_ton_conv;

        // Biomass: compare with Layer 1 (6.31 t/ha grain with no pest)
        // Under default pest pressure, grain should be noticeably lower
        display "Biomass" {
            chart "Biomass (g/m2)" type: series background: #white {
                data "Biomass (with pest)" value: empty(Crop) ? 0.0 : first(Crop).biomass color: #darkgreen style: line marker: false;
            }
        }

        // Pest pressure rising over the season (no in-season decay)
        // Try setting humidity below pest_humidity_limit to see a no-pest baseline
        display "Pest pressure" {
            chart "Pest load (0 to 1)" type: series background: #white {
                data "Pest load" value: empty(Plot) ? 0.0 : first(Plot).pest_load color: #red style: line marker: false;
            }
        }

        // k_pest: damage multiplier (1.0 = no damage, min_k_pest = maximum damage)
        // Drops during high-vulnerability phases (tillering: sw=0.9, flowering: sw=0.7)
        display "Damage multiplier" {
            chart "k_pest (1 = no damage)" type: series background: #white {
                data "k_pest" value: empty(Crop) ? 1.0 : first(Crop).k_pest color: #darkred style: line marker: false;
            }
        }

        // Cumulative grain lost to pests over the season
        display "Pest yield loss" {
            chart "Cumulative pest yield loss (t/ha)" type: series background: #white {
                data "Pest yield loss" value: empty(Crop) ? 0.0 : first(Crop).pest_yield_loss * harvest_index * biomass_to_ton_conv color: #darkorange style: line marker: false;
            }
        }
    }
}
