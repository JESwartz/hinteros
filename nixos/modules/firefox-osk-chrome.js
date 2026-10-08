// HinterOS on-screen keyboard, browser chrome part (appended to Firefox's mozilla.cfg; runs
// privileged in Firefox's main process). The OSK extension's content scripts only see fields in
// web pages; this reports Firefox's own fields (the address bar, find in page, search boxes in
// about: pages) the same way: {"focus": "text"|"password"|"none"} as one JSON line on the
// session daemon's osk.sock ($HINTEROS_OSK_SOCKET), on a connection of its own. The daemon
// keeps one state per connection (hinteros-daemon crates/hinteros-session/src/textfocus.rs).
// A trusted primary-button click that lands on the focused field also sends
// {"focus": ..., "clicked": true}, even if the focus did not change: the daemon shows the
// keyboard for a click into a field, not for focus that came by itself.
// Outside HinterOS (no socket) it does nothing.
(function hinterosOskChrome() {
  try {
    const S =
      typeof Services !== "undefined"
        ? Services
        : ChromeUtils.importESModule("resource://gre/modules/Services.sys.mjs").Services;
    const env = Cc["@mozilla.org/process/environment;1"].getService(Ci.nsIEnvironment);
    let socketPath = env.get("HINTEROS_OSK_SOCKET");
    if (!socketPath && env.get("XDG_RUNTIME_DIR")) {
      socketPath = env.get("XDG_RUNTIME_DIR") + "/hinteros/osk.sock";
    }
    if (!socketPath) {
      return;
    }
    const log = (msg) => S.console.logStringMessage("hinteros-osk (chrome): " + msg);

    // <input> types that take typed text (as in the extension's content.js).
    const TEXT_TYPES = new Set(["", "text", "search", "email", "url", "tel", "number", "password"]);

    function kindOf(el) {
      if (!el || el.disabled || el.readOnly) {
        return "none";
      }
      const tag = el.localName;
      if (tag === "textarea") {
        return "text";
      }
      if (tag === "input") {
        const type = (el.getAttribute("type") || "").toLowerCase();
        if (!TEXT_TYPES.has(type)) {
          return "none";
        }
        return type === "password" ? "password" : "text";
      }
      return el.isContentEditable ? "text" : "none";
    }

    // The focused element of the active Firefox window, if it is in the parent process. A web
    // page in a content process shows up as its <browser> element ("none"): the extension
    // reports those.
    function focusedElement() {
      let el = S.focus.focusedElement;
      while (el && el.shadowRoot && el.shadowRoot.activeElement) {
        el = el.shadowRoot.activeElement;
      }
      return el;
    }
    function current() {
      return kindOf(focusedElement());
    }

    let out = null;
    let sent = "none";

    function connect() {
      const file = Cc["@mozilla.org/file/local;1"].createInstance(Ci.nsIFile);
      file.initWithPath(socketPath);
      if (!file.exists()) {
        throw new Error(socketPath + " does not exist");
      }
      const sts = Cc["@mozilla.org/network/socket-transport-service;1"].getService(
        Ci.nsISocketTransportService
      );
      // Buffered and non-blocking: writes never stall the browser; the transport connects
      // and sends in the background.
      return sts.createUnixDomainTransport(file).openOutputStream(0, 0, 0);
    }

    function send(focus, clicked = false) {
      const msg = { focus, client: "hinteros-firefox-chrome" };
      if (clicked) {
        msg.clicked = true;
      }
      const line = JSON.stringify(msg) + "\n";
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          if (!out) {
            out = connect();
          }
          out.write(line, line.length);
          return true;
        } catch (e) {
          try {
            out && out.close();
          } catch (_) {}
          out = null;
          if (attempt === 1) {
            log("cannot reach the session daemon: " + e);
          }
        }
      }
      return false;
    }

    let pending = false;
    function report() {
      pending = false;
      const focus = current();
      if (focus !== sent && send(focus)) {
        sent = focus;
      }
    }
    // Look once focus has settled (focusout then focusin when moving between fields).
    function settle() {
      if (!pending) {
        pending = true;
        S.tm.dispatchToMainThread(report);
      }
    }

    // A click into the focused field (the address bar, whether it just got focus or had it).
    // "click" comes after the press moved focus, and only for the primary button.
    function clicked(event) {
      if (!event.isTrusted) {
        return;
      }
      const el = focusedElement();
      const focus = kindOf(el);
      if (focus !== "none" && event.composedPath().includes(el) && send(focus, true)) {
        sent = focus;
      }
    }

    const EVENTS = ["focusin", "focusout", "focus", "blur", "activate", "deactivate"];
    const watched = new WeakSet();
    function watch(win) {
      if (watched.has(win)) {
        return;
      }
      watched.add(win);
      for (const type of EVENTS) {
        win.addEventListener(type, settle, true);
      }
      win.addEventListener("unload", settle);
      win.addEventListener("click", clicked, true);
      settle();
    }

    S.obs.addObserver((win) => watch(win), "browser-delayed-startup-finished");
    // Windows open before this ran (normally none: autoconfig runs at startup).
    for (const win of S.wm.getEnumerator("navigator:browser")) {
      watch(win);
    }
  } catch (e) {
    const msg = "hinteros-osk (chrome): " + e;
    typeof console !== "undefined" ? console.error(msg) : dump(msg + "\n");
  }
})();
