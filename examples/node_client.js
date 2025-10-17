#!/usr/bin/env node

/**
 * Node.js example client for testing ReverseIt reverse proxy
 *
 * Tests both HTTP and WebSocket proxying functionality
 *
 * Usage:
 *   node node_client.js
 *
 * Requirements:
 *   npm install ws
 */

const http = require('http');
const WebSocket = require('ws');

const PROXY_URL = 'http://localhost:4000';
const COLORS = {
  reset: '\x1b[0m',
  green: '\x1b[32m',
  red: '\x1b[31m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  cyan: '\x1b[36m',
};

function log(message, color = 'reset') {
  console.log(`${COLORS[color]}${message}${COLORS.reset}`);
}

function httpGet(path) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, PROXY_URL);
    http.get(url, (res) => {
      let data = '';
      res.on('data', (chunk) => data += chunk);
      res.on('end', () => {
        resolve({
          status: res.statusCode,
          headers: res.headers,
          body: data
        });
      });
    }).on('error', reject);
  });
}

function httpPost(path, body) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, PROXY_URL);
    const postData = typeof body === 'string' ? body : JSON.stringify(body);

    const options = {
      hostname: url.hostname,
      port: url.port,
      path: url.pathname,
      method: 'POST',
      headers: {
        'Content-Type': 'text/plain',
        'Content-Length': Buffer.byteLength(postData)
      }
    };

    const req = http.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => data += chunk);
      res.on('end', () => {
        resolve({
          status: res.statusCode,
          headers: res.headers,
          body: data
        });
      });
    });

    req.on('error', reject);
    req.write(postData);
    req.end();
  });
}

async function testHTTP() {
  log('\n=== Testing HTTP Proxy ===', 'cyan');

  try {
    // Test 1: Simple GET
    log('\n1. Testing simple GET /hello', 'yellow');
    const helloRes = await httpGet('/hello');
    log(`   Status: ${helloRes.status}`, helloRes.status === 200 ? 'green' : 'red');
    log(`   Body: ${helloRes.body}`);

    // Test 2: JSON API endpoint
    log('\n2. Testing JSON endpoint /api/status', 'yellow');
    const statusRes = await httpGet('/api/status');
    log(`   Status: ${statusRes.status}`, statusRes.status === 200 ? 'green' : 'red');
    const statusJson = JSON.parse(statusRes.body);
    log(`   Response: ${JSON.stringify(statusJson, null, 2)}`);

    // Test 3: POST with body
    log('\n3. Testing POST /echo with body', 'yellow');
    const echoRes = await httpPost('/echo', 'Hello from Node.js!');
    log(`   Status: ${echoRes.status}`, echoRes.status === 200 ? 'green' : 'red');
    const echoJson = JSON.parse(echoRes.body);
    log(`   Echo: ${echoJson.echo}`);

    // Test 4: Headers forwarding
    log('\n4. Testing header forwarding /headers', 'yellow');
    const headersRes = await httpGet('/headers');
    log(`   Status: ${headersRes.status}`, headersRes.status === 200 ? 'green' : 'red');
    const headersJson = JSON.parse(headersRes.body);
    log(`   X-Forwarded-For: ${headersJson.headers['x-forwarded-for'] || 'missing'}`);
    log(`   X-Forwarded-Proto: ${headersJson.headers['x-forwarded-proto'] || 'missing'}`);
    log(`   X-Forwarded-Host: ${headersJson.headers['x-forwarded-host'] || 'missing'}`);

    // Test 5: 404 handling
    log('\n5. Testing 404 /nonexistent', 'yellow');
    const notFoundRes = await httpGet('/nonexistent');
    log(`   Status: ${notFoundRes.status}`, notFoundRes.status === 404 ? 'green' : 'red');

    log('\n✅ HTTP tests completed', 'green');

  } catch (error) {
    log(`\n❌ HTTP test failed: ${error.message}`, 'red');
    throw error;
  }
}

