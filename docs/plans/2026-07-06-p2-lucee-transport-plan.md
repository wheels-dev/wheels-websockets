# wheels-websockets P2 — Lucee Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver Wheels channel events over WebSockets on Lucee via the official `lucee/extension-websocket`, with P1 wire parity so the JS client and RustCFML path change zero bytes; ship as 0.2.0 and publish to the package registry.

**Architecture:** A new `LuceeExtensionTransport` plugs into the existing `ChannelEngineDecorator` seam. Connections register into a `server`-scope registry from an auto-installed, self-contained listener CFC (`wheels.cfc`) served by the extension at `/ws/wheels`; `broadcast()` snapshots the channel's clients under a named lock and `wsClient.send()`s the P1 frame, evicting dead clients.

**Tech Stack:** CFML (package repo `~/GitHub/wheels-dev/wheels-websockets`), lucee/extension-websocket ≥ 3.0.0.20, TestBox specs run inside the Wheels demo app (`~/GitHub/wheels-dev/wheels`) on the docker lucee7 image, node `ws` client for live verification.

**Spec:** `docs/specs/2026-07-06-p2-lucee-transport-design.md` (approved 2026-07-06). Read it before starting.

## Global Constraints

- Wire frame, verbatim: `{"t":"msg","ch":"/wheels","ev":<event>,"d":{"channel":<name>,"data":<string>,"id":<id>},"id":<id>}`. `d.data` is the string exactly as passed to `broadcast()`.
- **JSON keys MUST serialize in lowercase.** Lucee uppercases unquoted struct-literal keys; every frame struct literal MUST use quoted keys (`{"t" = "msg", ...}`). Specs assert the raw string with case-sensitive `Find()`.
- Extension floor: released **3.0.0.20**. `wsClient.getSession()` is unreleased (3.0.0.21) — MUST NOT be used. Connection ids are `CreateUUID()`.
- Server-scope key is exactly `"wheels-websockets"`; lock name is exactly `"wheels-websockets-registry"` (both sides: listener + transport).
- The listener template is **self-contained** (no `vendor.*` CreateObject paths, no `application.wheels` access) — it runs on a synthetic page context outside the app.
- Package CFCs compile on every engine (Lucee, Adobe, BoxLang, RustCFML); Lucee-only BIF calls (`websocketInfo()`) must be behind `GetFunctionList()` probes or try/catch. Specs must pass on a stock engine with **no** extension installed.
- All public non-lifecycle methods on `WheelsWebsockets.cfc` become global mixins executing in the target's variables scope — new helpers are `public`, `$`-prefixed, and must not read `variables.componentBase` unless documented instance-only (pattern already used by `$resolveWebsocketsTransport`).
- Never overwrite an existing `wheels.cfc` at the install target, under any condition.
- No reserved scope names as vars/params (`url`, `server`, ...). No inline closures as constructor named args. No `for` loops inside `finally`.
- Commits: conventional style, `git -c commit.gpgsign=false commit -s`, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Work on `main` of the package repo (solo-maintainer repo, no CI yet).
- Test harness cycle (Tasks 1–4): edit in package repo → rsync into demo app vendor/ → `docker restart` (image pins `inspectTemplate=never`) → curl the app-tests endpoint.

---

### Task 0: Test harness — package installed in the demo app under docker lucee7

**Files:**
- No repo files change permanently. Creates throwaway: `~/GitHub/wheels-dev/wheels/vendor/wheels-websockets/` (rsync target), `~/GitHub/wheels-dev/wheels/tests/specs/packages/` (spec copies), staged docker configs per the known recipe.

**Interfaces:**
- Produces: a running server at `http://localhost:60007` where `curl ".../wheels/app/tests?format=json&testBundles=tests.specs.packages.WebsocketsSpec"` runs package specs. The rsync+restart+curl loop used by every later task:

```bash
# THE LOOP (run from ~/GitHub/wheels-dev/wheels):
rsync -a --delete --exclude .git --exclude docs ~/GitHub/wheels-dev/wheels-websockets/ vendor/wheels-websockets/
cp ~/GitHub/wheels-dev/wheels-websockets/tests/*Spec.cfc tests/specs/packages/
docker restart wheels-lucee7-p2 && sleep 20
curl -s "http://localhost:60007/wheels/app/tests?format=json&testBundles=tests.specs.packages.LuceeTransportSpec" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('totalPass',0),'pass',d.get('totalFail',0),'fail',d.get('totalError',0),'error')"
```

- [ ] **Step 1: Stage docker configs and start the container** (recipe from `~/.claude/.../memory/reference_worktree_core_test_docker.md` — same-port mapping is mandatory)

```bash
cd ~/GitHub/wheels-dev/wheels
cp tools/docker/lucee7/server.json server.json
cp tools/docker/lucee7/settings.cfm config/settings.cfm
cp tools/docker/lucee7/CFConfig.json CFConfig.json
cp tools/docker/lucee7/box.json box.json
docker run -d --name wheels-lucee7-p2 -p 60007:60007 -v "$PWD":/wheels-test-suite wheels-test-lucee7:v1.0.0
```

- [ ] **Step 2: Install the package + existing spec, wait for boot, verify P1 baseline**

