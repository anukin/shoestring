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

function accessibilityClient() {
  const handlers = {};
  const elements = {};
  let hooks;
  const context = {
    document: {
      querySelector: () => ({getAttribute: () => "synthetic-csrf"}),
      querySelectorAll: () => [],
      getElementById: (id) => elements[id],
      addEventListener: (name, callback) => { handlers[name] = callback; }
    },
    addEventListener: (name, callback) => { handlers[name] = callback; },
    Phoenix: {Socket: function Socket() {}},
    LiveView: {LiveSocket: class {
      constructor(_url, _socket, options) { hooks = options.hooks; }
      connect() {}
    }},
    Date,
    setInterval: () => {}
  };
  const source = process.env.SHOESTRING_UI_SOURCE || path.join(__dirname, "../priv/static/assets/js/app.js");
  vm.runInNewContext(fs.readFileSync(source, "utf8"), context);
  return {handlers, elements, hooks};
}

test("a patched form transfers focus only to the requested existing destination", () => {
  const {handlers, elements} = accessibilityClient();
  let focused = 0;
  assert.equal(typeof handlers["phx:ss:focus"], "function", "form focus transfers must be handled");
  elements["agent-errors"] = {focus: () => { focused++; }};
  handlers["phx:ss:focus"]({detail: {id: "agent-errors"}});
  handlers["phx:ss:focus"]({detail: {id: "removed-role"}});
  assert.equal(focused, 1);
});

test("dismissing a flash restores focus, while navigation never steals it", () => {
  const {elements, hooks} = accessibilityClient();
  assert.equal(typeof hooks.FlashDismiss, "object", "dynamic flash buttons need a focus hook");
  let focused = 0;
  let click;
  let removed = 0;
  elements["product-main"] = {focus: () => { focused++; }};
  const el = {
    addEventListener: (name, callback) => { assert.equal(name, "click"); click = callback; },
    removeEventListener: (name, callback) => {
      assert.equal(name, "click"); assert.equal(callback, click); removed++;
    }
  };
  const hook = {el};
  hooks.FlashDismiss.mounted.call(hook);
  hooks.FlashDismiss.destroyed.call(hook);
  assert.equal(focused, 0);
  hooks.FlashDismiss.mounted.call(hook);
  click();
  hooks.FlashDismiss.destroyed.call(hook);
  assert.equal(focused, 1);
  assert.equal(removed, 2);
});
