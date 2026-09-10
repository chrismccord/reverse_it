# Changelog

## v0.3.0 (Unreleased)

Changes since v0.2.6. This minor release adds configuration options and stricter
resource limits; review the upgrade notes before deploying.

### Upgrade notes

- Backend WebSocket upgrade rejection bodies now have a separate 65,536-byte
  (64 KiB) buffering limit, even when `max_response_body_size` is `:infinity`.
  Set `max_websocket_upgrade_response_body_size` to a larger finite non-negative
  integer if needed. A smaller `max_response_body_size` still applies. Oversized
  rejections close the upstream and use the configured `error_response`.
- Upstream socket writes now time out after 55,000 ms and timed-out sockets are
  closed rather than reused. Configure `upstream_send_timeout` on the supervisor
  child for pooled HTTP, or in Plug options for direct one-shot HTTP and WebSocket
  connections. This bounds blocked writes, not the total request or TCP close
  while queued upload data is flushed; it does not add full-duplex forwarding
  of early backend responses.
- Use Bandit for WebSocket proxy routes. Cowboy's process handoff remains
  unsupported; ReverseIt now logs a warning on Cowboy WebSocket attempts.

### HTTP fixes

- Remove every untrusted `X-Forwarded-For`, `X-Forwarded-Proto`, and
  `X-Forwarded-Host` occurrence in `forwarded_headers: :replace` mode before
  adding trusted values. This also applies to WebSocket upgrade requests.
- Preserve trailing slashes when adding backend path prefixes, including the
  root path.
- Do not reject bodyless `HEAD` or `304` responses because their representation's
  `Content-Length` exceeds `max_response_body_size`, in pooled and one-shot modes.
- Serialize IPv6 backend URLs and Host authorities using `URI`, including
  brackets and scheme-specific default ports. Add the supervisor option
  `inet6: true` for pooled IPv6 connections (default: `false`).
- Bound blocked upstream writes, including streamed uploads to backends that
  stop reading, with the new `upstream_send_timeout` option.

### WebSocket fixes

- Close upstream sockets and return handshake errors when validation fails.
- Propagate invalid rejection-response headers instead of silently dropping them.
- Keep frame traffic on TLS for `https://` WebSocket backends.
- Deliver frames preceding a backend close, preserve its close code and reason,
  and ignore frames following the close.
- Preserve frame bytes received alongside the `101 Switching Protocols`
  response, including partial frames, and apply the existing frame-size checks.
- Bound buffered upgrade rejection bodies with the new limit described above.

### Development and examples

- Add multi-version Elixir/OTP CI, including the latest stable pair, with
  compilation and test warnings treated as errors. Pin GitHub Actions by SHA,
  refresh locked dependencies, and check formatting on the latest stable Elixir.
- Add focused regressions for these fixes, require a `1009` close in the
  WebSocket size-limit test, and allocate test ports by binding listeners to
  port zero instead of probing and releasing ports.
- Make Node WebSocket timeouts fail and require all five distinct WebSocket
  checks in both Node and Python clients, including binary payload verification.
  Fail HTTP checks on unexpected statuses.
- Add a persistent, loopback-only example server launcher:
  `MIX_ENV=test mix run --no-halt examples/server.exs`.

## v0.2.6 (2026-08-13)
- Stream large HTTP/1 request bodies through pooled Finch connections instead of opening a fresh upstream connection per request.
- Require Finch 0.23 for accumulator-aware request body streaming.

## v0.2.5 (2026-08-13)
- Abort downstream responses when an upstream body terminates early instead of completing a truncated response.
- Add bounded pre-header retries for replay-safe `GET` and `HEAD` requests.

## v0.2.4 (2026-08-11)
- Consume `Expect: 100-continue` after the downstream server accepts the request body instead of forwarding a stale expectation upstream
- Wait for a final upstream response when the transport emits informational `1xx` response blocks

## v0.2.3 (2026-08-08)
- Upgrade ws with full subprotocol negotiation

## v0.2.2 (2026-08-07)
- Support IPV6 in one-shot Unix socket upstreams

## v0.2.1 (2026-07-20)
- Support one-shot Unix socket upstreams

## v0.2.0 (2026-05-06)

### Breaking changes

- Replace permissive proxy defaults with bounded limits for request bodies, request headers, response headers, timeouts, and WebSocket frames.
- Rename the old body buffering behavior into explicit request body limit and buffering controls.
- Make upstream HTTP/2 opt-in with `protocols: [:http1, :http2]`; HTTP/1 remains the default for broad router compatibility.

### Bug fixes

- Support `wss://` backend WebSocket upgrades.
- Strip configured path prefixes only on path segment boundaries.
- Apply configured `add_headers`, `remove_headers`, and `error_response` options.

### Enhancements

- Enforce `max_request_body_size` for buffered and streamed request bodies.
- Stream backend responses instead of buffering complete responses in memory.
- Strip hop-by-hop headers, `Connection`-nominated headers, and WebSocket handshake headers before forwarding backend requests.
- Validate backend response headers before writing them to `Plug.Conn`.
- Add request target, request header line, aggregate request header, response header, and response body size limits.
- Add WebSocket idle timeout, backend upgrade timeout, maximum frame size, and bounded pending-frame queues.
- Verify backend TLS certificates by default, with `verify_tls: false` available for controlled environments.
- Add `forwarded_headers: :append | :replace | false` to control `X-Forwarded-*` behavior at trusted proxy boundaries.