```bash
mkdir -p tests/specs/packages
rsync -a --delete --exclude .git --exclude docs ~/GitHub/wheels-dev/wheels-websockets/ vendor/wheels-websockets/
cp ~/GitHub/wheels-dev/wheels-websockets/tests/*Spec.cfc tests/specs/packages/
docker restart wheels-lucee7-p2 && sleep 20
curl -s "http://localhost:60007/wheels/app/tests?format=json&testBundles=tests.specs.packages.WebsocketsSpec" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('totalPass',0),'pass',d.get('totalFail',0),'fail',d.get('totalError',0),'error')"
```

Expected: `11 pass 0 fail 0 error` (the P1 baseline). If the endpoint 404s, poll `http://localhost:60007/` until the server responds first. Do not proceed until the baseline is green.

---

### Task 1: `lib/LuceeExtensionTransport.cfc` + `tests/FakeWsClient.cfc`

**Files:**
- Create: `~/GitHub/wheels-dev/wheels-websockets/lib/LuceeExtensionTransport.cfc`
- Create: `~/GitHub/wheels-dev/wheels-websockets/tests/FakeWsClient.cfc`
- Create: `~/GitHub/wheels-dev/wheels-websockets/tests/LuceeTransportSpec.cfc`

**Interfaces:**
- Consumes: `server["wheels-websockets"].registry` struct shape `{<channelName>: {<connId>: wsClient}}`; wsClient duck-type `isOpen():boolean`, `send(string):any`.
- Produces: `LuceeExtensionTransport` with `init(string wireChannel = "/wheels")`, `active():boolean` (always true), `name():string` = `"lucee-extension"`, `wireChannel():string`, `broadcast(required string channel, required string event, required string data, required string id):void`. `FakeWsClient` with `init(boolean open = true, boolean failSend = false)`, `isOpen()`, `send(message)`, `sent():array`, `close()`.

- [ ] **Step 1: Write the failing specs**

Create `tests/FakeWsClient.cfc`:

```cfml
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
```

Create `tests/LuceeTransportSpec.cfc` (transport block only for now; later tasks append):

```cfml
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
				var client = $wsFakeClient();
				$wsRegister("orders", "conn-1", client);

				$wsTransport().broadcast(channel = "orders", event = "created", data = '{"orderId":99}', id = "42");

				expect(ArrayLen(client.sent())).toBe(1);
				var frame = DeserializeJSON(client.sent()[1]);
				expect(frame.t).toBe("msg");
				expect(frame.ch).toBe("/wheels");
				expect(frame.ev).toBe("created");
				expect(frame.d.channel).toBe("orders");
				expect(frame.d.data).toBe('{"orderId":99}');
				expect(frame.d.id).toBe("42");
				expect(frame.id).toBe("42");
			});

			it("serializes frame keys in exact lowercase for the JS client", () => {
				var client = $wsFakeClient();
				$wsRegister("orders", "conn-1", client);

				$wsTransport().broadcast(channel = "orders", event = "created", data = "{}", id = "1");

				// WheelsRealtime reads frame.ev / frame.d.channel case-sensitively;
				// DeserializeJSON is case-insensitive, so assert the RAW string.
				var raw = client.sent()[1];
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

	private any function $wsFakeClient(boolean open = true, boolean failSend = false) {
		return CreateObject("component", $wsBase() & ".tests.FakeWsClient").init(
			open = arguments.open,
			failSend = arguments.failSend
		);
	}

	private void function $wsRegister(required string channel, required string connId, required any client) {
		lock name="wheels-websockets-registry" type="exclusive" timeout=5 {
			if (!StructKeyExists(server, "wheels-websockets")) {
				server["wheels-websockets"] = { registry = {} };
			}
			if (!StructKeyExists(server["wheels-websockets"].registry, arguments.channel)) {
				server["wheels-websockets"].registry[arguments.channel] = {};
			}
			server["wheels-websockets"].registry[arguments.channel][arguments.connId] = arguments.client;
		}
	}

	private void function $wsClearRegistry() {
		lock name="wheels-websockets-registry" type="exclusive" timeout=5 {
			StructDelete(server, "wheels-websockets");
		}
	}
}
```

- [ ] **Step 2: Run to verify failure**

Run THE LOOP (Task 0). Expected: errors — `LuceeExtensionTransport.cfc` does not exist yet (CreateObject failure inside specs). The bundle itself must compile; if you see a compile error mentioning the spec file, fix the spec, not the loop.

- [ ] **Step 3: Implement the transport**

Create `lib/LuceeExtensionTransport.cfc`:

