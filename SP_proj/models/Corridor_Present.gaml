/**
 * Name: Corridor_Present
 * Author: Benguet Supply Chain ABM
 * Description: PRESENTATION prototype built on Corridor_World (imported environment).
 *   Roads, farms, markets, labels and DEM come from Corridor_World; this model adds
 *   the four-crop farm → disposer → truck → BAPTC → wholesale → retail flow.
 *   Trucks drive the connected road network (road_graph) with the moving skill:
 *   BAPTC → farm (empty), load, farm → BAPTC (loaded). No roads are created here.
 *   This import does not run reliably. The same drive now lives in
 *   Corridor_BAU.gaml, experiment bau_core_crops.
 * Tags: presentation, demo, visualization, supply_chain
 */
model Corridor_Present

import "Corridor_World.gaml"

global {
	// One time step = one hour (same clock as Corridor_BAU)
	float tick_hours <- 1.0;
	int sim_hour <- 0;
	int sim_day <- 0;
	int sim_month <- 1;
	int harvest_hour <- 6;
	int posting_hour <- 5;

	float spoilage_rate_per_hour <- 0.002;
	float harvest_kg_per_farm_day <- 800.0;
	float truck_capacity_kg <- 5000.0;
	float truck_speed_m_per_h <- 25000.0;
	float haul_cost_per_kg <- 3.5;
	float retail_markup <- 1.35;

	float floor_cabbage <- 20.0;
	float ceil_cabbage <- 28.0;
	float floor_carrot <- 26.0;
	float ceil_carrot <- 35.0;
	float floor_potato <- 38.0;
	float ceil_potato <- 44.0;
	float floor_chayote <- 10.0;
	float ceil_chayote <- 12.0;

	int n_disposers <- 3;
	int n_truckers <- 7; // one per farm cluster so all 7 farms can dispatch concurrently
	int rng_seed <- 19001;

	float demand_cabbage_day <- 1200.0;
	float demand_carrot_day <- 800.0;
	float demand_potato_day <- 900.0;
	float demand_chayote_day <- 600.0;

	market baptc <- nil;
	wholesaler the_wholesaler <- nil;
	retailer the_retailer <- nil;
	point baptc_gate;

	float ask_cabbage <- 24.0;
	float ask_carrot <- 30.5;
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

	float result_f <- 0.0;
	string result_s <- "";
	point result_pt;

	init {
		seed <- rng_seed;
		step <- tick_hours #h;
		do load_world;
		do refresh_asks;
		do update_calendar;

		baptc <- first(market where (each.is_simulated));
		if (baptc = nil) {
			baptc <- first(market);
			write "WARN: no simulated=Y market; using first market as BAPTC";
		}
		do snap_to_road(pt: baptc.location);
		baptc_gate <- result_pt;

		ask farm_cluster {
			point site_pt <- location;
			farm_cluster site_fc <- self;
			ask world {
				do snap_to_road(pt: site_pt);
			}
			point gate <- world.result_pt;
			create farm_stock number: 1 {
				site <- site_fc;
				location <- site_pt;
				road_pt <- gate;
				do clear_storage;
				do set_daily_ready;
			}
		}

		ask farm_stock {
			path p <- path_between(road_graph, baptc_gate, road_pt);
			if (p = nil or empty(p.edges)) {
				write "WARN: no road path BAPTC -> " + site.place_name;
			} else {
				route_m <- p.shape.perimeter;
				write "  route BAPTC -> " + site.place_name + ": " + length(p.edges) + " edges, " + int(route_m) + " m";
			}
		}

		create disposer number: n_disposers {
			location <- baptc.location;
			do clear_buffer;
		}

		list<farm_stock> farms <- list(farm_stock);
		loop fi from: 0 to: length(farms) - 1 {
			farm_stock fs <- farms[fi];
			disposer usual <- disposer[fi mod length(disposer)];
			create farmer number: 1 {
				home <- fs;
				location <- fs.location;
				usual_disposer <- usual;
				focus_crop <- "cabbage";
			}
		}

		create trucker number: n_truckers {
			location <- baptc_gate;
			load_kg <- 0.0;
			load_crop <- "";
			state <- "idle";
		}

		create wholesaler number: 1 {
			the_wholesaler <- self;
			location <- baptc.location;
			do clear_inventory;
			usual_disposer <- first(disposer);
		}

		create retailer number: 1 {
			the_retailer <- self;
			location <- baptc.location + {400, 400};
			usual_wholesaler <- first(wholesaler);
			do reset_daily_demand;
		}

		write "PRESENTATION ready: roads=" + length(road)
			+ " graph_edges=" + length(road_graph.edges)
			+ " farms=" + length(farm_stock)
			+ " truckers=" + length(trucker);
	}

	action update_calendar {
		sim_month <- int((sim_day mod 365) / 30.437) + 1;
		if (sim_month > 12) {
			sim_month <- 12;
		}
	}

	action refresh_asks {
		ask_cabbage <- (floor_cabbage + ceil_cabbage) / 2.0;
		ask_carrot <- (floor_carrot + ceil_carrot) / 2.0;
		ask_potato <- (floor_potato + ceil_potato) / 2.0;
		ask_chayote <- (floor_chayote + ceil_chayote) / 2.0;
		retail_cabbage <- ask_cabbage * retail_markup;
		retail_carrot <- ask_carrot * retail_markup;
		retail_potato <- ask_potato * retail_markup;
		retail_chayote <- ask_chayote * retail_markup;
	}

	action seasonal_share {
		arg crop type: string;
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
			result_f <- 0.55;
		}
	}

	// Nearest point lying on an existing road polyline (no new geometry is added).
	action snap_to_road {
		arg pt type: point;
		road nearest <- road closest_to pt;
		if (nearest = nil) {
			result_pt <- pt;
			return;
		}
		result_pt <- first(nearest.shape closest_points_with pt);
	}

	action bump_harvest {
		arg crop type: string;
		arg qty type: float;
		total_harvested_kg <- total_harvested_kg + qty;
	}

	action bump_deliver {
		arg crop type: string;
		arg qty type: float;
		total_delivered_kg <- total_delivered_kg + qty;
	}

	action bump_retail {
		arg crop type: string;
		arg qty type: float;
		total_retail_sold_kg <- total_retail_sold_kg + qty;
	}

	reflex clock {
		sim_hour <- sim_hour + 1;
		if (sim_hour >= 24) {
			sim_hour <- 0;
			sim_day <- sim_day + 1;
			do update_calendar;
			ask farm_stock {
				do set_daily_ready;
			}
			ask retailer {
				do reset_daily_demand;
			}
			write "Day " + sim_day + " summary: trips=" + trips_completed
				+ " delivered_kg=" + int(total_delivered_kg)
				+ " retail_kg=" + int(total_retail_sold_kg)
				+ " en_route=" + trucks_en_route;
		}
		trucks_en_route <- length(trucker where (each.state != "idle"));
	}

	reflex posting when: sim_hour = posting_hour {
		do refresh_asks;
	}

	reflex harvest_window when: sim_hour = harvest_hour {
		ask farmer {
			do do_harvest;
		}
	}

	reflex farmer_offers {
		ask shuffle(list(farmer)) {
			do try_offer;
		}
	}

	reflex disposer_clear {
		ask shuffle(list(disposer)) {
			do try_accept_and_dispatch;
			do try_clear_to_wholesale;
		}
	}

	reflex move_trucks {
		ask trucker {
			do drive;
		}
	}
	reflex retail_buy {
		ask retailer {
			do buy_and_sell;
		}
	}

	reflex spoil {
		float spoiled <- 0.0;
		float rate <- spoilage_rate_per_hour * tick_hours;
		ask farm_stock {
			do spoil_all(rate: rate);
			spoiled <- spoiled + result_f;
		}
		ask disposer {
			do spoil_all(rate: rate);
			spoiled <- spoiled + result_f;
		}
		ask wholesaler {
			do spoil_all(rate: rate);
			spoiled <- spoiled + result_f;
		}
		total_spoiled_kg <- total_spoiled_kg + spoiled;
	}

}

