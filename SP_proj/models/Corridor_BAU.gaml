/**
 * Name: Corridor_BAU
 * Author: Benguet Supply Chain ABM
 * Description: Multi-crop proof of concept — cabbage, carrot, potato, and chayote.
 *   Not the finished thesis model in docs/PLANNING.md.
 *   Hour tick, per-crop inventory/spoilage, five species, custom BDI, EMA trust, CSV log.
 *   Trucks use the presentation drive: BAPTC → farm (empty), load, farm → BAPTC (loaded)
 *   on the cleaned road graph. Seasonal harvest prior: potato Mar–Jun, cabbage Jul–Oct,
 *   carrot Nov–Feb; chayote year-round.
 *   No LLM. No disaster shocks. BAPTC only.
 * Tags: bau, cabbage, carrot, potato, chayote, bdi, trust, supply_chain
 */
model Corridor_BAU

global {
	float tick_hours <- 1.0;
	int harvest_hour <- 6;
	int posting_hour <- 5;
	float spoilage_rate_per_hour <- 0.002;
	float harvest_kg_per_farm_day <- 800.0;
	float truck_capacity_kg <- 5000.0;
	float truck_speed_m_per_h <- 25000.0;
	float arrive_tol_m <- 25.0;
	float haul_cost_per_kg <- 3.5;
	float retail_markup <- 1.35;
	float delay_frac <- 0.85;

	float floor_cabbage <- 20.0;
	float ceil_cabbage <- 28.0;
	float floor_carrot <- 26.0;
	float ceil_carrot <- 35.0;
	float floor_potato <- 38.0;
	float ceil_potato <- 44.0;
	float floor_chayote <- 10.0;
	float ceil_chayote <- 12.0;

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

	file network_shapefile <- shape_file("../../data/osm/network_cleaned_utm.shp");
	file markets_shapefile <- shape_file("../includes/markets_utm.shp");
	file farms_shapefile <- shape_file("../includes/farm_clusters_utm.shp");
	file dem_file <- grid_file("../includes/corridor_dem_utm.asc");

	geometry shape <- envelope(dem_file);
	graph road_graph;
	float dem_z_min <- 0.0;
	float dem_z_max <- 2822.0;

	market baptc <- nil;
	wholesaler the_wholesaler <- nil;
	retailer the_retailer <- nil;
	point baptc_gate;

	int sim_hour <- 0;
	int sim_day <- 0;
	int sim_month <- 1;
	bool log_header_written <- false;

	float ask_cabbage <- 24.0;
	float ask_carrot <- 30.0;
	float ask_potato <- 41.0;
	float ask_chayote <- 11.0;
	float retail_cabbage <- 32.0;
	float retail_carrot <- 40.0;
	float retail_potato <- 55.0;
	float retail_chayote <- 15.0;

	float total_harvested_kg <- 0.0;
	float total_spoiled_kg <- 0.0;
	float total_delivered_kg <- 0.0;
	float total_retail_sold_kg <- 0.0;
	int trips_completed <- 0;
	int trucks_en_route <- 0;

	float day_harvest_cabbage <- 0.0;
	float day_harvest_carrot <- 0.0;
	float day_harvest_potato <- 0.0;
	float day_harvest_chayote <- 0.0;
	float day_deliver_cabbage <- 0.0;
	float day_deliver_carrot <- 0.0;
	float day_deliver_potato <- 0.0;
	float day_deliver_chayote <- 0.0;
	float day_retail_cabbage <- 0.0;
	float day_retail_carrot <- 0.0;
	float day_retail_potato <- 0.0;
	float day_retail_chayote <- 0.0;
	float day_spoil_kg <- 0.0;
	int day_partner_switches <- 0;

	float source_trust_official <- 0.9;
	float source_trust_partner <- 0.7;
	float source_trust_rumor <- 0.2;

	float result_f <- 0.0;
	string result_s <- "";
	point result_pt;
	list<point> result_route <- [];

	init {
		seed <- rng_seed;
		step <- tick_hours #h;
		source_trust_official <- source_official_prior;
		source_trust_partner <- source_partner_prior;
		source_trust_rumor <- source_rumor_prior;
		do refresh_posted_prices;
		do update_calendar;

		create road from: network_shapefile with: [
			road_name::string(read("name")),
			source::string(read("source")),
			corr_role::string(read("role")),
			corr_link::string(read("link")),
			seg_length::float(read("len_m"))
		] {
			do colorize;
		}

		create market from: markets_shapefile with: [
			place_name::string(read("name")),
			sim_flag::string(read("simulated")),
			kind::string(read("kind"))
		] {
			is_simulated <- (sim_flag = "Y");
			if (is_simulated) {
				short_label <- "BAPTC";
			} else if (place_name contains "Hangar") {
				short_label <- "Hangar Market";
			} else if (place_name contains "La Trinidad") {
				short_label <- "LTVTP";
			} else {
				short_label <- place_name;
			}
		}

		baptc <- first(market where (each.is_simulated));
		if (baptc = nil) {
			baptc <- first(market);
			write "WARN: no simulated=Y market; using first market as BAPTC";
		}

		create farm_cluster from: farms_shapefile with: [
			place_name::string(read("name")),
			municipality::string(read("muni")),
			role::string(read("role")),
			dist_dpwh::float(read("dist_dpwh")),
			dist_fmr::float(read("dist_fmr"))
		] {
			do clear_storage;
			do set_daily_ready;
		}

		// Same road graph the presentation model drives on: welded road polylines,
		// targets snapped to graph vertices so goto has a legal node.
		road_graph <- as_edge_graph(road);
		do snap_to_graph(pt: baptc.location);
		baptc_gate <- result_pt;

		ask farm_cluster {
			do gate_point;
			road_pt <- result_pt;
			path p <- path_between(road_graph, baptc_gate, road_pt);
			if (p = nil or empty(p.edges)) {
				write "WARN: no road path BAPTC -> " + place_name;
			} else {
				write "  route BAPTC -> " + place_name + ": " + length(p.edges) + " edges, " + int(p.shape.perimeter) + " m";
			}
		}

		create disposer number: n_disposers {
			location <- baptc.location;
			do clear_buffer;
			intention_plan <- "ask_inside_band";
		}

		list<farm_cluster> farms <- list(farm_cluster);
		loop fi from: 0 to: length(farms) - 1 {
			farm_cluster fc <- farms[fi];
			disposer usual <- disposer[fi mod length(disposer)];
			disposer alt <- disposer[(fi + 1) mod length(disposer)];
			create farmer number: 1 {
				home <- fc;
				location <- fc.location;
				intention_plan <- "wait";
				usual_disposer <- usual;
				alt_disposer <- alt;
				trust_usual <- trust_usual_prior;
				trust_alt <- trust_stranger_prior;
				focus_crop <- "cabbage";
			}
		}

		create trucker number: n_truckers {
			location <- baptc_gate;
			load_kg <- 0.0;
			load_crop <- "";
			state <- "idle";
			intention_plan <- "delay_trip";
		}

		create wholesaler number: 1 {
			the_wholesaler <- self;
			location <- baptc.location;
			do clear_inventory;
			target_per_crop <- 2000.0;
			ration_per_crop <- 400.0;
			intention_plan <- "restock";
			usual_disposer <- first(disposer);
			trust_usual <- trust_usual_prior;
		}

		create retailer number: 1 {
			the_retailer <- self;
			location <- baptc.location + {400, 400};
			intention_plan <- "order_usual";
			trust_usual <- trust_usual_prior;
			do reset_daily_demand;
		}
		ask retailer {
			usual_wholesaler <- first(wholesaler);
		}
		ask wholesaler {
			usual_disposer <- first(disposer);
		}

		list<string> seen_road_names <- [];
		ask road where ((each.corr_role = "principal") or (each.corr_role = "alternate")) {
			if (road_name != nil and road_name != "" and !(seen_road_names contains road_name)) {
				create map_label number: 1 {
					txt <- myself.road_name;
					location <- centroid(myself.shape);
					col <- myself.line_color;
					kind <- "road";
				}
				seen_road_names <+ road_name;
			}
		}
		ask farm_cluster {
			create map_label number: 1 {
				txt <- myself.place_name;
				location <- myself.location + {0, 450};
				col <- rgb(90, 220, 110);
				kind <- "farm";
			}
		}
		ask market {
			create map_label number: 1 {
				txt <- myself.short_label;
				location <- myself.location + {0, 450};
				if (myself.is_simulated) {
					col <- rgb(255, 220, 60);
				} else {
					col <- rgb(255, 180, 100);
				}
				kind <- "market";
			}
		}

		write "BAU init (4 crops): roads=" + length(road)
			+ " graph_edges=" + length(road_graph.edges)
			+ " farms=" + length(farm_cluster)
			+ " farmers=" + length(farmer)
			+ " disposers=" + length(disposer)
			+ " truckers=" + length(trucker)
			+ " trust_enabled=" + trust_enabled;
	}

	action update_calendar {
		// Approximate month from sim_day (day 0 = January 1 stub calendar)
		sim_month <- int((sim_day mod 365) / 30.437) + 1;
		if (sim_month > 12) {
			sim_month <- 12;
		}
	}

	action refresh_posted_prices {
		ask_cabbage <- (floor_cabbage + ceil_cabbage) / 2.0;
		ask_carrot <- (floor_carrot + ceil_carrot) / 2.0;
		ask_potato <- (floor_potato + ceil_potato) / 2.0;
		ask_chayote <- (floor_chayote + ceil_chayote) / 2.0;
		if (trust_enabled) {
			ask_cabbage <- (source_trust_official * ask_cabbage + source_trust_partner * ask_cabbage)
				/ max(0.001, source_trust_official + source_trust_partner);
		}
		retail_cabbage <- ask_cabbage * retail_markup;
		retail_carrot <- ask_carrot * retail_markup;
		retail_potato <- ask_potato * retail_markup;
		retail_chayote <- ask_chayote * retail_markup;
	}

	action crop_ask {
		arg crop type: string;
		if (crop = "carrot") {
			result_f <- ask_carrot;
		} else if (crop = "potato") {
			result_f <- ask_potato;
		} else if (crop = "chayote") {
			result_f <- ask_chayote;
		} else {
			result_f <- ask_cabbage;
		}
	}

	action crop_mid {
		arg crop type: string;
		if (crop = "carrot") {
			result_f <- (floor_carrot + ceil_carrot) / 2.0;
		} else if (crop = "potato") {
			result_f <- (floor_potato + ceil_potato) / 2.0;
		} else if (crop = "chayote") {
			result_f <- (floor_chayote + ceil_chayote) / 2.0;
		} else {
			result_f <- (floor_cabbage + ceil_cabbage) / 2.0;
		}
	}

	action snap_to_graph {
		arg pt type: point;
		if (road_graph = nil or empty(road_graph.vertices)) {
			result_pt <- pt;
			return;
		}
		result_pt <- (list(road_graph.vertices) closest_to pt);
	}

	action seasonal_share {
		arg crop type: string;
		// Reyes et al. rotation prior (cited): potato Mar–Jun, cabbage Jul–Oct, carrot Nov–Feb
		if (crop = "potato") {
			if (sim_month >= 3 and sim_month <= 6) {
				result_f <- 1.0;
			} else {
				result_f <- 0.15;
			}
		} else if (crop = "cabbage") {
			if (sim_month >= 7 and sim_month <= 10) {
				result_f <- 1.0;
			} else {
				result_f <- 0.15;
			}
		} else if (crop = "carrot") {
			if (sim_month >= 11 or sim_month <= 2) {
				result_f <- 1.0;
			} else {
				result_f <- 0.15;
			}
		} else {
			// chayote: year-round highland prior
			result_f <- 0.55;
		}
	}

	reflex tick_clock {
		sim_hour <- sim_hour + 1;
		if (sim_hour >= 24) {
			sim_hour <- 0;
			do end_of_day;
			sim_day <- sim_day + 1;
			do update_calendar;
		}
	}

	reflex world_spoilage {
		float spoiled <- 0.0;
		ask farm_cluster {
			do spoil_all(rate: spoilage_rate_per_hour);
			spoiled <- spoiled + result_f;
		}
		ask disposer {
			do spoil_all(rate: spoilage_rate_per_hour);
			spoiled <- spoiled + result_f;
		}
		ask wholesaler {
			do spoil_all(rate: spoilage_rate_per_hour);
			spoiled <- spoiled + result_f;
		}
		total_spoiled_kg <- total_spoiled_kg + spoiled;
		day_spoil_kg <- day_spoil_kg + spoiled;
	}

	reflex posting_clock when: sim_hour = posting_hour {
		do refresh_posted_prices;
		ask disposer {
			intention_plan <- "ask_inside_band";
		}
		ask retailer {
			intention_plan <- "set_retail_price";
		}
	}

	reflex bdi_cycle {
		ask shuffle(list(farmer)) {
			do perceive;
			do maintain_desires;
			do deliberate;
			do act;
		}
		ask shuffle(list(disposer)) {
			do perceive;
			do maintain_desires;
			do deliberate;
			do act;
		}
		ask trucker {
			do perceive;
			do maintain_desires;
			do deliberate;
			do act;
		}
		trucks_en_route <- length(trucker where (each.state != "idle"));
		ask wholesaler {
			do perceive;
			do maintain_desires;
			do deliberate;
			do act;
		}
		ask retailer {
			do perceive;
			do maintain_desires;
			do deliberate;
			do act;
		}
	}

	action end_of_day {
		if (write_daily_csv) {
			do write_daily_log;
		}
		day_harvest_cabbage <- 0.0;
		day_harvest_carrot <- 0.0;
		day_harvest_potato <- 0.0;
		day_harvest_chayote <- 0.0;
		day_deliver_cabbage <- 0.0;
		day_deliver_carrot <- 0.0;
		day_deliver_potato <- 0.0;
		day_deliver_chayote <- 0.0;
		day_retail_cabbage <- 0.0;
		day_retail_carrot <- 0.0;
		day_retail_potato <- 0.0;
		day_retail_chayote <- 0.0;
		day_spoil_kg <- 0.0;
		day_partner_switches <- 0;
		ask farm_cluster {
			do set_daily_ready;
		}
		ask retailer {
			do reset_daily_demand;
		}
	}

	action write_daily_log {
		string line <- string(sim_day) + "," + string(sim_month) + ","
			+ string(ask_cabbage with_precision 2) + ","
			+ string(ask_carrot with_precision 2) + ","
			+ string(ask_potato with_precision 2) + ","
			+ string(ask_chayote with_precision 2) + ","
			+ string(day_harvest_cabbage with_precision 1) + ","
			+ string(day_harvest_carrot with_precision 1) + ","
			+ string(day_harvest_potato with_precision 1) + ","
			+ string(day_harvest_chayote with_precision 1) + ","
			+ string(day_deliver_cabbage with_precision 1) + ","
			+ string(day_deliver_carrot with_precision 1) + ","
			+ string(day_deliver_potato with_precision 1) + ","
			+ string(day_deliver_chayote with_precision 1) + ","
			+ string(day_retail_cabbage with_precision 1) + ","
			+ string(day_retail_carrot with_precision 1) + ","
			+ string(day_retail_potato with_precision 1) + ","
			+ string(day_retail_chayote with_precision 1) + ","
			+ string(day_spoil_kg with_precision 1) + ","
			+ string(day_partner_switches) + ","
			+ string(trust_enabled) + "\n";
		if (!log_header_written) {
			save "day,month,ask_cabbage,ask_carrot,ask_potato,ask_chayote,harvest_cabbage,harvest_carrot,harvest_potato,harvest_chayote,deliver_cabbage,deliver_carrot,deliver_potato,deliver_chayote,retail_cabbage,retail_carrot,retail_potato,retail_chayote,spoil_kg,partner_switches,trust_enabled\n"
				to: daily_log_path format: "text" rewrite: true;
			log_header_written <- true;
		}
		save line to: daily_log_path format: "text" rewrite: false;
	}

	action bump_harvest {
		arg crop type: string;
		arg qty type: float;
		total_harvested_kg <- total_harvested_kg + qty;
		if (crop = "carrot") {
			day_harvest_carrot <- day_harvest_carrot + qty;
		} else if (crop = "potato") {
			day_harvest_potato <- day_harvest_potato + qty;
		} else if (crop = "chayote") {
			day_harvest_chayote <- day_harvest_chayote + qty;
		} else {
			day_harvest_cabbage <- day_harvest_cabbage + qty;
		}
	}

	action bump_deliver {
		arg crop type: string;
		arg qty type: float;
		total_delivered_kg <- total_delivered_kg + qty;
		if (crop = "carrot") {
			day_deliver_carrot <- day_deliver_carrot + qty;
		} else if (crop = "potato") {
			day_deliver_potato <- day_deliver_potato + qty;
		} else if (crop = "chayote") {
			day_deliver_chayote <- day_deliver_chayote + qty;
		} else {
			day_deliver_cabbage <- day_deliver_cabbage + qty;
		}
	}

	action bump_retail {
		arg crop type: string;
		arg qty type: float;
		total_retail_sold_kg <- total_retail_sold_kg + qty;
		if (crop = "carrot") {
			day_retail_carrot <- day_retail_carrot + qty;
		} else if (crop = "potato") {
			day_retail_potato <- day_retail_potato + qty;
		} else if (crop = "chayote") {
			day_retail_chayote <- day_retail_chayote + qty;
		} else {
			day_retail_cabbage <- day_retail_cabbage + qty;
		}
	}
}

