/**
* Name: AgentStics
* Based on the internal empty template. 
* Author: Baptiste Lesquoy
* Tags: stics coupling
*/


model AgentStics


global {

	string STICS_CONN_SUCCESS <- "ConnectionSuccessful" const:true;
	string STICS_ERROR <- "error" const:true;
	int STICS_NO_DATE <- 9999; // sowing / harvest day never reached: only GAMA decides
	
	bool LOG_SERVER_MESSAGES <- true; // pass to true/false to toggle the printing of all messages received and sent by the agent, useful for debugging
	
}

species AgentStics skills:[network]{
	
	
	
	float default_timeout <- 20#s;
	
	int internal_cmd_count <- 0;
	
	
	unknown server;
	
	/**
	 * Reads the next message in the mailbox, provided a timeout duration.
	 * Returns the whole message object without any other checks.
	 * If timeout is reached returns a message with nil content
	 * Use a time out <= 0 to ignore time outs altogether and possibly wait forever.
	 */
	message read_next_raw_message(float timeout <- default_timeout) {
		
		// Refreshing the mailbox until there's a message or the timeout is reached
		float start <- gama.machine_time;
		loop while: !has_more_message() and (timeout > 0 and (gama.machine_time - start)/1000 < timeout){
			do fetch_message_from_network();
		}
		// Returning the first message in the mailbox, nil if empty (timeout)
		return fetch_message();
	}
	
	/**
	 * Reads the next message from the mailbox, provided a timeout duration, and returns it in the form of a map.
	 * If the timeout is reached, kills the simulation.
	 * Use a time out <= 0 to ignore time outs altogether and possibly wait forever.
	 */
	map<string, unknown> read_next_command_answer(float timeout <- default_timeout) {
		message m <- read_next_raw_message(timeout);
		
		// In case of timeout the message is nil
		if m.contents = nil {
			write "[STICS] The timeout has been reached before the server can answer" color:#red;
			write "[STICS] aborting simulation" color:#red;
			ask world {
				do die();
			}
		}
		if LOG_SERVER_MESSAGES {
			write '[STICS] Received from server: ' + m.contents;			
		}
		return from_json(m.contents);
		
	}
	
	/**
	 * Connects to a stics-server open at the address server_address on the provided port.
	 * Times out after the connection_timeout duration is reached, if connection_timeout is negative or 0, no time out will be applied.
	 * Call this method before doing any other operation with stics-server.
	 */
	action connect_to_stics(int port <- 8081, float connection_timeout <- default_timeout, string server_address <- "localhost"){
		
		do connect(protocol:"tcp_client", to:server_address, port:port, raw:true);
		
		// Waiting for a message to arrive
		write "Asking to connect to server, waiting for an answer";
		
		// For the first message we need to read it outside of the read_next_command_answer to initialize the server object
		message m <- read_next_raw_message(connection_timeout);

		// In case of timeout the message is nil
		if m.contents = nil {
			write "[STICS] Didn't receive connection confirmation from server" color:#red;
			write "[STICS] aborting simulation" color:#red;
			ask world {
				do die();
			}
		}
		
		map content <- from_json(m.contents); // we convert the json message into a map for an easier handling
		if content.keys contains "type" {
			if content["type"] = STICS_CONN_SUCCESS {
				write "[STICS] successfully connected to server at " + server_address + " on port " + port color:#green;
				server <- m.sender;
			}
			else {
				write "[STICS] couldn't connect to server:\n" + content color:#red;
				write "[STICS] aborting simulation" color:#red;
				ask world {
					do die();
				}
			}
		}
		else {
			// We shouldn't receive another kind of message, print it to debug
			write "[STICS] Unknown message: " + content color:#orange;
			ask world {
				do die();
			}
		}
	}
	
	/**
	 * Send any arbitrary command to the stics-server.
	 * This action is useful when composing a command yourself, with parameters that may
	 * change during the simulation. Not the best performance wise because of the serialization.
	 */
	action exec_command(string cmd_name, int crop_id, map params){
		map mess <- map("command"::cmd_name, "simulation_id"::crop_id) + params;
		string str_mess <- to_json(mess);
		if LOG_SERVER_MESSAGES{
			write "[STICS] about to send: " + str_mess color:#lightblue;			
		}
		do send(contents:str_mess, to:server);
	}
	
	/**
	 * Send the text of the command to the stics-server and returns the answer message from the server.
	 * This is particularly useful when running a fixed command for which the content can be created once at
	 * the beginning of the simulation then reused every call. This saves serialization/deserialization time
	 * which can be important for performances.
	 */
	map exec_command_and_wait_answer(string cmd_txt, float timeout <- default_timeout){
		if LOG_SERVER_MESSAGES{
			write "[STICS] about to send: " + cmd_txt color:#lightblue;			
		}
		do send(contents:cmd_txt, to:server);
		return read_next_command_answer(timeout);
	}
	
	string create_command_string(string methodName, int id_cmd, map<string,unknown> parameters <- map()){
		return '{"jsonrpc":"2.0", "method":"' + methodName + '", "params":' + to_json(parameters) + ', "id":'+ id_cmd +'}';
	}
	
	/**
	 * workspace_path: if given, STICS writes its output files in <workspace_path>/outputs/output_<id>/,
	 * including recup.tmp (soil and crop state at the end of the USM) needed to chain the next USM.
	 */
	map initialize_crop(string input_path, int nb_simulations <- 1, string workspace_path <- ""){
		internal_cmd_count <- internal_cmd_count + 1;
		map<string, unknown> params <- map("input_path"::input_path, "count"::nb_simulations);
		if workspace_path != "" {
			params["workspace_path"] <- workspace_path;
		}
		return exec_command_and_wait_answer(create_command_string("init_simulation", internal_cmd_count, params));
	}

	/**
	 * Close simulations. A finished USM must be closed: execute_all runs every open simulation,
	 * and a simulation past its datefin fails (no weather left).
	 */
	map close_simulations(list<int> crop_ids){
		internal_cmd_count <- internal_cmd_count + 1;
		return exec_command_and_wait_answer(create_command_string("close_simulations", internal_cmd_count, map("simulation_ids"::crop_ids)));
	}
	
	map execute_day(){
		internal_cmd_count <- internal_cmd_count + 1;
		return exec_command_and_wait_answer(create_command_string("execute_all", internal_cmd_count));
	}
	
	/**
	 * Get the values of a list of variables for all current simulations
	 */
	map get_variables(list<string> variables, list<int> crop_ids <- []){
		internal_cmd_count <- internal_cmd_count + 1;
		map<string, unknown> params <- map("variable_names"::(variables));
		if !empty(crop_ids) {
			params["simulation_ids"] <- crop_ids;
		}
		return exec_command_and_wait_answer(create_command_string("get_variable", internal_cmd_count, params));
	}
	
	map set_variables(list<int> crop_ids, list<string> variables, list<unknown> values){
		internal_cmd_count <- internal_cmd_count + 1;
		return exec_command_and_wait_answer(create_command_string("set_variable", internal_cmd_count, map("variable_names"::(variables), "simulation_ids"::(crop_ids), "values"::(values) )));
	}

	/**
	 * Get the value of one variable for one simulation
	 */
	float get_variable_for(int crop_id, string variable){
		internal_cmd_count <- internal_cmd_count + 1;
		map answer <- exec_command_and_wait_answer(create_command_string("get_variable", internal_cmd_count, map("variable_names"::[variable], "simulation_ids"::[crop_id])));
		if STICS_ERROR in answer.keys {
			write "[STICS] could not read " + variable + ": " + to_json(answer) color:#red;
			return 0.0;
		}
		return float(list<list>(map(answer["result"])["values"])[0][0]);
	}

	/**
	 * Returns true if a set_variables answer reports no error.
	 * The server answers with a success even when some writes failed (error_count > 0), so this has to be checked.
	 */
	bool set_succeeded(map answer){
		if STICS_ERROR in answer.keys {
			write "[STICS] set_variable failed: " + to_json(answer) color:#red;
			return false;
		}
		if int(map(answer["result"])["error_count"]) > 0 {
			write "[STICS] set_variable partly failed: " + to_json(answer) color:#red;
			return false;
		}
		return true;
	}

	/**
	 * Sowing and harvest days, as simulation day indexes (1 = first day of the USM = doy datedebut).
	 * sim_day must be a day not simulated yet, and these must be called after the first execute_day:
	 * STICS finishes its initialization on the first day and resets them from the tec file.
	 * STICS_NO_DATE blocks STICS's own sowing / harvest until a real day is set.
	 */
	// density in plants/m2; density < 0 keeps the densitesem of the USM tec file
	bool force_sowing(list<int> crop_ids, int sim_day, float density <- -1.0){
		if density < 0 {
			return set_succeeded(set_variables(crop_ids, ["nplt"], [sim_day]));
		}
		return set_succeeded(set_variables(crop_ids, ["nplt", "densitesem"], [sim_day, density]));
	}

	bool force_harvest(list<int> crop_ids, int sim_day){
		return set_succeeded(set_variables(crop_ids, ["nrecobs"], [sim_day]));
	}

}




