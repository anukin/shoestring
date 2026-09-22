// For Phoenix.HTML support, including form and button helpers
// copy the following scripts into your javascript bundle:
// * deps/phoenix_html/priv/static/phoenix_html.js

// For Phoenix.Channels support, copy the following scripts
// into your javascript bundle:
// * deps/phoenix/priv/static/phoenix.js

// For Phoenix.LiveView support, copy the following scripts
// into your javascript bundle:
// * deps/phoenix_live_view/priv/static/phoenix_live_view.js

(function (root) {
  "use strict";

  // Relative-time enhancement for `ShoestringWeb.TimeDisplay.countdown/1`.
  //
  // The server already rendered a correct phrase and the exact timestamp, so
  // this is progressive enhancement only: with JavaScript off the page still
  // states both. Nothing here talks to the server, and nothing here affects
  // any goal, lease or wake-up lifecycle -- it rewrites text, and that is all.
  //
  // The formatting rules mirror `ShoestringWeb.TimeDisplay.humanize/2` exactly
  // so a phrase does not change shape the moment the script loads. Both are
  // covered by tests (`test/shoestring_web/live/time_display_test.exs` and
  // `test/ui_countdown.test.js`); change them together.

  var MINUTE = 60;
  var HOUR = 3600;
  var DAY = 86400;

  var SUFFIX = { second: "s", minute: "m", hour: "h", day: "d" };
  var WORD = {
    second: ["second", "seconds"],
    minute: ["minute", "minutes"],
    hour: ["hour", "hours"],
    day: ["day", "days"]
  };

  function parts(magnitude) {
    if (magnitude < MINUTE) {
      return [["second", magnitude]];
    }
    if (magnitude < HOUR) {
      return [
        ["minute", Math.floor(magnitude / MINUTE)],
        ["second", magnitude % MINUTE]
      ];
    }
    if (magnitude < DAY) {
      return [
        ["hour", Math.floor(magnitude / HOUR)],
        ["minute", Math.floor(magnitude / MINUTE) % MINUTE]
      ];
    }
    return [
      ["day", Math.floor(magnitude / DAY)],
      ["hour", Math.floor(magnitude / HOUR) % 24]
    ];
  }

  // Only the first unit keeps its natural width, so "3h 09m" never narrows
  // to "3h 9m" while the phrase is ticking.
  function pad(value, leading) {
    return !leading && value < 10 ? "0" + value : String(value);
  }

  function decorate(direction, body) {
    return direction === "future" ? "in " + body : body + " ago";
  }

  // Takes epoch milliseconds and floors the difference -- the whole
  // difference, not each operand -- so it agrees with
  // `DateTime.diff(at, now, :second)`, which rounds toward negative infinity.
  // A target 900 ms in the past is therefore "1s ago" on both sides, not "now"
  // on one and "1s ago" on the other.
  function humanize(atMs, nowMs) {
    var seconds = Math.floor((atMs - nowMs) / 1000);
    var magnitude = Math.abs(seconds);

    if (magnitude < 1) {
      return { direction: "now", text: "now", label: "now" };
    }

    var direction = seconds > 0 ? "future" : "past";
    var units = parts(magnitude);

    var text = units
      .map(function (part, index) {
        return pad(part[1], index === 0) + SUFFIX[part[0]];
      })
      .join(" ");

    var label = units
      .map(function (part) {
        return part[1] + " " + WORD[part[0]][part[1] === 1 ? 0 : 1];
      })
      .join(" ");

    return {
      direction: direction,
      text: decorate(direction, text),
      label: decorate(direction, label)
    };
  }

  function refresh(el, nowMs) {
    var at = Date.parse(el.getAttribute("data-countdown-to"));

    // An unparseable target leaves the server-rendered phrase untouched
    // rather than replacing it with a guess.
    if (isNaN(at)) {
      return;
    }

    var humanized = humanize(at, nowMs);

    if (el.textContent.trim() !== humanized.text) {
      el.textContent = humanized.text;
    }

    el.setAttribute("aria-label", humanized.label);
    el.setAttribute("data-countdown-direction", humanized.direction);
  }

  function refreshAll(doc) {
    var nowMs = Date.now();
    var elements = doc.querySelectorAll("[data-countdown-to]");

    for (var i = 0; i < elements.length; i++) {
      refresh(elements[i], nowMs);
    }

    return elements.length;
  }

  function start(doc, win) {
    refreshAll(doc);
    win.setInterval(function () {
      refreshAll(doc);
    }, 1000);
  }

  if (typeof module !== "undefined" && module.exports) {
    module.exports = { humanize: humanize, refresh: refresh, refreshAll: refreshAll };
  }

  if (typeof document === "undefined") {
    return;
  }

  start(document, root);

  // Handle flash close
  // (you can safely remove this if you don't use the default flash component)
  document.querySelectorAll("[role=alert][data-flash]").forEach(function (el) {
    el.addEventListener("click", function () {
      el.setAttribute("hidden", "");
    });
  });
})(typeof globalThis !== "undefined" ? globalThis : this);