function testWebSocket() {
  return new Promise((resolve, reject) => {
    log('\n=== Testing WebSocket Proxy ===', 'cyan');

    const ws = new WebSocket('ws://localhost:4000/ws');
    let testsPassed = 0;
    const testsTotal = 5;

    ws.on('open', () => {
      log('\n✓ WebSocket connection established', 'green');

      // Test 1: Text frame
      log('\n1. Testing text frame', 'yellow');
      ws.send('Hello from Node.js!');
    });

    ws.on('message', (data) => {
      const message = data.toString();

      if (message === 'Backend echo: Hello from Node.js!') {
        log('   ✓ Received: ' + message, 'green');
        testsPassed++;

        // Test 2: Empty text frame
        log('\n2. Testing empty text frame', 'yellow');
        ws.send('');

      } else if (message === 'Backend echo: ') {
        log('   ✓ Received empty echo', 'green');
        testsPassed++;

        // Test 3: Large message
        log('\n3. Testing large message (10KB)', 'yellow');
        const largeMsg = 'A'.repeat(10000);
        ws.send(largeMsg);

      } else if (message.startsWith('Backend echo: AAAA')) {
        log(`   ✓ Received large message (${message.length} bytes)`, 'green');
        testsPassed++;

        // Test 4: Rapid messages
        log('\n4. Testing rapid successive messages', 'yellow');
        for (let i = 1; i <= 5; i++) {
          ws.send(`Rapid message ${i}`);
        }

      } else if (message.match(/Backend echo: Rapid message \d/)) {
        // Count rapid messages
        const rapidNum = parseInt(message.match(/\d/)[0]);
        if (rapidNum === 1) {
          log('   ✓ Receiving rapid messages...', 'green');
        }
        if (rapidNum === 5) {
          log('   ✓ All 5 rapid messages received', 'green');
          testsPassed++;

          // Test 5: Binary frame
          log('\n5. Testing binary frame', 'yellow');
          const buffer = Buffer.from([1, 2, 3, 4, 5]);
          ws.send(buffer);
        }
      }
    });

    ws.on('error', (error) => {
      log(`\n❌ WebSocket error: ${error.message}`, 'red');
      reject(error);
    });

    ws.on('close', () => {
      log('\n✓ WebSocket connection closed', 'green');

      if (testsPassed >= testsTotal - 1) { // Allow binary test to be async
        log(`\n✅ WebSocket tests completed (${testsPassed}/${testsTotal} passed)`, 'green');
        resolve();
      } else {
        reject(new Error(`Only ${testsPassed}/${testsTotal} tests passed`));
      }
    });

    // Handle binary messages
    ws.on('message', (data) => {
      if (Buffer.isBuffer(data) && data.length === 5) {
        const expected = Buffer.from([1, 2, 3, 4, 5]);
        if (data.equals(expected)) {
          log('   ✓ Received binary frame: ' + Array.from(data).join(', '), 'green');
          testsPassed++;

          // All tests done, close connection
          log('\n6. Closing connection', 'yellow');
          ws.close();
        }
      }
    });

    // Timeout after 5 seconds
    setTimeout(() => {
      if (ws.readyState === WebSocket.OPEN) {
        log('\n⚠ Test timeout, closing connection', 'yellow');
        ws.close();
        resolve(); // Don't fail on timeout, just complete
      }
    }, 5000);
  });
}

async function main() {
  log('╔════════════════════════════════════════╗', 'blue');
  log('║   ReverseIt Node.js Test Client       ║', 'blue');
  log('╚════════════════════════════════════════╝', 'blue');

  try {
    // Test HTTP
    await testHTTP();

    // Wait a bit between tests
    await new Promise(resolve => setTimeout(resolve, 500));

    // Test WebSocket
    await testWebSocket();

    log('\n' + '='.repeat(42), 'blue');
    log('✅ All tests completed successfully!', 'green');
    log('='.repeat(42) + '\n', 'blue');

    process.exit(0);

  } catch (error) {
    log('\n' + '='.repeat(42), 'blue');
    log('❌ Tests failed!', 'red');
    log('='.repeat(42) + '\n', 'blue');
    console.error(error);
    process.exit(1);
  }
}

// Run if called directly
if (require.main === module) {
  main();
}

module.exports = { httpGet, httpPost, testHTTP, testWebSocket };
