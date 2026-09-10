const assert = require('node:assert/strict');
const { test } = require('node:test');
const { EventEmitter } = require('node:events');
const { readFileSync } = require('node:fs');
const vm = require('node:vm');

function check(messages) {
  let socket;
  class WebSocket extends EventEmitter {
    constructor() { super(); socket = this; }
    send() {}
    close() { this.emit('close'); }
  }
  const module = { exports: {} };
  vm.runInNewContext(readFileSync(`${__dirname}/node_client.js`, 'utf8'), {
    module, Buffer, URL, console: { log() {} },
    require: (name) => name === 'ws' ? WebSocket : require(name),
    setTimeout() {}, clearTimeout() {},
  });
  const result = module.exports.testWebSocket();
  for (const [data, binary = false] of messages) {
    socket.emit('message', Buffer.from(data), binary);
  }
  socket.close();
  return result;
}

const textChecks = [
  ['Backend echo: Hello from Node.js!'],
  ['Backend echo: '],
  [`Backend echo: ${'A'.repeat(10000)}`],
  ...Array.from({ length: 5 }, (_, i) => [`Backend echo: Rapid message ${i + 1}`]),
];
const binary = Buffer.from([1, 2, 3, 4, 5]);

test('four checks without binary do not pass', { timeout: 1000 }, async () => {
  await assert.rejects(check(textChecks), /Only 4\/5/);
});

test('text frames containing binary-looking bytes do not pass', { timeout: 1000 }, async () => {
  await assert.rejects(check([...textChecks, [binary, false]]), /Only 4\/5/);
});

test('incorrect binary payload does not pass', { timeout: 1000 }, async () => {
  await assert.rejects(check([...textChecks, [Buffer.from([5, 4, 3, 2, 1]), true]]), /Only 4\/5/);
});

test('all five distinct checks pass', { timeout: 1000 }, async () => {
  await check([...textChecks, [binary, true]]);
});

test('duplicate replies cannot substitute for a missing check', { timeout: 1000 }, async () => {
  await assert.rejects(check([...Array(5).fill(textChecks[0]), [binary, true]]), /Only 2\/5/);
});

test('receiving rapid message 5 alone does not prove delivery of all five', { timeout: 1000 }, async () => {
  await assert.rejects(check([...textChecks.slice(0, 3), textChecks[7], [binary, true]]), /Only 4\/5/);
});
