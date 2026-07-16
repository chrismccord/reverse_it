# ReverseIt - Elixir HTTP/WebSocket Reverse Proxy

A full-featured HTTP/1.1, optional HTTP/2, and WebSocket reverse proxy for Elixir, built using Finch (HTTP) and Mint (WebSockets). Designed to work seamlessly within Phoenix/Plug pipelines.

## Features

- **Full HTTP Support**: HTTP/1.1 proxying by default, optional HTTP/2 upstreams, and streaming request/response bodies
- **Connection Pooling**: Automatic connection pooling via Finch (50 connections per backend)
- **One-Shot Upstreams**: Fresh HTTP/1.1 connections over TCP or Unix-domain sockets
- **HTTP/2 Support**: Opt-in upstream HTTP/2 support with `protocols: [:http1, :http2]`
- **WebSocket Proxying**: Bidirectional WebSocket frame forwarding with full protocol support
- **Plug Integration**: Works as a standard Plug module in any Phoenix or Plug application
- **Header Management**: Automatic X-Forwarded-* header injection and hop-by-hop header filtering
- **DoS Protection**: Configurable request/response, header, timeout, and WebSocket limits with router-style defaults
- **Path Manipulation**: Strip path prefixes and add backend path prefixes
- **Protocol Detection**: Automatic detection and routing for HTTP vs WebSocket upgrades

## Setup

First, add ReverseIt to your application's supervision tree with a connection pool:

```elixir
defmodule MyApp.Application do
  def start(_type, _args) do
    children = [
      # Start ReverseIt with a connection pool
      {ReverseIt, name: MyApp.ReverseProxy, pool_size: 100},
      # ... other children
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

## Usage

### In a Phoenix Router

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  # Regular Phoenix routes
  scope "/", MyAppWeb do
    get "/", PageController, :index
  end

  # Proxy API requests to backend service
  scope "/api" do
    forward "/", ReverseIt,
      name: MyApp.ReverseProxy,
      backend: "http://backend-api:4000",
      strip_path: "/api"
  end

  # Proxy WebSocket connections
  scope "/socket" do
    forward "/", ReverseIt,
      name: MyApp.ReverseProxy,
      backend: "ws://backend-ws:4000"
  end
end
```

### As a Plug

```elixir
defmodule MyApp.ProxyPlug do
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/", ReverseIt,
    name: MyApp.ReverseProxy,
    backend: "http://localhost:4001",
    upstream_idle_timeout: 60_000,
    protocols: [:http1, :http2]
end
```

### One-Shot Unix-Socket Upstreams

Use a one-shot upstream when every proxied request or WebSocket upgrade must
receive a fresh connection to a local Unix-domain socket:

```elixir
ReverseIt.call(
  conn,
  ReverseIt.init(
    name: MyApp.ReverseProxy,
    backend: "http://provider-tunnel",
    unix_socket: "/run/my_app/provider-tunnel.sock",
    upstream_connection: :one_shot,
    protocols: [:http1]
  )
)
```

The backend host remains the HTTP `Host` and WebSocket authority while
`:unix_socket` selects the transport address. Unix-socket upstreams are local,
unencrypted HTTP/1.1 only and always one-shot; ReverseIt never returns these
connections to the Finch pool.

## Customizing Requests and Responses

You can wrap ReverseIt in your own Plug to modify request headers, add response headers, implement authentication, logging, etc. Use `Plug.Conn.register_before_send/2` to modify responses before they're sent to the client.

```elixir
defmodule MyApp.APIProxy do
  @moduledoc """
  Custom proxy that adds authentication and custom headers.
  """

  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    # Modify request before proxying
    conn
    |> Plug.Conn.put_req_header("x-api-key", "...")
    # Register callback to modify response after backend responds
    |> Plug.Conn.register_before_send(fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-proxy-by", "MyApp")
      |> Plug.Conn.put_resp_header("x-proxy-version", "1.0")
      |> log_request()
    end)
    # Proxy to backend
    |> ReverseIt.call(
      ReverseIt.init(
        name: MyApp.ReverseProxy,
        backend: "http://backend-api:4000",
        strip_path: "/api"
      )
    )
  end

  defp log_request(conn) do
    Logger.info("Proxied #{conn.method} #{conn.request_path} → #{conn.status}")
    conn
  end
end

# In your router:
scope "/api" do
  forward "/", MyApp.APIProxy
end
```

