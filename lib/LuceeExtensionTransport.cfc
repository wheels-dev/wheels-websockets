/**
 * WebSocket transport for Lucee via the official lucee/extension-websocket.
 *
 * Delivery model mirrors the RustCFML backend: one shared wire endpoint
 * (/ws/wheels, served by the wheels.cfc listener the package installs into
 * the extension's websockets directory) and a server-scope registry mapping
 * each Wheels channel to its connected wsClients. broadcast() sends the same
 * frame shape the RustCFML wire uses, so WheelsRealtime needs no changes.
 *
 * The registry lives in the server scope because the extension invokes
 * listener CFCs on a synthetic page context that never runs Application.cfc —
 * application.wheels is invisible there; server scope is the shared ground.
 *
 * Best-effort delivery: a client whose send() throws (or that reports
 * !isOpen()) is evicted and never breaks publish() for the caller.
 */
component {

	public any function init(string wireChannel = "/wheels") {
		variables.wireChannelName = arguments.wireChannel;
		variables.registryKey = "wheels-websockets";
		return this;
	}

	public boolean function active() {
		return true;
	}

	public string function name() {
		return "lucee-extension";
	}

	public string function wireChannel() {
		return variables.wireChannelName;
	}

	public void function broadcast(
		required string channel,
		required string event,
		required string data,
		required string id
	) {
		// Quoted keys: Lucee uppercases unquoted struct-literal keys and the
		// JS client reads frame.ev / frame.d.channel case-sensitively.
		local.frame = SerializeJSON({
			"t" = "msg",
			"ch" = variables.wireChannelName,
			"ev" = arguments.event,
			"d" = {
				"channel" = arguments.channel,
				"data" = arguments.data,
				"id" = arguments.id
			},
			"id" = arguments.id
		});

		// Snapshot under the read lock, send outside it (sends can block).
		local.snapshot = {};
		lock name="wheels-websockets-registry" type="readonly" timeout=5 {
			if (
				StructKeyExists(server, variables.registryKey)
				&& StructKeyExists(server[variables.registryKey].registry, arguments.channel)
			) {
				local.source = server[variables.registryKey].registry[arguments.channel];
				for (local.connId in local.source) {
					local.snapshot[local.connId] = local.source[local.connId];
				}
			}
		}

		local.dead = [];
		for (local.connId in local.snapshot) {
			try {
				if (local.snapshot[local.connId].isOpen()) {
					local.snapshot[local.connId].send(local.frame);
				} else {
					ArrayAppend(local.dead, local.connId);
				}
			} catch (any e) {
				ArrayAppend(local.dead, local.connId);
			}
		}

		if (ArrayLen(local.dead)) {
			lock name="wheels-websockets-registry" type="exclusive" timeout=5 {
				for (local.connId in local.dead) {
					if (
						StructKeyExists(server, variables.registryKey)
						&& StructKeyExists(server[variables.registryKey].registry, arguments.channel)
					) {
						StructDelete(server[variables.registryKey].registry[arguments.channel], local.connId);
					}
				}
			}
		}
	}
}
