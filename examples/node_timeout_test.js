const assert = require('node:assert/strict');
const { test } = require('node:test');
const { EventEmitter } = require('node:events');
const { readFileSync } = require('node:fs');
const vm = require('node:vm');

function client() {
  let socket;
  const timers = new Map();
  class WebSocket extends EventEmitter {
    static OPEN = 1;
    constructor() {
      super();
      this.readyState = 0;
      this.terminated = false;
      socket = this;
    }
    send() {}
    close() { this.emit('close'); }
    terminate() { this.terminated = true; this.emit('close'); }
  }
  const module = { exports: {} };
  vm.runInNewContext(readFileSync(`${__dirname}/node_client.js`, 'utf8'), {
    module, Buffer, URL, console: { log() {} },
    require: (name) => name === 'ws' ? WebSocket : require(name),
    setTimeout: (callback, delay) => {
      const id = {};
      timers.set(id, { callback, delay });
      return id;
    },
    clearTimeout: (id) => timers.delete(id),
  });
  const result = module.exports.testWebSocket();
  return { socket, timers, result };
}

for (const readyState of [0, 1]) {
  test(`timeout rejects and terminates a socket in state ${readyState}`, { timeout: 1000 }, async () => {
    const { socket, timers, result } = client();
    socket.readyState = readyState;
    const rejection = assert.rejects(result, /timed out/);
    const [{ callback, delay }] = [...timers.values()];
    assert.equal(delay, 5000);
    callback();
    await rejection;
    assert.equal(socket.terminated, true);
    assert.equal(timers.size, 0);
  });
}

test('socket errors reject and cancel the deadline', { timeout: 1000 }, async () => {
  const { socket, timers, result } = client();
  const error = new Error('connection failed');
  const rejection = assert.rejects(result, (reason) => reason === error);
  socket.emit('error', error);
  await rejection;
  assert.equal(timers.size, 0);
});

test('successful completion cancels the deadline', { timeout: 1000 }, async () => {
  const { socket, timers, result } = client();
  for (const message of [
    'Backend echo: Hello from Node.js!',
    'Backend echo: ',
    `Backend echo: ${'A'.repeat(10000)}`,
    'Backend echo: Rapid message 5',
    Buffer.from([1, 2, 3, 4, 5]),
  ]) {
    socket.emit('message', Buffer.from(message));
  }
  await result;
  assert.equal(timers.size, 0);
  assert.equal(socket.terminated, false);
});
