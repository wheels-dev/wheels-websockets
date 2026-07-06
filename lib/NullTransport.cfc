/**
 * Inactive transport: used when no engine backend is available or the app set
 * `set(websocketsTransport="none")`. Channels continue over SSE unchanged.
 */
component {

	public any function init() {
		return this;
	}

	public boolean function active() {
		return false;
	}

	public string function name() {
		return "none";
	}

	public string function wireChannel() {
		return "";
	}

	public void function broadcast(
		required string channel,
		required string event,
		required string data,
		required string id
	) {
		// no-op
	}
}
