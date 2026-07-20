# gama-stics

GAMA project illustrating the coupling with STICS through its server mode (`--server`). It provides a GAMA agent implementing the basic functions of the STICS server API, along with an example model to demonstrate their use.

## Project contents

- `models/AgentStics.gaml` — the `AgentStics` species (skill `network`) that wraps the TCP communication with stics-server: connecting, sending JSON-RPC commands, reading responses, and higher-level actions (`initialize_crop`, `execute_day`, `get_variables`, `set_variables`).
- `models/example model.gaml` — an example model importing `AgentStics.gaml`, featuring a grid of plots (`crops`) driven by STICS and a `farmer` agent that sows, irrigates, and fertilizes over the course of the simulation.
- `includes/` — STICS input datasets (`usm_maize`, `usm_wheat`, `usm_wheat_no_inputs`) and images used by the example model.

## Requirements

- [GAMA Platform](https://gama-platform.org/) to open and run the project.
- STICS built/installed, with the ability to launch it in server mode.

## Running the example

1. Start STICS in server mode in a console, before launching the GAMA simulation:

   ```
   stics --server
   ```

   By default, the server listens on port `8081` (localhost). The GAMA model connects to it via `AgentStics.connect_to_stics`.

2. Open the project in GAMA and run the `ex` experiment from `models/example model.gaml`.

3. At each time step, the GAMA model sends an execution command to STICS for each plot, retrieves the result variables (yield, sowing density, irrigation, applied nitrogen), and updates the display accordingly.

## The AgentStics agent

The `AgentStics` species (in `models/AgentStics.gaml`) acts as a client for the stics-server JSON-RPC API. It notably exposes:

- `connect_to_stics(port, connection_timeout, server_address)` — establishes the TCP connection with the server.
- `initialize_crop(input_path, nb_simulations)` — initializes one or more simulations from a STICS dataset.
- `execute_day()` — executes one time step (one day) for all running simulations.
- `get_variables(variables)` — retrieves the values of a list of variables for all simulations.
- `set_variables(crop_ids, variables, values)` — updates variables for a given list of simulations.
- `exec_command(cmd_name, crop_id, params)` / `exec_command_and_wait_answer(cmd_txt, timeout)` — for composing and sending arbitrary commands to the server.

These actions handle JSON-RPC command serialization, response reading with timeout handling, and gracefully stopping the simulation on error or connection loss.
