/**
 * Specs for wheels-websockets. Run inside a Wheels app with the package
 * installed at vendor/wheels-websockets/ (copy this file into the app's
 * tests/specs/ or point your runner at the package tests directory).
 *
 * Components are resolved through the PackageLoader registry rather than the
 * package alias mapping — the alias is registered into application.mappings at
 * boot and is not reliably visible to component resolution on every engine.
 */
component extends="wheels.WheelsTest" {

	function run() {

		describe("ChannelEngineDecorator", () => {

			it("forwards publish() to the transport and preserves the inner result", () => {
				var engine = $wsMakeEngine("StubTransport");
				var result = engine.publish(channel = "orders", event = "created", data = '{"orderId":99}');

				expect(result).toBeStruct();
				expect(result).toHaveKey("subscriberCount");

				var sent = engine.$transport().recorded();
				expect(ArrayLen(sent)).toBe(1);
				expect(sent[1].channel).toBe("orders");
				expect(sent[1].event).toBe("created");
				expect(sent[1].data).toBe('{"orderId":99}');
				expect(Len(sent[1].id)).toBeGT(0);
			});

			it("still delivers to in-memory subscribers (the SSE path) alongside the transport", () => {
				var engine = $wsMakeEngine("StubTransport");

				var seen = { count = 0 };
				var cb = function(payload) { seen.count++; };
				engine.subscribe(channel = "alerts", callback = cb);

				var result = engine.publish(channel = "alerts", event = "ping", data = "{}");

				expect(seen.count).toBe(1);
				expect(result.subscriberCount).toBe(1);
				expect(ArrayLen(engine.$transport().recorded())).toBe(1);
			});

			it("failure-isolates the transport: a throwing broadcast never breaks publish()", () => {
				var engine = $wsMakeEngine("ThrowingTransport");
				var result = engine.publish(channel = "orders", event = "created", data = "{}");

				expect(result).toBeStruct();
				expect(result).toHaveKey("subscriberCount");
			});

			it("delegates the rest of the wheels.Channel surface to the inner engine", () => {
				var engine = $wsMakeEngine("StubTransport");

				var cb = function(payload) {};
				var subId = engine.subscribe(channel = "orders", callback = cb);
				expect(engine.subscriberCount("orders")).toBe(1);
				expect(engine.getChannels()).toInclude("orders");

				expect(engine.unsubscribe(channel = "orders", subscriberId = subId)).toBeTrue();
				expect(engine.subscriberCount("orders")).toBe(0);

				engine.removeChannel("orders");
				expect(engine.getChannels()).notToInclude("orders");
			});

			it("exposes the transport and inner engine for introspection", () => {
				var engine = $wsMakeEngine("StubTransport");
				expect(engine.$transport().name()).toBe("stub");
				expect(engine.$inner()).toBeInstanceOf("wheels.Channel");
			});

		});

		describe("transport resolution", () => {

			it("resolves the inactive transport when mode is none", () => {
				var t = $wsPackage().$resolveWebsocketsTransport("none");
				expect(t.active()).toBeFalse();
				expect(t.name()).toBe("none");
			});

			it("auto mode is inactive on engines without the wsPublish BIF", () => {
				// This spec suite runs on Lucee/Adobe in CI, where the RustCFML
				// realtime BIFs do not exist — auto must yield the null transport.
				var t = $wsPackage().$resolveWebsocketsTransport("auto");
				expect(t.active()).toBeFalse();
			});

			it("NullTransport broadcast is a safe no-op", () => {
				var t = $wsPackage().$resolveWebsocketsTransport("none");
				t.broadcast(channel = "x", event = "y", data = "{}", id = "1");
				expect(t.wireChannel()).toBe("");
			});

		});

		describe("boot()", () => {

			it("does not install a channel engine when no transport is active", () => {
				var app = { environment = "testing" };
				$wsFreshPackage().boot(app);
				expect(StructKeyExists(app, "channelEngine")).toBeFalse();
			});

			it("honors websocketsTransport=none", () => {
				var app = { environment = "testing", websocketsTransport = "none" };
				$wsFreshPackage().boot(app);
				expect(StructKeyExists(app, "channelEngine")).toBeFalse();
			});

		});

		describe("package load", () => {

			it("is loaded by the PackageLoader with its mixins collected", () => {
				expect(application.wheels.PackageLoaderObj.isPackageLoaded("wheels-websockets")).toBeTrue();

				// The manifest's "global" target expands into every concrete
				// mixin target; the per-method mixin="controller" annotation
				// keeps the view helper off the others.
				var mixins = application.wheels.PackageLoaderObj.getMixins();
				expect(mixins.controller).toHaveKey("websocketsInfo");
				expect(mixins.model).toHaveKey("websocketsInfo");
				expect(mixins.controller).toHaveKey("realtimeScriptTag");
				expect(StructKeyExists(mixins.model, "realtimeScriptTag")).toBeFalse();
			});

		});
	}

	// ------------------------------------------------------------------
	// Helpers
	// ------------------------------------------------------------------

	private any function $wsPackage() {
		return application.wheels.PackageLoaderObj.getPackage("wheels-websockets");
	}

	private any function $wsFreshPackage() {
		return CreateObject("component", GetMetadata($wsPackage()).name).init();
	}

	private string function $wsBase() {
		local.path = GetMetadata($wsPackage()).name;
		return ListDeleteAt(local.path, ListLen(local.path, "."), ".");
	}

	private any function $wsMakeEngine(required string transportCfc) {
		local.transport = CreateObject("component", $wsBase() & ".tests." & arguments.transportCfc).init();
		return CreateObject("component", $wsBase() & ".lib.ChannelEngineDecorator").init(
			inner = CreateObject("component", "wheels.Channel").init(),
			transport = local.transport
		);
	}
}
