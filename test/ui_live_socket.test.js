"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

test("the browser connects LiveView with its CSRF token", () => {
  const calls = [];
  const Socket = function Socket() {};
  const context = {
    document: {
      querySelector: () => ({getAttribute: () => "synthetic-csrf"}),
      querySelectorAll: () => []
    },
    Date,
    setInterval: () => {},
    Phoenix: {Socket},
    LiveView: {LiveSocket: class {
      constructor(url, socket, options) { calls.push({url, socket, options}); }
      connect() { calls.push("connected"); }
    }}
  };
  const source = process.env.SHOESTRING_UI_SOURCE || path.join(__dirname, "../priv/static/assets/js/app.js");
  vm.runInNewContext(fs.readFileSync(source, "utf8"), context);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].url, "/live");
  assert.equal(calls[0].socket, Socket);
  assert.equal(calls[0].options.params._csrf_token, "synthetic-csrf");
  assert.equal(calls[1], "connected");
});
