# ReverseIt - Elixir HTTP/WebSocket Reverse Proxy

A full-featured HTTP/1.1, HTTP/2, and WebSocket reverse proxy for Elixir, built using Bandit and Mint. Designed to work seamlessly within Phoenix/Plug pipelines.

## Features

- **Full HTTP Support**: HTTP/1.1 and HTTP/2 proxying with streaming request/response bodies ✅
- **WebSocket Proxying**: Bidirectional WebSocket frame forwarding (implementation complete, debugging in progress) 🔧
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
- `:protocols` - List of supported protocols (default: [:http1, :http2])

## Testing

The project includes test servers for validation:

```bash
# Start the test servers (backend on 4001, proxy on 4000)
mix run --no-halt

# Test HTTP proxying
curl http://localhost:4000/hello
curl http://localhost:4000/api/status
curl -X POST -d "test data" http://localhost:4000/echo
```

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
- HTTP/1.1 and HTTP/2 proxying
- Request/response streaming
- Header forwarding and filtering
- X-Forwarded-* headers
- Connection pooling
- Path manipulation (strip_path, path_prefix)
- Plug integration
- Configuration module

### 🔧 Implemented (Debugging Required)
- WebSocket upgrade detection
- WebSocket proxy handler (WebSock behavior)
- Bidirectional WebSocket frame forwarding
- WebSocket connection to backend via Mint.WebSocket

The WebSocket implementation is feature-complete but requires debugging of the async initialization sequence with Mint's message handling.

