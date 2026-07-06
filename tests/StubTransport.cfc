/**
 * Test double: records every broadcast for assertions.
 */
component {

	public any function init() {
		variables.broadcasts = [];
		return this;
	}

	public boolean function active() {
		return true;
	}

	public string function name() {
		return "stub";
	}

	public string function wireChannel() {
		return "/stub";
	}

	public void function broadcast(
		required string channel,
		required string event,
		required string data,
		required string id
	) {
		ArrayAppend(variables.broadcasts, Duplicate(arguments));
	}

	public array function recorded() {
		return variables.broadcasts;
	}
}