grid dem_cell file: dem_file neighbors: 4 {
	rgb color <- rgb(22, 26, 34);

	init {
		float z <- grid_value;
		if (z <= -9000.0) {
			color <- rgb(22, 26, 34);
		} else {
			float t <- min(1.0, max(0.0, (z - dem_z_min) / (dem_z_max - dem_z_min)));
			int r <- int(28 + t * 170);
			int g <- int(48 + t * 90);
			int b <- int(40 + (1.0 - t) * 35);
			color <- rgb(r, g, b);
		}
	}

	aspect default {
		draw shape color: color border: color;
	}
}

species road {
	string road_name <- "";
	string source <- "";
	string corr_role <- "";
	string corr_link <- "";
	float seg_length <- 0.0;
	rgb line_color <- #gray;
	float line_w <- 1.5;

	action colorize {
		if (corr_role = "principal") {
			line_w <- 3.5;
			if (corr_link = "halsema") {
				line_color <- rgb(255, 70, 70);
			} else if (corr_link = "kennon") {
				line_color <- rgb(255, 170, 40);
			} else if (corr_link = "marcos") {
				line_color <- rgb(80, 160, 255);
			} else if (corr_link = "naguilian") {
				line_color <- rgb(60, 220, 120);
			} else {
				line_color <- rgb(200, 205, 215);
			}
		} else if (corr_role = "alternate") {
			line_w <- 2.5;
			line_color <- rgb(80, 255, 230);
		} else if (corr_role = "fmr") {
			if (source = "da_completed_fmr") {
				line_w <- 1.8;
				line_color <- rgb(30, 175, 75);
			} else if (source = "geoportal_preview") {
				line_w <- 3.0;
				line_color <- rgb(40, 220, 90);
			} else {
				line_w <- 3.0;
				line_color <- rgb(40, 220, 90);
			}
		} else if (corr_role = "tier2") {
			line_w <- 1.6;
			line_color <- rgb(210, 180, 95);
		} else if (corr_role = "tier3") {
			line_w <- 0.9;
			line_color <- rgb(105, 115, 130);
		} else if (corr_role = "benguet_all") {
			line_w <- 1.8;
			line_color <- rgb(200, 205, 215);
		} else {
			line_w <- 1.5;
			line_color <- rgb(150, 155, 165);
		}
	}

	aspect default {
		draw shape color: line_color width: line_w;
	}
}

