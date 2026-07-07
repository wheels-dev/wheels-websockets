/**
 * wheels-websockets — opt-in realtime WebSocket transport for Wheels channels.
 *
 * Wheels core stays SSE-only. This package adds WebSocket delivery for the same
 * `publish()` semantics where the engine can serve it, by decorating the channel
 * engine singleton at boot (zero core changes):
 *
 *   publish(channel, event, data)
 *       └─> ChannelEngineDecorator ── in-memory subscribers (SSE, unchanged)
 *                                  └─ transport.broadcast() ── connected WS clients
 *
 * Engine support:
 *   - RustCFML: native (`wsPublish` BIF + engine-served channel CFCs). Active automatically.
 *   - Lucee:    planned — emulation over lucee/extension-websocket (see tracking issue).
 *   - Others:   inactive; the app runs unchanged on SSE.
 *
 * NOTE ON MIXINS: every public non-lifecycle method below is copied onto the
 * mixin targets and executes in the TARGET's variables scope — mixin methods
 * must not touch this component's instance state. All shared state lives on
 * the decorator installed at application.wheels.channelEngine.
 *
 * Decision record: wheels-dev/wheels#3154 · Tracking: wheels-dev/wheels#3292
 */
component implements="wheels.ServiceProviderInterface" {

	public any function init() {
		// The dotted path this CFC was instantiated with (e.g.
		// "vendor.wheels-websockets.WheelsWebsockets"). Sibling components are
		// created relative to it — the package alias mapping is not visible to
		// component resolution during the boot request, but this path is.
		local.myPath = GetMetadata(this).name;
		variables.componentBase = ListDeleteAt(local.myPath, ListLen(local.myPath, "."), ".");
		return this;
	}

	// ------------------------------------------------------------------
	// ServiceProvider lifecycle (runs on the package instance, not mixins)
	// ------------------------------------------------------------------

	public void function register(required any container) {
		// No service bindings in P1; the decorator is installed in boot().
	}

	/**
	 * Detect the engine, pick a transport, and — when one is active — pre-install
	 * the channel-engine decorator so the framework's lazy factory
	 * (Global.cfc::$getChannelEngine) finds it instead of creating a bare engine.
	 *
	 * @app The Wheels application settings struct (application.wheels).
	 */
	public void function boot(required struct app) {
		local.mode = "auto";
		if (StructKeyExists(arguments.app, "websocketsTransport") && Len(arguments.app.websocketsTransport)) {
			local.mode = LCase(arguments.app.websocketsTransport);
		}

		local.transport = $resolveWebsocketsTransport(local.mode);

		// The Lucee backend needs the listener CFC present in the extension's
		// directory before it can deliver anything; without it, stay on SSE.
		if (local.transport.active() && local.transport.name() == "lucee-extension") {
			if (!$ensureLuceeListener(arguments.app)) {
				local.transport = CreateObject("component", variables.componentBase & ".lib.NullTransport").init();
			}
		}

		if (local.transport.active()) {
			// Decorate the memory channel engine. Publish() keeps its exact
			// contract; WS delivery is additive and failure-isolated.
			local.inner = CreateObject("component", "wheels.Channel").init();
			arguments.app.channelEngine = CreateObject("component", variables.componentBase & ".lib.ChannelEngineDecorator").init(
				inner = local.inner,
				transport = local.transport
			);
			WriteLog(
				text = "[wheels-websockets] Active: '#local.transport.name()#' transport bridging channel publishes to WebSocket clients on wire channel '#local.transport.wireChannel()#'.",
				type = "information",
				file = "wheels"
			);
		} else {
			WriteLog(
				text = "[wheels-websockets] Inactive on this engine (mode=#local.mode#). Channels continue over SSE; no behavior change.",
				type = "information",
				file = "wheels"
			);
		}
	}

	// ------------------------------------------------------------------
	// Mixins (global unless annotated) — stateless, derive from the decorator
	// ------------------------------------------------------------------

	/**
	 * Status struct for debugging and conditional app logic:
	 * { active, transport, wireChannel }.
	 */
	public struct function websocketsInfo() {
		local.engine = $websocketsEngine();
		if (IsObject(local.engine) && StructKeyExists(local.engine, "$transport")) {
			local.t = local.engine.$transport();
			return {
				active = local.t.active(),
				transport = local.t.name(),
				wireChannel = local.t.active() ? local.t.wireChannel() : ""
			};
		}
		return { active = false, transport = "none", wireChannel = "" };
	}

	/**
	 * True when a WebSocket transport is live for this app.
	 */
	public boolean function websocketsActive() {
		return websocketsInfo().active;
	}

	/**
	 * Renders the <script> tag for the WheelsRealtime JS client.
	 *
	 * Recommended install publishes the asset:
	 *   cp vendor/wheels-websockets/assets/js/wheels-realtime.js public/assets/js/wheels-realtime.js
	 * Pass `inline=true` to embed the client directly (no publish step needed).
	 *
	 * @jsPath URL of the published client script.
	 * @inline Embed the script contents instead of referencing a file.
	 */
	public string function realtimeScriptTag(
		string jsPath = "/assets/js/wheels-realtime.js",
		boolean inline = false
	) mixin="controller" {
		if (arguments.inline) {
			local.pkgDir = application.wheels.PackageLoaderObj.getPackageMappings()["wheelsWebsockets"];
			return "<script>" & Chr(10) & FileRead(local.pkgDir & "/assets/js/wheels-realtime.js") & Chr(10) & "</script>";
		}
		return '<script defer src="#arguments.jsPath#"></script>';
	}

	// ------------------------------------------------------------------
	// Internals ($-prefixed by convention; safe as mixins — no instance state)
	// ------------------------------------------------------------------

	/**
	 * The installed channel engine, or "" when none exists yet.
	 */
	public any function $websocketsEngine() {
		if (
			StructKeyExists(application, "wheels")
			&& StructKeyExists(application.wheels, "channelEngine")
		) {
			return application.wheels.channelEngine;
		}
		return "";
	}

	/**
	 * Pick a transport for the requested mode. "auto" feature-detects the
	 * engine (RustCFML first, then the Lucee websocket extension); "none"
	 * (or any unknown value) yields the inactive transport. Forced modes
	 * ("rustcfml", "lucee") still feature-check — they never blind-activate.
	 *
	 * Instance-only: relies on variables.componentBase captured in init(), so
	 * call it on the package instance (PackageLoaderObj.getPackage(...)), never
	 * as a mixin copy.
	 */
	public any function $resolveWebsocketsTransport(required string mode) {
		local.m = LCase(arguments.mode);

		local.fl = {};
		try {
			local.fl = GetFunctionList();
		} catch (any e) {
			// fall through to the null transport
		}

		if ((local.m == "auto" || local.m == "rustcfml") && StructKeyExists(local.fl, "wsPublish")) {
			return CreateObject("component", variables.componentBase & ".lib.RustCfmlTransport").init();
		}

		if ((local.m == "auto" || local.m == "lucee") && StructKeyExists(local.fl, "websocketInfo")) {
			return $luceeTransportOrNull();
		}

		return CreateObject("component", variables.componentBase & ".lib.NullTransport").init();
	}

	/**
	 * The Lucee extension is installed, but the endpoint only works when the
	 * servlet container exposes a JSR-356 ServerContainer (Tomcat: always;
	 * CommandBox/undertow: only with websocket support enabled). Calling
	 * websocketInfo() both verifies that and lazily registers the endpoint.
	 * Instance-only (see $resolveWebsocketsTransport).
	 */
	public any function $luceeTransportOrNull() {
		try {
			websocketInfo();
		} catch (any e) {
			WriteLog(
				text = "[wheels-websockets] Lucee websocket extension detected but the endpoint is unavailable on this servlet container (#e.message#). Channels continue over SSE.",
				type = "warning",
				file = "wheels"
			);
			return CreateObject("component", variables.componentBase & ".lib.NullTransport").init();
		}
		return CreateObject("component", variables.componentBase & ".lib.LuceeExtensionTransport").init();
	}

	/**
	 * Make sure the wheels.cfc listener exists in the extension's websockets
	 * directory (reported by websocketInfo().mapping). Instance-only.
	 */
	public boolean function $ensureLuceeListener(required struct app) {
		try {
			local.info = websocketInfo();
			return $installListenerFile(directory = local.info.mapping, app = arguments.app);
		} catch (any e) {
			WriteLog(
				text = "[wheels-websockets] websocketInfo() failed while preparing the Lucee listener (#e.message#). Channels continue over SSE.",
				type = "warning",
				file = "wheels"
			);
			return false;
		}
	}

	/**
	 * File half of the auto-install, split out so it is testable without the
	 * extension. Existing files are never touched. Instance-only.
	 */
	public boolean function $installListenerFile(required string directory, required struct app) {
		try {
			local.target = ListAppend(arguments.directory, "wheels.cfc", "/");
			if (FileExists(local.target)) {
				return true;
			}

			local.allowInstall = true;
			if (StructKeyExists(arguments.app, "websocketsListenerInstall")) {
				local.allowInstall = arguments.app.websocketsListenerInstall;
			}
			local.source = GetDirectoryFromPath(GetMetadata(this).path) & "lucee/wheels.cfc";

			if (!local.allowInstall) {
				WriteLog(
					text = "[wheels-websockets] Lucee listener missing and auto-install is disabled (websocketsListenerInstall=false). Copy #local.source# to #arguments.directory# to serve /ws/wheels.",
					type = "warning",
					file = "wheels"
				);
				return false;
			}

			if (!DirectoryExists(arguments.directory)) {
				DirectoryCreate(arguments.directory, true, true);
			}
			FileCopy(local.source, local.target);
			WriteLog(
				text = "[wheels-websockets] Installed the Lucee listener at #local.target# (serves /ws/wheels). It is code you own — edit its auth gate.",
				type = "information",
				file = "wheels"
			);
			return true;
		} catch (any e) {
			WriteLog(
				text = "[wheels-websockets] Could not install the Lucee listener (#e.message#). Copy vendor/wheels-websockets/lucee/wheels.cfc into the extension's websockets directory manually.",
				type = "warning",
				file = "wheels"
			);
			return false;
		}
	}
}
