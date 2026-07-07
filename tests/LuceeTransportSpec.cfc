/**
 * Specs for the P2 Lucee backend. Engine-agnostic: everything runs against
 * fakes and the server-scope registry — no websocket extension required.
 * Resolution mirrors WebsocketsSpec: components load via the PackageLoader
 * registry, never the package alias mapping.
 */
component extends="wheels.WheelsTest" {

	function run() {

		describe("LuceeExtensionTransport", () => {

			beforeEach(() => {
				$wsClearRegistry();
			});

			afterEach(() => {
				$wsClearRegistry();
			});

			it("broadcasts the P1 wire frame to clients registered on the channel", () => {
				var wsClient = $wsFakeClient();
				$wsRegister("orders", "conn-1", wsClient);

				$wsTransport().broadcast(channel = "orders", event = "created", data = '{"orderId":99}', id = "42");

				expect(ArrayLen(wsClient.sent())).toBe(1);
				var frame = DeserializeJSON(wsClient.sent()[1]);
				expect(frame.t).toBe("msg");
				expect(frame.ch).toBe("/wheels");
				expect(frame.ev).toBe("created");
				expect(frame.d.channel).toBe("orders");
				expect(frame.d.data).toBe('{"orderId":99}');
				expect(frame.d.id).toBe("42");
				expect(frame.id).toBe("42");
			});

			it("serializes frame keys in exact lowercase for the JS client", () => {
				var wsClient = $wsFakeClient();
				$wsRegister("orders", "conn-1", wsClient);

				$wsTransport().broadcast(channel = "orders", event = "created", data = "{}", id = "1");

				// WheelsRealtime reads frame.ev / frame.d.channel case-sensitively;
				// DeserializeJSON is case-insensitive, so assert the RAW string.
				var raw = wsClient.sent()[1];
				expect(Find('"ev":', raw) > 0).toBeTrue();
				expect(Find('"ch":', raw) > 0).toBeTrue();
				expect(Find('"channel":', raw) > 0).toBeTrue();
				expect(Find('"data":', raw) > 0).toBeTrue();
			});

			it("does not deliver to clients on other channels", () => {
				var ordersClient = $wsFakeClient();
				var chatClient = $wsFakeClient();
				$wsRegister("orders", "conn-1", ordersClient);
				$wsRegister("chat", "conn-2", chatClient);

				$wsTransport().broadcast(channel = "orders", event = "created", data = "{}", id = "1");

				expect(ArrayLen(ordersClient.sent())).toBe(1);
				expect(ArrayLen(chatClient.sent())).toBe(0);
			});

			it("is a no-op when the registry or channel is absent", () => {
				$wsTransport().broadcast(channel = "ghost", event = "x", data = "{}", id = "1");
				// Not throwing is the behavior; also prove broadcast created no state.
				expect(StructKeyExists(server, "wheels-websockets")).toBeFalse();
			});

			it("evicts closed clients without sending to them", () => {
				var deadClient = $wsFakeClient(open = false);
				var liveClient = $wsFakeClient();
				$wsRegister("orders", "dead-1", deadClient);
				$wsRegister("orders", "live-1", liveClient);

				$wsTransport().broadcast(channel = "orders", event = "created", data = "{}", id = "1");

				expect(ArrayLen(deadClient.sent())).toBe(0);
				expect(ArrayLen(liveClient.sent())).toBe(1);
				expect(StructKeyExists(server["wheels-websockets"].registry["orders"], "dead-1")).toBeFalse();
				expect(StructKeyExists(server["wheels-websockets"].registry["orders"], "live-1")).toBeTrue();
			});

			it("isolates and evicts a client whose send throws, still delivering to the rest", () => {
				var failingClient = $wsFakeClient(failSend = true);
				var liveClient = $wsFakeClient();
				$wsRegister("orders", "boom-1", failingClient);
				$wsRegister("orders", "live-1", liveClient);

				$wsTransport().broadcast(channel = "orders", event = "created", data = "{}", id = "1");

				expect(ArrayLen(liveClient.sent())).toBe(1);
				expect(StructKeyExists(server["wheels-websockets"].registry["orders"], "boom-1")).toBeFalse();
			});

			it("reports the transport identity", () => {
				expect($wsTransport().active()).toBeTrue();
				expect($wsTransport().name()).toBe("lucee-extension");
				expect($wsTransport().wireChannel()).toBe("/wheels");
			});
		});

		describe("lucee listener template contract", () => {

			beforeEach(() => {
				$wsClearRegistry();
			});

			afterEach(() => {
				$wsClearRegistry();
				StructDelete(url, "channels");
			});

			it("onOpen registers the connection under every requested channel and returns a welcome frame", () => {
				url.channels = "orders, chat";
				var listener = $wsListener();
				var wsClient = $wsFakeClient();

				var welcome = listener.onOpen(wsClient);

				var parsed = DeserializeJSON(welcome);
				expect(parsed.t).toBe("welcome");
				expect(Len(parsed.d.connId)).toBeGT(0);
				expect(StructKeyExists(server["wheels-websockets"].registry, "orders")).toBeTrue();
				expect(StructKeyExists(server["wheels-websockets"].registry, "chat")).toBeTrue();
				expect(StructKeyExists(server["wheels-websockets"].registry["orders"], parsed.d.connId)).toBeTrue();
				expect(StructKeyExists(server["wheels-websockets"].registry["chat"], parsed.d.connId)).toBeTrue();
			});

			it("a registered connection receives transport broadcasts end to end", () => {
				url.channels = "orders";
				var listener = $wsListener();
				var wsClient = $wsFakeClient();
				listener.onOpen(wsClient);

				$wsTransport().broadcast(channel = "orders", event = "created", data = "{}", id = "9");

				expect(ArrayLen(wsClient.sent())).toBe(1);
				expect(DeserializeJSON(wsClient.sent()[1]).ev).toBe("created");
			});

			it("onOpen with no channels param registers nothing but still welcomes", () => {
				StructDelete(url, "channels");
				var listener = $wsListener();

				var welcome = listener.onOpen($wsFakeClient());

				expect(DeserializeJSON(welcome).t).toBe("welcome");
				var hasAny = StructKeyExists(server, "wheels-websockets")
					&& StructCount(server["wheels-websockets"].registry) > 0;
				expect(hasAny).toBeFalse();
			});

			it("onClose deregisters the connection from all its channels", () => {
				url.channels = "orders,chat";
				var listener = $wsListener();
				var wsClient = $wsFakeClient();
				var welcome = DeserializeJSON(listener.onOpen(wsClient));

				listener.onClose(wsClient, "bye");

				expect(StructKeyExists(server["wheels-websockets"].registry["orders"], welcome.d.connId)).toBeFalse();
				expect(StructKeyExists(server["wheels-websockets"].registry["chat"], welcome.d.connId)).toBeFalse();
			});

			it("onError also deregisters", () => {
				url.channels = "orders";
				var listener = $wsListener();
				var wsClient = $wsFakeClient();
				var welcome = DeserializeJSON(listener.onOpen(wsClient));

				listener.onError(wsClient, { message = "boom" });

				expect(StructKeyExists(server["wheels-websockets"].registry["orders"], welcome.d.connId)).toBeFalse();
			});

			it("onMessage returns a serialized ack", () => {
				var listener = $wsListener();
				var ack = listener.onMessage($wsFakeClient(), "ping");
				expect(DeserializeJSON(ack).d.received).toBeTrue();
			});
		});
	}

	// ------------------------------------------------------------------
	// Helpers (same resolution pattern as WebsocketsSpec)
	// ------------------------------------------------------------------

	private any function $wsPackage() {
		return application.wheels.PackageLoaderObj.getPackage("wheels-websockets");
	}

	private string function $wsBase() {
		local.path = GetMetadata($wsPackage()).name;
		return ListDeleteAt(local.path, ListLen(local.path, "."), ".");
	}

	private any function $wsTransport() {
		return CreateObject("component", $wsBase() & ".lib.LuceeExtensionTransport").init();
	}

	private any function $wsListener() {
		return CreateObject("component", $wsBase() & ".lucee.wheels");
	}

	private any function $wsFakeClient(boolean open = true, boolean failSend = false) {
		return CreateObject("component", $wsBase() & ".tests.FakeWsClient").init(
			open = arguments.open,
			failSend = arguments.failSend
		);
	}

	private void function $wsRegister(required string channel, required string connId, required any wsClient) {
		lock name="wheels-websockets-registry" type="exclusive" timeout=5 {
			if (!StructKeyExists(server, "wheels-websockets")) {
				server["wheels-websockets"] = { registry = {} };
			}
			if (!StructKeyExists(server["wheels-websockets"].registry, arguments.channel)) {
				server["wheels-websockets"].registry[arguments.channel] = {};
			}
			server["wheels-websockets"].registry[arguments.channel][arguments.connId] = arguments.wsClient;
		}
	}

	private void function $wsClearRegistry() {
		lock name="wheels-websockets-registry" type="exclusive" timeout=5 {
			StructDelete(server, "wheels-websockets");
		}
	}
}
