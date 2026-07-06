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
| Lucee 6/7 | Emulation over [lucee/extension-websocket](https://github.com/lucee/extension-websocket) | Planned ([#3292](https://github.com/wheels-dev/wheels/issues/3292)) |
| Adobe CF / BoxLang | — | Demand-gated ([discussion #3286](https://github.com/wheels-dev/wheels/discussions/3286)) |

On unsupported engines the package logs one line and stays inactive — installing it
is always safe.

## Install

```bash
wheels packages add websockets
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
`GetFunctionList()` ⇒ RustCFML) and, when a transport is available, pre-installs a
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