```cfml
/**
 * WebSocket transport for Lucee via the official lucee/extension-websocket.
 *
 * Delivery model mirrors the RustCFML backend: one shared wire endpoint
 * (/ws/wheels, served by the wheels.cfc listener the package installs into
 * the extension's websockets directory) and a server-scope registry mapping
 * each Wheels channel to its connected wsClients. broadcast() sends the same
 * frame shape the RustCFML wire uses, so WheelsRealtime needs no changes.
 *
 * The registry lives in the server scope because the extension invokes
 * listener CFCs on a synthetic page context that never runs Application.cfc —
 * application.wheels is invisible there; server scope is the shared ground.
 *
 * Best-effort delivery: a client whose send() throws (or that reports
 * !isOpen()) is evicted and never breaks publish() for the caller.
 */
component {

	public any function init(string wireChannel = "/wheels") {
		variables.wireChannelName = arguments.wireChannel;
		variables.registryKey = "wheels-websockets";
		return this;
	}

	public boolean function active() {
		return true;
	}

	public string function name() {
		return "lucee-extension";
	}

	public string function wireChannel() {
		return variables.wireChannelName;
	}

	public void function broadcast(
		required string channel,
		required string event,
		required string data,
		required string id
	) {
		// Quoted keys: Lucee uppercases unquoted struct-literal keys and the
		// JS client reads frame.ev / frame.d.channel case-sensitively.
		local.frame = SerializeJSON({
			"t" = "msg",
			"ch" = variables.wireChannelName,
			"ev" = arguments.event,
			"d" = {
				"channel" = arguments.channel,
				"data" = arguments.data,
				"id" = arguments.id
			},
			"id" = arguments.id
		});

		// Snapshot under the read lock, send outside it (sends can block).
		local.snapshot = {};
		lock name="wheels-websockets-registry" type="readonly" timeout=5 {
			if (
				StructKeyExists(server, variables.registryKey)
				&& StructKeyExists(server[variables.registryKey].registry, arguments.channel)
			) {
				local.source = server[variables.registryKey].registry[arguments.channel];
				for (local.connId in local.source) {
					local.snapshot[local.connId] = local.source[local.connId];
				}
			}
		}

		local.dead = [];
		for (local.connId in local.snapshot) {
			try {
				if (local.snapshot[local.connId].isOpen()) {
					local.snapshot[local.connId].send(local.frame);
				} else {
					ArrayAppend(local.dead, local.connId);
				}
			} catch (any e) {
				ArrayAppend(local.dead, local.connId);
			}
		}

		if (ArrayLen(local.dead)) {
			lock name="wheels-websockets-registry" type="exclusive" timeout=5 {
				for (local.connId in local.dead) {
					if (
						StructKeyExists(server, variables.registryKey)
						&& StructKeyExists(server[variables.registryKey].registry, arguments.channel)
					) {
						StructDelete(server[variables.registryKey].registry[arguments.channel], local.connId);
					}
				}
			}
		}
	}
}
```

- [ ] **Step 4: Run to verify pass**

Run THE LOOP. Expected: `7 pass 0 fail 0 error` for `LuceeTransportSpec`. Also re-run the `WebsocketsSpec` bundle — still `11 pass`.

- [ ] **Step 5: Commit**

```bash
cd ~/GitHub/wheels-dev/wheels-websockets
git add lib/LuceeExtensionTransport.cfc tests/FakeWsClient.cfc tests/LuceeTransportSpec.cfc
git -c commit.gpgsign=false commit -s -m "feat: LuceeExtensionTransport — P1 wire frames over the server-scope registry

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Listener template `lucee/wheels.cfc`

**Files:**
- Create: `~/GitHub/wheels-dev/wheels-websockets/lucee/wheels.cfc`
- Modify: `~/GitHub/wheels-dev/wheels-websockets/tests/LuceeTransportSpec.cfc` (append describe block + helpers)

**Interfaces:**
- Consumes: wsClient duck-type (`send()`, `close()`); `url.channels` query param; registry shape/lock from Task 1.
- Produces: extension lifecycle contract — `onOpen(wsClient)` returns welcome JSON string, `onMessage(wsClient, message)` returns ack JSON string, `onClose(wsClient, reasonPhrase)`, `onError(wsClient, cfCatch)`. Registers/deregisters `variables.connId` (a `CreateUUID()`) under every requested channel.

- [ ] **Step 1: Append failing specs to `tests/LuceeTransportSpec.cfc`** (inside `run()`, after the transport describe)

```cfml
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
				var client = $wsFakeClient();

				var welcome = listener.onOpen(client);

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
				var client = $wsFakeClient();
				listener.onOpen(client);

				$wsTransport().broadcast(channel = "orders", event = "created", data = "{}", id = "9");

				expect(ArrayLen(client.sent())).toBe(1);
				expect(DeserializeJSON(client.sent()[1]).ev).toBe("created");
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
				var client = $wsFakeClient();
				var welcome = DeserializeJSON(listener.onOpen(client));

				listener.onClose(client, "bye");

				expect(StructKeyExists(server["wheels-websockets"].registry["orders"], welcome.d.connId)).toBeFalse();
				expect(StructKeyExists(server["wheels-websockets"].registry["chat"], welcome.d.connId)).toBeFalse();
			});

			it("onError also deregisters", () => {
				url.channels = "orders";
				var listener = $wsListener();
				var client = $wsFakeClient();
				var welcome = DeserializeJSON(listener.onOpen(client));

				listener.onError(client, { message = "boom" });

				expect(StructKeyExists(server["wheels-websockets"].registry["orders"], welcome.d.connId)).toBeFalse();
			});

			it("onMessage returns a serialized ack", () => {
				var listener = $wsListener();
				var ack = listener.onMessage($wsFakeClient(), "ping");
				expect(DeserializeJSON(ack).d.received).toBeTrue();
			});
		});
```

And this helper next to the others:

```cfml
	private any function $wsListener() {
		return CreateObject("component", $wsBase() & ".lucee.wheels");
	}
