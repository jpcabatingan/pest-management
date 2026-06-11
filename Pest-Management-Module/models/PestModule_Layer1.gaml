/**
 * Name:        PestModule_Layer1
 * Description: Standalone pest management model - Layer 1: Rice growth baseline.
 *              One plot, one crop, thermal-time driven biomass accumulation,
 *              phase-based fAPAR, harvest at maturity.
 *              No pest, no farmer. Purpose: validate the growth curve before
 *              Layers 2 and 3 are added.
 *
 * Design spec: pest_module_design_notes.md, Parts 2-4.
 * STAR-FARM alignment:
 *   - Tbase = 8.0 (Plant_growth_models.gaml:93)
 *   - fAPAR phases (Parameters.gaml:136-139): 0.2 / 0.7 / 0.9 / 0.85
 *   - Growth formula: daily_growth = potential_rue * solar_rad * fAPAR
 *     (k_pest multiplies here in Layer 2)
 *   - Thermal time: dTT = max(0, t_mean - Tbase)
 *
 * Layer 2 extension points are marked with: // [LAYER 2]
 * Layer 3 extension points are marked with: // [LAYER 3]
 *
 * Author: Joanne Maryz Cabatingan
 */

model PestModule_Layer1

global {

    // ---- Synthetic weather (constants - replace with file read in Layer 2) ----
    float t_mean    <- 28.0;   // mean daily air temperature (deg C)
    float solar_rad <- 18.0;   // daily solar radiation (MJ/m2/day)
    // [LAYER 2] add: float humidity <- 80.0; for pest infection trigger

    // ---- Thermal time ---------------------------------------------------------
    float Tbase <- 10.0;        // base temperature for GDD - matches Plant_growth_models.gaml:93

    // ---- Crop growth ----------------------------------------------------------
    float potential_rue <- 0.77; // OM5451/OM6976: variety.RUE (1.2) * rue_efficiency_factor (0.64)
                              // cultivars.csv + Parameters.gaml:106
                              // treat as sensitivity parameter; range 0.64–0.77 across varieties

    // fAPAR by phenological phase - values from Parameters.gaml:136-139
    float fAPAR_phase1 <- 0.2;   // germination / emergence
    float fAPAR_phase2 <- 0.7;   // vegetative (tillering)
    float fAPAR_phase3 <- 0.9;   // reproductive (booting / flowering)
    float fAPAR_phase4 <- 0.85;  // grain fill / senescence

    // Phenological thresholds (deg C * day, cumulative from sowing)
    // Indicative values for tropical Mekong Delta varieties; calibrate against cultivars.csv
    float tt_emergence <- 100.0;  // sowing to emergence
    float tt_veg       <- 700.0;  // emergence to flowering
    float tt_rep       <- 500.0;  // flowering to maturity

    // Derived thresholds - declared after their inputs so inline init is valid
    float emergence_threshold <- 100.0;   // updated in init
    float flowering_threshold <- 800.0;   // updated in init
    float maturity_threshold  <- 1300.0;  // updated in init

    // ---- Season control -------------------------------------------------------
    int season      <- 1;
    int max_seasons <- 2;  // run this many seasons then pause

    // ---- Output helpers -------------------------------------------------------
    float biomass_to_ton_conv <- 0.01;  // g/m2 to t/ha - matches Parameters.gaml:162
    float harvest_index       <- 0.45;  // grain / total biomass ratio

    init {
        // Compute derived thresholds from the tunable inputs
        emergence_threshold <- tt_emergence;
        flowering_threshold <- tt_emergence + tt_veg;
        maturity_threshold  <- tt_emergence + tt_veg + tt_rep;
        create Plot number: 1;
        // Plot's pending_sow flag is true by default, so it sows on cycle 1 automatically
    }

    reflex stop_when_done when: season > max_seasons {
        write "All " + max_seasons + " season(s) complete.";
        do pause;
    }
}

// ---------------------------------------------------------------------------
// Crop is declared before Plot so its reflexes execute first each cycle.
// This means Plot sees the updated thermal_time when checking maturity
// in the same cycle (no one-step lag at the harvest boundary).
// ---------------------------------------------------------------------------

