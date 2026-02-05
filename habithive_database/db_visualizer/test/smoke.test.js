'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

/**
 * This is a minimal smoke test that ensures the db_visualizer entrypoint
 * can be required/imported without immediately throwing.
 *
 * Notes:
 * - We intentionally do NOT start the HTTP server in tests.
 * - We only verify that loading the module does not crash due to syntax errors
 *   or missing dependencies.
 */
test('smoke: server.js can be required', () => {
  const serverPath = path.join(__dirname, '..', 'server.js');

  assert.doesNotThrow(() => {
    // eslint-disable-next-line global-require, import/no-dynamic-require
    require(serverPath);
  });
});
