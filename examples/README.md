# ReverseIt Example Clients

This directory contains example client implementations in different languages to test and demonstrate ReverseIt's HTTP and WebSocket proxying capabilities.

## Prerequisites

Make sure the test servers are running:

```bash
# From the project root
mix test --only websocket
# Or run the test suite which starts the servers
```

The examples expect:
- **Proxy server** on `http://localhost:4000`
- **Backend server** on `http://localhost:4001`

## Node.js Client

A comprehensive test client using Node.js built-in `http` module and the `ws` WebSocket library.

### Installation

```bash
npm install ws
```

### Usage

```bash
node examples/node_client.js
```

### Tests Performed

**HTTP:**
- Simple GET request
- JSON API endpoint
- POST with body
- Header forwarding validation
- 404 error handling

**WebSocket:**
- Text frame proxying
- Empty text frame
- Large messages (10KB)
- Rapid successive messages
- Binary frames

## Python Client

A similar test suite implemented in Python using `requests` and `websocket-client`.

### Installation

```bash
pip install requests websocket-client
```

### Usage

```bash
python3 examples/python_client.py
# Or make it executable
chmod +x examples/python_client.py
./examples/python_client.py
```

### Tests Performed

Same test suite as Node.js client:
- HTTP: GET, POST, JSON, headers, 404
- WebSocket: text, empty, large messages, rapid messages, binary

## Manual Testing

You can also use these clients as a reference for manual testing with tools like:

### cURL (HTTP)

```bash
# Simple GET
curl http://localhost:4000/hello

# JSON endpoint
curl http://localhost:4000/api/status

# POST with body
curl -X POST http://localhost:4000/echo -d "test data"

# View headers
curl http://localhost:4000/headers
```

### wscat (WebSocket)

```bash
# Install wscat
npm install -g wscat

# Connect to WebSocket
wscat -c ws://localhost:4000/ws

# Then type messages interactively
> Hello from wscat!
< Backend echo: Hello from wscat!
```

### websocat (WebSocket)

```bash
# Install websocat
# On macOS: brew install websocat
# On Linux: cargo install websocat

# Interactive WebSocket session
websocat ws://localhost:4000/ws

# Echo messages
echo "Hello" | websocat ws://localhost:4000/ws
```

## Expected Output

All test clients should show:
- ✅ Green checkmarks for passing tests
- Status codes and response bodies
- WebSocket message exchanges
- Final summary of test results

Example output:
```
╔════════════════════════════════════════╗
║   ReverseIt Node.js Test Client       ║
╚════════════════════════════════════════╝

=== Testing HTTP Proxy ===

1. Testing simple GET /hello
   Status: 200
   Body: Hello from backend!

...

✅ All tests completed successfully!
```

## Troubleshooting

### "Connection refused"

Make sure the test servers are running. Start them with:

```bash
# Terminal 1: Start backend
MIX_ENV=test mix run --no-halt

# Terminal 2: Run tests to start both servers
mix test
```

### WebSocket connection fails

Check that:
1. Backend server supports WebSocket on `/ws` endpoint
2. No firewall blocking connections
3. Ports 4000 and 4001 are available

### Binary frames not working (Python)

Ensure you have the latest `websocket-client`:

```bash
pip install --upgrade websocket-client
```

## Integration with CI/CD

These clients can be used in CI/CD pipelines for integration testing:

```bash
# Start servers in background
mix test --only websocket &
SERVER_PID=$!

# Wait for servers to start
sleep 2

# Run client tests
node examples/node_client.js
EXIT_CODE=$?

# Cleanup
kill $SERVER_PID

exit $EXIT_CODE
```

## Contributing

When adding new proxy features, please update these example clients to demonstrate and test the new functionality.
