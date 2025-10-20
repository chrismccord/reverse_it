# ReverseIt - Elixir HTTP/WebSocket Reverse Proxy

A full-featured HTTP/1.1, HTTP/2, and WebSocket reverse proxy for Elixir, built using Finch (HTTP) and Mint (WebSockets). Designed to work seamlessly within Phoenix/Plug pipelines.

## Features

- **Full HTTP Support**: HTTP/1.1 and HTTP/2 proxying with streaming request/response bodies
- **Connection Pooling**: Automatic connection pooling via Finch (50 connections per backend)
- **HTTP/2 Multiplexing**: Leverages HTTP/2 multiplexing for efficient request handling
- **WebSocket Proxying**: Bidirectional WebSocket frame forwarding with full protocol support
- **Plug Integration**: Works as a standard Plug module in any Phoenix or Plug application
- **Header Management**: Automatic X-Forwarded-* header injection and hop-by-hop header filtering
- **Request Body Limits**: Configurable limits to prevent memory exhaustion (default: 10MB)
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
    timeout: 60_000,
    protocols: [:http1, :http2]
end
```

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
- `:pool_timeout` - Connection timeout in ms (default: 30,000)

### Plug Options (when using as a Plug)

- `:name` (required) - Name of the Finch pool to use
- `:backend` (required) - Backend URL (http://, https://, ws://, or wss://)
- `:strip_path` - Path prefix to strip from incoming requests
- `:timeout` - Request timeout in milliseconds (default: 30,000)
- `:max_body_size` - Maximum request body size in bytes (default: 10,485,760 / 10MB, `:infinity` for unlimited)
- `:protocols` - List of supported protocols (default: [:http1, :http2])

## Testing

The project includes comprehensive test coverage with test servers that start automatically during test runs:

```bash
# Run all tests (14 tests: 6 HTTP + 7 WebSocket + 1 doctest)
# Test servers start automatically on ports 4000 (proxy) and 4001 (backend)
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
                                     50 pooled HTTP/1.1 or HTTP/2 connections
```

### WebSocket Proxy Flow
```
Client ↔ Phoenix/Bandit ↔ ReverseIt (Plug) ↔ ReverseIt.WebSocketProxy (WebSock) ↔ Mint.WebSocket ↔ Backend
```

## Connection Pooling

ReverseIt uses [Finch](https://hexdocs.pm/finch) for HTTP requests, providing:

- **Automatic pooling**: 50 connections per backend by default
- **Connection reuse**: HTTP connections are reused across requests
- **HTTP/2 multiplexing**: Multiple requests can share a single HTTP/2 connection
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
    └── websocket_proxy.ex   # WebSocket proxy handler (WebSock behavior)

test/
└── support/
    ├── test_backend.ex      # Test backend server
    └── test_proxy.ex        # Test proxy server
```

## Implementation Status

**HTTP Proxying:**
- HTTP/1.1 and HTTP/2 proxying
- Request/response streaming
- Header forwarding and filtering
- X-Forwarded-* headers
- Connection pooling
- Path manipulation (strip_path, path_prefix)
- Plug integration
- Configuration module with validation

**WebSocket Proxying:**
- WebSocket upgrade detection and routing
- WebSocket proxy handler (WebSock behavior)
- Bidirectional frame forwarding (text, binary, ping, pong, close)
- Async initialization with frame buffering
- Backend connection via Mint.WebSocket
- Multiple concurrent connections
- Large message handling


