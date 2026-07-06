/**
 * The Wheels channels wire — copy this file to public/websockets/wheels.cfc.
 *
 * On RustCFML, CFCs under <webroot>/websockets/ are engine-served WebSocket
 * channels; this one is the shared wire that wheels-websockets publishes on
 * (ws://host/ws/wheels). Clients declare which Wheels channels they want via
 * the `channels` query param and are joined to one room per channel; the
 * package's transport publishes each event only to its channel's room.
 *
 * This file is CODE YOU OWN — edit the auth gate below for your app.
 * Generated from wheels-websockets v0.1.0.
 */
component socket="/wheels" encoding="json" {

	/**
	 * Connect gate. Return false to reject the connection, or an array of
	 * rooms to accept and auto-join.
	 *
	 * AUTH: by default every connection is accepted and may subscribe to any
	 * channel it names. If your channels carry per-user data, authenticate
	 * here — e.g. validate a signed token passed as ?token=... — and restrict
	 * the rooms accordingly.
	 */
	function onConnect( socket ) {
		// Example auth hook (uncomment and adapt):
		// if ( !isAuthorized( socket.param( "token" ) ?: "" ) ) {
		//     return false;
		// }

		var wanted = listToArray( socket.param( "channels" ) ?: "" );
		var rooms = [];
		for ( var c in wanted ) {
			arrayAppend( rooms, "ch:" & trim( c ) );
		}
		return rooms;
	}

	/**
	 * The wire is server->client by design (mirroring Wheels SSE channels).
	 * Inbound frames are acknowledged but not routed anywhere; client->server
	 * communication in a Wheels app is a normal HTTP request that calls
	 * publish(). Extend this if your app wants true client->server messaging.
	 */
	function onMessage( socket, message ) {
		return { received = true };
	}
}
