# Changelog

## [0.2.0] - 2026-07-06

> **Correction (2026-07-07):** retesting on current Lucee **7.0.4.34** showed the
> "startup hook never fires" defect was already fixed upstream in Lucee **7.0.2.7**
> ([LDEV-5955](https://luceeserver.atlassian.net/browse/LDEV-5955)) — our earlier
> runs used older builds (7.0.0.395, 7.0.1.100). With a locally built extension
> from master, the **full delivery bar passes on Lucee 7.0.4.34**. The single
> remaining blocker for stock Lucee 7 users is that the store has no
> jakarta-compatible extension release (3.0.0.18 fails to load on Lucee 7).

### Added

- Lucee backend over the official [lucee/extension-websocket](https://github.com/lucee/extension-websocket)
  (Lucee 6.2+): `LuceeExtensionTransport`, auto-installed self-contained `wheels.cfc`
  listener at `/ws/wheels`, same wire frames as the RustCFML backend — the JS client
  is unchanged.
- `websocketsTransport` accepts `"lucee"`; new `websocketsListenerInstall` setting
  (default `true`) gates the auto-install of the listener template.

### Notes

- **Lucee 6.2+ verified live end-to-end**: handshake + welcome frame, `publish()`
  delivery of the exact wire frame, channel isolation, and dead-client eviction, all
  proven against the store extension (`websocket-extension-3.0.0.18.lex`) on the
  official Lucee docker image (Tomcat 11).
- **Lucee 7 pending upstream**: no current Lucee 7 build (Tomcat or CommandBox/undertow)
  works yet, due to two independent upstream defects — the extension's startup hook
  never fires on Lucee 7, and no jakarta-compatible extension release exists on the
  store. The package detects this, logs one warning, and channels continue over SSE
  with zero request-path impact — verified live on both stacks.
- CommandBox/undertow footgun: `web.webSocket.enable: true` in `server.json` arms
  CommandBox's own WebSocket layer, which answers `/ws/wheels` upgrades itself
  (false-positive handshake, no frames delivered). Documented in the README.
- Graceful degradation (carried over from 0.1.0): containers without a JSR-356
  `ServerContainer`, or a missing/broken backend, log one warning and continue on SSE.

## [0.1.0] - 2026-07-06

### Added

- Initial release: WebSocket transport for Wheels channels as an opt-in package.
- RustCFML backend — bridges `publish()` onto the native realtime engine
  (`wsPublish`, one shared wire channel, one room per Wheels channel; verified
  live on RustCFML v0.423: HTTP → `publish()` → connected WS client with room
  isolation).
- `ChannelEngineDecorator` installed at boot via the ServiceProvider lifecycle —
  zero core changes, transport failure-isolated from `publish()` callers.
- `channels/wheels.cfc` wire-channel template (code you own, auth hook included).
- `WheelsRealtime` browser client with automatic fallback to the stock
  `WheelsSSE` client.
- Helpers: `websocketsActive()`, `websocketsInfo()`, `realtimeScriptTag()`.
- `set(websocketsTransport="none")` kill switch; engines without a backend are
  automatically inactive (log-once, no behavior change).