```

- [ ] **Step 2: Run to verify failure**

THE LOOP. Expected: the six new specs error (component `...lucee.wheels` not found); the seven Task 1 specs still pass.

- [ ] **Step 3: Implement the listener template**

Create `lucee/wheels.cfc`:

```cfml
/**
 * The Wheels channels wire for Lucee — served by lucee/extension-websocket
 * at ws://host/ws/wheels (this file's name IS the URL segment).
 *
 * Auto-installed by wheels-websockets v0.2.0 into the extension's websockets
 * directory. This file is CODE YOU OWN:
 *   - edit the auth gate in onOpen() for your app
 *   - delete this file and reload your app to regenerate a fresh copy
 *   - set(websocketsListenerInstall=false) in your Wheels app to disable
 *     auto-install entirely
 *
 * SELF-CONTAINED by design: this CFC runs on a synthetic page context outside
 * your application (no Application.cfc, no application.wheels, no vendor.*
 * component paths). It shares state with the app through the server scope:
 *   server["wheels-websockets"].registry[<channel>][<connId>] = wsClient
 *
 * Clients declare Wheels channels via the query string
 * (ws://host/ws/wheels?channels=orders,chat) and receive only events
 * published to those channels. The wire is server->client (mirroring Wheels
 * SSE channels); inbound frames are acked but not routed.
 */
component {

	function onOpen(wsClient) {
		// AUTH: by default every connection is accepted and may subscribe to
		// any channel it names. If your channels carry per-user data, validate
		// a credential here — e.g. a signed token passed as ?token=... — and
		// close unauthorized connections:
		//
		// if (!Len(url.token ?: "") || !myTokenIsValid(url.token)) {
		//     arguments.wsClient.close();
		//     return;
		// }

		variables.connId = CreateUUID();
		variables.channels = [];
		local.wanted = ListToArray(url.channels ?: "");
		for (local.name in local.wanted) {
			ArrayAppend(variables.channels, Trim(local.name));
		}

		$register(arguments.wsClient);

		// The extension sends this return value to the client. WheelsRealtime
		// ignores frames without d.channel, so the welcome is informational.
		return SerializeJSON({ "t" = "welcome", "d" = { "connId" = variables.connId } });
	}

	function onMessage(wsClient, message) {
		// Server->client wire by design: client->server communication in a
		// Wheels app is a normal HTTP request that calls publish().
		return SerializeJSON({ "t" = "ack", "d" = { "received" = true } });
	}

	function onClose(wsClient, reasonPhrase) {
		$deregister();
	}

	function onError(wsClient, cfCatch) {
		$deregister();
	}

	// ------------------------------------------------------------------
	// Registry plumbing — inlined because this file cannot resolve the
	// package's component paths (see header). Keep key + lock names in
	// sync with lib/LuceeExtensionTransport.cfc.
	// ------------------------------------------------------------------

	function $register(wsClient) {
		if (!ArrayLen(variables.channels)) {
			return;
		}
		lock name="wheels-websockets-registry" type="exclusive" timeout=5 {
			if (!StructKeyExists(server, "wheels-websockets")) {
				server["wheels-websockets"] = { registry = {} };
			}
			for (local.channelName in variables.channels) {
				if (!StructKeyExists(server["wheels-websockets"].registry, local.channelName)) {
					server["wheels-websockets"].registry[local.channelName] = {};
				}
				server["wheels-websockets"].registry[local.channelName][variables.connId] = arguments.wsClient;
			}
		}
	}

	function $deregister() {
		if (!StructKeyExists(variables, "connId")) {
			return;
		}
		lock name="wheels-websockets-registry" type="exclusive" timeout=5 {
			if (!StructKeyExists(server, "wheels-websockets")) {
				return;
			}
			for (local.channelName in variables.channels) {
				if (StructKeyExists(server["wheels-websockets"].registry, local.channelName)) {
					StructDelete(server["wheels-websockets"].registry[local.channelName], variables.connId);
				}
			}
		}
	}
}
```

- [ ] **Step 4: Run to verify pass**

THE LOOP. Expected: `13 pass 0 fail 0 error` for `LuceeTransportSpec`; `WebsocketsSpec` still `11 pass`.

- [ ] **Step 5: Commit**

```bash
cd ~/GitHub/wheels-dev/wheels-websockets
git add lucee/wheels.cfc tests/LuceeTransportSpec.cfc
git -c commit.gpgsign=false commit -s -m "feat: self-contained Lucee listener template (wheels.cfc) for /ws/wheels

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Detection, auto-install, and boot wiring in `WheelsWebsockets.cfc`

**Files:**
- Modify: `~/GitHub/wheels-dev/wheels-websockets/WheelsWebsockets.cfc` (`$resolveWebsocketsTransport`, `boot()`; add `$luceeTransportOrNull`, `$ensureLuceeListener`, `$installListenerFile`)
- Modify: `~/GitHub/wheels-dev/wheels-websockets/tests/LuceeTransportSpec.cfc` (append describe block)
- Modify: `~/GitHub/wheels-dev/wheels-websockets/tests/WebsocketsSpec.cfc` (comment update only, in the "auto mode is inactive" spec)

