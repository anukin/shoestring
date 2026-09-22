"use strict";

// Regression tests for the countdown enhancer in
// priv/static/assets/js/app.js.
//
// The enhancer is progressive enhancement over a phrase the server already
// rendered, so the thing that must not drift is the phrase format itself.
// These tests assert the browser implementation against
// test/fixtures/countdown_phrases.json -- the same table
// ShoestringWeb.TimeDisplayTest asserts the Elixir implementation against.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const countdown = require(path.join(root, "priv/static/assets/js/app.js"));
const fixture = JSON.parse(
  fs.readFileSync(path.join(root, "test/fixtures/countdown_phrases.json"), "utf8")
);

const NOW_MS = Date.parse("2026-09-07T12:00:00.000Z");

test("app.js loads outside a browser without touching the DOM", () => {
  assert.equal(typeof countdown.humanize, "function");
  assert.equal(typeof countdown.refresh, "function");
  assert.equal(typeof countdown.refreshAll, "function");
});

test("every phrase in the shared parity table round-trips", () => {
  for (const kase of fixture.cases) {
    const at = NOW_MS + kase.offset_seconds * 1000;

    assert.deepEqual(
      countdown.humanize(at, NOW_MS),
      { direction: kase.direction, text: kase.text, label: kase.label },
      `offset ${kase.offset_seconds}s`
    );
  }
});

test("sub-second distances floor, matching DateTime.diff/3 on the server", () => {
  assert.equal(countdown.humanize(NOW_MS + 900, NOW_MS).text, "now");
  assert.equal(countdown.humanize(NOW_MS - 900, NOW_MS).text, "1s ago");
});

test("trailing units stay zero padded so the phrase keeps its width", () => {
  const widths = new Set(
    [11100, 11160, 11220, 11280].map(
      (offset) => countdown.humanize(NOW_MS + offset * 1000, NOW_MS).text.length
    )
  );

  assert.equal(widths.size, 1);
});

test("refresh rewrites the phrase, the label and the direction", () => {
  const el = fakeElement("2026-09-07T12:04:32.000000Z", "in 4m 32s");

  countdown.refresh(el, NOW_MS + 4 * 60 * 1000);

  assert.equal(el.textContent, "in 32s");
  assert.equal(el.attributes["aria-label"], "in 32 seconds");
  assert.equal(el.attributes["data-countdown-direction"], "future");
});

test("an unreadable target leaves the server-rendered phrase alone", () => {
  const el = fakeElement("whenever capacity frees up", "in 4m 32s");

  countdown.refresh(el, NOW_MS);

  assert.equal(el.textContent, "in 4m 32s");
  assert.equal(el.attributes["aria-label"], undefined);
});

test("refreshAll updates every countdown on the page and reports the count", () => {
  // refreshAll reads the real clock, so the targets are anchored to it: an
  // hour out and an hour back, with five seconds of slack so the phrase
  // cannot flip while the test runs.
  const offset = (3600 + 5) * 1000;
  const ahead = fakeElement(new Date(Date.now() + offset).toISOString(), "stale");
  const behind = fakeElement(new Date(Date.now() - offset).toISOString(), "stale");
  const doc = { querySelectorAll: () => [ahead, behind] };

  assert.equal(countdown.refreshAll(doc), 2);
  assert.equal(ahead.attributes["data-countdown-direction"], "future");
  assert.equal(behind.attributes["data-countdown-direction"], "past");
  assert.equal(ahead.textContent, "in 1h 00m");
  assert.equal(behind.textContent, "1h 00m ago");
});

function fakeElement(target, text) {
  return {
    textContent: text,
    attributes: { "data-countdown-to": target },
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(this.attributes, name)
        ? this.attributes[name]
        : null;
    },
    setAttribute(name, value) {
      this.attributes[name] = value;
    }
  };
}
