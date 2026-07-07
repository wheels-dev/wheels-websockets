/**
 * Test double for the extension's wsClient object (duck-typed: isOpen/send).
 */
component {

	public any function init(boolean open = true, boolean failSend = false) {
		variables.openFlag = arguments.open;
		variables.failSend = arguments.failSend;
		variables.sentMessages = [];
		return this;
	}

	public boolean function isOpen() {
		return variables.openFlag;
	}

	public any function send(required string message) {
		if (variables.failSend) {
			throw(type = "Fake.SendFailure", message = "simulated send failure");
		}
		ArrayAppend(variables.sentMessages, arguments.message);
		return true;
	}

	public array function sent() {
		return variables.sentMessages;
	}

	public void function close() {
		variables.openFlag = false;
	}
}