**Interfaces:**
- Consumes: `LuceeExtensionTransport` (Task 1); `lucee/wheels.cfc` template file (Task 2); existing `NullTransport`/`RustCfmlTransport`; `websocketInfo()` BIF when present (its `mapping` key = absolute listener directory).
- Produces: `$resolveWebsocketsTransport(mode)` honoring `"auto"|"rustcfml"|"lucee"|"none"`; `$luceeTransportOrNull():any` (instance-only); `$ensureLuceeListener(required struct app):boolean` (instance-only); `$installListenerFile(required string directory, required struct app):boolean` (instance-only); `boot()` that downgrades a lucee transport to Null when the listener can't be ensured. New app setting consumed: `websocketsListenerInstall` (default true).

- [ ] **Step 1: Append failing specs to `tests/LuceeTransportSpec.cfc`**

```cfml
		describe("lucee transport resolution and install guards", () => {

			it("mode=lucee resolves inactive when the extension BIF is absent", () => {
				// Package specs run on stock engines without the websocket
				// extension, so the forced-lucee branch must feature-check.
				var transport = $wsPackage().$resolveWebsocketsTransport("lucee");
				expect(transport.active()).toBeFalse();
			});

			it("mode=rustcfml resolves inactive when wsPublish is absent", () => {
				var transport = $wsPackage().$resolveWebsocketsTransport("rustcfml");
				expect(transport.active()).toBeFalse();
			});

			it("$installListenerFile writes the stamped listener into an empty directory", () => {
				var dir = $wsTempDir();
				var ok = $wsFreshPackage().$installListenerFile(directory = dir, app = {});

				expect(ok).toBeTrue();
				expect(FileExists(dir & "/wheels.cfc")).toBeTrue();
				var content = FileRead(dir & "/wheels.cfc");
				expect(content).toInclude("wheels-websockets");
				expect(content).toInclude("onOpen");
				DirectoryDelete(dir, true);
			});

			it("$installListenerFile never overwrites an existing file", () => {
				var dir = $wsTempDir();
				FileWrite(dir & "/wheels.cfc", "SENTINEL");

				var ok = $wsFreshPackage().$installListenerFile(directory = dir, app = {});

				expect(ok).toBeTrue();
				expect(FileRead(dir & "/wheels.cfc")).toBe("SENTINEL");
				DirectoryDelete(dir, true);
			});

			it("$installListenerFile honors websocketsListenerInstall=false", () => {
				var dir = $wsTempDir();
				var ok = $wsFreshPackage().$installListenerFile(
					directory = dir,
					app = { websocketsListenerInstall = false }
				);

				expect(ok).toBeFalse();
				expect(FileExists(dir & "/wheels.cfc")).toBeFalse();
				DirectoryDelete(dir, true);
			});
		});
```

