# wheels-websockets

Opt-in realtime **WebSocket transport for Wheels channels**. Your app keeps calling
`publish()` exactly as before — where the engine can serve WebSockets, connected
browsers get the event over a socket; everywhere else, nothing changes and
[SSE channels](https://guides.wheels.dev/v4-0-0/digging-deeper/channels/) keep working.

```
publish("orders", "created", serializeJSON(order))
    └─> in-memory subscribers  ──>  SSE clients          (core, unchanged)
    └─> WebSocket transport    ──>  WS clients            (this package)
```

## Engine support

| Engine | Transport | Status |
|---|---|---|
| RustCFML | Native (`wsPublish` + engine-served channel CFCs) | ✅ v0.1.0 |
| Lucee 6.2+ | Over [lucee/extension-websocket](https://github.com/lucee/extension-websocket) | ✅ v0.2.0 — shipped, verified live |
| Lucee 7 | Same backend | ⏳ Works on 7.0.2.7+ (verified live on 7.0.4.34 with an extension master build) — waiting only on a jakarta-compatible extension **release** ([#3292](https://github.com/wheels-dev/wheels/issues/3292)); graceful SSE fallback until then |
| Adobe CF / BoxLang | — | Demand-gated ([discussion #3286](https://github.com/wheels-dev/wheels/discussions/3286)) |

On unsupported engines, or where a backend is detected but can't activate, the
package logs one line and stays on SSE — installing it is always safe.

## Install

```bash
wheels packages add wheels-websockets
```

(or manually: extract the release into `vendor/wheels-websockets/` and reload.)

Then, on RustCFML:

1. **Publish the wire channel CFC** (code you own — includes the auth hook):
   ```bash
   cp vendor/wheels-websockets/channels/wheels.cfc public/websockets/wheels.cfc
   ```
2. **Publish the JS client:**
   ```bash
   cp vendor/wheels-websockets/assets/js/wheels-realtime.js public/assets/js/wheels-realtime.js
   ```
3. Reload the app. `wheels.log` shows:
   `[wheels-websockets] Active: 'rustcfml' transport bridging channel publishes to WebSocket clients ...`

## Lucee setup (Lucee 6.2+)

1. Install the official websocket extension once (needs a restart):
   - env pin: `LUCEE_EXTENSIONS="3F9DFF32-B555-449D-B0EB5DB723044045;version=3.0.0.18"`
   - or direct download: drop [`websocket-extension-3.0.0.18.lex`](https://ext.lucee.org/websocket-extension-3.0.0.18.lex)
     into `lucee-server/deploy/` and restart
   - or Lucee Admin → Extensions → "WebSocket"
2. Install this package (`wheels packages add wheels-websockets`) and restart/reload.
   On boot the package detects the extension, and — if the listener is absent — writes
   `wheels.cfc` into the extension's configured websockets directory (skip with
   `set(websocketsListenerInstall=false)`); channel publishes then reach WebSocket
   clients at `ws://host/ws/wheels`.
3. The listener is code you own — edit its auth gate in `onOpen()`. Delete it and
   reload to regenerate.

| Setting | Default | Meaning |
|---|---|---|
| `websocketsTransport` | `auto` | `auto` \| `rustcfml` \| `lucee` \| `none` |
| `websocketsListenerInstall` | `true` | Allow boot() to write the listener when absent |

**Servlet containers:** Tomcat (incl. Lucee Express / `wheels start`) works today on
**Lucee 6.2+** — live-verified end-to-end (handshake, delivery, channel isolation,
eviction) against the store extension above. **Lucee 7 needs two things**: an engine
at **7.0.2.7 or newer** (older 7.x builds never fire extension startup hooks —
[LDEV-5955](https://luceeserver.atlassian.net/browse/LDEV-5955), fixed; note the
`wheels` CLI's bundled Lucee Express is currently older than this) and a
**jakarta-compatible extension release**, which the store doesn't have yet — the
extension's master branch works (full delivery bar live-verified on Lucee 7.0.4.34
from a local build), so this is purely a release-publication gap. Until it ships,
the package detects the situation, logs one warning, and channels keep working over
SSE with zero request-path impact. Installing today's released extension (3.0.0.18)
on Lucee 7 is harmless but inert: the extension itself fails to load with a
`NoSuchMethodError` in Lucee's logs (it predates Lucee 7's API), the engine and your
app are unaffected, and the package stays on SSE — this is exactly the configuration
our graceful-degradation verification ran against.

**CommandBox / undertow footgun:** setting `web.webSocket.enable: true` in
`server.json` arms CommandBox's own WebSocket layer, which answers `/ws/wheels`
upgrades itself — a false-positive 101 handshake with no CFML listener behind it and
no frames ever delivered. Even once Lucee 7 is fixed upstream, account for this
shadowing before relying on WS over CommandBox.

Any container without a JSR-356 `ServerContainer` (or Lucee < 6.2): the package
logs once and stays on SSE.

## Use

Server side — nothing new; the channels API you already use:

```cfm
publish(channel="orders", event="created", data=SerializeJSON(order));
```

Browser side:

```html
#realtimeScriptTag()#
<script>
  var rt = WheelsRealtime.connect({
    channels: ["orders", "alerts"],
    onEvent: function (channel, event, data, id) {
      console.log(channel, event, data);
    },
    onStatus: function (state) { /* "ws" | "sse" | "reconnecting" | "closed" */ }
  });
</script>
```

`WheelsRealtime` connects over WebSocket and **falls back to the stock `WheelsSSE`
client automatically** when it's on the page — one subscription API on every engine.

Helpers mixed into your app:

| Helper | Returns |
|---|---|
| `websocketsActive()` | `true` when a WS transport is live |
| `websocketsInfo()` | `{ active, transport, wireChannel }` |
| `realtimeScriptTag([jsPath] [, inline=true])` | The client `<script>` tag (view helper) |

## Configuration

```cfm
// config/settings.cfm
set(websocketsTransport="none");   // force-disable (default: "auto")
```

## Security

The published `public/websockets/wheels.cfc` accepts every connection by default
and lets it subscribe to any channel it names — same trust model as the stock SSE
channel endpoint. If your channels carry per-user data, implement the auth hook in
`onConnect()` (e.g. validate a signed token from `socket.param("token")`) and
restrict the rooms you return.

## How it works

At app boot the package feature-detects the engine (`wsPublish` in
`GetFunctionList()` ⇒ RustCFML; else a guarded `websocketInfo()` call ⇒ Lucee
6.2+) and, when a transport is available, pre-installs a
decorator around the framework's in-memory channel engine. The decorator forwards
every `publish()` to the transport **after** normal delivery, failure-isolated — a
broken socket layer can never affect `publish()` callers or SSE. Wheels channel
names map to rooms (`ch:<name>`) on one shared wire channel (`/ws/wheels`), so
clients receive only the channels they subscribed to.

No Wheels core changes are required or made.

## Tests

`tests/WebsocketsSpec.cfc` (BDD, `wheels.WheelsTest`) — copy into an app with the
package installed, or point your runner at the package `tests/` directory.

## License

Apache-2.0 — © Wheels Core Team.