// Crop stock attached to one Corridor_World farm_cluster (geography stays in the world model).
species farm_stock {
	farm_cluster site <- nil;
	point road_pt; // pickup point on the road network nearest the farm
	float route_m <- 0.0;
	float result_f <- 0.0;
	string result_s <- "";

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
		float took <- min(qty, result_f);
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

	action spoil_all {
		arg rate type: float;
		do total_storage;
		float before <- result_f;
		storage_cabbage <- max(0.0, storage_cabbage * (1.0 - rate));
		storage_carrot <- max(0.0, storage_carrot * (1.0 - rate));
		storage_potato <- max(0.0, storage_potato * (1.0 - rate));
		storage_chayote <- max(0.0, storage_chayote * (1.0 - rate));
		do total_storage;
		result_f <- max(0.0, before - result_f);
	}

	aspect default {
		do total_storage;
		draw ("" + int(result_f) + " kg") color: #white font: font("Arial", 9, #bold) at: location + {0, -200};
	}
}

species farmer {
	farm_stock home <- nil;
	disposer usual_disposer <- nil;
	string focus_crop <- "cabbage";
	bool offer_open <- false;

	action do_harvest {
		if (home = nil) {
			return;
		}
		float hc <- home.ready_cabbage;
		float hr <- home.ready_carrot;
		float hp <- home.ready_potato;
		float hh <- home.ready_chayote;
		ask home {
			do add_storage(crop: "cabbage", qty: hc);
			do add_storage(crop: "carrot", qty: hr);
			do add_storage(crop: "potato", qty: hp);
			do add_storage(crop: "chayote", qty: hh);
			ready_cabbage <- 0.0;
			ready_carrot <- 0.0;
			ready_potato <- 0.0;
			ready_chayote <- 0.0;
		}
		ask world {
			do bump_harvest(crop: "cabbage", qty: hc);
			do bump_harvest(crop: "carrot", qty: hr);
			do bump_harvest(crop: "potato", qty: hp);
			do bump_harvest(crop: "chayote", qty: hh);
		}
	}

	action try_offer {
		if (offer_open or home = nil or usual_disposer = nil) {
			return;
		}
		if (length(trucker where (each.state = "idle")) = 0) {
			return;
		}
		// One truck per farm at a time; pickup happens when that truck reaches the farm.
		if (!empty(trucker where (each.origin = home))) {
			return;
		}
		ask home {
			do richest_crop;
		}
		focus_crop <- home.result_s;
		ask home {
			do get_storage(crop: myself.focus_crop);
		}
		float qty <- min(home.result_f, truck_capacity_kg);
		if (qty < 50.0) {
			return;
		}
		offer_open <- true;
		ask usual_disposer {
			do receive_offer(f: myself, qty: qty, crop: myself.focus_crop);
		}
	}

	action on_offer_result {
		arg accepted type: bool;
		offer_open <- false;
	}

	aspect default {
		draw circle(90.0) color: rgb(120, 255, 140) border: #white;
	}
}

