#!/bin/bash

# Quick smoke test using curl and wscat
# Tests basic HTTP and WebSocket functionality

PROXY="http://localhost:4000"

echo "=== ReverseIt cURL Examples ==="
echo

echo "1. Simple GET request:"
curl -s "$PROXY/hello"
echo -e "\n"

echo "2. JSON API endpoint:"
curl -s "$PROXY/api/status" | jq '.'
echo

echo "3. POST with body:"
curl -s -X POST "$PROXY/echo" -d "Hello from curl!"
echo -e "\n"

echo "4. View forwarded headers:"
curl -s "$PROXY/headers" | jq '.headers | {host, "x-forwarded-for", "x-forwarded-proto", "x-forwarded-host"}'
echo

echo "5. Test 404 handling:"
curl -s -w "\nStatus: %{http_code}\n" "$PROXY/nonexistent"
echo

echo "=== WebSocket Test ==="
echo "Run: wscat -c ws://localhost:4000/ws"
echo "Or:  websocat ws://localhost:4000/ws"
echo
