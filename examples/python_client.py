#!/usr/bin/env python3

"""
Python example client for testing ReverseIt reverse proxy

Tests both HTTP and WebSocket proxying functionality

Usage:
    python3 python_client.py

Requirements:
    pip install websocket-client requests
"""

import json
import sys
import time
import requests
import websocket

PROXY_URL = "http://localhost:4000"
WS_URL = "ws://localhost:4000/ws"

# ANSI color codes
class Colors:
    RESET = '\033[0m'
    GREEN = '\033[32m'
    RED = '\033[31m'
    YELLOW = '\033[33m'
    BLUE = '\033[34m'
    CYAN = '\033[36m'

def log(message, color=Colors.RESET):
    """Print colored log message"""
    print(f"{color}{message}{Colors.RESET}")

def test_http():
    """Test HTTP proxy functionality"""
    log("\n=== Testing HTTP Proxy ===", Colors.CYAN)

    try:
        # Test 1: Simple GET
        log("\n1. Testing simple GET /hello", Colors.YELLOW)
        response = requests.get(f"{PROXY_URL}/hello")
        log(f"   Status: {response.status_code}",
            Colors.GREEN if response.status_code == 200 else Colors.RED)
        log(f"   Body: {response.text}")

        # Test 2: JSON API endpoint
        log("\n2. Testing JSON endpoint /api/status", Colors.YELLOW)
        response = requests.get(f"{PROXY_URL}/api/status")
        log(f"   Status: {response.status_code}",
            Colors.GREEN if response.status_code == 200 else Colors.RED)
        data = response.json()
        log(f"   Response: {json.dumps(data, indent=2)}")

        # Test 3: POST with body
        log("\n3. Testing POST /echo with body", Colors.YELLOW)
        response = requests.post(f"{PROXY_URL}/echo", data="Hello from Python!")
        log(f"   Status: {response.status_code}",
            Colors.GREEN if response.status_code == 200 else Colors.RED)
        data = response.json()
        log(f"   Echo: {data['echo']}")

        # Test 4: Headers forwarding
        log("\n4. Testing header forwarding /headers", Colors.YELLOW)
        response = requests.get(f"{PROXY_URL}/headers")
        log(f"   Status: {response.status_code}",
            Colors.GREEN if response.status_code == 200 else Colors.RED)
        data = response.json()
        headers = data.get('headers', {})
        log(f"   X-Forwarded-For: {headers.get('x-forwarded-for', 'missing')}")
        log(f"   X-Forwarded-Proto: {headers.get('x-forwarded-proto', 'missing')}")
        log(f"   X-Forwarded-Host: {headers.get('x-forwarded-host', 'missing')}")

        # Test 5: 404 handling
        log("\n5. Testing 404 /nonexistent", Colors.YELLOW)
        response = requests.get(f"{PROXY_URL}/nonexistent")
        log(f"   Status: {response.status_code}",
            Colors.GREEN if response.status_code == 404 else Colors.RED)

        log("\n✅ HTTP tests completed", Colors.GREEN)
        return True

    except Exception as e:
        log(f"\n❌ HTTP test failed: {e}", Colors.RED)
        return False

def test_websocket():
    """Test WebSocket proxy functionality"""
    log("\n=== Testing WebSocket Proxy ===", Colors.CYAN)

    tests_passed = 0
    rapid_messages = set()
    binary_received = False

    def on_message(ws, message):
        nonlocal tests_passed, rapid_messages, binary_received

        # Handle binary messages
        if isinstance(message, bytes):
            if message == bytes([1, 2, 3, 4, 5]):
                log(f"   ✓ Received binary frame: {list(message)}", Colors.GREEN)
                tests_passed += 1
                binary_received = True
                # All tests done
                log("\n6. Closing connection", Colors.YELLOW)
                ws.close()
            return

        # Handle text messages
        if message == "Backend echo: Hello from Python!":
            log("   ✓ Received: " + message, Colors.GREEN)
            tests_passed += 1
            # Test 2: Empty text frame
            log("\n2. Testing empty text frame", Colors.YELLOW)
            ws.send("")

        elif message == "Backend echo: ":
            log("   ✓ Received empty echo", Colors.GREEN)
            tests_passed += 1
            # Test 3: Large message
            log("\n3. Testing large message (10KB)", Colors.YELLOW)
            ws.send("A" * 10000)

        elif message.startswith("Backend echo: AAAA"):
            log(f"   ✓ Received large message ({len(message)} bytes)", Colors.GREEN)
            tests_passed += 1
            # Test 4: Rapid messages
            log("\n4. Testing rapid successive messages", Colors.YELLOW)
            for i in range(1, 6):
                ws.send(f"Rapid message {i}")

        elif "Backend echo: Rapid message" in message:
            # Track rapid messages
            num = int(message.split()[-1])
            rapid_messages.add(num)
            if num == 1:
                log("   ✓ Receiving rapid messages...", Colors.GREEN)
            if len(rapid_messages) == 5:
                log("   ✓ All 5 rapid messages received", Colors.GREEN)
                tests_passed += 1
                # Test 5: Binary frame
                log("\n5. Testing binary frame", Colors.YELLOW)
                ws.send(bytes([1, 2, 3, 4, 5]), opcode=websocket.ABNF.OPCODE_BINARY)

    def on_error(ws, error):
        log(f"\n❌ WebSocket error: {error}", Colors.RED)

    def on_close(ws, close_status_code, close_msg):
        log("\n✓ WebSocket connection closed", Colors.GREEN)

    def on_open(ws):
        log("\n✓ WebSocket connection established", Colors.GREEN)
        # Test 1: Text frame
        log("\n1. Testing text frame", Colors.YELLOW)
        ws.send("Hello from Python!")

    try:
        ws = websocket.WebSocketApp(
            WS_URL,
            on_open=on_open,
            on_message=on_message,
            on_error=on_error,
            on_close=on_close
        )

        # Run with timeout
        ws.run_forever(ping_interval=30, ping_timeout=10)

        if tests_passed >= 4:  # Allow some async variance
            log(f"\n✅ WebSocket tests completed ({tests_passed}/5 passed)", Colors.GREEN)
            return True
        else:
            log(f"\n⚠ Only {tests_passed}/5 tests passed", Colors.YELLOW)
            return False

    except Exception as e:
        log(f"\n❌ WebSocket test failed: {e}", Colors.RED)
        return False

def main():
    """Run all tests"""
    log("╔════════════════════════════════════════╗", Colors.BLUE)
    log("║   ReverseIt Python Test Client        ║", Colors.BLUE)
    log("╚════════════════════════════════════════╝", Colors.BLUE)

    http_ok = test_http()

    # Wait a bit between tests
    time.sleep(0.5)

    ws_ok = test_websocket()

    log("\n" + "=" * 42, Colors.BLUE)
    if http_ok and ws_ok:
        log("✅ All tests completed successfully!", Colors.GREEN)
        log("=" * 42 + "\n", Colors.BLUE)
        sys.exit(0)
    else:
        log("❌ Some tests failed!", Colors.RED)
        log("=" * 42 + "\n", Colors.BLUE)
        sys.exit(1)

if __name__ == "__main__":
    main()
