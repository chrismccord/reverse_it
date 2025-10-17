# ReverseIt - Elixir HTTP/WebSocket Reverse Proxy

A full-featured HTTP/1.1, HTTP/2, and WebSocket reverse proxy for Elixir, built using Bandit and Mint. Designed to work seamlessly within Phoenix/Plug pipelines.

## Features

- **Full HTTP Support**: HTTP/1.1 and HTTP/2 proxying with streaming request/response bodies ✅
- **WebSocket Proxying**: Bidirectional WebSocket frame forwarding with full protocol support ✅
- **Plug Integration**: Works as a standard Plug module in any Phoenix or Plug application ✅
- **Header Management**: Automatic X-Forwarded-* header injection and hop-by-hop header filtering ✅
- **Connection Pooling**: Built on Mint's connection pooling ✅
- **Path Manipulation**: Strip path prefixes and add backend path prefixes ✅
- **Protocol Detection**: Automatic detection and routing for HTTP vs WebSocket upgrades ✅

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
    forward "/", ReverseIt.Proxy,
      backend: "http://backend-api:4000",
      strip_path: "/api"
  end

  # Proxy WebSocket connections
  scope "/socket" do
    forward "/", ReverseIt.Proxy,
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

  forward "/", ReverseIt.Proxy,
    backend: "http://localhost:4001",
    timeout: 60_000,
    protocols: [:http1, :http2]
end
```

## Configuration Options

- `:backend` (required) - Backend URL (http://, https://, ws://, or wss://)
- `:strip_path` - Path prefix to strip from incoming requests
- `:timeout` - Request timeout in milliseconds (default: 30,000)
- `:connect_timeout` - Connection timeout in milliseconds (default: 5,000)
- `:protocols` - List of supported protocols (default: [:http1, :http2])
- `:verify_tls` - Verify TLS certificates (default: true)
- `:add_headers` - List of headers to add to backend requests (default: [])
- `:remove_headers` - List of header names to remove from client requests (default: [])
- `:max_body_size` - Maximum request/response body size in bytes (default: 10MB)
- `:error_response` - Response to return when backend fails (default: {502, "Bad Gateway"})

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
Client → Phoenix/Bandit → ReverseIt.Proxy (Plug) → Mint.HTTP → Backend
```

### WebSocket Proxy Flow
```
Client ↔ Phoenix/Bandit ↔ ReverseIt.WebSocketProxy (WebSock) ↔ Mint.WebSocket ↔ Backend
```

## Project Structure

```
lib/
├── reverse_it/
│   ├── application.ex       # OTP application with test servers
│   ├── config.ex            # Configuration parser and validator
│   ├── proxy.ex             # Main Plug module with upgrade detection
│   ├── http_proxy.ex        # HTTP request proxying logic
│   ├── websocket_proxy.ex   # WebSocket proxy handler (WebSock behavior)
│   ├── test_backend.ex      # Test backend server
│   └── test_proxy.ex        # Test proxy server
```

## Implementation Status

### ✅ Fully Implemented and Tested

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
- Rapid message streams

**Test Coverage:**
- 14 passing tests (6 HTTP + 7 WebSocket + 1 doctest)
- Example clients in Node.js and Python
- Comprehensive edge case coverage