## Configuration Options

### Supervisor Options (when starting ReverseIt)

- `:name` (required) - Name for the Finch connection pool
- `:pool_size` - Max connections per backend (default: 50)
- `:pool_count` - Number of connection pools (default: 1)
- `:connect_timeout` - Backend connection timeout in ms (default: 5,000)
- `:conn_max_idle_time` - Idle timeout for pooled backend HTTP/1 connections (default: 90,000)
- `:protocols` - Upstream protocols for pooled Finch requests (default: `[:http1]`)

### Plug Options (when using as a Plug)

- `:name` (required) - Name of the Finch pool to use
- `:backend` (required) - Backend URL (http://, https://, ws://, or wss://)
- `:unix_socket` - Connect through this Unix-domain socket instead of the backend host/port
- `:upstream_connection` - `:pooled` or `:one_shot` (default: `:pooled`)
- `:strip_path` - Path prefix to strip from incoming requests
- `:connect_timeout` - Backend connection timeout in milliseconds (default: 5,000)
- `:pool_timeout` - Finch pool checkout timeout in milliseconds (default: 5,000)
- `:response_header_timeout` - Time to wait for backend response headers in streaming paths (default: 30,000)
- `:upstream_idle_timeout` - Rolling idle timeout while receiving backend data (default: 55,000)
- `:request_body_read_timeout` - Rolling timeout while reading client request bodies (default: 55,000)
- `:max_request_body_size` - Maximum request body size in bytes (default: 104,857,600 / 100MB, `:infinity` for unlimited)
- `:request_body_buffer_size` - Body bytes buffered before switching to request streaming (default: 1,048,576 / 1MB)
- `:max_response_body_size` - Maximum response body size in bytes (default: `:infinity`)
- `:max_request_target_bytes` - Maximum request path/query bytes (default: 8,192)
- `:max_request_header_line_bytes` - Maximum single request header bytes (default: 8,192)
- `:max_request_header_bytes` - Maximum total request header bytes (default: 65,536)
- `:max_request_headers` - Maximum request header count (default: 100)
- `:max_response_header_bytes` - Maximum backend response header bytes (default: 65,536)
- `:forwarded_headers` - `:append`, `:replace`, or `false` for X-Forwarded-* behavior (default: `:append`)
- `:add_headers` / `:remove_headers` - Backend request header policy
- `:verify_tls` - Verify backend TLS certificates (default: `true`)
- `:protocols` - List of supported upstream protocols (default: `[:http1]`)
- `:websocket_idle_timeout` - WebSocket idle timeout in milliseconds (default: 55,000)
- `:websocket_backend_upgrade_timeout` - Backend WebSocket upgrade timeout (default: 5,000)
- `:max_websocket_frame_size` - Maximum WebSocket frame/message size (default: 16,777,216 / 16MB)
- `:max_websocket_pending_bytes` - Maximum bytes buffered before backend upgrade completes (default: 1,048,576 / 1MB)
- `:max_websocket_pending_frames` - Maximum frame count buffered before backend upgrade completes (default: 16)
- `:websocket_compress` - Negotiate client WebSocket compression (default: `false`)

### Router-Style Defaults

ReverseIt’s defaults are intentionally broad enough for general HTTP routers while still bounding common DoS vectors:

- 30s backend response-header timeout for streaming paths
- 55s rolling backend/client body idle timeouts
- 90s pooled backend HTTP/1 keepalive idle timeout
- 8KB request target and per-header line limits
- 64KB aggregate request/response header limits
- 100MB maximum request body with a 1MB in-memory request buffer threshold
- 16MB WebSocket frame/message limit and bounded pre-upgrade frame buffering

If ReverseIt runs behind a trusted edge proxy, set `forwarded_headers: :replace` at the edge-facing ReverseIt instance. Use `:append` only when downstream applications treat X-Forwarded-* as informational rather than trusted identity.

## Testing

The project includes comprehensive test coverage with test servers that start automatically during test runs:

```bash
# Run all tests
# Test servers start automatically on available local ports
mix test

# Run only WebSocket tests
mix test --only websocket
```

**Note:** Test servers are only started during `mix test` and are not included in the library when used as a dependency.

### Interactive Testing

For manual/interactive testing, the example clients can be used while tests are running:

```bash
# Terminal 1: Keep test servers running
mix test --trace

# Terminal 2: Run example clients
node examples/node_client.js
python3 examples/python_client.py

# Or use curl/wscat
curl http://localhost:4000/hello
wscat -c ws://localhost:4000/ws
```

### Example Clients

The `examples/` directory contains full test clients in multiple languages:

```bash
# Node.js client (requires: npm install ws)
node examples/node_client.js

# Python client (requires: pip install requests websocket-client)
python3 examples/python_client.py

# Quick curl examples
bash examples/curl_examples.sh
```

See [examples/README.md](examples/README.md) for detailed usage.

## Architecture

### HTTP Proxy Flow
```
Client → Phoenix/Bandit → ReverseIt (Plug) → Finch (connection pool) → Backend
                                              ↑
                                     50 pooled HTTP/1.1 connections by default
```

For `upstream_connection: :one_shot`, ReverseIt uses a fresh passive Mint
HTTP/1.1 connection instead of Finch. This path supports both TCP and
Unix-domain sockets and closes the upstream after the response.

### WebSocket Proxy Flow
```
Client ↔ Phoenix/Bandit ↔ ReverseIt (Plug) ↔ ReverseIt.WebSocketProxy (WebSock) ↔ Mint.WebSocket ↔ Backend
```

## Connection Pooling

ReverseIt uses [Finch](https://hexdocs.pm/finch) for HTTP requests, providing:

- **Automatic pooling**: 50 connections per backend by default
- **Connection reuse**: HTTP connections are reused across requests
- **HTTP/2 support**: Upstream HTTP/2 can be enabled with `protocols: [:http1, :http2]`
- **Performance**: Eliminates TCP/TLS handshake overhead
- **Production-ready**: Battle-tested in production Elixir applications

You configure the pool when adding ReverseIt to your supervisor tree:

```elixir
children = [
  {ReverseIt, name: MyApp.ReverseProxy, pool_size: 100, pool_count: 2}
]
```

## Project Structure

```
lib/
├── reverse_it.ex            # Main Plug module with protocol detection
└── reverse_it/
    ├── application.ex       # OTP application supervisor
    ├── config.ex            # Configuration parser and validator
    ├── http_proxy.ex        # HTTP request proxying logic
    ├── upstream.ex          # TCP/Unix one-shot Mint connections
    └── websocket_proxy.ex   # WebSocket proxy handler (WebSock behavior)

test/
└── support/
    ├── test_backend.ex      # Test backend server
    └── test_proxy.ex        # Test proxy server
```

## Implementation Status

**HTTP Proxying:**
- HTTP/1.1 proxying by default; HTTP/2 upstream support is opt-in with `protocols: [:http1, :http2]`
- Request body streaming above the configured buffer threshold
- Response streaming through Finch/Mint without buffering complete responses
- Header forwarding, validation, and RFC hop-by-hop filtering
- X-Forwarded-* headers
- Connection pooling
- Fresh one-shot TCP or Unix-domain socket connections
- Path manipulation (strip_path, path_prefix)
- Plug integration
- Configuration module with validation

**WebSocket Proxying:**
- WebSocket upgrade detection and routing
- WebSocket proxy handler (WebSock behavior)
- Bidirectional frame forwarding (text, binary, ping, pong, close)
- Async initialization with frame buffering
- Bounded frame sizes, pending buffers, and idle/upgrade timeouts
- Backend connection via Mint.WebSocket
- Multiple concurrent connections
- Large message handling
