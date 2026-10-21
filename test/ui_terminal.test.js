const test = require("node:test");
const assert = require("node:assert/strict");
const terminal = require("../priv/static/assets/js/terminal.js");

test("terminal input preserves Unicode and all binary byte values", () => {
  const text = "héllo 世界\x1b[200~paste\x1b[201~";
  assert.equal(Buffer.from(terminal.decode(terminal.input(text, false).data)).toString("utf8"), text);
  const bytes = Uint8Array.from({ length: 256 }, (_, i) => i);
  assert.deepEqual(terminal.decode(terminal.encode(bytes)), bytes);
  assert.deepEqual(terminal.decode(terminal.input(String.fromCharCode(...bytes), true).data), bytes);
});

test("terminal input bounds count UTF-8 bytes and preserve the exact allowed boundary", () => {
  assert.equal(terminal.input("é".repeat(4097), false), null);
  assert.equal(terminal.decode(terminal.input("é".repeat(4096), false).data).length, 8192);
  assert.equal(terminal.input("", false), null);
});

test("output receives credit only after xterm consumes exact raw bytes", () => {
  const bytes = Uint8Array.from([0, 255, 128, 27, 91, 72]);
  let consumed;
  const messages = [];
  terminal.consume({ write(data, done) { assert.deepEqual(data, bytes); consumed = done; } },
    { push(...args) { messages.push(args); } }, { sequence: 7, data: terminal.encode(bytes) });
  assert.deepEqual(messages, []);
  consumed();
  assert.deepEqual(messages, [["ack", { sequence: 7 }]]);
});

test("takeover, detached ownership and ended sessions remain explicit", () => {
  assert.match(terminal.label({ ownership: "takeover_requested" }), /explicit automation boundary/);
  assert.match(terminal.label({ ownership: "detached_human_owned" }), /retained while detached/);
  assert.match(terminal.label({ ownership: "human_owned", can_input: false }), /Another attachment/);
  assert.match(terminal.label({ ownership: "human_owned", can_input: true }), /You control/);
  assert.match(terminal.label({ state: "ended" }), /Session ended/);
});

test("channel closure exposes recovery and fences stale or intentional close callbacks", () => {
  const active = {};
  const state = {
    channel: active, connected: true, state: {can_input: true, ownership: "human_owned"},
    statusNode: {}, applyStatus(status) { this.state = status; }
  };
  terminal.Hook.channelLost.call(state, {});
  assert.equal(state.connected, true);
  terminal.Hook.channelLost.call(state, active);
  assert.equal(state.connected, false);
  assert.equal(state.state.can_input, false);
  assert.equal(state.state.ownership, "human_owned");
  assert.match(state.statusNode.textContent, /Reattach/);
  state.channel = null;
  state.connected = true;
  terminal.Hook.channelLost.call(state, active);
  assert.equal(state.connected, true);
});

test("an unconfirmed request detaches without retry and explains what to inspect", () => {
  let detached = 0;
  let message;
  const state = {state: {}, detach() { detached++; }, notice(text) { message = text; }};
  terminal.Hook.requestTimedOut.call(state);
  assert.equal(detached, 1);
  assert.match(message, /inspect the output before sending it again/);
  state.state.state = "ended";
  terminal.Hook.requestTimedOut.call(state);
  assert.equal(detached, 1);
});