species disposer {
	float buffer_cabbage <- 0.0;
	float buffer_carrot <- 0.0;
	float buffer_potato <- 0.0;
	float buffer_chayote <- 0.0;
	list<farmer> offer_farmers <- [];
	list<float> offer_qtys <- [];
	list<string> offer_crops <- [];
	float result_f <- 0.0;
	string result_s <- "";

	action clear_buffer {
		buffer_cabbage <- 0.0;
		buffer_carrot <- 0.0;
		buffer_potato <- 0.0;
		buffer_chayote <- 0.0;
	}

	action buffer_total {
		result_f <- buffer_cabbage + buffer_carrot + buffer_potato + buffer_chayote;
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

	action spoil_all {
		arg rate type: float;
		do buffer_total;
		float before <- result_f;
		buffer_cabbage <- max(0.0, buffer_cabbage * (1.0 - rate));
		buffer_carrot <- max(0.0, buffer_carrot * (1.0 - rate));
		buffer_potato <- max(0.0, buffer_potato * (1.0 - rate));
		buffer_chayote <- max(0.0, buffer_chayote * (1.0 - rate));
		do buffer_total;
		result_f <- max(0.0, before - result_f);
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

	action try_accept_and_dispatch {
		loop while: (!empty(offer_farmers)) {
			trucker free <- first(trucker where (each.state = "idle"));
			if (free = nil) {
				return;
			}
			farmer f <- first(offer_farmers);
			float qty <- first(offer_qtys);
			string crop <- first(offer_crops);
			remove index: 0 from: offer_farmers;
			remove index: 0 from: offer_qtys;
			remove index: 0 from: offer_crops;
			if (f = nil or f.home = nil) {
				if (f != nil) {
					ask f {
						do on_offer_result(accepted: false);
					}
				}
			} else {
				ask f {
					do on_offer_result(accepted: true);
				}
				ask free {
					do assign_trip(o: f.home, qty: qty, crop: crop, d: myself);
				}
			}
		}
	}

	action try_clear_to_wholesale {
		do buffer_total;
		if (result_f < 50.0 or the_wholesaler = nil) {
			return;
		}
		do richest_buffer;
		string crop <- result_s;
		do take_buffer(crop: crop, qty: 1500.0);
		float move <- result_f;
		if (move > 0.0) {
			ask the_wholesaler {
				do add_inventory(crop: crop, qty: move);
			}
		}
	}

	aspect default {
		draw square(140.0) color: rgb(255, 200, 80) border: #white;
	}
}

// Drives on road_graph only: idle at BAPTC → to_farm (empty) → to_market (loaded) → idle.
species trucker skills: [moving] {
	float load_kg <- 0.0;
	float order_kg <- 0.0;
	string load_crop <- "";
	string state <- "idle"; // idle | to_farm | to_market
	disposer shipper <- nil;
	farm_stock origin <- nil;
	point dest;

	action assign_trip {
		arg o type: farm_stock;
		arg qty type: float;
		arg crop type: string;
		arg d type: disposer;
		shipper <- d;
		origin <- o;
		load_crop <- crop;
		order_kg <- min(qty, truck_capacity_kg);
		load_kg <- 0.0;
		dest <- o.road_pt;
		state <- "to_farm";
	}

	action drive {
		if (state = "idle") {
			return;
		}
		do goto target: dest on: road_graph speed: truck_speed_m_per_h / #h recompute_path: false;
		if ((location distance_to dest) <= 1.0) {
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

	action pick_up {
		ask origin {
			do take_storage(crop: myself.load_crop, qty: myself.order_kg);
		}
		load_kg <- origin.result_f;
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
		shipper <- nil;
		origin <- nil;
		state <- "idle";
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
	float inv_cabbage <- 0.0;
	float inv_carrot <- 0.0;
	float inv_potato <- 0.0;
	float inv_chayote <- 0.0;
	disposer usual_disposer <- nil;
	float result_f <- 0.0;

	action clear_inventory {
		inv_cabbage <- 0.0;
		inv_carrot <- 0.0;
		inv_potato <- 0.0;
		inv_chayote <- 0.0;
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

	action take_inventory {
		arg crop type: string;
		arg qty type: float;
		float have <- 0.0;
		if (crop = "carrot") {
			have <- inv_carrot;
		} else if (crop = "potato") {
			have <- inv_potato;
		} else if (crop = "chayote") {
			have <- inv_chayote;
		} else {
			have <- inv_cabbage;
		}
		float took <- min(qty, have);
		if (crop = "carrot") {
			inv_carrot <- inv_carrot - took;
		} else if (crop = "potato") {
			inv_potato <- inv_potato - took;
		} else if (crop = "chayote") {
			inv_chayote <- inv_chayote - took;
		} else {
			inv_cabbage <- inv_cabbage - took;
		}
		result_f <- took;
	}

	action spoil_all {
		arg rate type: float;
		float before <- inv_cabbage + inv_carrot + inv_potato + inv_chayote;
		inv_cabbage <- max(0.0, inv_cabbage * (1.0 - rate));
		inv_carrot <- max(0.0, inv_carrot * (1.0 - rate));
		inv_potato <- max(0.0, inv_potato * (1.0 - rate));
		inv_chayote <- max(0.0, inv_chayote * (1.0 - rate));
		result_f <- max(0.0, before - (inv_cabbage + inv_carrot + inv_potato + inv_chayote));
	}

	aspect default {
		draw hexagon(160.0) color: rgb(180, 140, 255) border: #white;
	}
}

species retailer {
	wholesaler usual_wholesaler <- nil;
	float demand_cabbage <- 0.0;
	float demand_carrot <- 0.0;
	float demand_potato <- 0.0;
	float demand_chayote <- 0.0;

	action reset_daily_demand {
		demand_cabbage <- demand_cabbage_day;
		demand_carrot <- demand_carrot_day;
		demand_potato <- demand_potato_day;
		demand_chayote <- demand_chayote_day;
	}

	action buy_crop {
		arg crop type: string;
		arg want type: float;
		if (usual_wholesaler = nil or want <= 0.0) {
			return;
		}
		ask usual_wholesaler {
			do take_inventory(crop: crop, qty: want);
		}
		float got <- usual_wholesaler.result_f;
		if (got > 0.0) {
			ask world {
				do bump_retail(crop: crop, qty: got);
			}
			if (crop = "carrot") {
				demand_carrot <- max(0.0, demand_carrot - got);
			} else if (crop = "potato") {
				demand_potato <- max(0.0, demand_potato - got);
			} else if (crop = "chayote") {
				demand_chayote <- max(0.0, demand_chayote - got);
			} else {
				demand_cabbage <- max(0.0, demand_cabbage - got);
			}
		}
	}

	action buy_and_sell {
		do buy_crop(crop: "cabbage", want: min(400.0, demand_cabbage));
		do buy_crop(crop: "carrot", want: min(400.0, demand_carrot));
		do buy_crop(crop: "potato", want: min(400.0, demand_potato));
		do buy_crop(crop: "chayote", want: min(400.0, demand_chayote));
	}

	aspect default {
		draw square(120.0) color: rgb(255, 120, 160) border: #white;
	}
}

experiment present_flow type: gui {
	parameter "Number of truckers" var: n_truckers min: 1 max: 12;
	parameter "Truck speed (m per hour)" var: truck_speed_m_per_h min: 5000.0 max: 60000.0;
	parameter "Daily harvest per farm (kg)" var: harvest_kg_per_farm_day min: 100.0 max: 3000.0;

	output {
		monitor "Simulation day" value: sim_day;
		monitor "Hour of day" value: sim_hour;
		monitor "Month" value: sim_month;
		monitor "Cabbage ask (PHP/kg)" value: ask_cabbage;
		monitor "Carrot ask (PHP/kg)" value: ask_carrot;
		monitor "Potato ask (PHP/kg)" value: ask_potato;
		monitor "Chayote ask (PHP/kg)" value: ask_chayote;
		monitor "Harvested (kg)" value: total_harvested_kg;
		monitor "Delivered to BAPTC (kg)" value: total_delivered_kg;
		monitor "Retail sold (kg)" value: total_retail_sold_kg;
		monitor "Spoiled (kg)" value: total_spoiled_kg;
		monitor "Trucks en route" value: trucks_en_route;
		monitor "Completed trips" value: trips_completed;

		display "Corridor map" type: 2d background: rgb(22, 26, 34) {
			grid dem_cell;
			species road;
			species farm_cluster;
			species market;
			species farm_stock;
			species farmer;
			species disposer;
			species trucker;
			species wholesaler;
			species retailer;
			species map_label;

			overlay position: {5, 5} size: {420 #px, 90 #px} background: rgb(20, 24, 32, 200) rounded: true {
				draw "Benguet vegetable supply chain" color: #orange font: font("Arial", 12, #bold) at: {12 #px, 28 #px};
				draw "Farms → disposers → BAPTC → city retail" color: #white font: font("Arial", 10, #plain) at: {12 #px, 52 #px};
				draw "Blue truck = heading to farm; crop color = loaded; line = route" color: #white font: font("Arial", 10, #plain) at: {12 #px, 72 #px};
			}
		}

		display "Crop flows" type: 2d {
			chart "Cumulative crop volume (kg)" type: series {
				data "Harvested" value: total_harvested_kg color: #green;
				data "Delivered to BAPTC" value: total_delivered_kg color: #blue;
				data "Retail sold" value: total_retail_sold_kg color: #orange;
				data "Spoiled" value: total_spoiled_kg color: #red;
			}
		}

		display "Wholesale prices" type: 2d {
			chart "BAPTC posted ask (PHP/kg)" type: series {
				data "Cabbage" value: ask_cabbage color: #lime;
				data "Carrot" value: ask_carrot color: #orange;
				data "Potato" value: ask_potato color: #yellow;
				data "Chayote" value: ask_chayote color: #cyan;
			}
		}
	}
}