species Crop {

    float biomass      <- 0.0;  // accumulated plant mass (g/m2)
    float thermal_time <- 0.0;  // growing degree days since sowing (deg C * day)
    float growth_stage <- 0.0;  // normalised development: 0 = sowing, 1 = maturity
    // [LAYER 2] add: float pest_yield_loss <- 0.0;

    // Step 1: accumulate thermal time and update development stage
    reflex accumulate {
        float dTT <- max(0.0, t_mean - Tbase);
        thermal_time <- thermal_time + dTT;
        growth_stage <- min(1.0, thermal_time / maturity_threshold);
    }

    // Step 2: grow via radiation use efficiency
    // Matches STAR-FARM line 391: daily_growth = potential_rue * solar_rad * fAPAR * [stresses]
    // [LAYER 2] k_pest multiplies daily_growth here:
    //   float k_pest <- max(min_k_pest, 1.0 - (stage_weight * my_plot.pest_load));
    //   float stressed <- daily_growth * k_pest;
    //   pest_yield_loss <- pest_yield_loss + (daily_growth - stressed);
    //   biomass <- biomass + stressed;
    reflex grow {
        float fAPAR <- fAPAR_phase1;
        if      (thermal_time < emergence_threshold) { fAPAR <- fAPAR_phase1; }
        else if (thermal_time < flowering_threshold) { fAPAR <- fAPAR_phase2; }
        else if (thermal_time < maturity_threshold)  { fAPAR <- fAPAR_phase3; }
        else                                         { fAPAR <- fAPAR_phase4; }
        float daily_growth <- potential_rue * solar_rad * fAPAR;
        biomass <- biomass + daily_growth;
    }
}

// ---------------------------------------------------------------------------

species Plot {

    Crop associated_crop <- nil;
    bool pending_sow     <- true;   // true at start and set true again after each harvest
    // [LAYER 2] add: float pest_load <- 0.0;
    // [LAYER 3] add: int days_since_last_spray <- 0;
    // [LAYER 3] add: int spray_count <- 0;

    // Sow whenever the flag is raised (first cycle and after each harvest)
    reflex sow_crop when: pending_sow {
        create Crop returns: c;
        associated_crop <- first(c);
        pending_sow <- false;
        write "Day " + cycle + " | Season " + season + ": sown.";
    }

    // Check maturity after Crop has already run its reflexes this cycle
    // [LAYER 2] add reflex update_pest here (between sow_crop and check_maturity)
    // [LAYER 3] add reflex farmer_decides here (between update_pest and check_maturity)
    reflex check_maturity when: associated_crop != nil and associated_crop.thermal_time >= maturity_threshold {
        float grain_tha <- associated_crop.biomass * harvest_index * biomass_to_ton_conv;
        write "Day " + cycle + " | Season " + season + ": harvested. Biomass=" + (associated_crop.biomass with_precision 1) + "g/m2. Grain=" + (grain_tha with_precision 2) + "t/ha.";
        ask associated_crop { do die; }
        associated_crop <- nil;
        season <- season + 1;
        if (season <= max_seasons) { pending_sow <- true; }
    }
}

// ---------------------------------------------------------------------------

experiment Layer1_RiceGrowth type: gui {

    parameter "t_mean (deg C)"              var: t_mean         min: 20.0  max: 40.0;
    parameter "solar_rad (MJ/m2/day)"       var: solar_rad      min: 5.0   max: 30.0;
    parameter "Tbase (deg C)"               var: Tbase          min: 5.0   max: 15.0;
    parameter "potential_rue (g/MJ)"        var: potential_rue  min: 0.5   max: 3.0;
    parameter "tt_emergence (deg-C*day)"    var: tt_emergence   min: 50.0  max: 300.0;
    parameter "tt_veg (deg-C*day)"          var: tt_veg         min: 300.0 max: 1200.0;
    parameter "tt_rep (deg-C*day)"          var: tt_rep         min: 200.0 max: 800.0;
    parameter "harvest_index"               var: harvest_index  min: 0.3   max: 0.6;
    parameter "Seasons to simulate"         var: max_seasons    min: 1     max: 5;

    output {
        monitor "Day"              value: cycle;
        monitor "Season"           value: season;
        monitor "Biomass (g/m2)"   value: empty(Crop) ? 0.0 : first(Crop).biomass;
        monitor "Growth stage"     value: empty(Crop) ? 0.0 : first(Crop).growth_stage;
        monitor "Thermal time"     value: empty(Crop) ? 0.0 : first(Crop).thermal_time;
        monitor "Grain yield t/ha" value: empty(Crop) ? 0.0 : first(Crop).biomass * harvest_index * biomass_to_ton_conv;

        // Expected shape: S-curve rising faster in Phase 3 (fAPAR=0.9)
        // levelling at roughly 1300-1600 g/m2 at harvest (~65 days at defaults)
        display "Biomass" {
            chart "Biomass (g/m2)" type: series background: #white {
                data "Total biomass" value: empty(Crop) ? 0.0 : first(Crop).biomass color: #darkgreen style: line marker: false;
            }
        }

        display "Development" {
            chart "Growth stage (0 to 1)" type: series background: #white {
                data "Growth stage" value: empty(Crop) ? 0.0 : first(Crop).growth_stage color: #darkorange style: line marker: false;
            }
        }

        display "Yield" {
            chart "Grain yield (t/ha)" type: series background: #white {
                data "Grain yield" value: empty(Crop) ? 0.0 : first(Crop).biomass * harvest_index * biomass_to_ton_conv color: #goldenrod style: line marker: false;
            }
        }
    }
}
