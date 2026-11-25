(function () {
  "use strict";

  const B = window.Backend;
  const views = new Map();
  const FONT = '"JetBrains Mono", ui-monospace, Menlo, monospace';

  function cssVar(name) {
    const scr = document.getElementById("scr");
    return getComputedStyle(scr).getPropertyValue(name).trim();
  }
  function theme() {
    const bg = cssVar("--term-bg") || "#22212B";
    return {
      background: bg, foreground: cssVar("--term-ink") || "#E4E2EE", cursor: cssVar("--term-ink") || "#E4E2EE",
      cursorAccent: bg, selectionBackground: "rgba(159,180,255,.35)"
    };
  }
  function decode(b64) {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }

  /// Keys the app keeps for itself even while a terminal has the keyboard.
  function isAppShortcut(e) {
    if (!e.metaKey || e.altKey || e.ctrlKey) return false;
    return /^[jJnN0-9,]$/.test(e.key);
  }

  function create(key, sid, size) {
    const host = document.createElement("div");
    host.className = "xterm-host";
    host.dataset.key = key;
    const term = new window.Terminal({
      fontFamily: FONT, fontSize: size === "small" ? 11 : 12.5, lineHeight: 1.15, cursorBlink: true, scrollback: 2000,
      macOptionIsMeta: false, macOptionClickForcesSelection: true, allowTransparency: false, theme: theme(), drawBoldTextInBrightColors: true
    });
    const fit = new window.FitAddon.FitAddon();
    term.loadAddon(fit);
    term.attachCustomKeyEventHandler(e => !isAppShortcut(e));
    const view = { key, sid, host, term, fit, pty: null, opened: false, disposed: false, retries: 0, pending: [] };
    term.onData(d => { if (view.pty != null) B.ptyInput(view.pty, d); else view.pending.push(d); });
    term.onBinary(d => { if (view.pty != null) B.ptyBinary(view.pty, d); });
    term.onResize(({ cols, rows }) => { if (view.pty != null) B.ptyResize(view.pty, cols, rows); });
    view.observer = new ResizeObserver(() => refit(view));
    views.set(key, view);
    return view;
  }

  function refit(view) {
    if (view.disposed || !view.opened || !view.host.isConnected || !view.host.clientWidth) return;
    try { view.fit.fit(); } catch (err) { if (!(err instanceof TypeError)) throw err; }
  }

  function connect(view) {
    const cols = Math.max(view.term.cols, 20), rows = Math.max(view.term.rows, 5);
    B.ptyOpen(view.sid, cols, rows, {
      data: b64 => { if (!view.disposed) view.term.write(decode(b64)); },
      exit: () => {
        if (view.disposed) return;
        view.pty = null;
        if (B.byId(view.sid) && view.retries < 3) {
          view.retries++;
          setTimeout(() => { if (!view.disposed) connect(view); }, 600);
        } else {
          view.term.write("\r\n\x1b[2m[detached]\x1b[0m\r\n");
        }
      }
    }).then(pty => {
      if (view.disposed) { B.ptyClose(pty); return; }
      view.pty = pty;
      view.retries = 0;
      B.ptyResize(pty, view.term.cols, view.term.rows);
      view.pending.splice(0).forEach(d => B.ptyInput(pty, d));
    }).catch(err => {
      view.term.write(`\r\n\x1b[2m[could not attach: ${err && err.message ? err.message : err}]\x1b[0m\r\n`);
    });
  }

  const T = {
    /// Puts the live terminal for `key` into `slot`, making and attaching it the first time.
    mount(slot, key, sid, size) {
      if (!slot) return null;
      let view = views.get(key);
      if (view && view.sid !== sid) { T.dispose(key); view = null; }
      if (!view) view = create(key, sid, size);
      if (view.host.parentNode !== slot) slot.appendChild(view.host);
      if (!view.opened) {
        view.term.open(view.host);
        view.opened = true;
        view.observer.observe(view.host);
        refit(view);
        connect(view);
      } else {
        requestAnimationFrame(() => refit(view));
      }
      return view;
    },
    /// Detaches and drops every terminal whose key is not in `keep`.
    prune(keep) {
      for (const key of Array.from(views.keys())) if (!keep.has(key)) T.dispose(key);
    },
    dispose(key) {
      const view = views.get(key);
      if (!view) return;
      view.disposed = true;
      views.delete(key);
      view.observer.disconnect();
      if (view.pty != null) B.ptyClose(view.pty);
      view.term.dispose();
      view.host.remove();
    },
    focus(key) {
      const view = views.get(key);
      if (view) view.term.focus();
      return !!view;
    },
    has(key) { return views.has(key); },
    applyTheme() {
      const t = theme();
      views.forEach(v => { v.term.options.theme = t; });
    },
    refitAll() {
      views.forEach(v => {
        v.term.options.fontFamily = FONT;
        refit(v);
      });
    },
    keys() { return Array.from(views.keys()); },
    view(key) { return views.get(key); }
  };

  if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => T.refitAll());
  window.Terminals = T;
})();
