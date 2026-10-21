(function (root) {
  "use strict";
  var MAX_INPUT = 8192;

  function encode(bytes) {
    var text = "";
    for (var i = 0; i < bytes.length; i++) text += String.fromCharCode(bytes[i]);
    return root.btoa ? root.btoa(text) : Buffer.from(bytes).toString("base64");
  }

  function decode(data) {
    if (!root.atob) return new Uint8Array(Buffer.from(data, "base64"));
    var text = root.atob(data);
    return Uint8Array.from(text, function (ch) { return ch.charCodeAt(0); });
  }

  function input(data, binary) {
    var bytes = binary ? Uint8Array.from(data, function (ch) { return ch.charCodeAt(0); }) : new TextEncoder().encode(data);
    if (bytes.length < 1 || bytes.length > MAX_INPUT) return null;
    return { data: encode(bytes) };
  }

  function label(status) {
    if (status.state === "ended") return "Session ended. Open the run details for its outcome and checkpoint.";
    if (status.ownership === "takeover_requested") return "Control requested. Waiting for an explicit automation boundary.";
    if (status.ownership === "detached_human_owned") return "Human control is retained while detached. In the owning browser, choose Request control, then Release control to return input to automation.";
    if (status.can_input) return "You control terminal input. Release control before automation can send again.";
    if (status.ownership === "human_owned") return "Another attachment controls terminal input. You are viewing output.";
    return "Viewing output. Request control to type; automation currently owns input.";
  }

  function consume(terminal, channel, frame) {
    var bytes = decode(frame.data);
    if (bytes.length > 65536 || !Number.isSafeInteger(frame.sequence) || frame.sequence < 0) throw new Error("invalid_terminal_output");
    terminal.write(bytes, function () { channel.push("ack", { sequence: frame.sequence }); });
  }

  var Hook = {
    mounted: function () {
      var self = this;
      this.statusNode = this.el.querySelector("#terminal-status");
      this.noticeNode = this.el.querySelector("#terminal-notice");
      this.buttons = Array.from(this.el.querySelectorAll("[data-terminal-action]"));
      this.tokens = { socket_token: this.el.dataset.socketToken, capability: this.el.dataset.capability };
      this.state = { can_input: false };
      this.connected = false;
      this.disposables = [];
      this.buttonListeners = [];
      if (!root.Phoenix || !root.Terminal || !root.FitAddon) {
        this.notice("Terminal assets could not load. Reload this page to attach.");
        return;
      }
      this.terminal = new root.Terminal({
        scrollback: 1000, screenReaderMode: true, allowProposedApi: false,
        fontFamily: "ui-monospace, SFMono-Regular, Menlo, Consolas, monospace",
        fontSize: 14, lineHeight: 1.25, cursorBlink: false,
        theme: { background: "#172821", foreground: "#f1f6f1", cursor: "#b0d3a9", selectionBackground: "#395849" },
        linkHandler: { activate: function () {} }
      });
      this.fit = new root.FitAddon.FitAddon();
      this.terminal.loadAddon(this.fit);
      this.terminal.open(this.el.querySelector("#terminal-screen"));
      this.disposables.push(this.terminal.onData(function (data) { self.sendInput(data, false); }));
      this.disposables.push(this.terminal.onBinary(function (data) { self.sendInput(data, true); }));
      this.disposables.push(this.terminal.onResize(function (size) {
        if (self.connected && self.state.can_input) self.channel.push("resize", { rows: size.rows, cols: size.cols });
      }));
      this.buttons.forEach(function (button) {
        var listener = function () { self.act(button.dataset.terminalAction); };
        button.addEventListener("click", listener);
        self.buttonListeners.push([button, listener]);
      });
      this.resizeObserver = new ResizeObserver(function () { self.fit.fit(); });
      this.resizeObserver.observe(this.el.querySelector("#terminal-screen"));
      this.socket = new root.Phoenix.Socket("/terminal/socket", {
        params: function () {
          return { token: self.tokens.socket_token, _csrf_token: document.querySelector("meta[name='csrf-token']").content };
        }
      });
      this.socket.onError(function () {
        self.connected = false;
        self.applyStatus({ can_input: false, ownership: self.state.ownership });
        self.statusNode.textContent = "Connection lost. Reconnecting without releasing input ownership…";
        self.refreshTokens(function () {});
      });
      this.socket.connect();
      this.attach();
    },

    refreshTokens: function (done) {
      var self = this;
      this.pushEvent("refresh_terminal_tokens", {}, function (tokens) {
        if (!tokens.error) { self.tokens = tokens; done(); }
        else self.notice("This terminal is unavailable. Open the run details.");
      });
    },

    attach: function () {
      var self = this;
      this.channel = this.socket.channel("terminal:" + this.el.dataset.runId, function () { return { capability: self.tokens.capability }; });
      var channel = this.channel;
      channel.onClose(function () { self.channelLost(channel); });
      channel.onError(function () { self.channelLost(channel); });
      this.channel.on("output", function (frame) {
        if (self.channel !== channel) return;
        try { consume(self.terminal, channel, frame); }
        catch (_error) { self.detach(); self.notice("Invalid terminal output. Detached to keep the browser bounded."); }
      });
      this.channel.on("status", function (status) { if (self.channel === channel) self.applyStatus(status); });
      this.channel.on("detached", function () {
        if (self.channel !== channel) return;
        self.connected = false;
        self.applyStatus({ can_input: false, ownership: self.state.ownership });
        self.notice("Output exceeded this attachment's buffer. Reattach for recent scrollback; the run is still supervised.");
      });
      this.channel.join().receive("ok", function (snapshot) {
        if (self.channel !== channel) return;
        self.connected = true;
        self.terminal.reset();
        consume(self.terminal, self.channel, snapshot);
        self.applyStatus(snapshot);
        if (snapshot.gap) self.notice("Reattached with recent output only; older scrollback is unavailable.");
        self.fit.fit();
      }).receive("error", function () {
        if (self.channel !== channel) return;
        self.connected = false;
        self.applyStatus({ can_input: false });
        self.notice("Could not attach. Reattach to refresh access, or open the run details if the session has ended.");
      }).receive("timeout", function () { self.channelLost(channel); });
    },

    sendInput: function (data, binary) {
      if (!this.connected || !this.state.can_input) return;
      var message = input(data, binary);
      if (!message) { this.notice("Send at most 8 KiB at a time. This input was not sent."); return; }
      var self = this;
      var channel = this.channel;
      channel.push("input", message).receive("error", function () { if (self.channel === channel) self.notice("Input was refused. Check that this attachment still owns control."); })
        .receive("timeout", function () { self.requestTimedOut(channel); });
    },

    act: function (action) {
      var self = this;
      if (action === "detach") { this.detach(); return; }
      if (action === "reattach") {
        var previous = this.channel;
        this.channel = null;
        if (previous) previous.leave();
        this.refreshTokens(function () { self.attach(); });
        return;
      }
      if (!this.connected) return;
      var channel = this.channel;
      channel.push(action, {}).receive("ok", function (status) {
        if (self.channel !== channel) return;
        if (status && status.ownership) self.applyStatus(status);
        if (action === "takeover" && self.state.can_input) {
          self.fit.fit();
          self.channel.push("resize", { rows: self.terminal.rows, cols: self.terminal.cols });
          self.terminal.focus();
        }
      }).receive("error", function () { self.notice("The action was refused. Check ownership or open the run details."); })
        .receive("timeout", function () { self.requestTimedOut(channel); });
    },

    applyStatus: function (status) {
      this.state = status;
      var self = this;
      this.statusNode.textContent = label(status);
      this.buttons.forEach(function (button) {
        var action = button.dataset.terminalAction;
        var needsOwner = action === "release" || action === "interrupt";
        button.disabled = !self.connected || status.state === "ended" || (needsOwner && !status.can_input) || (action === "takeover" && status.can_input);
        if (action === "reattach") { button.hidden = self.connected || status.state === "ended"; button.disabled = status.state === "ended"; }
        if (action === "detach") button.hidden = !self.connected;
      });
      if (this.terminal) this.terminal.options.disableStdin = !status.can_input;
    },

    detach: function () {
      var previous = this.channel;
      this.channel = null;
      if (previous) previous.leave();
      this.connected = false;
      this.applyStatus({ can_input: false, ownership: this.state.can_input ? "detached_human_owned" : this.state.ownership });
      this.statusNode.textContent = this.state.ownership === "detached_human_owned"
        ? "Detached. The run continues; human input ownership is retained until explicitly released."
        : "Detached from output. The run continues with its current input owner.";
    },

    channelLost: function (channel) {
      if (this.channel !== channel || this.disposed || this.state.state === "ended") return;
      this.connected = false;
      this.applyStatus({ can_input: false, ownership: this.state.ownership });
      this.statusNode.textContent = "Terminal connection closed. Reattach to view output; input ownership has not been released.";
    },

    requestTimedOut: function (channel) {
      if ((channel && this.channel !== channel) || this.disposed || this.state.state === "ended") return;
      this.detach();
      this.notice("The terminal did not confirm the action. Reattach and inspect the output before sending it again.");
    },

    notice: function (text) { this.noticeNode.textContent = text; this.noticeNode.hidden = false; },

    destroyed: function () {
      this.disposed = true;
      if (this.channel) this.channel.leave();
      if (this.socket) this.socket.disconnect();
      if (this.resizeObserver) this.resizeObserver.disconnect();
      (this.disposables || []).forEach(function (item) { item.dispose(); });
      (this.buttonListeners || []).forEach(function (item) { item[0].removeEventListener("click", item[1]); });
      if (this.terminal) this.terminal.dispose();
    }
  };
  var exports = { Hook: Hook, encode: encode, decode: decode, input: input, label: label, consume: consume };
  root.ShoestringTerminal = exports;
  if (typeof module !== "undefined" && module.exports) module.exports = exports;
})(typeof globalThis !== "undefined" ? globalThis : this);