species market {
	string place_name <- "";
	string short_label <- "";
	string sim_flag <- "";
	string kind <- "";
	bool is_simulated <- false;

	aspect default {
		rgb c <- rgb(230, 230, 235);
		if (is_simulated) {
			c <- rgb(255, 220, 60);
		} else if (kind = "market") {
			c <- rgb(255, 150, 60);
		}
		draw square(260.0) color: c border: #white;
	}
}

species farm_cluster {
	float result_f <- 0.0;
	string result_s <- "";
	point result_pt;
	point road_pt;
	string place_name <- "";
	string municipality <- "";
	string role <- "";
	float dist_dpwh <- 0.0;
	float dist_fmr <- 0.0;

	float storage_cabbage <- 0.0;
	float storage_carrot <- 0.0;
	float storage_potato <- 0.0;
	float storage_chayote <- 0.0;
	float ready_cabbage <- 0.0;
	float ready_carrot <- 0.0;
	float ready_potato <- 0.0;
	float ready_chayote <- 0.0;

	action clear_storage {
		storage_cabbage <- 0.0;
		storage_carrot <- 0.0;
		storage_potato <- 0.0;
		storage_chayote <- 0.0;
	}

	action set_daily_ready {
		float base <- harvest_kg_per_farm_day;
		ask world { do seasonal_share(crop: "cabbage"); }
		float sc <- world.result_f;
		ask world { do seasonal_share(crop: "carrot"); }
		float sr <- world.result_f;
		ask world { do seasonal_share(crop: "potato"); }
		float sp <- world.result_f;
		ask world { do seasonal_share(crop: "chayote"); }
		float sh <- world.result_f;
		float denom <- max(0.001, sc + sr + sp + sh);
		ready_cabbage <- base * sc / denom;
		ready_carrot <- base * sr / denom;
		ready_potato <- base * sp / denom;
		ready_chayote <- base * sh / denom;
	}

	action total_storage {
		result_f <- storage_cabbage + storage_carrot + storage_potato + storage_chayote;
	}

	action get_storage {
		arg crop type: string;
		if (crop = "carrot") {
			result_f <- storage_carrot;
		} else if (crop = "potato") {
			result_f <- storage_potato;
		} else if (crop = "chayote") {
			result_f <- storage_chayote;
		} else {
			result_f <- storage_cabbage;
		}
	}

	action add_storage {
		arg crop type: string;
		arg qty type: float;
		if (crop = "carrot") {
			storage_carrot <- storage_carrot + qty;
		} else if (crop = "potato") {
			storage_potato <- storage_potato + qty;
		} else if (crop = "chayote") {
			storage_chayote <- storage_chayote + qty;
		} else {
			storage_cabbage <- storage_cabbage + qty;
		}
	}

	action take_storage {
		arg crop type: string;
		arg qty type: float;
		do get_storage(crop: crop);
		float have <- result_f;
		float took <- min(qty, have);
		if (crop = "carrot") {
			storage_carrot <- storage_carrot - took;
		} else if (crop = "potato") {
			storage_potato <- storage_potato - took;
		} else if (crop = "chayote") {
			storage_chayote <- storage_chayote - took;
		} else {
			storage_cabbage <- storage_cabbage - took;
		}
		result_f <- took;
	}

	action spoil_all {
		arg rate type: float;
		float loss <- (storage_cabbage + storage_carrot + storage_potato + storage_chayote) * rate;
		storage_cabbage <- max(0.0, storage_cabbage * (1.0 - rate));
		storage_carrot <- max(0.0, storage_carrot * (1.0 - rate));
		storage_potato <- max(0.0, storage_potato * (1.0 - rate));
		storage_chayote <- max(0.0, storage_chayote * (1.0 - rate));
		result_f <- loss;
	}

	action richest_crop {
		string best <- "cabbage";
		float best_kg <- storage_cabbage;
		if (storage_carrot > best_kg) {
			best <- "carrot";
			best_kg <- storage_carrot;
		}
		if (storage_potato > best_kg) {
			best <- "potato";
			best_kg <- storage_potato;
		}
		if (storage_chayote > best_kg) {
			best <- "chayote";
		}
		result_s <- best;
	}

	action gate_point {
		ask world {
			do snap_to_graph(pt: myself.location);
		}
		result_pt <- world.result_pt;
		road_pt <- result_pt;
	}

	aspect default {
		draw triangle(320.0) color: rgb(90, 220, 110) border: #white;
		do total_storage;
		draw ("" + int(result_f)) color: #white font: font("Arial", 9, #bold) at: location + {0, -200};
	}
}

