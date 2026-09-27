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
| Lucee 7 | Same backend | ⚠️ Works on 7.0.2.7+ **only with the store's `3.0.0.20-SNAPSHOT` extension pinned** (full delivery bar verified live on 7.0.5.41) — an unpinned install gets 3.0.0.18, which can't load on Lucee 7, so the package stays on SSE. Waiting on a jakarta-compatible extension **release** ([#1](https://github.com/wheels-dev/wheels-websockets/issues/1), [#3292](https://github.com/wheels-dev/wheels/issues/3292)). See [Lucee 7](#lucee-7) |
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

1. Install the official websocket extension once (needs a restart). On **Lucee 7**, pin
   the snapshot build instead — see [Lucee 7](#lucee-7).
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
eviction) against the store extension above. For Lucee 7, see [Lucee 7](#lucee-7).

**Rewrite rules (`wheels start` / Tomcat):** the WebSocket upgrade has to get past
your app's URL rewriting. Apps generated before
[wheels-dev/wheels#3676](https://github.com/wheels-dev/wheels/pull/3676) ship a
`rewrite.config` whose front-controller catch-all rewrites `/ws/wheels` to
`/index.cfm/ws/wheels`, so the client gets a Wheels 404 instead of a `101`. Add these
two lines to your project-root `rewrite.config`, just above the
`# Route everything else through the front controller` rule, then restart:

```
RewriteCond %{HTTP:Upgrade} ^websocket$ [NC]
RewriteRule ^/ws/.*$ - [L]
```

The `RewriteCond` keeps ordinary HTTP routes under `/ws/` on the Wheels router. A
Dockerfile from `wheels deploy init` needs the same two lines in its `printf` rule list
before `'RewriteRule ^/(.*)$ /index.cfm/$1 [L]'`.

**CommandBox / undertow:** not a working path yet. Setting `web.webSocket.enable: true`
in `server.json` arms CommandBox's own WebSocket layer, which answers `/ws/wheels`
upgrades itself — a false-positive 101 handshake with no CFML listener behind it and
no frames ever delivered. Without that flag (retested on CommandBox 6.3.3 + Lucee
7.0.5.41 + `3.0.0.20-SNAPSHOT`), the extension accepts the upgrade once `ws/` is
excluded from `urlrewrite.xml`, but the connection closes (`1006`) without running the
listener — even a trivial echo CFC gets no frame. Use Tomcat (`wheels start`, or the
official `lucee/lucee` image) for WebSockets.

### Lucee 7

Lucee 7 works today when three things line up:

1. **An engine at 7.0.2.7 or newer.** Older 7.x builds never fire extension startup
   hooks ([LDEV-5955](https://luceeserver.atlassian.net/browse/LDEV-5955), fixed).
   `wheels new` currently pins an older build (`"lucee": {"version": "7.0.0.395"}` in
   `lucee.json`) — raise it, e.g. to `7.0.5.41`.
2. **The extension's snapshot build, pinned.** The store serves a jakarta-compatible
   build only as `3.0.0.20-SNAPSHOT`; `3.0.0.19` and `3.0.0.20` are not in the store.
   ```bash
   LUCEE_EXTENSIONS="3F9DFF32-B555-449D-B0EB5DB723044045;version=3.0.0.20-SNAPSHOT" wheels start
   ```
   An **unpinned** install (`LUCEE_EXTENSIONS` with the ID only) resolves to the newest
   release, 3.0.0.18, which predates Lucee 7's API: it fails to load with a
   `NoSuchMethodError` in Lucee's logs, the engine and your app are unaffected, and the
   package logs one warning and stays on SSE with zero request-path impact.
3. **The `/ws/` rewrite pass-through** above, for apps generated before
   wheels-dev/wheels#3676.

Verified live on Lucee 7.0.5.41 (Tomcat 11) with this setup: handshake + welcome,
`publish()` delivery, channel isolation, dead-client eviction, and the SSE fallback
with `set(websocketsTransport="none")`. The pin is a stopgap until
lucee/extension-websocket publishes a jakarta-compatible **release**
([#1](https://github.com/wheels-dev/wheels-websockets/issues/1)); drop it then.

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
