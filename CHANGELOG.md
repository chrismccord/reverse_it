# Changelog

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

