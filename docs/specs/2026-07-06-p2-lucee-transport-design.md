# P2 Design — Lucee transport over lucee/extension-websocket

- **Date:** 2026-07-06
- **Status:** Approved (maintainer sign-off same day)
- **Target version:** 0.2.0
- **Decision records:** wheels-dev/wheels#3154 (GO as package), wheels-dev/wheels#3292 (tracking), maintainer Q&A 2026-07-06 (backend = official extension; listener auto-install = yes; registry publish bundled after verification)

## Goal

Make `wheels-websockets` deliver channel events over WebSockets on Lucee, using the
official [`lucee/extension-websocket`](https://github.com/lucee/extension-websocket),
with the same app-facing behavior as the RustCFML backend shipped in 0.1.0: install
the package, install the extension, and `publish()` reaches connected browsers — no
core changes, no JS changes, SSE fallback everywhere else.

## Non-goals (P2)

- Client→server messaging beyond the `{received: true}` ack (wire stays server→client, mirroring SSE semantics).
- Presence, acks-to-server, rooms beyond one-room-per-channel.
- Adobe / BoxLang backends (P4, demand-gated via wheels-dev/wheels#3286).
- Auto-installing the **extension** itself (`.lex`) — that stays a documented one-time step (`LUCEE_EXTENSIONS` pin or Lucee Admin); it needs a restart anyway.
- The RustCFML upstream ask (configurable channel-CFC directory) — tracked separately.

## Backend selection (researched 2026-07-06)

| Candidate | Verdict | Why |
|---|---|---|
| **lucee/extension-websocket** (official) | **Chosen** | Active (3.0.0.20 released, CI, recent LDEV fixes). Dual-API: javax on Lucee 6.2+/Tomcat 9, jakarta on Lucee 7/Tomcat 11. Serves listener CFCs at `/ws/{component-name}` → free URL parity with P1. `.lex` install, pinnable via `LUCEE_EXTENSIONS`. |
| isapir/lucee-websocket | Rejected | Requires hand-edited `web.xml` + jar on the container classpath; javax-era (Tomcat 8/9) — no Lucee 7/Tomcat 11 path. |
| pixl8/socket.io-lucee | Rejected | Self-described ALPHA; pinned to socket.io client 2.3.1 (2020); client-side acks documented broken on Lucee 6/7. |

### Extension facts the design relies on (verified in source)

- Endpoint template is `@ServerEndpoint("/ws/{component-name}")` — `wheels.cfc` ⇒ `/ws/wheels`.
- Listener lifecycle: `onOpen(wsClient)`, `onMessage(wsClient, message)` (return value = reply), `onClose(wsClient, reasonPhrase)`, `onError(wsClient, cfCatch)`; one listener CFC **instance per connection** (its `variables` scope is per-connection state).
- `wsClient.send(message)` resolves engine config at call time ⇒ a stored `wsClient` reference is callable from any later HTTP request. This is the bridge primitive.
- Listener CFCs execute on a synthetic page context (`ThreadUtil.createPageContext`) that never runs `Application.cfc` ⇒ **listeners cannot see `application.wheels`**. Shared state must live in the `server` scope.
- The query string is passed into that page context ⇒ `url.channels` works inside the listener.
- `wsClient.getSession()` ships only in **unreleased 3.0.0.21** — the design must not use it (released 3.0.0.20 is the floor).
- `websocketInfo()` BIF: probe for detection; its `mapping` key is the absolute listener directory (used by auto-install); calling it also lazily registers the endpoint.
- Deployment uses the JSR-356 `ServerContainer` ServletContext attribute: native on Tomcat (= Lucee Express, which is what LuCLI's `wheels start` runs); on CommandBox/undertow it requires `web.webSocket.enable` and needs a live spike; absent ⇒ the extension throws ⇒ we degrade to SSE.

## Architecture

```
publish(channel, event, data)
    └─> ChannelEngineDecorator (unchanged, 0.1.0)
            ├── in-memory subscribers (SSE — unchanged)
            └── LuceeExtensionTransport.broadcast()
                    └── server["wheels-websockets"].registry[channel] → wsClient.send(frame)

browser ── ws://host/ws/wheels?channels=orders,chat ──> extension ──> {lucee-config}/websockets/wheels.cfc
                                                                        onOpen: auth gate + register wsClient
                                                                        onClose/onError: deregister
```

### 1. Wire & URL — byte-identical to P1

Frames: `{t: "msg", ch: "/wheels", ev: <event>, d: {channel, data, id}, id}`.
URL: `/ws/wheels` (+ `?channels=<csv>` and optional app params, e.g. `token`).
Consequence: **zero changes** to `assets/js/wheels-realtime.js` and zero changes to the
RustCFML transport. Apps moving between engines change nothing client-side.

### 2. `lib/LuceeExtensionTransport.cfc` (new)

Same surface as `RustCfmlTransport`: `active()`, `name()` (= `"lucee-extension"`),
`wireChannel()` (= `"/wheels"`), `broadcast(channel, event, data, id)`.

`broadcast()`:
1. Serialize the frame once.
2. Snapshot `server["wheels-websockets"].registry[channel]` under the named lock (short, read-only critical section).
3. Outside the lock, `wsClient.send(json)` per client, each in try/catch; a send that throws or a client with `isOpen() == false` is collected for eviction.
4. Evict collected connection ids under the lock.

Never throws to `publish()` callers (the decorator's try/catch remains the outer net).

### 3. Connection registry — `server` scope

```
server["wheels-websockets"] = {
    registry = { "<channelName>" = { "<connId>" = wsClient, ... }, ... }
}
```

- All mutations under `cflock name="wheels-websockets-registry"`.
- `connId = CreateUUID()` minted in `onOpen` (NOT `getSession().getId()` — see version floor above).
- Cleanup is two-layer: eager (`onClose`/`onError` deregister) + lazy (broadcast evicts dead clients — covers hard-killed sockets that never fire `onClose`).
- Server restart clears scope and connections together; nothing persists.
- Rationale for `server` scope: it is the only scope shared between the extension's synthetic page contexts and app requests. Key is namespaced; contents are transient run-time state only.

### 4. Listener template `lucee/wheels.cfc` + auto-install

- Ships in the package as `lucee/wheels.cfc`; **self-contained** (registry logic inlined, ~80 lines) because the extension's page context cannot resolve the app's `vendor.*` dotted paths.
- Code-you-own contract, parallel to the RustCFML `channels/wheels.cfc` template:
  - `onOpen(wsClient)`: commented auth hook (token example); parse `url.channels`; mint connId; register per channel; keep `{connId, channels}` in `variables` (per-connection instance state); send a welcome frame — `SerializeJSON({t: "welcome", d: {connId}})`, which `WheelsRealtime` ignores by design (it only dispatches frames carrying `d.channel`). Note the extension casts listener return values to string, so anything returned to the wire must already be serialized.
  - `onMessage(wsClient, message)`: return `{received: true}` (SerializeJSON'd) — ack-only wire, same as P1.
  - `onClose(wsClient, reasonPhrase)` / `onError(wsClient, cfCatch)`: deregister connId from all its channels.
- Stamped header: generated-by + package version + "safe to edit; delete this file and reload to regenerate; set(websocketsListenerInstall=false) to disable auto-install".
- **Auto-install in `boot()`** (maintainer-approved): when the Lucee probe succeeds, call `websocketInfo()`, read the listener directory from `mapping`, and if `wheels.cfc` is **absent** there, write the template. If any file exists at that path, never touch it (info log). Not writable / any failure ⇒ one-time warning log with the manual copy command, transport still activates if the listener already exists, otherwise resolve inactive.

### 5. Detection, configuration, failure containment

`$resolveWebsocketsTransport(mode)`:
- `"none"` / unknown ⇒ NullTransport. `"rustcfml"` / `"lucee"` force a branch (still feature-checked).
- `"auto"` (default): probe `GetFunctionList()` for `wsPublish` (RustCFML) **first**, then `websocketinfo` (Lucee extension).
- The Lucee branch must survive a real `websocketInfo()` call in try/catch — on containers without a JSR-356 `ServerContainer` the extension throws; we resolve NullTransport and log the cause once (`wheels.log`).

Settings (all optional, via `set()` in the app):

| Setting | Default | Meaning |
|---|---|---|
| `websocketsTransport` | `"auto"` | `"auto"` \| `"rustcfml"` \| `"lucee"` \| `"none"` |
| `websocketsListenerInstall` | `true` | Allow boot() to write the listener into the extension's directory when absent |

Every Lucee-specific call sits in try/catch; a broken transport degrades to SSE, never
to a broken app (PackageLoader per-package isolation remains the outermost net).
Engine floor: Lucee 6.2+ (extension requirement); older Lucee ⇒ inactive/SSE, documented.

### 6. Testing & verification

- **Package specs (engine-agnostic, run on any engine):**
  - `FakeWsClient` test double: records `send()` payloads; can simulate `isOpen() == false` and throwing `send()`.
  - Transport specs: broadcast fans out to the right channel only; frame shape matches P1; dead client evicted; throwing client evicted and isolated; empty channel is a no-op.
  - Listener contract specs: instantiate `lucee/wheels.cfc` directly from the vendor path (plain CFML), drive `onOpen`/`onMessage`/`onClose`/`onError` with fakes; assert registration/deregistration and the ack.
  - Boot specs: auto-install honored/skipped per setting; existing file never overwritten.
- **Live primary — `wheels start` (LuCLI ⇒ Lucee Express/Tomcat):** extension pinned via `LUCEE_EXTENSIONS`; `node ws` client on `/ws/wheels`; HTTP request → `publish()` → frame delivered; channel isolation verified (subscriber to `orders` does not receive `chat`). Same end-to-end bar P1 met on RustCFML.
- **Spike — CommandBox/undertow (docker lucee7 image):** `web.webSocket.enable` + extension; record the outcome either way. If undertow can't host the endpoint, that's a documented limitation with SSE fallback — not a release blocker (dev loop = Tomcat via LuCLI; Tomcat production covered).
- **Regression:** the 11 existing P1 specs + full demo-app suite on Lucee 7 stay green; RustCFML ladder re-run to confirm no cross-contamination.

## Delivery (after verification)

1. Version 0.2.0: CHANGELOG entry, README engine-matrix update (Lucee row → shipped), extension-install docs (`LUCEE_EXTENSIONS=org.lucee:websocket-extension:<version>` + Admin path).
2. Tick the P2 checkbox on wheels-dev/wheels#3292 with verification evidence.
3. **P3 bundled (maintainer-approved):** two-PR registry publish flow so `wheels packages add wheels-websockets` works; publish as 0.2.0.

## Risks

| Risk | Mitigation |
|---|---|
| Undertow/CommandBox can't host the endpoint | Live spike; graceful SSE fallback + documented matrix; Tomcat (LuCLI dev, production) unaffected |
| Concurrent `send()` to one session throws (JSR-356 single-writer) | Per-send try/catch + eviction; realtime contract is best-effort delivery |
| Extension config directory not writable at boot | Warning log + manual copy instructions; transport activates only when the listener exists |
| `server`-scope registry leaks entries | Eager deregister + lazy eviction on broadcast; entries are tiny (wsClient refs) |
| Extension pre-3.0.0.20 or Lucee < 6.2 | Probe fails or `websocketInfo()` throws ⇒ inactive/SSE with one-time log |

## Unresolved questions

None blocking. Two observations recorded for later phases:
- If the undertow spike **passes**, CommandBox users get WS with one server.json flag — worth a README callout.
- The extension's default `idleTimeout` (300s) closes quiet connections; `WheelsRealtime` auto-reconnects, so behavior is correct but produces reconnect churn on idle dashboards. A `property idleTimeout=0` note in the listener template is documented, not defaulted.
