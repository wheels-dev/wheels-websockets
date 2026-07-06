/**
 * WheelsRealtime — browser client for wheels-websockets.
 *
 * Connects to the shared wire channel served by public/websockets/wheels.cfc
 * (ws://host/ws/wheels), subscribes to named Wheels channels, and dispatches
 * events per channel. Falls back to the WheelsSSE client (if present on the
 * page) when WebSockets are unavailable, so the same subscription code works
 * on every engine.
 *
 * Usage:
 *   var rt = WheelsRealtime.connect({
 *     channels: ["orders", "alerts"],
 *     onEvent: function (channel, event, data, id) { ... },
 *     onStatus: function (state) { ... }   // "ws" | "sse" | "reconnecting" | "closed"
 *   });
 *   rt.close();
 */
(function (global) {
	"use strict";

	function connect(options) {
		var opts = options || {};
		var channels = opts.channels || [];
		var onEvent = opts.onEvent || function () {};
		var onStatus = opts.onStatus || function () {};
		var wirePath = opts.wirePath || "/ws/wheels";
		var maxWsAttempts = opts.maxWsAttempts || 2;

		var state = {
			ws: null,
			sse: null,
			attempts: 0,
			closedByUser: false
		};

		function wsUrl() {
			var proto = global.location.protocol === "https:" ? "wss://" : "ws://";
			return proto + global.location.host + wirePath +
				"?channels=" + encodeURIComponent(channels.join(",")) +
				(opts.params ? "&" + opts.params : "");
		}

		function openWs() {
			state.attempts += 1;
			var ws;
			try {
				ws = new global.WebSocket(wsUrl());
			} catch (e) {
				fallback();
				return;
			}
			state.ws = ws;

			ws.onopen = function () {
				state.attempts = 0;
				onStatus("ws");
			};

			ws.onmessage = function (e) {
				var frame;
				try {
					frame = JSON.parse(e.data);
				} catch (err) {
					return;
				}
				// Wire frames: { t, ch, ev, d: { channel, data, id }, id }
				var d = frame.d || {};
				if (d.channel) {
					onEvent(d.channel, frame.ev, d.data, d.id);
				}
			};

			ws.onclose = function () {
				state.ws = null;
				if (state.closedByUser) {
					onStatus("closed");
					return;
				}
				if (state.attempts >= maxWsAttempts) {
					fallback();
					return;
				}
				onStatus("reconnecting");
				setTimeout(openWs, Math.min(1000 * Math.pow(2, state.attempts), 15000));
			};
		}

		function fallback() {
			// Delegate to the stock Wheels SSE client when it is on the page.
			if (global.WheelsSSE && typeof global.WheelsSSE.subscribe === "function") {
				onStatus("sse");
				state.sse = channels.map(function (ch) {
					return global.WheelsSSE.subscribe(ch, function (payload) {
						onEvent(ch, payload.event, payload.data, payload.id);
					});
				});
			} else {
				onStatus("closed");
			}
		}

		openWs();

		return {
			close: function () {
				state.closedByUser = true;
				if (state.ws) {
					state.ws.close();
				}
				if (state.sse) {
					state.sse.forEach(function (sub) {
						if (sub && typeof sub.close === "function") {
							sub.close();
						}
					});
				}
			},
			transport: function () {
				if (state.ws) {
					return "ws";
				}
				return state.sse ? "sse" : "none";
			}
		};
	}

	global.WheelsRealtime = { connect: connect };
})(typeof window !== "undefined" ? window : this);