species map_label {
	string txt <- "";
	string kind <- "";
	rgb col <- #white;

	aspect default {
		draw txt color: col font: font("Arial", 11, #bold) perspective: false;
	}
}

species farmer {
	farm_cluster home <- nil;
	disposer usual_disposer <- nil;
	disposer alt_disposer <- nil;
	float trust_usual <- 0.85;
	float trust_alt <- 0.35;
	string intention_plan <- "wait";
	string focus_crop <- "cabbage";
	float belief_posted_ask <- 22.0;
	float belief_spoil_pressure <- 0.0;
	float desire_sell <- 0.5;
	float desire_keep_partner <- 0.8;
	float pending_offer_kg <- 0.0;
	string pending_crop <- "";
	bool offer_open <- false;

	action perceive {
		if (home != nil) {
			ask home { do richest_crop; }
			focus_crop <- home.result_s;
			ask home { do total_storage; }
			belief_spoil_pressure <- min(1.0, home.result_f / max(1.0, harvest_kg_per_farm_day * 2.0));
		}
		ask world { do crop_ask(crop: myself.focus_crop); }
		belief_posted_ask <- world.result_f;
		if (trust_enabled and usual_disposer != nil) {
			ask usual_disposer {
				do ask_for(crop: myself.focus_crop);
			}
			belief_posted_ask <- (source_trust_official * belief_posted_ask
				+ source_trust_partner * usual_disposer.result_f)
				/ max(0.001, source_trust_official + source_trust_partner);
		}
	}

	action maintain_desires {
		desire_sell <- 0.4 + 0.6 * belief_spoil_pressure;
		if (trust_enabled) {
			desire_keep_partner <- trust_usual;
		} else {
			desire_keep_partner <- 0.5;
		}
	}

	action deliberate {
		if (offer_open) {
			return;
		}
		if (home != nil and sim_hour = harvest_hour) {
			float ready_sum <- home.ready_cabbage + home.ready_carrot + home.ready_potato + home.ready_chayote;
			if (ready_sum > 0.0) {
				intention_plan <- "harvest_now";
				return;
			}
		}
		if (home = nil) {
			intention_plan <- "wait";
			return;
		}
		ask home { do total_storage; }
		if (home.result_f <= 1.0) {
			intention_plan <- "wait";
			return;
		}
		ask world { do crop_mid(crop: myself.focus_crop); }
		float mid <- world.result_f;
		if (belief_posted_ask < delay_frac * mid and belief_spoil_pressure < 0.7) {
			intention_plan <- "delay_sale_low_price";
			return;
		}
		bool usual_ok <- true;
		if (trust_enabled) {
			usual_ok <- trust_usual >= trust_partner_threshold;
		}
		if (usual_ok and usual_disposer != nil) {
			ask home { do get_storage(crop: myself.focus_crop); }
			if (home.result_f > truck_capacity_kg) {
				intention_plan <- "split_deliveries";
			} else {
				intention_plan <- "sell_usual_disposer";
			}
		} else {
			intention_plan <- "switch_disposer_if_blocked";
		}
	}

	action act {
		if (intention_plan = "harvest_now") {
			if (home = nil) {
				return;
			}
			do harvest_crop(crop: "cabbage", qty: home.ready_cabbage);
			do harvest_crop(crop: "carrot", qty: home.ready_carrot);
			do harvest_crop(crop: "potato", qty: home.ready_potato);
			do harvest_crop(crop: "chayote", qty: home.ready_chayote);
			home.ready_cabbage <- 0.0;
			home.ready_carrot <- 0.0;
			home.ready_potato <- 0.0;
			home.ready_chayote <- 0.0;
			intention_plan <- "wait";
		} else if (intention_plan = "delay_sale_low_price" or intention_plan = "wait") {
			// hold
		} else if (intention_plan = "sell_usual_disposer" or intention_plan = "split_deliveries"
			or intention_plan = "switch_disposer_if_blocked") {
			do try_sell;
		}
	}

	action harvest_crop {
		arg crop type: string;
		arg qty type: float;
		if (qty <= 0.0) {
			return;
		}
		ask home {
			do add_storage(crop: crop, qty: qty);
		}
		ask world {
			do bump_harvest(crop: crop, qty: qty);
		}
	}

	action try_sell {
		disposer target <- usual_disposer;
		float tscore <- trust_usual;
		if (intention_plan = "switch_disposer_if_blocked") {
			target <- alt_disposer;
			tscore <- trust_alt;
			day_partner_switches <- day_partner_switches + 1;
		}
		if (target = nil or home = nil) {
			return;
		}
		if (!empty(trucker where (each.origin_farm = home and each.state != "idle"))) {
			return;
		}
		if (trust_enabled and tscore < trust_partner_threshold) {
			intention_plan <- "wait";
			return;
		}
		string crop <- focus_crop;
		ask home { do get_storage(crop: crop); }
		float qty <- home.result_f;
		if (intention_plan = "split_deliveries") {
			qty <- min(qty, truck_capacity_kg / 3.0);
		}
		qty <- min(qty, truck_capacity_kg);
		if (qty <= 1.0) {
			return;
		}
		pending_offer_kg <- qty;
		pending_crop <- crop;
		offer_open <- true;
		ask target {
			do receive_offer(f: myself, qty: qty, crop: crop);
		}
	}

	action on_offer_result {
		arg d type: disposer;
		arg qty type: float;
		arg accepted type: bool;
		arg crop type: string;
		if (accepted) {
			// Stock stays on the farm until the truck arrives and picks it up.
			offer_open <- false;
			pending_offer_kg <- 0.0;
			pending_crop <- "";
			if (trust_enabled) {
				if (d = usual_disposer) {
					trust_usual <- (1.0 - trust_alpha) * trust_usual + trust_alpha * 1.0;
				} else {
					trust_alt <- (1.0 - trust_alpha) * trust_alt + trust_alpha * 1.0;
					if (trust_alt > trust_usual) {
						disposer tmp <- usual_disposer;
						usual_disposer <- alt_disposer;
						alt_disposer <- tmp;
						float tt <- trust_usual;
						trust_usual <- trust_alt;
						trust_alt <- tt;
					}
				}
			}
			intention_plan <- "wait";
		} else {
			offer_open <- false;
			pending_offer_kg <- 0.0;
			pending_crop <- "";
			if (trust_enabled) {
				if (d = usual_disposer) {
					trust_usual <- (1.0 - trust_alpha) * trust_usual + trust_alpha * 0.0;
				} else {
					trust_alt <- (1.0 - trust_alpha) * trust_alt + trust_alpha * 0.0;
				}
			}
			intention_plan <- "switch_disposer_if_blocked";
		}
	}

	aspect default {
		draw circle(90.0) color: rgb(120, 255, 140) border: #white;
	}
}

species disposer {
	float result_f <- 0.0;
	string result_s <- "";
	float buffer_cabbage <- 0.0;
	float buffer_carrot <- 0.0;
	float buffer_potato <- 0.0;
	float buffer_chayote <- 0.0;
	string intention_plan <- "ask_inside_band";
	float desire_clear <- 0.5;
	list<farmer> offer_farmers <- [];
	list<float> offer_qtys <- [];
	list<string> offer_crops <- [];

	action clear_buffer {
		buffer_cabbage <- 0.0;
		buffer_carrot <- 0.0;
		buffer_potato <- 0.0;
		buffer_chayote <- 0.0;
	}

	action buffer_total {
		result_f <- buffer_cabbage + buffer_carrot + buffer_potato + buffer_chayote;
	}

	action ask_for {
		arg crop type: string;
		ask world { do crop_ask(crop: crop); }
		result_f <- world.result_f;
	}

	action add_buffer {
		arg crop type: string;
		arg qty type: float;
		if (crop = "carrot") {
			buffer_carrot <- buffer_carrot + qty;
		} else if (crop = "potato") {
			buffer_potato <- buffer_potato + qty;
		} else if (crop = "chayote") {
			buffer_chayote <- buffer_chayote + qty;
		} else {
			buffer_cabbage <- buffer_cabbage + qty;
		}
	}

	action take_buffer {
		arg crop type: string;
		arg qty type: float;
		float have <- 0.0;
		if (crop = "carrot") {
			have <- buffer_carrot;
		} else if (crop = "potato") {
			have <- buffer_potato;
		} else if (crop = "chayote") {
			have <- buffer_chayote;
		} else {
			have <- buffer_cabbage;
		}
		float took <- min(qty, have);
		if (crop = "carrot") {
			buffer_carrot <- buffer_carrot - took;
		} else if (crop = "potato") {
			buffer_potato <- buffer_potato - took;
		} else if (crop = "chayote") {
			buffer_chayote <- buffer_chayote - took;
		} else {
			buffer_cabbage <- buffer_cabbage - took;
		}
		result_f <- took;
	}

	action spoil_all {
		arg rate type: float;
		do buffer_total;
		float loss <- result_f * rate;
		buffer_cabbage <- max(0.0, buffer_cabbage * (1.0 - rate));
		buffer_carrot <- max(0.0, buffer_carrot * (1.0 - rate));
		buffer_potato <- max(0.0, buffer_potato * (1.0 - rate));
		buffer_chayote <- max(0.0, buffer_chayote * (1.0 - rate));
		result_f <- loss;
	}

	action richest_buffer {
		string best <- "cabbage";
		float best_kg <- buffer_cabbage;
		if (buffer_carrot > best_kg) {
			best <- "carrot";
			best_kg <- buffer_carrot;
		}
		if (buffer_potato > best_kg) {
			best <- "potato";
			best_kg <- buffer_potato;
		}
		if (buffer_chayote > best_kg) {
			best <- "chayote";
		}
		result_s <- best;
	}

	action perceive {
		do buffer_total;
		desire_clear <- min(1.0, result_f / 2000.0);
	}

	action maintain_desires {
	}

	action deliberate {
		if (!empty(offer_farmers) and first(offer_qtys) > 0.0) {
			do buffer_total;
			if (result_f + first(offer_qtys) > truck_capacity_kg * 3.0) {
				intention_plan <- "reject_lot";
			} else {
				intention_plan <- "accept_lot";
			}
		} else {
			do buffer_total;
			if (result_f > 50.0) {
				intention_plan <- "allocate_usual_buyer";
			} else {
				intention_plan <- "ask_inside_band";
			}
		}
	}

	action act {
		if (intention_plan = "accept_lot" and !empty(offer_farmers)) {
			loop while: (!empty(offer_farmers)) {
				trucker free <- first(trucker where (each.state = "idle"));
				if (free = nil) {
					break;
				}
				farmer f <- first(offer_farmers);
				float qty <- first(offer_qtys);
				string crop <- first(offer_crops);
				remove index: 0 from: offer_farmers;
				remove index: 0 from: offer_qtys;
				remove index: 0 from: offer_crops;
				if (f != nil and f.home != nil) {
					ask f {
						do on_offer_result(d: myself, qty: qty, accepted: true, crop: crop);
					}
					ask free {
						do assign_trip(origin: f.home, dest_market: baptc, qty: qty, crop: crop, d: myself);
					}
				} else if (f != nil) {
					ask f {
						do on_offer_result(d: myself, qty: qty, accepted: false, crop: crop);
					}
				}
			}
			intention_plan <- "pay_after_clear";
		} else if (intention_plan = "reject_lot" and !empty(offer_farmers)) {
			farmer f <- first(offer_farmers);
			float q <- first(offer_qtys);
			string c <- first(offer_crops);
			remove index: 0 from: offer_farmers;
			remove index: 0 from: offer_qtys;
			remove index: 0 from: offer_crops;
			if (f != nil) {
				ask f {
					do on_offer_result(d: myself, qty: q, accepted: false, crop: c);
				}
			}
		}
		do buffer_total;
		if (result_f > 50.0 and the_wholesaler != nil) {
			do richest_buffer;
			string crop <- result_s;
			do take_buffer(crop: crop, qty: 1500.0);
			float move <- result_f;
			if (move > 0.0) {
				ask the_wholesaler {
					do add_inventory(crop: crop, qty: move);
				}
				if (trust_enabled) {
					the_wholesaler.trust_usual <- (1.0 - trust_alpha) * the_wholesaler.trust_usual + trust_alpha * 1.0;
				}
				intention_plan <- "pay_after_clear";
			}
		}
	}

	action receive_offer {
		arg f type: farmer;
		arg qty type: float;
		arg crop type: string;
		if (offer_farmers contains f) {
			return;
		}
		offer_farmers <+ f;
		offer_qtys <+ qty;
		offer_crops <+ crop;
	}

	action dispatch_haul {
		arg origin type: farm_cluster;
		arg qty type: float;
		arg crop type: string;
		trucker free <- first(trucker where (each.state = "idle"));
		if (free = nil) {
			return;
		}
		ask free {
			do assign_trip(origin: origin, dest_market: baptc, qty: qty, crop: crop, d: myself);
		}
	}

	aspect default {
		draw square(140.0) color: rgb(255, 200, 80) border: #white;
	}
}

// Presentation drive: idle at BAPTC → to_farm (empty) → to_market (loaded) → idle.
species trucker skills: [moving] {
	float load_kg <- 0.0;
	float order_kg <- 0.0;
	string load_crop <- "";
	string state <- "idle"; // idle | to_farm | to_market
	string intention_plan <- "delay_trip";
	point dest;
	farm_cluster origin_farm <- nil;
	disposer shipper <- nil;
	bool use_halsema <- true;

	action perceive {
	}

	action maintain_desires {
	}

	action deliberate {
		if (state = "idle") {
			intention_plan <- "delay_trip";
		} else if (use_halsema) {
			intention_plan <- "route_halsema";
		} else {
			intention_plan <- "route_alternate";
		}
	}

	action act {
		do drive;
	}

	action drive {
		if (state = "idle") {
			return;
		}
		do goto target: dest on: road_graph speed: truck_speed_m_per_h / #h recompute_path: true;
		if ((location distance_to dest) <= arrive_tol_m) {
			if (state = "to_farm") {
				do pick_up;
			} else {
				do arrive;
			}
		} else if (current_path = nil) {
			write "WARN: " + name + " has no road path to " + dest + "; aborting trip";
			do arrive;
		}
	}

	action assign_trip {
		arg origin type: farm_cluster;
		arg dest_market type: market;
		arg qty type: float;
		arg crop type: string;
		arg d type: disposer;
		if (origin = nil) {
			return;
		}
		origin_farm <- origin;
		shipper <- d;
		load_crop <- crop;
		order_kg <- min(qty, truck_capacity_kg);
		load_kg <- 0.0;
		use_halsema <- true;
		if (qty > truck_capacity_kg) {
			intention_plan <- "partial_load";
		} else {
			intention_plan <- "route_halsema";
		}
		ask origin {
			do gate_point;
		}
		dest <- origin.road_pt;
		location <- baptc_gate;
		state <- "to_farm";
	}

	action pick_up {
		if (origin_farm != nil) {
			ask origin_farm {
				do take_storage(crop: myself.load_crop, qty: myself.order_kg);
			}
			load_kg <- origin_farm.result_f;
		}
		if (load_kg <= 0.0) {
			load_crop <- "";
		}
		dest <- baptc_gate;
		state <- "to_market";
	}

	action arrive {
		location <- baptc_gate;
		if (shipper != nil and load_kg > 0.0) {
			ask shipper {
				do add_buffer(crop: myself.load_crop, qty: myself.load_kg);
			}
			ask world {
				do bump_deliver(crop: myself.load_crop, qty: myself.load_kg);
			}
			trips_completed <- trips_completed + 1;
		}
		load_kg <- 0.0;
		order_kg <- 0.0;
		load_crop <- "";
		state <- "idle";
		intention_plan <- "delay_trip";
		origin_farm <- nil;
		shipper <- nil;
	}

	aspect default {
		rgb c <- rgb(180, 180, 190);
		if (state = "to_farm") {
			c <- rgb(80, 160, 255);
		} else if (state = "to_market") {
			if (load_crop = "carrot") {
				c <- rgb(255, 140, 40);
			} else if (load_crop = "potato") {
				c <- rgb(220, 200, 80);
			} else if (load_crop = "chayote") {
				c <- rgb(80, 220, 160);
			} else if (load_crop = "cabbage") {
				c <- rgb(80, 220, 100);
			}
		}
		if (state != "idle" and current_path != nil) {
			draw current_path.shape color: c width: 2.2;
		}
		draw circle(110.0) color: c border: #white;
		if (load_kg > 0.0) {
			draw (load_crop + " " + int(load_kg) + "kg") color: #white font: font("Arial", 10, #bold) at: location + {0, -180};
		}
	}
}

species wholesaler {
	float result_f <- 0.0;
	string result_s <- "";
	float inv_cabbage <- 0.0;
	float inv_carrot <- 0.0;
	float inv_potato <- 0.0;
	float inv_chayote <- 0.0;
	float target_per_crop <- 2000.0;
	float ration_per_crop <- 400.0;
	string intention_plan <- "restock";
	disposer usual_disposer <- nil;
	float trust_usual <- 0.85;
	string focus_crop <- "cabbage";
	float last_sold_kg <- 0.0;
	string last_sold_crop <- "";

	action clear_inventory {
		inv_cabbage <- 0.0;
		inv_carrot <- 0.0;
		inv_potato <- 0.0;
		inv_chayote <- 0.0;
	}

	action inv_total {
		result_f <- inv_cabbage + inv_carrot + inv_potato + inv_chayote;
	}

	action get_inv {
		arg crop type: string;
		if (crop = "carrot") {
			result_f <- inv_carrot;
		} else if (crop = "potato") {
			result_f <- inv_potato;
		} else if (crop = "chayote") {
			result_f <- inv_chayote;
		} else {
			result_f <- inv_cabbage;
		}
	}

	action add_inventory {
		arg crop type: string;
		arg qty type: float;
		if (crop = "carrot") {
			inv_carrot <- inv_carrot + qty;
		} else if (crop = "potato") {
			inv_potato <- inv_potato + qty;
		} else if (crop = "chayote") {
			inv_chayote <- inv_chayote + qty;
		} else {
			inv_cabbage <- inv_cabbage + qty;
		}
	}

	action spoil_all {
		arg rate type: float;
		do inv_total;
		float loss <- result_f * rate;
		inv_cabbage <- max(0.0, inv_cabbage * (1.0 - rate));
		inv_carrot <- max(0.0, inv_carrot * (1.0 - rate));
		inv_potato <- max(0.0, inv_potato * (1.0 - rate));
		inv_chayote <- max(0.0, inv_chayote * (1.0 - rate));
		result_f <- loss;
	}

	action perceive {
		focus_crop <- "cabbage";
		float best <- inv_cabbage;
		if (inv_carrot > best) {
			focus_crop <- "carrot";
			best <- inv_carrot;
		}
		if (inv_potato > best) {
			focus_crop <- "potato";
			best <- inv_potato;
		}
		if (inv_chayote > best) {
			focus_crop <- "chayote";
		}
	}

	action maintain_desires {
	}

	action deliberate {
		do inv_total;
		if (result_f < ration_per_crop * 2.0) {
			intention_plan <- "ration";
		} else if (result_f < target_per_crop * 3.0) {
			intention_plan <- "restock";
		} else {
			intention_plan <- "markup_inside_band";
		}
	}

	action act {
		if (intention_plan = "restock" and usual_disposer != nil) {
			do pull_crop(crop: "cabbage");
			do pull_crop(crop: "carrot");
			do pull_crop(crop: "potato");
			do pull_crop(crop: "chayote");
		}
		if (the_retailer != nil) {
			do push_crop(crop: "cabbage");
			do push_crop(crop: "carrot");
			do push_crop(crop: "potato");
			do push_crop(crop: "chayote");
		}
	}

	action pull_crop {
		arg crop type: string;
		do get_inv(crop: crop);
		float need <- max(0.0, target_per_crop - result_f);
		if (need <= 0.0 or usual_disposer = nil) {
			return;
		}
		float take <- 0.0;
		ask usual_disposer {
			do take_buffer(crop: crop, qty: need);
			take <- result_f;
		}
		if (take > 0.0) {
			do add_inventory(crop: crop, qty: take);
			if (trust_enabled) {
				trust_usual <- (1.0 - trust_alpha) * trust_usual + trust_alpha * 1.0;
			}
		}
	}

	action push_crop {
		arg crop type: string;
		ask the_retailer { do demand_of(crop: crop); }
		float demand <- the_retailer.result_f;
		do get_inv(crop: crop);
		if (demand <= 1.0 or result_f <= 1.0) {
			return;
		}
		float want <- min(200.0, demand);
		do sell_crop(crop: crop, qty: want);
		float got <- last_sold_kg;
		if (got > 0.0) {
			ask the_retailer {
				do consume(crop: crop, qty: got);
			}
			ask world {
				do bump_retail(crop: crop, qty: got);
			}
		}
	}

	action sell_crop {
		arg crop type: string;
		arg qty type: float;
		do get_inv(crop: crop);
		float avail <- result_f;
		if (intention_plan = "ration") {
			avail <- min(avail, ration_per_crop * 0.5);
		}
		last_sold_kg <- min(qty, avail);
		last_sold_crop <- crop;
		if (crop = "carrot") {
			inv_carrot <- inv_carrot - last_sold_kg;
		} else if (crop = "potato") {
			inv_potato <- inv_potato - last_sold_kg;
		} else if (crop = "chayote") {
			inv_chayote <- inv_chayote - last_sold_kg;
		} else {
			inv_cabbage <- inv_cabbage - last_sold_kg;
		}
	}

	aspect default {
		draw square(160.0) color: rgb(200, 140, 255) border: #white;
	}
}

species retailer {
	float result_f <- 0.0;
	string result_s <- "";
	float demand_cabbage <- 1200.0;
	float demand_carrot <- 800.0;
	float demand_potato <- 900.0;
	float demand_chayote <- 600.0;
	string intention_plan <- "order_usual";
	wholesaler usual_wholesaler <- nil;
	float trust_usual <- 0.85;

	action reset_daily_demand {
		demand_cabbage <- demand_cabbage_day;
		demand_carrot <- demand_carrot_day;
		demand_potato <- demand_potato_day;
		demand_chayote <- demand_chayote_day;
	}

	action demand_of {
		arg crop type: string;
		if (crop = "carrot") {
			result_f <- demand_carrot;
		} else if (crop = "potato") {
			result_f <- demand_potato;
		} else if (crop = "chayote") {
			result_f <- demand_chayote;
		} else {
			result_f <- demand_cabbage;
		}
	}

	action consume {
		arg crop type: string;
		arg qty type: float;
		if (crop = "carrot") {
			demand_carrot <- max(0.0, demand_carrot - qty);
		} else if (crop = "potato") {
			demand_potato <- max(0.0, demand_potato - qty);
		} else if (crop = "chayote") {
			demand_chayote <- max(0.0, demand_chayote - qty);
		} else {
			demand_cabbage <- max(0.0, demand_cabbage - qty);
		}
	}

	action perceive {
		retail_cabbage <- ask_cabbage * retail_markup;
		retail_carrot <- ask_carrot * retail_markup;
		retail_potato <- ask_potato * retail_markup;
		retail_chayote <- ask_chayote * retail_markup;
	}

	action maintain_desires {
	}

	action deliberate {
		float left <- demand_cabbage + demand_carrot + demand_potato + demand_chayote;
		if (left > 10.0) {
			intention_plan <- "order_usual";
		} else {
			intention_plan <- "set_retail_price";
		}
		// substitute_skip: no cross-crop substitution in Phase 1
	}

	action act {
		// Fulfillment is pushed by wholesaler; retailer only tracks demand and prices
		if (intention_plan = "substitute_skip") {
			return;
		}
	}

	aspect default {
		draw circle(110.0) color: rgb(255, 120, 120) border: #white;
	}
}

experiment bau_core_crops type: gui {
	parameter "Trust enabled" var: trust_enabled;
	parameter "Trust EMA alpha" var: trust_alpha min: 0.01 max: 0.5;
	parameter "Spoilage / hour" var: spoilage_rate_per_hour min: 0.0 max: 0.02;
	parameter "Harvest kg / farm / day" var: harvest_kg_per_farm_day min: 100.0 max: 3000.0;
	parameter "Truck capacity kg" var: truck_capacity_kg min: 500.0 max: 10000.0;
	parameter "Truck speed (m per hour)" var: truck_speed_m_per_h min: 5000.0 max: 60000.0;
	parameter "Write daily CSV" var: write_daily_csv;

	output {
		monitor "Day" value: sim_day;
		monitor "Month" value: sim_month;
		monitor "Ask cabbage" value: ask_cabbage;
		monitor "Ask carrot" value: ask_carrot;
		monitor "Ask potato" value: ask_potato;
		monitor "Ask chayote" value: ask_chayote;
		monitor "Harvested kg" value: total_harvested_kg;
		monitor "Delivered kg" value: total_delivered_kg;
		monitor "Retail sold kg" value: total_retail_sold_kg;
		monitor "Spoiled kg" value: total_spoiled_kg;
		monitor "Trucks en route" value: trucks_en_route;
		monitor "Completed trips" value: trips_completed;
		monitor "Trust on" value: trust_enabled;

		display "corridor_bau" type: 2d background: rgb(22, 26, 34) {
			grid dem_cell;
			species road;
			species farm_cluster;
			species market;
			species farmer;
			species disposer;
			species trucker;
			species wholesaler;
			species retailer;
			species map_label;

			overlay position: {5, 5} size: {460 #px, 90 #px} background: rgb(20, 24, 32, 200) rounded: true {
				draw "Benguet vegetable supply chain" color: #orange font: font("Arial", 12, #bold) at: {12 #px, 28 #px};
				draw "Farms → disposers → BAPTC → city retail" color: #white font: font("Arial", 10, #plain) at: {12 #px, 52 #px};
				draw "Blue truck = heading to farm; crop color = loaded; line = route" color: #white font: font("Arial", 10, #plain) at: {12 #px, 72 #px};
			}
		}

		display "inventories" type: 2d {
			chart "Core crops delivered (cumulative)" type: series {
				data "delivered" value: total_delivered_kg color: #blue;
				data "retail sold" value: total_retail_sold_kg color: #orange;
				data "spoiled" value: total_spoiled_kg color: #red;
				data "harvested" value: total_harvested_kg color: #green;
			}
		}

		display "asks" type: 2d {
			chart "BAPTC ask PHP/kg" type: series {
				data "cabbage" value: ask_cabbage color: #lime;
				data "carrot" value: ask_carrot color: #orange;
				data "potato" value: ask_potato color: #yellow;
				data "chayote" value: ask_chayote color: #cyan;
			}
		}
	}
}

// Alias for older README / scripts
experiment bau_cabbage type: gui {
	parameter "Trust enabled" var: trust_enabled;
	parameter "Write daily CSV" var: write_daily_csv;

	output {
		monitor "Day" value: sim_day;
		monitor "Delivered kg" value: total_delivered_kg;
		monitor "Retail sold kg" value: total_retail_sold_kg;
		display "corridor_bau" type: 2d background: rgb(22, 26, 34) {
			grid dem_cell;
			species road;
			species farm_cluster;
			species market;
			species farmer;
			species disposer;
			species trucker;
			species wholesaler;
			species retailer;
			species map_label;
		}
	}
}
