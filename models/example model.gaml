/**
* Name: examplemodel
* Based on the internal empty template. 
* Author: Baptiste Lesquoy
* Tags: 
*/


model examplemodel

import 'AgentStics.gaml'

global {
	
	float step <- 1#d;
	
	string crop_input_data_maize <- to_absolute_path('../includes/usm_wheat_no_inputs/');
	
	image_file fertilizer_img <- image_file("../includes/fertilizer.png");

	image_file watering_can_img <- image_file("../includes/watering can.png");

	image_file seeds_img <- image_file("../includes/seeds.png");

	init{
		
		create AgentStics {
			
			default_timeout <- 5#s;
			do connect_to_stics(port: 8081);
		
			// for each crop in gama initialize one in stics
			map answer <- initialize_crop(crop_input_data_maize, length(crops));
			if answer["type"] != STICS_SUCCESS {
				write "Error while trying to initialize a crop: " + answer color:#red;
				ask world {
					do die();						
				}
			}
			loop crop over: crops{
				if answer["type"] = STICS_SUCCESS {
					crop.stics_id <- int(answer["simulation_ids"][0]);
				}
				else {
					write "Error while trying to initialize a crop: " + answer color:#red;
					ask world {
						do die();						
					}
				}
			}	
		}
		
		create farmer {
			location <- one_of(crops).location;
		}
		
	}

	reflex daily_loop {
		ask AgentStics {
			// execute one day of simulation for all crops
			map answer <- execute_day();
			if answer["type"] = STICS_ERROR {
				write "An error happened while trying to execute one simulation day on all simulations: " + to_json(answer) color:#red;
				do die();
			}
			
			// extract masec
			answer <- get_variables(["rendementsec", "densitesem", "airg(n)", "anit(n)"]);
			if answer["type"] = STICS_ERROR {
				write "An error happened while trying to execute one simulation day on all simulations: " + to_json(answer) color:#red;
				do die();
			}
			// save yields in the right crop

			loop i from:0 to:length(list(answer["values"]))-1 {
				crops crop <- crops first_with(each.stics_id = answer["simulation_ids"][i]); // TODO: in real usecase, use a map of id => agent to speed up the retrieval 
				crop.yields <- float(list<list<float>>(answer["values"])[i][0]);
//				write "Planned for today for this crop: " + slice(answer["values"][i], 1,-1);
				crop.seeds <- float(list<list<float>>(answer["values"])[i][1]);
				crop.watering <- crop.watering + float(list<list<float>>(answer["values"])[i][2]);
				crop.fertilizer <- crop.fertilizer + float(list<list<float>>(answer["values"])[i][3]);
			}
				
			
		}
	}
	
	reflex end_sim when:cycle >= 400 {
		do pause();			
		write "End of simulation" color:#green;
	}

}

species farmer {
	
	rgb color <- #red;
	geometry shape <- circle(1#m);
	
	reflex move_around {
		// picks a new random crop every day
		location <- one_of(crops).location;
	}
	
	reflex do_fermer_things {
		crops current_crop <- first(crops overlapping self);
		if cycle <= 14 {
			float qt_semis <- rnd(10.0, 75.0);
			ask AgentStics {
				do set_variables([current_crop.stics_id], ["densitesem"], [qt_semis]);
			}
		}
		else {
			if flip(0.3) and current_crop.watering < 400{
				float qt_irr <- rnd(10.0, 50.0);
				qt_irr <- min(400 - current_crop.watering, qt_irr);
				ask AgentStics {
					do set_variables([current_crop.stics_id], ["airg(n)"], [qt_irr]);					
				}
				current_crop.watering <- current_crop.watering + qt_irr;
			}
			else if flip(0.5) and current_crop.fertilizer < 300 {
				float qt_fertN <- rnd(30.0, 100.0);
				qt_fertN <- min(qt_fertN, 300 - current_crop.fertilizer);
				ask AgentStics {
					do set_variables([current_crop.stics_id], ["anit(n)"], [qt_fertN]);					
				}
				current_crop.fertilizer <- current_crop.fertilizer + qt_fertN;
			}
			else{
				write "today I rest";
			}
		}
	}
	
	
	aspect default {
		draw circle(2.5) color:#white;
		draw image('../includes/farmer.png') size:{4#m,5#m};
	}
	
}

grid crops width:4 height:4 {
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
	output {
		
		display main {
			species crops;
			species farmer;
		}
	}
}
