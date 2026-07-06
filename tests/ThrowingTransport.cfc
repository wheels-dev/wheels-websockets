/**
 * Test double: always throws — proves the decorator failure-isolates the transport.
 */
component {

	public any function init() {
		return this;
	}

	public boolean function active() {
		return true;
	}

	public string function name() {
		return "throwing";
	}

	public string function wireChannel() {
		return "/throwing";
	}

	public void function broadcast(
		required string channel,
		required string event,
		required string data,
		required string id
	) {
		Throw(type = "WheelsWebsockets.TestBoom", message = "transport exploded (by design)");
	}
}
