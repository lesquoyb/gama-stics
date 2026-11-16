/**
* Name: singleplot
* Single-plot version of 'example model.gaml': one STICS simulation, one farmer.
* Tags: stics coupling
* Author: Lucas Grosjean, Baptiste Lesquoy
*/


model singleplot

import 'AgentStics.gaml'

global {

	float step <- 1#d;

	// world sized to one cell of the 4x4 example so the display looks the same
	geometry shape <- square(25#m);

	string crop_input_data <- to_absolute_path('../includes/usm_wheat_no_inputs/');

	image_file fertilizer_img <- image_file("../includes/fertilizer.png");

	image_file watering_can_img <- image_file("../includes/watering can.png");

	image_file seeds_img <- image_file("../includes/seeds.png");

	bool DEBUG_MODE <- false;

	// sowing and harvest decided by GAMA, as cumulative days of year (doy > 365 = following year)
	int sowing_doy <- 309;
	int harvest_doy <- 589;
	float sowing_density <- 10.0; // plants/m2; < 0: use the densitesem of the USM tec file

	int start_doy;  // first day of the USM (datedebut), read from STICS
	int end_doy;    // last day of the USM (datefin): no weather after it
	int start_year; // calendar year of start_doy, read from the USM climate file

	// console log
	int log_every <- 30; // status line every N simulated days (0 = stages and decisions only)
	// STICS stage dates (cumulative doy, 0 until reached), in crop cycle order
	map<string, string> STAGES <- [
		"iplts"::"sowing", "igers"::"germination", "ilevs"::"emergence",
		"iamfs"::"end of juvenile phase (AMF)", "ilaxs"::"maximum leaf area (LAX)",
		"iflos"::"flowering", "idrps"::"start of grain filling (DRP)",
		"imats"::"physiological maturity", "irecs"::"harvest"
	];
	list<string> DAILY_VARIABLES <- ["rendementsec", "densitesem", "airg(n)", "anit(n)",
		"lai(n)", "masec(n)", "resmes", "trr(n)"] + STAGES.keys;
	map<string, int> stage_doys; // stages already reached and logged
	float rain_since_log <- 0.0;

	crops the_plot;

	// "05/11/1994 (doy 309)"
	string fmt_doy(int doy) {
		date d <- date([start_year, 1, 1, 0, 0, 0]) + (doy - 1) * #day;
		return string(d, "dd/MM/yyyy") + " (doy " + doy + ")";
	}

	init{

		gama.pref_cast_container_contents <- true; // TODO: needed in 2026 alphas of gama, harmless otherwise.

		LOG_SERVER_MESSAGES <- DEBUG_MODE;

		the_plot <- first(crops);

		// year of the first weather line: "station year month day doy ..."
		start_year <- int((first(text_file(crop_input_data + "/climat.txt").contents) split_with " ")[1]);

		create AgentStics {

			default_timeout <- 5#s;
			do connect_to_stics(port: 8081);

			map answer <- initialize_crop(crop_input_data, 1);
			if STICS_ERROR in answer.keys {
				write "Error while trying to initialize a crop: " + answer color:#red;
				ask world {
					do die();
				}
			}
			the_plot.stics_id <- int(answer["result"][0]);
			start_doy <- int(get_variable_for(the_plot.stics_id, "iwater"));
			end_doy <- int(get_variable_for(the_plot.stics_id, "ifwater"));
		}

		write "[USM] " + crop_input_data + " | STICS simulation " + the_plot.stics_id color:#blue;
		write "[USM] " + fmt_doy(start_doy) + " -> " + fmt_doy(end_doy) + ", " + (end_doy - start_doy + 1) + " days" color:#blue;
		write "[farmer plan] sowing " + fmt_doy(sowing_doy)
			+ (sowing_density < 0 ? " at the USM density" : " at " + sowing_density + " plants/m2")
			+ ", harvest " + fmt_doy(harvest_doy) color:#green;
		if sowing_doy <= start_doy + 1 or sowing_doy > end_doy {
			write "[farmer plan] sowing day outside the USM (doy " + (start_doy + 2) + " to " + end_doy + "): no sowing" color:#orange;
		}
		if harvest_doy > end_doy {
			write "[farmer plan] harvest day after the end of the USM: STICS will harvest at its deadline (irecbutoir)" color:#orange;
		}

		create farmer {
			location <- the_plot.location;
		}

	}

	reflex daily_loop {
		map<string, float> v;
		ask AgentStics {
			// execute one day of simulation
			map answer <- execute_day();
			if STICS_ERROR in answer.keys {
				write "An error happened while trying to execute one simulation day: " + to_json(answer) color:#red;
				do die();
			}

			answer <- get_variables(DAILY_VARIABLES);
			if STICS_ERROR in answer.keys {
				write "An error happened while trying to read the variables: " + to_json(answer) color:#red;
				do die();
			}

			list<float> values <- list<list<float>>(answer["result"]["values"])[0];
			loop i from: 0 to: length(DAILY_VARIABLES) - 1 {
				v[DAILY_VARIABLES[i]] <- float(values[i]);
			}
		}

		the_plot.yields <- v["rendementsec"];
		the_plot.seeds <- v["densitesem"];
		the_plot.watering <- the_plot.watering + v["airg(n)"];
		the_plot.fertilizer <- the_plot.fertilizer + v["anit(n)"];

		// doy simulated in this cycle
		int today <- start_doy + cycle;
		rain_since_log <- rain_since_log + v["trr(n)"];

		// a stage is reached when STICS gives it a date that is not in the future
		// (before the farmer acts, iplts still holds the tec file sowing date)
		loop stage over: STAGES.keys {
			int d <- int(v[stage]);
			if d > 0 and d <= today and !(stage in stage_doys.keys) {
				stage_doys[stage] <- d;
				write "[STICS] " + fmt_doy(d) + " " + STAGES[stage]
					+ " | LAI " + (v["lai(n)"] with_precision 2)
					+ " | biomass " + (v["masec(n)"] with_precision 2) + " t/ha"
					+ " | grain " + (v["rendementsec"] with_precision 2) + " t/ha" color:#blue;
			}
		}

		if log_every > 0 and mod(cycle + 1, log_every) = 0 {
			write "[day " + (cycle + 1) + "] " + fmt_doy(today)
				+ " | LAI " + (v["lai(n)"] with_precision 2)
				+ " | biomass " + (v["masec(n)"] with_precision 2) + " t/ha"
				+ " | grain " + (v["rendementsec"] with_precision 2) + " t/ha"
				+ " | soil water " + (v["resmes"] with_precision 0) + " mm"
				+ " | rain " + (rain_since_log with_precision 0) + " mm in " + log_every + " d";
			rain_since_log <- 0.0;
		}
	}

	// after daily_loop of cycle k, STICS has simulated up to doy start_doy + k
	reflex end_sim when: start_doy + cycle >= end_doy {
		do pause();
		write "[USM] end on " + fmt_doy(end_doy) color:#blue;
		loop stage over: STAGES.keys {
			write "    " + STAGES[stage] + ": " + (stage in stage_doys.keys ? fmt_doy(stage_doys[stage]) : "not reached");
		}
		write "    grain yield: " + (the_plot.yields with_precision 2) + " t/ha";
	}

}

species farmer {

	rgb color <- #red;
	geometry shape <- circle(1#m);

	reflex do_farmer_things {
		// daily_loop runs before the farmer: STICS has already simulated cycle + 1 days
		int last_sim_day <- cycle + 1;

		if cycle = 0 {
			ask AgentStics {
				// block STICS's own sowing and harvest: only the farmer decides
				if !set_succeeded(set_variables([the_plot.stics_id], ["nplt", "nrecobs"], [STICS_NO_DATE, STICS_NO_DATE])) {
					ask world { do die(); }
				}
			}
			write "[farmer] STICS sowing and harvest from the tec file disabled" color:#green;
		}

		// decisions are applied to the next simulated day
		int next_doy <- start_doy + last_sim_day;
		if next_doy = sowing_doy {
			ask AgentStics {
				if force_sowing([the_plot.stics_id], last_sim_day + 1, sowing_density) {
					write "[farmer] decides to sow on " + world.fmt_doy(sowing_doy)
						+ (sowing_density < 0 ? " at the USM density" : " at " + sowing_density + " plants/m2") color:#green;
				}
			}
		}
		if next_doy = harvest_doy {
			ask AgentStics {
				if force_harvest([the_plot.stics_id], last_sim_day + 1) {
					write "[farmer] decides to harvest on " + world.fmt_doy(harvest_doy) color:#green;
				}
			}
		}
	}



	aspect default {
		draw circle(2.5) color:#white;
		draw image('../includes/farmer.png') size:{4#m,5#m};
	}

}

grid crops width:1 height:1 {
	int stics_id <- -1;
	rgb color <- processColor() update: processColor();
	float yields <- 0.0;
	float seeds <- 0.0;
	float watering <- 0.0;
	float fertilizer <- 0.0;

	rgb processColor(){
		if yields = 0 {
			return #saddlebrown;
		}
		return hsb(float(to_hsb(#lightgreen)[0]), 0.2 + yields/5, float(to_hsb(#lightgreen)[2]));
	}

	aspect default {
		draw shape color:color;
		draw seeds_img size: {seeds/75.0 * 10, seeds/75.0 * 10} at:location + {-7.5,-7.5};
		draw watering_can_img size: {watering/400, watering/400} * {5, 6.5} at:location + {5,2.5};
		draw fertilizer_img size: {fertilizer/300, fertilizer/300} * {5, 6.5} at:location + {-5,5};
		if (yields > 0){
			float height <- 10/(7.2/yields);
			draw rectangle(2, height) at: location + {11, 11 - height/2} color:#red;
		}
		draw shape wireframe:true color:#black;
	}

}


experiment ex {
	parameter "Sowing day (doy)" var: sowing_doy;
	parameter "Harvest day (doy, > 365 = next year)" var: harvest_doy;
	parameter "Sowing density (plants/m2, < 0 = USM value)" var: sowing_density;
	parameter "Status line every N days (0 = off)" var: log_every;

	output {

		display main {
			species crops;
			species farmer;
		}
	}
}
