// Simple WebSocket client test using Node.js built-in WebSocket
const WebSocket = require('ws');

const ws = new WebSocket('ws://localhost:4000/ws');

ws.on('open', function open() {
  console.log('[Client] Connected to WebSocket through proxy!');

  // Send first message
  ws.send('Hello from Node.js client!');
  console.log('[Client] Sent: Hello from Node.js client!');
});

ws.on('message', function incoming(data) {
  console.log('[Client] Received:', data.toString());

  // Send second message after receiving first response
  if (data.toString().includes('Hello from Node.js client')) {
    setTimeout(() => {
      ws.send('Second message from client');
      console.log('[Client] Sent: Second message from client');

      // Close after a moment
      setTimeout(() => {
        console.log('[Client] Closing connection...');
        ws.close();
      }, 1000);
    }, 500);
  }
});

ws.on('close', function close() {
  console.log('[Client] WebSocket closed');
  process.exit(0);
});

ws.on('error', function error(err) {
  console.error('[Client] WebSocket error:', err.message);
  process.exit(1);
});

// Timeout if nothing happens
setTimeout(() => {
  console.error('[Client] Timeout - no response received');
  process.exit(1);
}, 10000);
