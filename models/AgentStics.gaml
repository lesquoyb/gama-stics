/**
* Name: AgentStics
* Based on the internal empty template. 
* Author: Baptiste Lesquoy
* Tags: stics coupling
*/


model AgentStics

species AgentStics skills:[network]{
	
	
	string STICS_CONN_SUCCESS <- "ConnectionSuccessful" const:true;
	string STICS_SUCCESS <- "Success" const:true;
	string STICS_ERROR <- "Error" const:true;
	
	float default_timeout <- 20#s;
	
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
	 * Reads the next message from the mailbox, provided a timeout duration, and returns it 
	 * in the form of a map.
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
		write m.contents;
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
		write m;
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
		write "[STICS] about to send: " + str_mess color:#lightblue;
		do send(contents:str_mess, to:server);
	}
	
	/**
	 * Send the text of the command to the stics-server and returns the answer message from the server
	 * This is particularly useful when running a fixed command for which the content can be created once at
	 * the beginning of the simulation then reused every call. This saves serialization/deserialization time
	 * which can be important for performances.
	 */
	map exec_command_and_wait_answer(string cmd_txt, float timeout <- default_timeout){
		do send(contents:cmd_txt, to:server);
		return read_next_command_answer(timeout);
	}
	
	string create_command_string(string methodName, map<string,unknown> parameters <- map()){
		return '{"jsonrpc": "2.0", "method": "' + methodName + '", "params":' + to_json(parameters) + '}';
	}
	
	map initialize_crop(string input_path, int nb_simulations <- 1){
		return exec_command_and_wait_answer(create_command_string("init_simulation",map("input_path"::input_path,"count"::nb_simulations)));
	}
	
	map execute_day(){
		return exec_command_and_wait_answer(create_command_string("execute_all"));
	}
	
	/**
	 * Get the values of a list of variables for all current simulations
	 */
	map get_variables(list<string> variables){
		return exec_command_and_wait_answer(create_command_string("get_variable", map("variable_names"::to_json(variables))));		
	}
	
	map set_variables(list<int> crop_ids, list<string> variables, list<unknown> values){
		return exec_command_and_wait_answer(create_command_string("set_variable", map("variable_names"::to_json(variables), "simulation_ids"::to_json(crop_ids), "values"::to_json(values) )));
	}
	
}




