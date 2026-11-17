/**
* Name: usmsequence
* A sequence of USMs on one plot, driven by GAMA through the STICS server.
* Each USM runs to its datefin, then is closed; its end state (recup.tmp: soil water, N, organic matter,
* residues, roots) is copied into the next USM folder (codesuite = 1 in its new_travail.usm) before starting it.
* Sowing / harvest of each USM can be kept from its tec file or forced by the farmer.
* Tags: stics coupling
* Author: Lucas Grosjean, Baptiste Lesquoy
*/


model usmsequence

import 'AgentStics.gaml'

global {

	float step <- 1#d;

	// world sized to one cell of the 4x4 example so the display looks the same
	geometry shape <- square(25#m);

	// USMs run one after another on the same plot (from the 2nd one on: codesuite = 1)
	string usm_root <- to_absolute_path('../includes/sequence_plot2');
	list<string> usm_names <- ["USM_ble_2020_2", "USM_mais_2021_2"];
	// STICS output files are written in <workspace>/outputs/output_<simulation id>/
	string workspace <- to_absolute_path('../stics_workspace');

	// farmer decisions, one value per USM, as cumulative doy of that USM (doy > 365 = following year)
	list<int> sowing_doys <- [-1, -1];             // -1: sowing date of the USM tec file
	list<int> harvest_doys <- [-1, -1];            // -1: harvest computed by STICS
	list<float> sowing_densities <- [-1.0, -1.0];  // plants/m2, -1: density of the USM tec file

	bool DEBUG_MODE <- false;
	int log_every <- 30; // status line every N simulated days (0 = stages and decisions only)

	image_file fertilizer_img <- image_file("../includes/fertilizer.png");
	image_file watering_can_img <- image_file("../includes/watering can.png");
	image_file seeds_img <- image_file("../includes/seeds.png");

	// current USM
	int usm_index <- -1;
	int sim_id <- -1;
	int start_doy;   // datedebut
	int end_doy;     // datefin: no weather after it
	int start_year;  // calendar year of start_doy, from the USM climate file
	int usm_day <- 0; // days already simulated in the current USM

	// STICS stage dates (cumulative doy, 0 until reached), in crop cycle order
	map<string, string> STAGES <- [
		"iplts"::"sowing", "igers"::"germination", "ilevs"::"emergence",
		"iamfs"::"end of juvenile phase (AMF)", "ilaxs"::"maximum leaf area (LAX)",
		"iflos"::"flowering", "idrps"::"start of grain filling (DRP)",
		"imats"::"physiological maturity", "irecs"::"harvest"
	];
	list<string> DAILY_VARIABLES <- ["mafruit", "densitesem", "airg(n)", "anit(n)",
		"lai(n)", "masec(n)", "resmes", "trr(n)"] + STAGES.keys;
	map<string, int> stage_doys; // stages of the current USM already reached and logged
	float rain_since_log <- 0.0;

	crops the_plot;
	AgentStics stics;

	// "05/11/2019 (doy 309)"
	string fmt_doy(int doy) {
		date d <- date([start_year, 1, 1, 0, 0, 0]) + (doy - 1) * #day;
		return string(d, "dd/MM/yyyy") + " (doy " + doy + ")";
	}

	string usm_path(int i) {
		return usm_root + "/" + usm_names[i];
	}

	init {
		gama.pref_cast_container_contents <- true; // TODO: needed in 2026 alphas of gama, harmless otherwise.
		LOG_SERVER_MESSAGES <- DEBUG_MODE;

		the_plot <- first(crops);
		create AgentStics {
			default_timeout <- 5#s;
			do connect_to_stics(port: 8081);
		}
		stics <- first(AgentStics);
		create farmer {
			location <- the_plot.location;
		}

		write "[sequence] " + length(usm_names) + " USMs: " + usm_names color:#blue;
		do start_usm(0);
	}

	action start_usm(int i) {
		usm_index <- i;
		string path_usm <- usm_path(i);

		map answer;
		ask stics {
			answer <- initialize_crop(path_usm, 1, workspace);
		}
		if STICS_ERROR in answer.keys {
			write "[USM] could not initialize " + path_usm + ": " + to_json(answer) color:#red;
			sim_id <- -1; // stops daily_loop
			do pause();
		} else {
			do setup_usm(i, int(list(answer["result"])[0]));
		}
	}

	action setup_usm(int i, int new_sim_id) {
		string path_usm <- usm_path(i);
		sim_id <- new_sim_id;
		the_plot.stics_id <- sim_id;
		ask stics {
			start_doy <- int(get_variable_for(sim_id, "iwater"));
			end_doy <- int(get_variable_for(sim_id, "ifwater"));
		}
		// year of the first weather line: "station year month day doy ..."
		start_year <- int((first(text_file(path_usm + "/climat.txt").contents) split_with " ")[1]);

		usm_day <- 0;
		stage_doys <- [];
		rain_since_log <- 0.0;
		the_plot.yields <- 0.0;
		the_plot.seeds <- 0.0;
		the_plot.watering <- 0.0;
		the_plot.fertilizer <- 0.0;

		write "[USM " + (i + 1) + "/" + length(usm_names) + "] " + usm_names[i] + " | STICS simulation " + sim_id
			+ " | soil from " + (i = 0 ? "its own initial state (ficini)" : "the end of " + usm_names[i - 1] + " (recup.tmp)") color:#blue;
		write "[USM " + (i + 1) + "/" + length(usm_names) + "] " + fmt_doy(start_doy) + " -> " + fmt_doy(end_doy)
			+ ", " + (end_doy - start_doy + 1) + " days" color:#blue;
		write "[farmer plan] sowing " + (sowing_doys[i] < 0 ? "on the tec file date" : fmt_doy(sowing_doys[i]))
			+ (sowing_densities[i] < 0 ? " at the tec file density" : " at " + sowing_densities[i] + " plants/m2")
			+ ", harvest " + (harvest_doys[i] < 0 ? "computed by STICS" : fmt_doy(harvest_doys[i])) color:#green;
		if sowing_doys[i] >= 0 and (sowing_doys[i] <= start_doy + 1 or sowing_doys[i] > end_doy) {
			write "[farmer plan] sowing day outside the USM (doy " + (start_doy + 2) + " to " + end_doy + "): no sowing" color:#orange;
		}
		if harvest_doys[i] > end_doy {
			write "[farmer plan] harvest day after the end of the USM: STICS will harvest at its deadline (irecbutoir)" color:#orange;
		}
	}

	action end_usm() {
		write "[USM " + (usm_index + 1) + "/" + length(usm_names) + "] " + usm_names[usm_index] + " ends on " + fmt_doy(end_doy) color:#blue;
		loop stage over: STAGES.keys {
			write "    " + STAGES[stage] + ": " + (stage in stage_doys.keys ? fmt_doy(stage_doys[stage]) : "not reached");
		}
		write "    grain: " + (the_plot.yields with_precision 2) + " t/ha";

		// a finished USM must be closed: execute_all runs every open simulation
		int finished <- sim_id;
		ask stics {
			map closed <- close_simulations([finished]);
		}

		sim_id <- -1; // stops daily_loop until the next USM is started

		// soil handover: recup.tmp written by STICS at the end of the USM goes to the next USM folder
		string src <- workspace + "/outputs/output_" + finished + "/recup.tmp";
		if usm_index + 1 >= length(usm_names) {
			write "[sequence] done" color:#blue;
			do pause();
		} else if !file_exists(src) {
			write "[sequence] " + src + " not found: cannot chain the next USM" color:#red;
			do pause();
		} else {
			string dst <- usm_path(usm_index + 1) + "/recup.tmp";
			string content <- "";
			loop l over: text_file(src).contents {
				content <- content + l + "\n";
			}
			save content to: dst format: "text" rewrite: true;
			write "[sequence] end state of " + usm_names[usm_index] + " copied to " + dst color:#blue;
			do start_usm(usm_index + 1);
		}
	}

	reflex daily_loop when: sim_id >= 0 {
		map<string, float> v;
		ask stics {
			map answer <- execute_day();
			if STICS_ERROR in answer.keys {
				write "An error happened while trying to execute one simulation day: " + to_json(answer) color:#red;
				ask world { do pause(); }
			} else {
				answer <- get_variables(DAILY_VARIABLES, [sim_id]);
				if STICS_ERROR in answer.keys {
					write "An error happened while trying to read the variables: " + to_json(answer) color:#red;
					ask world { do pause(); }
				} else {
					list<float> values <- list<list<float>>(answer["result"]["values"])[0];
					loop k from: 0 to: length(DAILY_VARIABLES) - 1 {
						v[DAILY_VARIABLES[k]] <- float(values[k]);
					}
				}
			}
		}
		if !empty(v) {
			do process_day(v);
		}
	}

	action process_day(map<string, float> v) {
		usm_day <- usm_day + 1;
		int today <- start_doy + usm_day - 1; // doy simulated in this cycle

		the_plot.yields <- v["mafruit"];
		the_plot.seeds <- v["densitesem"];
		the_plot.watering <- the_plot.watering + v["airg(n)"];
		the_plot.fertilizer <- the_plot.fertilizer + v["anit(n)"];
		rain_since_log <- rain_since_log + v["trr(n)"];

		// a stage is reached when STICS gives it a date that is not in the future
		loop stage over: STAGES.keys {
			int d <- int(v[stage]);
			if d > 0 and d <= today and !(stage in stage_doys.keys) {
				stage_doys[stage] <- d;
				write "[STICS] " + fmt_doy(d) + " " + STAGES[stage]
					+ " | LAI " + (v["lai(n)"] with_precision 2)
					+ " | biomass " + (v["masec(n)"] with_precision 2) + " t/ha"
					+ " | grain " + (v["mafruit"] with_precision 2) + " t/ha" color:#blue;
			}
		}

		if log_every > 0 and mod(usm_day, log_every) = 0 {
			write "[day " + usm_day + "] " + fmt_doy(today)
				+ " | LAI " + (v["lai(n)"] with_precision 2)
				+ " | biomass " + (v["masec(n)"] with_precision 2) + " t/ha"
				+ " | grain " + (v["mafruit"] with_precision 2) + " t/ha"
				+ " | soil water " + (v["resmes"] with_precision 0) + " mm"
				+ " | rain " + (rain_since_log with_precision 0) + " mm in " + log_every + " d";
			rain_since_log <- 0.0;
		}

		if today >= end_doy {
			do end_usm(); // starts the next USM: its first day is simulated next cycle
		}
	}

}

species farmer {

	rgb color <- #red;
	geometry shape <- circle(1#m);

	// runs after daily_loop; usm_day = 0 right after a new USM has been started
	reflex do_farmer_things when: usm_day > 0 {
		int i <- usm_index;
		int today <- start_doy + usm_day - 1;

		// first simulated day of the USM: STICS has finished its initialization, writes are now kept
		if usm_day = 1 {
			list<string> names <- [];
			list<float> values <- [];
			if sowing_doys[i] >= 0 {
				names <+ "nplt";
				values <+ float(STICS_NO_DATE);
			} else if sowing_densities[i] >= 0 {
				names <+ "densitesem";
				values <+ sowing_densities[i];
			}
			if harvest_doys[i] >= 0 {
				names <+ "nrecobs";
				values <+ float(STICS_NO_DATE);
			}
			if !empty(names) {
				ask stics {
					if !set_succeeded(set_variables([sim_id], names, values)) {
						ask world { do pause(); }
					}
				}
				write "[farmer] set on day 1: " + names + " (tec file sowing / harvest disabled where GAMA decides)" color:#green;
			}
		}

		// decisions are applied to the next simulated day
		if sowing_doys[i] >= 0 and today + 1 = sowing_doys[i] {
			ask stics {
				if force_sowing([sim_id], usm_day + 1, sowing_densities[i]) {
					write "[farmer] decides to sow on " + world.fmt_doy(sowing_doys[i])
						+ (sowing_densities[i] < 0 ? " at the tec file density" : " at " + sowing_densities[i] + " plants/m2") color:#green;
				}
			}
		}
		if harvest_doys[i] >= 0 and today + 1 = harvest_doys[i] {
			ask stics {
				if force_harvest([sim_id], usm_day + 1) {
					write "[farmer] decides to harvest on " + world.fmt_doy(harvest_doys[i]) color:#green;
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
		return hsb(float(to_hsb(#lightgreen)[0]), min(1.0, 0.2 + yields/15), float(to_hsb(#lightgreen)[2]));
	}

	aspect default {
		draw shape color:color;
		draw seeds_img size: {min(1.0, seeds/350.0) * 10, min(1.0, seeds/350.0) * 10} at:location + {-7.5,-7.5};
		draw watering_can_img size: {watering/400, watering/400} * {5, 6.5} at:location + {5,2.5};
		draw fertilizer_img size: {fertilizer/300, fertilizer/300} * {5, 6.5} at:location + {-5,5};
		if (yields > 0){
			float height <- min(1.0, yields/15.0) * 10; // full bar at 15 t/ha
			draw rectangle(2, height) at: location + {11, 11 - height/2} color:#red;
		}
		draw shape wireframe:true color:#black;
	}

}


experiment ex {
	parameter "Status line every N days (0 = off)" var: log_every;

	output {
		display main {
			species crops;
			species farmer;
		}
	}
}