And these helpers next to the others (copy `$wsFreshPackage` from `WebsocketsSpec` — bundles don't share private helpers):

```cfml
	private any function $wsFreshPackage() {
		return CreateObject("component", GetMetadata($wsPackage()).name).init();
	}

	private string function $wsTempDir() {
		local.dir = GetTempDirectory() & "wswheels-" & CreateUUID();
		DirectoryCreate(local.dir, true, true);
		return local.dir;
	}
```

- [ ] **Step 2: Run to verify failure**

THE LOOP. Expected: 2 resolution specs FAIL (current code returns Null only for non-auto modes — forced `"lucee"`/`"rustcfml"` already return inactive, so check carefully: with current code `$resolveWebsocketsTransport("lucee")` hits the `mode != "auto"` branch and returns NullTransport — those two specs may already PASS. The 3 `$installListenerFile` specs must ERROR (method not found). If the resolution specs pass pre-change, note it and keep them as pinning specs.)

- [ ] **Step 3: Implement in `WheelsWebsockets.cfc`**

Replace the existing `$resolveWebsocketsTransport` with:

```cfml
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
```

Add the three new helpers (below `$resolveWebsocketsTransport`, above the closing brace):

```cfml
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
```

In `boot()`, insert between `local.transport = $resolveWebsocketsTransport(local.mode);` and `if (local.transport.active()) {`:

```cfml
		// The Lucee backend needs the listener CFC present in the extension's
		// directory before it can deliver anything; without it, stay on SSE.
		if (local.transport.active() && local.transport.name() == "lucee-extension") {
			if (!$ensureLuceeListener(arguments.app)) {
				local.transport = CreateObject("component", variables.componentBase & ".lib.NullTransport").init();
			}
		}
```

In `tests/WebsocketsSpec.cfc`, update the comment in the "auto mode is inactive" spec from:

```cfml
				// This spec suite runs on Lucee/Adobe in CI, where the RustCFML
				// realtime BIFs do not exist — auto must yield the null transport.
```

to:

```cfml
				// Package specs run on stock engines where neither the RustCFML
				// realtime BIFs nor the Lucee websocket extension are installed —
				// auto must yield the null transport. (On a Lucee with the
				// extension installed this spec would legitimately fail; run the
				// suite on a stock engine.)
```

- [ ] **Step 4: Run to verify pass**

THE LOOP. Expected: `18 pass 0 fail 0 error` for `LuceeTransportSpec`; `11 pass` for `WebsocketsSpec`.

- [ ] **Step 5: Full-suite regression on the harness**

```bash
curl -s "http://localhost:60007/wheels/app/tests?format=json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('totalPass',0),'pass',d.get('totalFail',0),'fail',d.get('totalError',0),'error')"
```

Expected: 0 fail, 0 error across the demo-app suite with the package installed.

- [ ] **Step 6: Commit**

```bash
cd ~/GitHub/wheels-dev/wheels-websockets
git add WheelsWebsockets.cfc tests/LuceeTransportSpec.cfc tests/WebsocketsSpec.cfc
git -c commit.gpgsign=false commit -s -m "feat: Lucee detection, listener auto-install, and boot wiring

websocketsTransport gains the lucee value; boot() installs the stamped
listener via websocketInfo().mapping unless websocketsListenerInstall=false,
and downgrades to SSE when the endpoint or listener is unavailable.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Live end-to-end on Tomcat (`wheels start`, the primary target)

**Files:**
- No permanent repo changes. Throwaway: a scratch Wheels app (or the demo app) with `public/ws-verify-tmp.cfm`, node script in `$CLAUDE_JOB_DIR/tmp`.

**Interfaces:**
- Consumes: everything from Tasks 1–3; `lucee/extension-websocket` `.lex`; LuCLI `wheels start` (Lucee Express/Tomcat).
- Produces: recorded evidence (frame transcripts) for the 0.2.0 release notes and #3292.

- [ ] **Step 1: Prepare a Lucee 7 app with the package and the extension**

Preferred host: the wheels repo demo app (package already rsync'd from Task 0 — but run on the HOST via LuCLI, not docker, to get Tomcat). Install the extension by env var when starting:

```bash
cd ~/GitHub/wheels-dev/wheels
git checkout -- server.json config/settings.cfm CFConfig.json && rm -f box.json   # unstage docker configs first
LUCEE_EXTENSIONS="3F9DFF32-B555-449D-B0EB5DB723044045;version=3.0.0.20" wheels start
```

Notes for the executor: the GUID is the extension's ID from download.lucee.org. If the env-var form doesn't take (check `wheels log` / server console for "websocket"), fall back to dropping the `.lex` into the runtime's `lucee-server/deploy/` dir (`find ~/.lucli -type d -name deploy`), then restart. Confirm install with a probe page or `wheels console` evaluating `IsDefined("websocketInfo")`.

- [ ] **Step 2: Confirm boot activated the transport and installed the listener**

```bash
grep -i "wheels-websockets" ~/.lucli/**/logs/wheels.log 2>/dev/null | tail -5
# Expect: "[wheels-websockets] Active: 'lucee-extension' transport ..." and
#         "[wheels-websockets] Installed the Lucee listener at ..."
```

Also verify the file landed: the path in the log must contain `websockets/wheels.cfc` under the lucee-config dir.

- [ ] **Step 3: Create the publish trigger page**

Write `public/ws-verify-tmp.cfm` in the app:

```cfm
<cfscript>
	// Throwaway verification page — deleted after P2 sign-off.
	param name="url.ch" default="orders";
	param name="url.msg" default="hello";
	result = application.wheels.channelEngine.publish(
		channel = url.ch,
		event = "verify",
		data = SerializeJSON({ "msg" = url.msg })
	);
	WriteOutput(SerializeJSON(result));
</cfscript>
```

- [ ] **Step 4: Connect two ws clients and prove delivery + channel isolation**

```bash
cd /Users/peter/.claude/jobs/744da55b/tmp && npm ls ws >/dev/null 2>&1 || npm i ws
cat > ws-check.js <<'EOF'
const WebSocket = require('ws');
const url = process.argv[2];
const label = process.argv[3] || 'client';
const ws = new WebSocket(url);
ws.on('open', () => console.log(label, 'OPEN'));
ws.on('message', (m) => console.log(label, 'FRAME', m.toString()));
ws.on('close', (c) => console.log(label, 'CLOSE', c));
ws.on('error', (e) => console.log(label, 'ERROR', e.message));
EOF
# Terminal A (orders subscriber) and B (chat subscriber) — PORT from wheels start output:
node ws-check.js "ws://localhost:PORT/ws/wheels?channels=orders" orders-client &
node ws-check.js "ws://localhost:PORT/ws/wheels?channels=chat" chat-client &
sleep 2
curl -s "http://localhost:PORT/ws-verify-tmp.cfm?ch=orders&msg=live-test"
sleep 2; kill %1 %2
```

Expected: both clients print `OPEN` + a `welcome` frame; **only** `orders-client` prints a `FRAME` containing `"ev":"verify"` and `"channel":"orders"`; `chat-client` prints nothing further. Save the transcript.

- [ ] **Step 5: Reconnect/eviction sanity**

Kill a subscriber (ctrl-c), publish again to its channel — server must not error (check `wheels.log` for the eviction being silent), and a fresh client connecting afterwards receives new events.

- [ ] **Step 6: Clean up scratch artifacts**

```bash
rm ~/GitHub/wheels-dev/wheels/public/ws-verify-tmp.cfm
wheels stop
```

Record the evidence block (commands + transcripts) in the task notes for the #3292 comment. No commit (nothing in-repo changed).

---

### Task 5: CommandBox/undertow spike (docker lucee7)

**Files:**
- No permanent changes; outcome is recorded in README (Task 7) and #3292.

**Interfaces:**
- Consumes: docker harness from Task 0; extension env var from Task 4.
- Produces: a verdict — "works with `web.webSocket.enable`" or "unsupported on undertow (SSE fallback engages)" — plus the boot log line proving graceful degradation either way.

- [ ] **Step 1: Enable undertow websockets + extension on the container**

Edit the staged `server.json` in the wheels repo (throwaway; docker copy): add `"webSocket": { "enable": true }` under the existing `"web"` key (create it if absent; if CommandBox rejects the key, try lowercase `"websocket"`). Then:

```bash
cd ~/GitHub/wheels-dev/wheels
cp tools/docker/lucee7/server.json server.json   # re-stage, then edit in the webSocket key
docker rm -f wheels-lucee7-p2
docker run -d --name wheels-lucee7-p2 -p 60007:60007 \
  -e LUCEE_EXTENSIONS="3F9DFF32-B555-449D-B0EB5DB723044045;version=3.0.0.20" \
  -v "$PWD":/wheels-test-suite wheels-test-lucee7:v1.0.0
sleep 60
```

- [ ] **Step 2: Probe**

```bash
docker logs wheels-lucee7-p2 2>&1 | grep -i -m5 "websocket"
curl -s "http://localhost:60007/wheels/app/tests?format=json&testBundles=tests.specs.packages.WebsocketsSpec" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('totalPass',0),'pass',d.get('totalFail',0),'fail',d.get('totalError',0),'error')"
node /Users/peter/.claude/jobs/744da55b/tmp/ws-check.js "ws://localhost:60007/ws/wheels?channels=orders" undertow-probe
```

Interpret: if the ws client gets `OPEN`+`welcome`, undertow hosts the endpoint — repeat Task 4 Steps 3–4 against port 60007 for full end-to-end. If it errors, capture the `[wheels-websockets] ... endpoint is unavailable` warning from the container's wheels.log — that IS the graceful-degradation evidence. **Either outcome is a pass for this task; record which.**

Important: the "auto mode is inactive" spec in WebsocketsSpec will legitimately FAIL on this container when the extension is live — that's the documented stock-engine assumption, not a defect. Note it and move on.

- [ ] **Step 3: Tear down the extension container, restore the plain harness**

```bash
docker rm -f wheels-lucee7-p2
cd ~/GitHub/wheels-dev/wheels && git checkout -- server.json config/settings.cfm CFConfig.json && rm -f box.json
rm -rf vendor/wheels-websockets tests/specs/packages
```

(Full harness restore here — Tasks 6–8 don't need it. If a later fix requires the loop again, re-run Task 0.)

---

### Task 6: RustCFML no-regression check

**Files:** none (verification only).

**Interfaces:**
- Consumes: `~/.claude/rustcfml-ladder/` rig (latest engine binary), the package repo.
- Produces: evidence that transport resolution still picks `rustcfml` on RustCFML after the Task 3 refactor.

- [ ] **Step 1: Boot a RustCFML-served app with the package and assert the transport**

Follow `~/.claude/rustcfml-ladder/README` to serve the wheels tree (or the P1 scratch app) with the package installed on the latest cached engine binary. Then request a probe page (or reuse `ws-verify-tmp.cfm` pattern) that outputs `SerializeJSON(websocketsInfo())`.

Expected: `{"active":true,"transport":"rustcfml","wireChannel":"/wheels"}`.

Fallback if the rig is unavailable or broken today: the resolution specs from Task 3 cover the branch ordering (`wsPublish` checked before `websocketInfo`); note the skip explicitly in the task record and in the #3292 comment.

---

### Task 7: Docs + version bump to 0.2.0

**Files:**
- Modify: `~/GitHub/wheels-dev/wheels-websockets/README.md`
- Modify: `~/GitHub/wheels-dev/wheels-websockets/CHANGELOG.md`
- Modify: `~/GitHub/wheels-dev/wheels-websockets/package.json` (version → `0.2.0`)
- Modify: `~/GitHub/wheels-dev/wheels-websockets/channels/wheels.cfc` (header: `v0.1.0` → `v0.2.0`)
- Modify: `~/GitHub/wheels-dev/wheels-websockets/lucee/wheels.cfc` (header already says 0.2.0 — verify)

**Interfaces:**
- Consumes: verified behavior + spike verdicts from Tasks 4–6.
- Produces: user-facing docs for the Lucee backend.

- [ ] **Step 1: README updates**

Engine matrix row for Lucee changes from "planned" to shipped; add a "Lucee setup" section containing, at minimum:

```markdown
## Lucee setup (Lucee 6.2+)

