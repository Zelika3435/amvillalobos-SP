/**
 * Name: Corridor_World
 * Author: Benguet Supply Chain ABM
 * Description: Official DPWH Benguet LRS roads plus Benguet DA completed FMR
 *   (Geoportal DA FMR preview–aligned; not official DA vectors). Display-only DEM.
 *   No synthetic bridges. Elevation does not drive travel time or BAU calibration.
 * Tags: gis, shapefile, dem, supply_chain, network
 */
model Corridor_World

global {
	file network_shapefile <- shape_file("../../data/osm/network_cleaned_utm.shp");
	file markets_shapefile <- shape_file("../includes/markets_utm.shp");
	file farms_shapefile <- shape_file("../includes/farm_clusters_utm.shp");
	file dem_file <- grid_file("../includes/corridor_dem_utm.asc");

	geometry shape <- envelope(dem_file);
	graph road_graph;

	// Display stretch for SRTM elevations in this clip (meters)
	float dem_z_min <- 0.0;
	float dem_z_max <- 2822.0;
	bool world_loaded <- false;

	init {
		do load_world;
	}

	// Importing models' init runs BEFORE this one, so they must call load_world themselves.
	action load_world {
		if (world_loaded) {
			return;
		}
		world_loaded <- true;

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

		create farm_cluster from: farms_shapefile with: [
			place_name::string(read("name")),
			municipality::string(read("muni")),
			role::string(read("role")),
			dist_dpwh::float(read("dist_dpwh")),
			dist_fmr::float(read("dist_fmr"))
		];

		road_graph <- as_edge_graph(road);

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
				txt <- "Farm: " + myself.place_name;
				location <- myself.location + {0, 450};
				col <- rgb(90, 220, 110);
				kind <- "farm";
			}
		}

		ask market {
			create map_label number: 1 {
				txt <- myself.short_label;
				location <- myself.location + {0, 450};
				col <- (myself.is_simulated ? rgb(255, 220, 60) : rgb(255, 180, 100));
				kind <- "market";
			}
		}

		write "roads=" + length(road)
			+ " dpwh=" + length(road where (each.source = "dpwh"))
			+ " fmr_da=" + length(road where (each.source = "da_completed_fmr"))
			+ " osm_tier2=" + length(road where (each.source = "osm_tier2"))
			+ " osm_tier3=" + length(road where (each.source = "osm_tier3"))
			+ " farms=" + length(farm_cluster) + " markets=" + length(market)
			+ " dem_cells=" + length(dem_cell);
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
			// Low valleys dark green → mid olive → highland tan
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
	string place_name <- "";
	string municipality <- "";
	string role <- "";
	float dist_dpwh <- 0.0;
	float dist_fmr <- 0.0;

	aspect default {
		draw triangle(320.0) color: rgb(90, 220, 110) border: #white;
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

experiment map_view type: gui {
	output {
		display "corridor" type: 2d background: rgb(22, 26, 34) {
			grid dem_cell;
			species road;
			species farm_cluster;
			species market;
			species map_label;
		}
	}
}
