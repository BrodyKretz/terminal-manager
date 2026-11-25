(function () {
  "use strict";

  const TAG_COLORS = ["#7AA2F7", "#F7768E", "#9ECE6A", "#E0AF68", "#BB9AF7", "#7DCFFF", "#FF9E64", "#73DACA", "#C0CAF5", "#F4B8E4"];
  const listeners = [];
  const ptyHandlers = new Map();

  const B = {
    sessions: [], closed: [], events: [], seq: 0, home: "", modes: [], defaultMode: "Auto", prefs: {}, ready: false,
    on(fn) { listeners.push(fn); },
    byId(id) { return B.sessions.find(s => s.id === id); }
  };
  const notify = (kind, data) => listeners.forEach(fn => fn(kind, data));

  function hashTag(id) {
    let h = 0;
    for (const c of String(id)) h = (h * 31 + c.charCodeAt(0)) >>> 0;
    return TAG_COLORS[h % TAG_COLORS.length];
  }
  function decorate(s) {
    s.tag = hashTag(s.id);
    s.files = s.files || [];
    return s;
  }

  function post(op, args) {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tm;
    if (!handler) return Promise.reject(new Error("no-native"));
    return handler.postMessage(Object.assign({ op }, args || {}));
  }
  B.call = post;

  function setSessions(list, closed) {
    B.sessions = (list || []).map(decorate);
    if (closed) B.closed = closed;
  }
  function upsertEvents(events, removed) {
    if (removed && removed.length) {
      const gone = new Set(removed);
      B.events = B.events.filter(e => !gone.has(e.seq));
    }
    const fresh = [];
    for (const e of events || []) {
      const i = B.events.findIndex(x => x.seq === e.seq);
      if (i >= 0) B.events[i] = e;
      else { B.events.push(e); fresh.push(e); }
      if (e.seq > B.seq) B.seq = e.seq;
    }
    if (B.events.length > 900) B.events.splice(0, B.events.length - 900);
    return fresh;
  }

  window.TMNative = {
    receive(evt) {
      switch (evt.type) {
        case "sessions": setSessions(evt.sessions, evt.closed); notify("change"); break;
        case "feed": upsertEvents(evt.events, evt.removed).forEach(e => notify("event", e)); notify("change"); break;
        case "status": { const s = B.byId(evt.sid); if (s) notify("status", { s, from: evt.from, to: evt.to }); break; }
        case "pty": { const h = ptyHandlers.get(evt.pty); if (h) h.data(evt.data); break; }
        case "ptyExit": { const h = ptyHandlers.get(evt.pty); if (h) { ptyHandlers.delete(evt.pty); h.exit(); } break; }
        case "prefs": B.prefs = evt.prefs || {}; notify("change"); break;
        case "menu": notify("menu", evt); break;
        case "toast": notify("toast", evt); break;
        case "window": notify("window", evt); break;
      }
    }
  };

  B.start = async function () {
    const hello = await post("hello");
    B.home = hello.home || "";
    B.modes = hello.permissionModes || [];
    B.defaultMode = hello.defaultMode || (B.modes[0] && B.modes[0].label) || "Auto";
    B.prefs = hello.prefs || {};
    setSessions(hello.sessions, hello.closed);
    B.events = [];
    upsertEvents(hello.events);
    B.ready = true;
    notify("reset");
    notify("change");
  };

  const run = (op, args) => post(op, args).catch(err => { notify("error", { op, err }); throw err; });
  B.create = o => run("create", o).then(r => r.id);
  B.answer = (sid, askId, idx, typed) => run("answer", typed !== undefined ? { id: sid, ask: askId, text: typed } : { id: sid, ask: askId, index: idx });
  B.send = (sid, text) => run("send", { id: sid, text });
  B.review = sid => run("review", { id: sid });
  B.rename = (sid, name) => run("rename", { id: sid, name: String(name || "").trim() });
  B.setMode = (sid, mode) => run("setMode", { id: sid, mode });
  B.setMuted = (sid, muted) => run("setMuted", { id: sid, muted });
  B.restart = sid => run("restart", { id: sid });
  B.stop = sid => run("stop", { id: sid });
  B.interrupt = sid => run("stop", { id: sid });
  B.remove = sid => run("delete", { id: sid });
  B.resume = id => run("resume", { id }).then(r => r.id);
  B.dirStatus = path => post("dirStatus", { path });
  B.folders = () => post("folders").then(r => r.folders || []);
  B.chooseFolder = () => post("chooseFolder").then(r => r.path || null);
  B.finder = sid => run("finder", { id: sid });
  B.copyPath = sid => run("copyPath", { id: sid }).then(r => r.path);
  B.setPrefs = p => post("setPrefs", p).then(prefs => { B.prefs = prefs; notify("change"); return prefs; });
  B.log = text => post("log", { text }).catch(() => {});

  B.ptyOpen = (sid, cols, rows, handlers) => post("ptyOpen", { id: sid, cols, rows }).then(r => { ptyHandlers.set(r.pty, handlers); return r.pty; });
  B.ptyInput = (pty, data) => post("ptyInput", { pty, data }).catch(() => {});
  B.ptyBinary = (pty, binary) => post("ptyInput", { pty, binary }).catch(() => {});
  B.ptyResize = (pty, cols, rows) => post("ptyResize", { pty, cols, rows }).catch(() => {});
  B.ptyClose = pty => { ptyHandlers.delete(pty); return post("ptyClose", { pty }).catch(() => {}); };

  window.Backend = B;
})();