1. Install the official websocket extension once (needs a restart):
   - env pin: `LUCEE_EXTENSIONS="3F9DFF32-B555-449D-B0EB5DB723044045;version=3.0.0.20"`
   - or Lucee Admin → Extensions → "WebSocket".
2. Install this package (`wheels packages add wheels-websockets`) and restart/reload.
   On boot the package writes the `wheels.cfc` listener into the extension's
   websockets directory (skip with `set(websocketsListenerInstall=false)`) and
   channel publishes start reaching WebSocket clients at `ws://host/ws/wheels`.
3. The listener is code you own — edit its auth gate. Delete it and reload to
   regenerate.

| Setting | Default | Meaning |
|---|---|---|
| `websocketsTransport` | `auto` | `auto` \| `rustcfml` \| `lucee` \| `none` |
| `websocketsListenerInstall` | `true` | Allow boot() to write the listener when absent |

Servlet containers: Tomcat (incl. Lucee Express / `wheels start`) works out of
the box. CommandBox/undertow: <VERDICT FROM TASK 5>. Anything else without a
JSR-356 ServerContainer: the package logs once and stays on SSE.
```

Replace `<VERDICT FROM TASK 5>` with the actual spike result — leaving the placeholder is a task failure.

- [ ] **Step 2: CHANGELOG entry**

```markdown
## 0.2.0 — 2026-07-XX

