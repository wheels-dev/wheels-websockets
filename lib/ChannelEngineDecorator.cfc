/**
 * Decorates the Wheels in-memory channel engine (wheels.Channel), forwarding
 * every publish() to a WebSocket transport in addition to the normal in-memory
 * subscriber fan-out (which is what SSE consumes).
 *
 * Installed by WheelsWebsockets.boot() BEFORE the framework's lazy factory
 * (Global.cfc::$getChannelEngine) runs, so the whole app transparently uses it.
 *
 * Contract: mirrors the full public surface of wheels.Channel. The transport
 * is failure-isolated — a broken WS broadcast never affects publish() callers
 * or SSE delivery.
 */
component {

	public any function init(required any inner, required any transport) {
		variables.inner = arguments.inner;
		variables.transport = arguments.transport;
		return this;
	}

	// ------------------------------------------------------------------
	// wheels.Channel public surface (delegated)
	// ------------------------------------------------------------------

	public string function subscribe(
		required string channel,
		required any callback,
		string id = CreateUUID()
	) {
		return variables.inner.subscribe(argumentCollection = arguments);
	}

	public struct function publish(
		required string channel,
		required string event,
		required string data,
		string id = CreateUUID()
	) {
		local.result = variables.inner.publish(argumentCollection = arguments);

		try {
			variables.transport.broadcast(
				channel = arguments.channel,
				event = arguments.event,
				data = arguments.data,
				id = arguments.id
			);
		} catch (any e) {
			WriteLog(
				text = "[wheels-websockets] WS broadcast failed on channel [#arguments.channel#]: #e.message#",
				type = "error",
				file = "wheels"
			);
		}

		return local.result;
	}

	public boolean function unsubscribe(required string channel, required string subscriberId) {
		return variables.inner.unsubscribe(argumentCollection = arguments);
	}

	public numeric function subscriberCount(required string channel) {
		return variables.inner.subscriberCount(argumentCollection = arguments);
	}

	public array function getChannels() {
		return variables.inner.getChannels();
	}

	public void function removeChannel(required string channel) {
		variables.inner.removeChannel(argumentCollection = arguments);
	}

	// ------------------------------------------------------------------
	// Decorator introspection (used by the mixin helpers and tests)
	// ------------------------------------------------------------------

	public any function $inner() {
		return variables.inner;
	}

	public any function $transport() {
		return variables.transport;
	}
}
