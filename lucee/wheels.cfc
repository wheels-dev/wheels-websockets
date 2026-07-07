/**
 * The Wheels channels wire for Lucee — served by lucee/extension-websocket
 * at ws://host/ws/wheels (this file's name IS the URL segment).
 *
 * Auto-installed by wheels-websockets v0.2.0 into the extension's websockets
 * directory. This file is CODE YOU OWN:
 *   - edit the auth gate in onOpen() for your app
 *   - delete this file and reload your app to regenerate a fresh copy
 *   - set(websocketsListenerInstall=false) in your Wheels app to disable
 *     auto-install entirely
 *
 * SELF-CONTAINED by design: this CFC runs on a synthetic page context outside
 * your application (no Application.cfc, no application.wheels, no vendor.*
 * component paths). It shares state with the app through the server scope:
 *   server["wheels-websockets"].registry[<channel>][<connId>] = wsClient
 *
 * Clients declare Wheels channels via the query string
 * (ws://host/ws/wheels?channels=orders,chat) and receive only events
 * published to those channels. The wire is server->client (mirroring Wheels
 * SSE channels); inbound frames are acked but not routed.
 */
component {

	function onOpen(wsClient) {
		// AUTH: by default every connection is accepted and may subscribe to
		// any channel it names. If your channels carry per-user data, validate
		// a credential here — e.g. a signed token passed as ?token=... — and
		// close unauthorized connections:
		//
		// if (!Len(url.token ?: "") || !myTokenIsValid(url.token)) {
		//     arguments.wsClient.close();
		//     return;
		// }

		variables.connId = CreateUUID();
		variables.channels = [];
		local.wanted = ListToArray(url.channels ?: "");
		for (local.name in local.wanted) {
			ArrayAppend(variables.channels, Trim(local.name));
		}

		$register(arguments.wsClient);

		// The extension sends this return value to the client. WheelsRealtime
		// ignores frames without d.channel, so the welcome is informational.
		return SerializeJSON({ "t" = "welcome", "d" = { "connId" = variables.connId } });
	}

	function onMessage(wsClient, message) {
		// Server->client wire by design: client->server communication in a
		// Wheels app is a normal HTTP request that calls publish().
		return SerializeJSON({ "t" = "ack", "d" = { "received" = true } });
	}

	function onClose(wsClient, reasonPhrase) {
		$deregister();
	}

	function onError(wsClient, cfCatch) {
		$deregister();
	}

	// ------------------------------------------------------------------
	// Registry plumbing — inlined because this file cannot resolve the
	// package's component paths (see header). Keep key + lock names in
	// sync with lib/LuceeExtensionTransport.cfc.
	// ------------------------------------------------------------------

	function $register(wsClient) {
		if (!ArrayLen(variables.channels)) {
			return;
		}
		lock name="wheels-websockets-registry" type="exclusive" timeout=5 {
			if (!StructKeyExists(server, "wheels-websockets")) {
				server["wheels-websockets"] = { registry = {} };
			}
			for (local.channelName in variables.channels) {
				if (!StructKeyExists(server["wheels-websockets"].registry, local.channelName)) {
					server["wheels-websockets"].registry[local.channelName] = {};
				}
				server["wheels-websockets"].registry[local.channelName][variables.connId] = arguments.wsClient;
			}
		}
	}

	function $deregister() {
		if (!StructKeyExists(variables, "connId")) {
			return;
		}
		lock name="wheels-websockets-registry" type="exclusive" timeout=5 {
			if (!StructKeyExists(server, "wheels-websockets")) {
				return;
			}
			for (local.channelName in variables.channels) {
				if (StructKeyExists(server["wheels-websockets"].registry, local.channelName)) {
					StructDelete(server["wheels-websockets"].registry[local.channelName], variables.connId);
				}
			}
		}
	}
}