### Added
- Lucee backend over the official lucee/extension-websocket (Lucee 6.2+):
  `LuceeExtensionTransport`, auto-installed self-contained `wheels.cfc`
  listener at `/ws/wheels`, same wire frames as the RustCFML backend — the
  JS client is unchanged.
- `websocketsTransport` accepts `"lucee"`; new `websocketsListenerInstall`
  setting (default `true`).

### Notes
- Graceful degradation: containers without a JSR-356 ServerContainer (or a
  missing listener) log one warning and continue on SSE.
```

- [ ] **Step 3: Bump `package.json` version to `0.2.0`; sync template headers; final harness run** (re-run Task 0 + full suites if the harness was torn down, or rely on the Task 3 Step 5 green + no code changes since — state which in the commit body)

- [ ] **Step 4: Commit**

```bash
cd ~/GitHub/wheels-dev/wheels-websockets
git add README.md CHANGELOG.md package.json channels/wheels.cfc lucee/wheels.cfc
git -c commit.gpgsign=false commit -s -m "docs: 0.2.0 — Lucee backend docs, settings table, engine matrix

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Release 0.2.0 + registry publish (P3) + tracking

**Files:**
- Package repo: tag `v0.2.0`, push.
- Registry repo `wheels-dev/wheels-packages`: manifest PR (exact file layout per the flow memory).
- Wheels repo issue #3292: tick P2/P3 checkboxes + evidence comment.
- Memory: update `project_2962_feature_campaign.md` (+ MEMORY.md hook if wording changes).

**Interfaces:**
- Consumes: everything green above; `~/.claude/.../memory/reference_basecoat_publish_flow.md` (READ IT FIRST — two-PR sequence: source tag → registry manifest, mirror auto-fills).
- Produces: `wheels packages add wheels-websockets` resolving 0.2.0.

- [ ] **Step 1: Push and tag**

```bash
cd ~/GitHub/wheels-dev/wheels-websockets
git push origin main
git tag v0.2.0 && git push origin v0.2.0
```

- [ ] **Step 2: Registry manifest PR** — follow `reference_basecoat_publish_flow.md` exactly (clone/branch `wheels-dev/wheels-packages`, add the wheels-websockets entry pointing at the `v0.2.0` tag, open PR). **Report the PR and STOP — Peter merges** (standing feedback: confirm before merging code-tier PRs; registry manifests count).

- [ ] **Step 3: Verify install UX after Peter merges**

```bash
WHEELS_PACKAGES_REGISTRY=wheels-dev/wheels-packages wheels packages show wheels-websockets
# then in a scratch app: wheels packages add wheels-websockets
```

- [ ] **Step 4: Update #3292** — tick the P2 and P3 checkboxes in the body (`gh issue edit 3292 --repo wheels-dev/wheels --body-file <edited>`) and add the evidence comment (`gh issue comment 3292 --repo wheels-dev/wheels --body-file <file>`): Tomcat transcript, undertow verdict, spec counts, listener auto-install log lines.

- [ ] **Step 5: Update memory** — append P2/P3 outcome + any new hard-won lessons to `project_2962_feature_campaign.md`.

---

## Self-Review Notes (completed at write time)

- **Spec coverage:** wire parity (T1), transport (T1), registry (T1/T2), listener + auto-install (T2/T3), detection/settings/fallback (T3), engine-agnostic specs (T1–T3), live Tomcat (T4), undertow spike (T5), RustCFML regression (T6), docs/0.2.0 (T7), registry publish + tracking (T8). Idle-timeout observation from the spec is documented in the listener header + README ("code you own"), not defaulted — matches spec.
- **Type consistency:** transport `name()` = `"lucee-extension"` used identically in boot wiring (T3) and specs; registry key `"wheels-websockets"` + lock `"wheels-websockets-registry"` identical in T1 transport, T2 listener, spec helpers; `$installListenerFile(directory, app)` signature identical in T3 impl and specs.
- **Known judgment points for the executor:** (a) the two forced-mode resolution specs may already pass before T3's change — they're pinning specs, keep them; (b) `websocketInfo().mapping` is asserted by the extension source to be the absolute physical directory — if a live run shows it's a file path or has a trailing slash, adjust `ListAppend(...)` accordingly and add a spec; (c) `LUCEE_EXTENSIONS` GUID/version syntax may need the `name=` field on some Lucee builds — Task 4 Step 1 lists the `.lex`-drop fallback.
