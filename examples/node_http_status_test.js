const assert = require('node:assert/strict');
const { test } = require('node:test');
const { EventEmitter } = require('node:events');
const { readFileSync } = require('node:fs');
const vm = require('node:vm');

function check(failingPath) {
  function respond(path, callback) {
    const response = new EventEmitter();
    response.statusCode = path === failingPath ? 502 : path === '/nonexistent' ? 404 : 200;
    response.headers = {};
    queueMicrotask(() => {
      callback(response);
      response.emit('data', JSON.stringify({ echo: 'hello', headers: {} }));
      response.emit('end');
    });
    return new EventEmitter();
  }
  const http = {
    get: (url, callback) => respond(url.pathname, callback),
    request: (options, callback) => {
      const request = new EventEmitter();
      request.write = () => {};
      request.end = () => respond(options.path, callback);
      return request;
    },
  };
  const module = { exports: {} };
  vm.runInNewContext(readFileSync(`${__dirname}/node_client.js`, 'utf8'), {
    module, Buffer, URL, console: { log() {} },
    require: (name) => name === 'http' ? http : class WebSocket {},
  });
  return module.exports.testHTTP();
}

for (const path of ['/hello', '/api/status', '/echo', '/headers', '/nonexistent']) {
  test(`unexpected status at ${path} fails the HTTP check`, async () => {
    await assert.rejects(check(path), /Expected HTTP .*received 502/);
  });
}

test('expected 200 responses and intentional 404 pass', async () => {
  await check();
});
