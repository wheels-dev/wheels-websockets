# Changelog

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
