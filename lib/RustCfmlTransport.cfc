/**
 * WebSocket transport for RustCFML's native realtime engine.
 *
 * Delivery model: one shared wire channel (default "/wheels", served by the
 * channel CFC the app copies to public/websockets/wheels.cfc). Each Wheels
 * channel name maps to a room ("ch:<name>") that clients join at connect
 * time, so delivery is targeted — verified live: a client subscribed to
 * "orders" receives orders events and a client subscribed to "chat" does not.
 *
 * wsPublish() is a RustCFML BIF (engine-registered); this component is only
 * ever instantiated when feature detection has confirmed it exists.
 */
component {

	public any function init(string wireChannel = "/wheels") {
		variables.wireChannelName = arguments.wireChannel;
		return this;
	}

	public boolean function active() {
		return true;
	}

	public string function name() {
		return "rustcfml";
	}

	public string function wireChannel() {
		return variables.wireChannelName;
	}

	/**
	 * Fan a Wheels channel event out to the WS clients subscribed to it.
	 * Payload mirrors the channel-bus event shape ({channel, data, id}) so the
	 * JS client can dispatch by Wheels channel name.
	 */
	public void function broadcast(
		required string channel,
		required string event,
		required string data,
		required string id
	) {
		wsPublish(
			channel = variables.wireChannelName,
			event = arguments.event,
			data = { channel = arguments.channel, data = arguments.data, id = arguments.id },
			to = "ch:" & arguments.channel
		);
	}
}
