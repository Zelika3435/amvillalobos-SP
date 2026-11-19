/**
 * Name: BAU_Params
 * Author: Benguet Supply Chain ABM
 * Description: Proof-of-concept stub parameters (cabbage, carrot, potato, chayote).
 *   Runtime values live in Corridor_BAU.gaml global — keep both in sync.
 *   This file is not imported.
 * Tags: params, bau, cabbage, carrot, potato, chayote
 */
model BAU_Params

global {
	float tick_hours <- 1.0;
	int harvest_hour <- 6;
	int posting_hour <- 5;

	float spoilage_rate_per_hour <- 0.002;
	float harvest_kg_per_farm_day <- 800.0; // split across in-season crops
	float truck_capacity_kg <- 5000.0;
	float truck_speed_m_per_h <- 25000.0;
	float seg_len_m <- 75.0;
	float graph_tolerance_m <- 10.0;
	float arrive_tol_m <- 100.0;
	float haul_cost_per_kg <- 3.5;
	float retail_markup <- 1.35;

	// AgriTrak-informed posted bands (Wonderball / Carrot / Granola / Chayote dump mids)
	float floor_cabbage <- 20.0;
	float ceil_cabbage <- 28.0;
	float floor_carrot <- 26.0;
	float ceil_carrot <- 35.0;
	float floor_potato <- 38.0;
	float ceil_potato <- 44.0;
	float floor_chayote <- 10.0;
	float ceil_chayote <- 12.0;

	float delay_frac <- 0.85; // delay sale if believed ask < delay_frac * mid band

	bool trust_enabled <- true;
	float trust_alpha <- 0.15;
	float trust_usual_prior <- 0.85;
	float trust_stranger_prior <- 0.35;
	float trust_partner_threshold <- 0.45;
	float source_official_prior <- 0.9;
	float source_partner_prior <- 0.7;
	float source_rumor_prior <- 0.2;

	int n_disposers <- 3;
	int n_truckers <- 7;
	int rng_seed <- 19001;

	float demand_cabbage_day <- 1200.0;
	float demand_carrot_day <- 800.0;
	float demand_potato_day <- 900.0;
	float demand_chayote_day <- 600.0;

	bool write_daily_csv <- true;
	string daily_log_path <- "../results/bau_crops_daily.csv";
}
