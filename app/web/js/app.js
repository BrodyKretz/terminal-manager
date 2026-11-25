(function () {
  "use strict";

  const B = window.Backend;
  const T = window.Terminals;
  const $ = id => document.getElementById(id);
  const scr = $("scr");
  const esc = s => String(s == null ? "" : s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const pad = n => String(n).padStart(2, "0");
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const STATUS = {
    working: { label: "Working" }, needs_you: { label: "Needs you" }, ready: { label: "Ready for review" }, process: { label: "Running" },
    idle: { label: "Idle" }, exited: { label: "Exited" }, reviewed: { label: "Reviewed" }
  };
  const VERB = {
    Read: "Read", Update: "Edited", Edit: "Edited", MultiEdit: "Edited", NotebookEdit: "Edited", Write: "Wrote", Bash: "Ran", Search: "Searched",
    Grep: "Searched", Glob: "Listed", WebFetch: "Fetched", WebSearch: "Searched the web", Task: "Started an agent", Agent: "Started an agent"
  };
  const EDIT_TOOLS = /^(Update|Edit|MultiEdit|NotebookEdit|Write)$/;
  const IC = {
    bell: '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M8 2.2a3.8 3.8 0 0 0-3.8 3.8v2.4L3 10.6h10l-1.2-2.2V6A3.8 3.8 0 0 0 8 2.2ZM6.4 12.4a1.7 1.7 0 0 0 3.2 0" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>',
    bellOff: '<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path d="M8 2.2a3.8 3.8 0 0 0-3.8 3.8v2.4L3 10.6h10l-1.2-2.2V6A3.8 3.8 0 0 0 8 2.2ZM6.4 12.4a1.7 1.7 0 0 0 3.2 0M2.5 2.5l11 11" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>',
    funnel: '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M2.5 3h11L9.3 8.2V13l-2.6-1.3V8.2Z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>'
  };
  const ERRORS = {
    "not-ready": "Still starting up. Try again in a moment.", "no-claude": "Claude Code was not found on your login PATH.",
    "folder-failed": "That folder could not be used.", "tmux-failed": "tmux could not start the session.",
    "answer-in-terminal": "Answer this one in its terminal.", "already-answered": "That was already answered in the terminal.",
    "not-found": "That session is gone.", "bad-request": "That did not work."
  };

  const S = {
    view: "feed", style: "a", filter: "all", sessFilter: new Set(), seenAt: {}, lastLook: Date.now(),
    drafts: {}, typing: {}, renaming: null, modal: null, modalReturn: null, trayOpen: new Set(),
    awayCount: 0, pillCount: 0, feedMaxSeq: 0, firstRender: true, feedWasHidden: false, focusKey: null, autoFocus: false,
    folders: [], dirInfo: {}
  };

  function storageGet(k) {
    try { return window.localStorage.getItem(k); } catch (err) { if (err instanceof DOMException) return null; throw err; }
  }
  function storageSet(k, v) {
    try { window.localStorage.setItem(k, v); } catch (err) { if (!(err instanceof DOMException)) throw err; }
  }
  function initialStyle() {
    const q = new URLSearchParams(location.search).get("style");
    if (/^[abc]$/.test(q || "")) return q;
    const st = storageGet("tm-style");
    return /^[abc]$/.test(st || "") ? st : "a";
  }
  function initialTray() {
    try { return new Set(JSON.parse(storageGet("tm-tray-open") || "[]")); } catch (err) { if (err instanceof SyntaxError) return new Set(); throw err; }
  }
  function saveTray() { storageSet("tm-tray-open", JSON.stringify(Array.from(S.trayOpen))); }

  const ses = id => B.byId(id);
  const modes = () => B.modes.map(m => m.label);
  const seenOf = sid => (S.seenAt[sid] != null ? S.seenAt[sid] : S.lastLook);
  const isUnseen = e => e.type !== "think" && e.at > seenOf(e.sid);
  const shapeSt = st => `<span class="shape s-${st}" aria-hidden="true"></span>`;
  const shape = s => (s ? `<span class="shape s-${s.status}${(s.status === "exited" && s.exitCode) || s.failed ? " bad" : ""}" aria-hidden="true"></span>` : shapeSt("exited"));
  const askHTML = t => esc(t).replace(/^Allow (\w+): (.+)\?$/, "Allow $1: <code>$2</code>?");
  const errText = err => ERRORS[err && err.message] || (err && err.message) || "That did not work.";
  function statusLabel(s) {
    if (s.status === "exited") return "Exited";
    return (STATUS[s.status] || { label: s.status }).label;
  }

  function fmtShort(ms) {
    const sec = Math.max(0, Math.floor(ms / 1000));
    if (sec < 60) return `${sec}s`;
    const m = Math.floor(sec / 60);
    if (m < 60) return `${m}m`;
    const h = Math.floor(m / 60), r = m % 60;
    if (h >= 48) return `${Math.floor(h / 24)}d`;
    return r ? `${h}h ${r}m` : `${h}h`;
  }
  function fmtClock(ms) {
    const sec = Math.max(0, Math.floor(ms / 1000));
    if (sec >= 3600) return fmtShort(ms);
    return `${Math.floor(sec / 60)}:${pad(sec % 60)}`;
  }
  function fmtAgo(ms) {
    const sec = Math.floor(ms / 1000);
    if (sec < 60) return "just now";
    const m = Math.floor(sec / 60);
    if (m < 60) return `${m} min ago`;
    const h = Math.floor(m / 60);
    if (h < 48) return `${h} h ago`;
    return `${Math.floor(h / 24)} days ago`;
  }

  function tickText(spec) {
    const i = spec.indexOf(":");
    const kind = spec.slice(0, i), id = spec.slice(i + 1);
    const t = Date.now();
    if (kind === "ev") { const e = B.events.find(x => x.seq === Number(id)); return e ? fmtShort(t - e.at) : ""; }
    if (kind === "closed") { const c = B.closed.find(x => x.id === id); return c ? fmtAgo(t - c.closedAt) : ""; }
    const s = ses(id);
    if (!s) return "";
    if (kind === "since") return fmtShort(t - s.statusAt);
    if (kind === "pill") return s.status === "working" ? fmtClock(t - s.statusAt) : fmtShort(t - s.statusAt);
    if (kind === "total") return fmtShort(t - s.startedAt);
    if (kind === "secs") return fmtShort(t - s.statusAt);
    return "";
  }
  function tick(root) {
    (root || scr).querySelectorAll("[data-tick]").forEach(el => {
      const txt = tickText(el.dataset.tick);
      if (el.textContent !== txt) el.textContent = txt;
    });
  }

  const FOCUS_ATTRS = ["act", "sid", "i", "f", "where", "step", "kind", "dir", "mode", "seq", "cid", "style", "pref"];
  function focusKeyOf(el) {
    if (!el || !el.dataset) return null;
    if (el.dataset.fk) return `fk|${el.dataset.fk}`;
    if (!el.dataset.act) return null;
    return FOCUS_ATTRS.map(a => el.dataset[a] || "").join("|");
  }
  function captureFocus(root) {
    const a = document.activeElement;
    if (!a || !root.contains(a)) return null;
    const key = focusKeyOf(a);
    return key ? { key, s: a.selectionStart, e: a.selectionEnd } : null;
  }
  function restoreFocus(root, f) {
    if (!f) return;
    const n = Array.from(root.querySelectorAll("[data-fk],[data-act]")).find(x => focusKeyOf(x) === f.key);
    if (!n) return;
    n.focus({ preventScroll: true });
    if (typeof n.selectionStart === "number" && f.s != null) n.setSelectionRange(f.s, f.e);
  }
  function hydrate(root) {
    root.querySelectorAll("[data-draft]").forEach(i => {
      const v = S.drafts[i.dataset.draft] || "";
      if (i.value !== v) i.value = v;
      if (i.tagName === "TEXTAREA" && i.classList.contains("cmp-text")) autoGrow(i);
    });
    tick(root);
  }
  /// The live terminals live outside the patched HTML: a patch would destroy them, so they step out first.
  function rescueTerminals(el) {
    el.querySelectorAll(".xterm-host").forEach(h => h.remove());
  }
  function patch(el, html) {
    if (!el || el._h === html) return false;
    const f = captureFocus(el);
    rescueTerminals(el);
    el.innerHTML = html;
    el._h = html;
    hydrate(el);
    restoreFocus(el, f);
    return true;
  }

  function reconcile(box, items, opts) {
    opts = opts || {};
    const old = new Map();
    for (const n of box.children) if (n.dataset.k) old.set(n.dataset.k, n);
    const keep = new Set(items.map(i => i.key));
    for (const [k, n] of old) {
      if (keep.has(k) || n._leaving) continue;
      rescueTerminals(n);
      if (opts.leave) { n._leaving = true; opts.leave(n); } else n.remove();
    }
    let prev = null;
    for (const it of items) {
      let n = old.get(it.key);
      let isNew = false;
      if (!n || n._leaving) {
        n = document.createElement(it.tag || "div");
        n.dataset.k = it.key;
        isNew = true;
      }
      if (n._c !== it.cls) { n.className = it.cls; n._c = it.cls; }
      if (it.attrs) for (const a in it.attrs) if (n.getAttribute(a) !== it.attrs[a]) n.setAttribute(a, it.attrs[a]);
      let updated = false;
      if (n._h !== it.html) {
        const f = captureFocus(n);
        rescueTerminals(n);
        n.innerHTML = it.html;
        n._h = it.html;
        hydrate(n);
        restoreFocus(n, f);
        updated = true;
      }
      let want = prev ? prev.nextSibling : box.firstChild;
      while (want && want._leaving && want !== n) want = want.nextSibling;
      if (want !== n) box.insertBefore(n, want);
      prev = n;
      if (isNew && opts.enter) opts.enter(n, it);
      if (updated && opts.update) opts.update(n, it);
    }
  }

  function autoGrow(t) {
    t.style.height = "auto";
    t.style.height = `${Math.min(Math.max(t.scrollHeight, 38), 140)}px`;
  }

  function cat(e) {
    if (e.type === "tool") return e.tool === "Bash" ? "command" : EDIT_TOOLS.test(e.tool) ? "edit" : "other";
    if (e.type === "cmd") return "command";
    if (e.type === "perm" || e.type === "ask") return "ask";
    if (e.type === "done") return "finished";
    if (e.type === "you") return "you";
    return "other";
  }
  function kindLabel(e) {
    const c = ({ edit: "edit", command: "run", ask: "ask", finished: "done", you: "you" })[cat(e)];
    if (c) return c;
    if (e.type === "tool") return ({ Read: "read", Grep: "find", Glob: "find", WebFetch: "web", WebSearch: "web" })[e.tool] || "tool";
    return ({ say: "note", think: "think", out: "out", exit: "exit", life: "info" })[e.type] || "info";
  }

  function listOrder() {
    const order = { needs_you: 0, ready: 1, working: 2, idle: 3, reviewed: 4 };
    const sortSt = arr => arr.map((s, i) => [s, i]).sort((a, b) => ((order[a[0].status] ?? 5) - (order[b[0].status] ?? 5)) || a[1] - b[1]).map(x => x[0]);
    const claude = sortSt(B.sessions.filter(s => s.kind === "claude"));
    const shells = B.sessions.filter(s => s.kind === "shell");
    return { claude, shells, all: claude.concat(shells) };
  }
  function unseenCount(sid) {
    const seen = seenOf(sid);
    let n = 0;
    for (const e of B.events) if (e.sid === sid && e.type !== "think" && e.at > seen) n++;
    return n;
  }
  function laneSessions() {
    const byWait = (a, b) => a.statusAt - b.statusAt;
    return B.sessions.filter(s => s.status === "needs_you" && s.ask).sort(byWait)
      .concat(B.sessions.filter(s => s.status === "ready").sort(byWait));
  }

  function optsHTML(s, where, withKbd) {
    if (!s.ask.answerable || !s.ask.options.length) {
      return `<button class="opt first" data-act="openTerm" data-sid="${s.id}" data-where="${where}">Answer in its terminal</button>`;
    }
    const typingKey = `${where}:${s.id}`;
    return s.ask.options.map((o, i) => {
      const isType = /^Type an answer$/i.test(o);
      const pressed = isType && S.typing[typingKey];
      return `<button class="opt ${i === 0 && !S.typing[typingKey] ? "first" : ""} ${pressed ? "pressed" : ""}" data-act="${isType ? "typeAnswer" : "answer"}" data-sid="${s.id}" data-i="${i}" data-where="${where}">${esc(o)}${withKbd ? `<kbd>${i + 1}</kbd>` : ""}</button>`;
    }).join("");
  }
  function inrowHTML(key, sid, placeholder, act, label) {
    return `<div class="inrow"><input class="field" data-draft="${key}" data-fk="${key}" data-enter="${act}" data-sid="${sid}" data-key="${key}" placeholder="${esc(placeholder)}" aria-label="${esc(placeholder)}" autocomplete="off"><button class="sendb" data-act="${act}" data-sid="${sid}" data-key="${key}">${label || "Send"}</button></div>`;
  }

  function renderHeader() {
    const c = st => B.sessions.filter(s => s.status === st).length;
    patch($("tally"), `<span class="t">${shapeSt("needs_you")}<b>${c("needs_you")}</b> need you</span><span class="t">${shapeSt("ready")}<b>${c("ready")}</b> ready</span><span class="t">${shapeSt("working")}<b>${c("working")}</b> working</span><span class="t">${shapeSt("process")}<b>${c("process")}</b> running</span>`);
    const d = $("btnDnd");
    const dnd = !!B.prefs.dnd;
    d.classList.toggle("on", dnd);
    d.setAttribute("aria-checked", String(dnd));
    $("styleSeg").querySelectorAll("button").forEach(b => { const on = b.dataset.style === S.style; b.classList.toggle("on", on); b.setAttribute("aria-checked", String(on)); });
  }

  function rowItem(s) {
    const nNew = S.view === s.id ? 0 : unseenCount(s.id);
    const sub = s.kind === "shell" ? (s.status === "process" ? s.command : s.status === "exited" ? (s.exitCode != null ? `code ${s.exitCode}` : s.summary) : s.cwd) : s.summary;
    const filtering = S.sessFilter.has(s.id);
    let qa = "";
    if (s.status === "needs_you" && s.ask) {
      const typing = S.typing[`qa:${s.id}`];
      qa = `<div class="qa-wrap"><div class="qa-in"><div class="qa needs">
        <div class="qa-k">Quick answer · ${s.ask.type === "permission" ? "permission" : "question"}</div>
        <div class="qa-q">${askHTML(s.ask.text)}</div>
        <div class="opts">${optsHTML(s, "qa", false)}</div>
        ${typing ? inrowHTML(`qa:${s.id}`, s.id, "Type your answer", "sendTyped") : ""}</div></div></div>`;
    }
    const html = `<button class="row-main" data-act="open" data-sid="${s.id}"><span class="r-1">${shape(s)}<span class="r-name">${esc(s.name)}</span>${s.muted ? `<span class="r-muted" title="Notifications muted">${IC.bellOff}</span>` : ""}${nNew ? `<span class="r-new">${nNew} new</span>` : ""}<span class="r-time" data-tick="since:${s.id}"></span></span><span class="r-sub"><span class="r-st">${statusLabel(s)}</span>${sub ? ` · ${esc(sub)}` : ""}</span></button><button class="r-filter" data-act="sfilter" data-sid="${s.id}" aria-pressed="${filtering}" title="${filtering ? "Stop filtering the feed to this session" : "Show only this session in the feed"}" aria-label="${filtering ? "Stop filtering the feed" : `Show only ${esc(s.name)} in the feed`}">${IC.funnel}</button>${qa}`;
    return {
      key: `r:${s.id}`, html,
      cls: `row st-${s.status}${S.view === s.id ? " on" : ""}${filtering ? " filtering" : ""}${S.typing[`qa:${s.id}`] ? " qa-open" : ""}`,
      attrs: { "data-ask": s.status === "needs_you" ? s.id : "", "data-where": "qa" }
    };
  }

  function renderList() {
    const { claude, shells } = listOrder();
    const items = [];
    items.push({ key: "h:claude", cls: "l-h", html: `Claude <span class="c">${claude.length}</span>` });
    if (!claude.length) items.push({ key: "e:claude", cls: "l-empty", html: "No Claude sessions. Press ⌘N to start one." });
    claude.forEach(s => items.push(rowItem(s)));
    items.push({ key: "h:term", cls: "l-h", html: `Terminals <span class="c">${shells.length}</span>` });
    shells.forEach(s => items.push(rowItem(s)));
    items.push({ key: "h:closed", cls: "l-h", html: `Recently closed <span class="c">${B.closed.length}</span>` });
    if (!B.closed.length) items.push({ key: "e:closed", cls: "l-empty", html: "Deleted Claude sessions wait here." });
    B.closed.slice(0, 6).forEach(c => {
      const fresh = Date.now() - c.closedAt < 60000;
      items.push({
        key: `x:${c.id}`, cls: `closed-row${fresh ? " hl" : ""}`,
        html: `${shapeSt("idle")}<span class="nm" title="${esc(c.lastLine)}">${esc(c.name)}</span><span class="when" data-tick="closed:${c.id}"></span><button class="btn" data-act="resume" data-cid="${c.id}">Resume</button>`
      });
    });
    reconcile($("listItems"), items);
    const all = $("allAct");
    all.classList.toggle("on", S.view === "feed");
    const badge = $("allBadge");
    badge.hidden = !(S.view !== "feed" && S.awayCount);
    badge.textContent = `${S.awayCount} new`;
  }

  function lastMessage(s) {
    return s.lastReply || s.summary || "";
  }
  function fileTotals(s) {
    return { add: s.files.reduce((a, f) => a + f.add, 0), del: s.files.reduce((a, f) => a + f.del, 0) };
  }

  function laneItem(s) {
    let html;
    if (s.status === "needs_you") {
      const typing = S.typing[`lane:${s.id}`];
      html = `<div class="wc-top">${shape(s)}<span class="wc-kind">${s.ask.type === "permission" ? "Needs permission" : "Asked a question"}</span><span class="wc-t" data-tick="since:${s.id}"></span></div>
        <button class="wc-name" data-act="open" data-sid="${s.id}">${esc(s.name)}<small>${esc(s.dir)}</small></button>
        <div class="wc-body">${askHTML(s.ask.text)}</div>
        ${typing ? inrowHTML(`lane:${s.id}`, s.id, "Type your answer", "sendTyped") : `<div class="opts">${optsHTML(s, "lane", false)}</div>`}`;
    } else {
      const { add, del } = fileTotals(s);
      html = `<div class="wc-top">${shape(s)}<span class="wc-kind">${s.failed ? "Stopped on an error" : "Ready for review"}</span><span class="wc-t" data-tick="since:${s.id}"></span></div>
        <button class="wc-name" data-act="open" data-sid="${s.id}">${esc(s.name)}<small>${esc(s.dir)}</small></button>
        <div class="wc-msg">${esc(lastMessage(s))}</div>
        <div class="wc-files">${s.files.length} file${s.files.length === 1 ? "" : "s"} <span class="add">+${add}</span><span class="del">−${del}</span><button class="btn sm ok" data-act="review" data-sid="${s.id}">Looks good</button></div>
        ${inrowHTML(`lane:${s.id}`, s.id, `Feedback for ${s.name}`, "sendLane")}`;
    }
    return { key: s.id, cls: `wcard ${s.status === "needs_you" ? "needs" : "ready"}`, html, attrs: { "data-ask": s.status === "needs_you" ? s.id : "", "data-where": "lane" } };
  }

  function animateCard(n, entering) {
    if (reduced) { if (!entering) n.remove(); return; }
    const isRow = S.style === "b";
    const cs = getComputedStyle(n);
    const gap = parseFloat(getComputedStyle(n.parentNode).columnGap) || 0;
    const kids = Array.from(n.children);
    const full = isRow
      ? { height: `${n.offsetHeight}px`, paddingTop: cs.paddingTop, paddingBottom: cs.paddingBottom, opacity: 1 }
      : { flexBasis: `${n.offsetWidth}px`, paddingLeft: cs.paddingLeft, paddingRight: cs.paddingRight, marginRight: "0px", opacity: 1 };
    const zero = isRow
      ? { height: "0px", paddingTop: "0px", paddingBottom: "0px", opacity: 0 }
      : { flexBasis: "0px", paddingLeft: "0px", paddingRight: "0px", marginRight: `${-gap}px`, opacity: 0 };
    if (!isRow) kids.forEach(k => { k.style.width = `${k.offsetWidth}px`; k.style.flex = "none"; });
    n.style.overflow = "hidden";
    const anim = n.animate(entering ? [zero, full] : [full, zero], { duration: entering ? 300 : 260, easing: "cubic-bezier(.2,.7,.2,1)", fill: entering ? "none" : "forwards" });
    anim.finished.then(() => {
      if (!entering) { n.remove(); return; }
      n.style.overflow = "";
      kids.forEach(k => { k.style.width = ""; k.style.flex = ""; });
    });
  }

  function animateEvIn(n) {
    if (reduced) return;
    const cs = getComputedStyle(n);
    const h = n.offsetHeight;
    const tint = getComputedStyle(scr).getPropertyValue("--work-soft").trim();
    n.style.overflow = "hidden";
    n.animate([
      { height: "0px", paddingTop: "0px", paddingBottom: "0px", marginBottom: "0px", opacity: 0 },
      { height: `${h}px`, paddingTop: cs.paddingTop, paddingBottom: cs.paddingBottom, marginBottom: cs.marginBottom, opacity: 1 }
    ], { duration: 240, easing: "cubic-bezier(.2,.7,.2,1)" }).finished.then(() => { n.style.overflow = ""; });
    n.animate([{ boxShadow: `inset 0 0 0 100vmax ${tint}` }, { boxShadow: "inset 0 0 0 100vmax transparent" }], { duration: 1000, easing: "ease-out" });
  }

  function evText(e) {
    switch (e.type) {
      case "tool": return `<span class="v">${esc(VERB[e.tool] || e.tool)}</span>${e.args ? ` <code>${esc(e.args)}</code>` : ""}`;
      case "say": return esc(e.text);
      case "think": return `<span class="flag work">Thinking</span> <span class="v">(<span data-tick="ev:${e.seq}"></span>)</span>`;
      case "perm": return `<span class="flag needs">Needs permission</span><span class="ev-q">${askHTML(e.text)}</span>${e.answer ? `<span class="ev-ans">${esc(e.answer)}</span>` : ""}`;
      case "ask": return `<span class="flag needs">Asked</span><span class="ev-q">${esc(e.text)}</span>${e.answer ? `<span class="ev-ans">${esc(e.answer)}</span>` : ""}`;
      case "done": return `<span class="flag ready">Finished its turn</span> <span class="v">ready for your review</span>`;
      case "cmd": return `<span class="v">Ran</span> <code>${esc(e.text)}</code>`;
      case "out": return `<span class="v">Printed</span> <code class="o">${esc(e.text)}</code>`;
      case "exit": return `<span class="flag ${e.code ? "needs" : ""}">Exited</span> <span class="v">with code ${e.code}</span>`;
      case "you": return e.text ? `<span class="v">You ${esc(e.verb)}</span> “${esc(e.text)}”` : `<span class="v">You ${esc(e.verb)}</span>`;
      case "life": return `<span class="flag ${e.flag || ""}">${esc(e.text)}</span>`;
    }
    return "";
  }

  function evItem(e, cont) {
    const s = ses(e.sid);
    const t = new Date(e.at);
    const pending = (e.type === "perm" || e.type === "ask") && !e.answer && s && s.status === "needs_you" && s.askSeq === e.seq;
    const live = e.type === "done" && s && s.status === "ready" && s.lastDone === e.seq;
    const name = s ? s.name : e.sname;
    const html = `<span class="ev-time"><b>${pad(t.getHours())}:${pad(t.getMinutes())}</b><span class="sec">:${pad(t.getSeconds())}</span></span><span class="ev-tag" style="--tag:${s ? s.tag : "#8A8C95"}">${shape(s)}<span class="nm">${esc(name)}</span></span><div class="ev-what"><span class="ev-kind">${kindLabel(e)}</span><span class="ev-text">${evText(e)}</span>${e.detail ? `<span class="ev-detail">${esc(e.detail)}</span>` : ""}</div><span></span>`;
    return {
      key: String(e.seq), html, fresh: e.seq > S.feedMaxSeq,
      cls: `ev k-${cat(e)}${pending ? " pending" : ""}${live ? " live" : ""}${cont ? " cont" : ""}${isUnseen(e) ? " new" : ""}`,
      attrs: { tabindex: "0", "data-key": String(e.seq), "data-sid": e.sid }
    };
  }

  function feedData() {
    const visible = B.events.filter(e => e.type !== "think" || (ses(e.sid) || {}).status === "working");
    const scoped = S.sessFilter.size ? visible.filter(e => S.sessFilter.has(e.sid)) : visible;
    const counts = { all: scoped.length };
    scoped.forEach(e => { const k = cat(e); counts[k] = (counts[k] || 0) + 1; });
    const filtered = scoped.filter(e => S.filter === "all" || cat(e) === S.filter).sort((a, b) => (b.at - a.at) || (b.seq - a.seq));
    return { counts, rest: filtered.slice(0, 250) };
  }

  function isFeedLive() {
    const fw = $("feedwrap");
    return $("evlist").getBoundingClientRect().top >= fw.getBoundingClientRect().top - 6;
  }

  function renderFeed() {
    const quiet = S.firstRender || S.feedWasHidden;
    const waiting = laneSessions();
    reconcile($("laneCards"), waiting.map(laneItem), {
      enter: n => { if (!quiet) animateCard(n, true); },
      leave: n => animateCard(n, false)
    });
    $("laneN").textContent = waiting.length;
    $("laneEmpty").hidden = waiting.length > 0;

    const fw = $("feedwrap");
    const live = !quiet && isFeedLive();
    let anchor = null;
    if (!quiet && !live) {
      const top = fw.getBoundingClientRect().top;
      const n = Array.from($("evlist").children).find(x => x.getBoundingClientRect().bottom > top + 1);
      if (n) anchor = { n, top: n.getBoundingClientRect().top };
    }

    const { counts, rest } = feedData();
    const chips = [["all", "All"], ["ask", "Asks"], ["edit", "Edits"], ["command", "Commands"], ["finished", "Finished"], ["you", "From you"]];
    const names = Array.from(S.sessFilter).map(id => (ses(id) || { name: "closed" }).name);
    patch($("feedTools"), `<h2>Activity</h2>${chips.map(([k, n]) => `<button class="chip ${S.filter === k ? "on" : ""}" data-act="filter" data-f="${k}" aria-pressed="${S.filter === k}">${n}<span class="n">${counts[k] || 0}</span></button>`).join("")}${names.length ? `<button class="chip sess" data-act="clearSessFilter" title="Show every session again">Only ${esc(names.join(", "))}<span class="x" aria-hidden="true">✕</span></button>` : ""}<span class="live"><i></i>Live</span>`);

    let prev = null, added = 0;
    const items = rest.map(e => { const it = evItem(e, prev === e.sid); prev = e.sid; return it; });
    reconcile($("evlist"), items, {
      enter: (n, it) => {
        if (quiet || !it.fresh) return;
        if (live) animateEvIn(n); else added++;
      }
    });
    if (added) S.pillCount += added;
    $("feedEmpty").hidden = !!rest.length;
    if (anchor && anchor.n.isConnected) {
      const delta = anchor.n.getBoundingClientRect().top - anchor.top;
      if (Math.abs(delta) >= 1) fw.scrollTop += delta;
    }
    const pill = $("newPill");
    pill.hidden = !S.pillCount;
    pill.textContent = `${S.pillCount} new event${S.pillCount === 1 ? "" : "s"}`;
    S.feedMaxSeq = B.seq;
    S.feedWasHidden = false;
  }

  function composerHTML(s, ph) {
    const working = s.status === "working";
    return `<div class="composer" data-act="focusComposer"><textarea class="cmp-text" rows="1" data-draft="cmp:${s.id}" data-fk="cmp:${s.id}" data-composer="${s.id}" placeholder="${esc(ph)}" aria-label="${esc(ph)}"></textarea><div class="cmp-foot"><span class="hint">⏎ send · ⇧⏎ new line${working ? " · Esc interrupts" : ""}</span><button class="btn sm primary" data-act="send" data-sid="${s.id}"${s.status === "exited" ? " disabled" : ""}>Send</button></div></div>`;
  }

  function barHTML(s) {
    const shell = s.kind === "shell";
    const label = s.status === "exited" ? (s.exitCode != null ? `Exited · code ${s.exitCode}` : "Exited") : statusLabel(s);
    const acts = [`<button class="btn icon" data-act="bell" data-sid="${s.id}" aria-pressed="${s.muted}" title="${s.muted ? "Unmute notifications" : "Mute notifications"}" aria-label="${s.muted ? "Unmute notifications" : "Mute notifications"}">${s.muted ? IC.bellOff : IC.bell}</button>`];
    acts.push(`<button class="btn sm" data-act="rename" data-sid="${s.id}">Rename</button>`);
    if (shell) {
      if (s.status === "process") acts.push(`<button class="btn sm" data-act="stop" data-sid="${s.id}">Stop<kbd>⌃C</kbd></button>`);
      acts.push(`<button class="btn sm" data-act="restart" data-sid="${s.id}">Restart</button>`);
      acts.push(`<button class="btn sm danger" data-act="delete" data-sid="${s.id}">${s.status === "exited" ? "Remove" : "Delete"}</button>`);
    } else {
      const resume = s.status === "exited" && s.canResume;
      acts.push(`<button class="btn sm" data-act="restart" data-sid="${s.id}" title="${s.canResume ? "Restart Claude and keep the conversation" : "Start Claude again"}">${resume ? "Resume" : "Restart"}</button>`, `<button class="btn sm" data-act="stop" data-sid="${s.id}"${s.status === "working" || s.status === "needs_you" ? "" : " disabled"} title="Sends Esc">Stop</button>`, `<button class="btn sm danger" data-act="delete" data-sid="${s.id}">Delete</button>`);
    }
    const title = S.renaming === s.id
      ? `<input class="rename" data-fk="rename" data-draft="rename" data-sid="${s.id}" aria-label="Session name" spellcheck="false">`
      : `<h2 title="F2 to rename">${esc(s.name)}</h2>`;
    return `<button class="back" data-act="feed">All activity${S.awayCount ? `<span class="r-new">${S.awayCount} new</span>` : ""}</button>
      <div class="sv-title">${shape(s)}${title}<span class="pill st-${s.status}">${label} · <span class="tm" data-tick="pill:${s.id}"></span></span></div>
      <div class="sv-acts">${acts.join("")}</div>`;
  }

  function metaHTML(s) {
    const dir = `<span class="m"><span class="dir">${esc(s.kind === "shell" ? s.cwd : s.dir)}</span><button class="lnk" data-act="finder" data-sid="${s.id}">Open in Finder</button><button class="lnk" data-act="copyPath" data-sid="${s.id}">Copy path</button></span>`;
    if (s.kind === "shell") {
      return `<span class="m"><span class="k">In status</span><b data-tick="since:${s.id}"></b></span>${s.command && s.status === "process" ? `<span class="m"><span class="k">Command</span><b>${esc(s.command)}</b></span>` : ""}<span class="m"><span class="k">Shell</span><b>zsh</b></span>${dir}`;
    }
    const hasCtx = typeof s.context === "number";
    const ctx = hasCtx ? Math.round(s.context) : 0;
    const modeCtl = `<span class="sel"><select data-change="mode" data-sid="${s.id}" data-fk="mode:${s.id}" aria-label="Permission mode">${modes().map(m => `<option${m === s.mode ? " selected" : ""}>${esc(m)}</option>`).join("")}</select></span>`;
    return `<span class="m"><span class="k">In status</span><b data-tick="since:${s.id}"></b></span>
      <span class="m"><span class="k">Total</span><b data-tick="total:${s.id}"></b></span>
      <span class="m"><span class="k">Context</span><span class="meter ${ctx >= 80 ? "hot" : ""}"><i style="width:${ctx}%"></i></span><b>${hasCtx ? `${ctx}%` : "—"}</b>${ctx >= 80 ? `<span style="color:var(--needs)">near limit</span>` : ""}</span>
      <span class="m"><span class="k">Mode</span>${modeCtl}</span>${dir}`;
  }

  function cmdHTML(s) {
    if (s.kind !== "shell") {
      if (s.status === "exited") return `<div class="cmdline info"><span class="muted">Claude exited.${s.canResume ? " Resume brings the conversation back." : ""}</span><button class="tbtn" data-act="restart" data-sid="${s.id}">${s.canResume ? "Resume" : "Restart"}</button></div>`;
      return "";
    }
    if (s.status === "process") return `<div class="cmdline info"><span class="muted">${esc(s.command)} is running. Stop it to get a prompt back.</span><button class="tbtn warn" data-act="stop" data-sid="${s.id}">Stop (⌃C)</button></div>`;
    if (s.status === "exited") return `<div class="cmdline info"><span class="muted">${s.exitCode != null ? `Process exited with code ${s.exitCode}.` : "The terminal went away."}</span><button class="tbtn" data-act="restart" data-sid="${s.id}">Restart</button><button class="tbtn" data-act="removeShell" data-sid="${s.id}">Remove</button></div>`;
    return "";
  }

  function bottomHTML(s) {
    if (s.kind === "shell") return "";
    let out = "";
    if (s.status === "needs_you" && s.ask) {
      const typing = S.typing[`ans:${s.id}`];
      const n = s.ask.answerable ? s.ask.options.length : 0;
      out += `<div class="askp" data-ask="${s.id}" data-where="ans" tabindex="-1"><div class="askp-k">${shape(s)}${s.ask.type === "permission" ? "Needs permission" : "Asked a question"}<span class="t">waiting <span data-tick="since:${s.id}"></span></span></div>
        <div class="askp-q">${askHTML(s.ask.text)}</div>
        <div class="opts">${optsHTML(s, "ans", n > 0)}<span class="askp-foot">${n ? `Press 1–${n} to choose, or answer in the terminal above` : "The terminal above shows the full prompt"}</span></div>
        ${typing ? inrowHTML(`ans:${s.id}`, s.id, "Type your answer", "sendTyped", "Send answer") : ""}</div>`;
    } else if (s.status === "ready") {
      const { add, del } = fileTotals(s);
      out += `<div class="review"><div class="rv-head">${shape(s)}<b>Review this turn</b><span class="sum">${s.files.length} file${s.files.length === 1 ? "" : "s"} changed · <span class="add">+${add}</span> <span class="del">−${del}</span></span><button class="btn sm ok" data-act="review" data-sid="${s.id}">Looks good</button></div>
        ${s.files.length ? `<div class="rv-files">${s.files.map(f => `<div><span class="p">${esc(f.path)}</span>${f.binary ? `<span class="bin">binary</span>` : `<span class="add">+${f.add}</span><span class="del">−${f.del}</span>`}</div>`).join("")}</div>` : `<p class="rv-none">No files changed this turn.</p>`}
        ${composerHTML(s, `Feedback for ${s.name}`)}</div>`;
    } else if (s.status !== "exited") {
      out += composerHTML(s, `Message ${s.name}`);
    }
    return out;
  }

  function renderSession(s) {
    const sv = $("sessionView");
    if (sv._sid !== s.id || sv._kind !== s.kind) {
      rescueTerminals(sv);
      sv.innerHTML = `<div class="sv-bar" id="svBar"></div><div class="sv-meta" id="svMeta"></div>
        <div class="termbox"><div class="term xt" id="svTerm"></div><div id="svCmd"></div></div>
        <div class="bottom" id="svBottom" hidden></div>`;
      sv._sid = s.id;
      sv._kind = s.kind;
    }
    patch($("svBar"), barHTML(s));
    patch($("svMeta"), metaHTML(s));
    T.mount($("svTerm"), `main:${s.id}`, s.id, "normal");
    patch($("svCmd"), cmdHTML(s));
    const bottom = bottomHTML(s);
    const bt = $("svBottom");
    bt.hidden = !bottom;
    patch(bt, bottom);
  }

  function renderCenter() {
    const fv = $("feedView"), sv = $("sessionView");
    if (S.view === "feed") {
      fv.hidden = false;
      sv.hidden = true;
      renderFeed();
    } else {
      fv.hidden = true;
      sv.hidden = false;
      S.feedWasHidden = true;
      renderSession(ses(S.view));
    }
  }

  function trayItem(s) {
    const open = S.trayOpen.has(s.id);
    const inMain = S.view === s.id;
    const label = s.status === "exited" ? (s.exitCode != null ? `Exited · code ${s.exitCode}` : "Exited") : statusLabel(s);
    const last = s.lastLine || (s.status === "process" ? s.command : s.cwd) || "";
    let body = "";
    if (open && inMain) {
      body = `<div class="tsh-note">Shown in the main view</div>`;
    } else if (open) {
      body = `<div class="term xt" data-slot="${s.id}"></div>`;
      if (s.status === "process") body += `<div class="tsh-acts"><button class="btn sm" data-act="stop" data-sid="${s.id}">Stop (⌃C)</button><button class="lnk" data-act="open" data-sid="${s.id}">Open full</button></div>`;
      else if (s.status === "exited") body += `<div class="tsh-acts"><button class="btn sm" data-act="restart" data-sid="${s.id}">Restart</button><button class="btn sm danger" data-act="removeShell" data-sid="${s.id}">Remove</button><button class="lnk" data-act="open" data-sid="${s.id}">Open full</button></div>`;
      else body += `<div class="tsh-acts"><button class="lnk" data-act="open" data-sid="${s.id}">Open full</button></div>`;
    }
    const html = `<button class="tsh-tog" data-act="trayToggle" data-sid="${s.id}" aria-expanded="${open}" title="${open ? "Collapse" : "Expand"} ${esc(s.name)}"><span class="tsh-head">${shape(s)}<span class="nm">${esc(s.name)}</span><span class="st"><b>${label}</b> · <span data-tick="since:${s.id}"></span></span></span>${open ? "" : `<span class="tsh-last">${esc(last)}</span>`}</button>${body}`;
    return { key: s.id, cls: `tsh${open ? " open" : ""}`, html, attrs: { "data-shellcard": s.id } };
  }

  function renderTray() {
    const shells = B.sessions.filter(s => s.kind === "shell");
    $("trayN").textContent = shells.length;
    reconcile($("trayList"), shells.map(trayItem));
    $("trayList").querySelectorAll("[data-slot]").forEach(slot => T.mount(slot, `tray:${slot.dataset.slot}`, slot.dataset.slot, "small"));
  }

  /// Terminals live only while shown: the main view's session and the open tray cards.
  function pruneTerminals() {
    const keep = new Set();
    if (S.view !== "feed" && ses(S.view)) keep.add(`main:${S.view}`);
    B.sessions.forEach(s => { if (s.kind === "shell" && S.trayOpen.has(s.id) && S.view !== s.id) keep.add(`tray:${s.id}`); });
    T.prune(keep);
  }

  function prefsModalHTML() {
    const p = B.prefs;
    const sw = (pref, on, disabled, label, hint) => `<div class="pref"><div class="tx"><b>${label}</b><span>${hint}</span></div><button class="switch ${on ? "on" : ""}" role="switch" aria-checked="${!!on}" data-act="pref" data-pref="${pref}"${disabled ? " disabled" : ""} aria-label="${label}"><span class="knob"></span></button></div>`;
    const loginHint = p.openAtLoginAvailable === false ? esc(p.openAtLoginNote || "Not available in this run.") : "Starts in the menu bar when you log in";
    return { cls: "modal prefs", label: "prefsTitle", html: `
      <h2 id="prefsTitle">Settings<kbd>⌘,</kbd></h2>
      <p class="sub">Sessions keep running in tmux whether or not this window is open.</p>
      ${sw("notifications", p.notifications !== false, false, "Notification banners", "A macOS banner when a session needs you and this window is in the background")}
      ${sw("dnd", !!p.dnd, false, "Do not disturb", "No banners or toasts; the feed keeps recording")}
      ${sw("openAtLogin", !!p.openAtLogin, p.openAtLoginAvailable === false, "Open at login", loginHint)}
      <div class="modal-foot" style="margin-top:14px"><button class="btn" data-act="closeModal" data-fk="m:cancel">Done</button></div>` };
  }

  function modalHTML() {
    const m = S.modal;
    if (!m) return null;
    if (m.type === "prefs") return prefsModalHTML();
    if (m.type === "delete") {
      const s = ses(m.sid);
      if (!s) return null;
      const sub = s.kind === "claude"
        ? (s.canResume ? "Ends Claude and its tmux session. The conversation waits in Recently closed, where Resume brings it back." : "Ends Claude and its tmux session.")
        : "Ends the shell, everything running in it, and its tmux session.";
      return { cls: "modal delm", label: "delTitle", html: `
        <h2 id="delTitle">Delete ${esc(s.name)}?</h2>
        <p class="sub">${sub}</p>
        <div class="what">${shape(s)}<b>${esc(s.name)}</b><code>${esc(s.dir)}</code></div>
        <div class="modal-foot"><button class="btn" data-act="closeModal" data-fk="m:cancel">Cancel</button><button class="btn danger-fill" data-act="confirmDelete" data-sid="${s.id}" data-fk="m:ok">End and delete</button></div>` };
    }
    if (m.type === "help") {
      const rows = [
        ["⌘J", "Next session needing you, then ready ones"], ["⌘N", "New session sheet"], ["⌘0 · Esc", "Back to All activity"],
        ["⌘1 … ⌘9", "Open the nth session in the list"], ["1 2 3", "Pick an option on the focused prompt"], ["⏎ · ⇧⏎", "Send / new line in the composer"],
        ["Esc", "Interrupt a working session (from the composer); closes sheets"], ["⌘,", "Settings"], ["F2", "Rename the open session inline"], ["?", "This list"]
      ];
      return { cls: "modal help", label: "helpTitle", html: `
        <h2 id="helpTitle">Keyboard shortcuts</h2>
        <p class="sub">Inside a terminal every key goes to the terminal, except ⌘ shortcuts.</p>
        <table class="keys">${rows.map(([k, d]) => `<tr><td>${k.split(" ").map(x => (x === "·" || x === "…" ? ` ${x} ` : `<kbd>${esc(x)}</kbd>`)).join("")}</td><td>${esc(d)}</td></tr>`).join("")}</table>
        <div class="modal-foot" style="margin-top:14px"><button class="btn" data-act="closeModal" data-fk="m:cancel">Close</button></div>` };
    }
    const isClaude = m.kind === "claude";
    const st = n => (n < m.step ? "done" : n === m.step ? "cur" : "todo");
    const path = normalizePath(S.drafts["nm:path"] || "");
    const chg = n => `<button class="chg" data-act="nmGo" data-step="${n}">Change</button>`;
    let s1 = "", s2 = "", s3 = "";
    if (m.step === 1) {
      s1 = `<div class="seg2" role="radiogroup"><button class="${isClaude ? "on" : ""}" role="radio" aria-checked="${isClaude}" data-act="nmKind" data-kind="claude" data-fk="nm:k:claude"><b>Claude session</b><span>Claude Code in a folder</span></button><button class="${!isClaude ? "on" : ""}" role="radio" aria-checked="${!isClaude}" data-act="nmKind" data-kind="shell" data-fk="nm:k:shell"><b>Terminal</b><span>Plain zsh shell</span></button></div>`;
    }
    if (m.step === 2) {
      s2 = `<div class="dirs all">${S.folders.map(d => `<button class="${d === path ? "on" : ""}" data-act="nmDir" data-dir="${esc(d)}">${esc(d)}</button>`).join("") || `<span class="lane-empty" style="margin:0">No folders in ~/work yet</span>`}</div>
        <div class="pathrow"><label class="pathf"><input data-draft="nm:path" data-fk="nm:path" data-enter="nmNext" placeholder="~/work/new-project" spellcheck="false" autocomplete="off" aria-label="Folder path"><span id="nmPathStatus">${pathStatusHTML(path)}</span></label><button class="btn" data-act="nmChoose">Choose…</button></div>`;
    }
    if (m.step === 3) {
      s3 = `<textarea class="ta" data-draft="nm:prompt" data-fk="nm:prompt" placeholder="What should Claude start on? Leave empty to just open it." aria-label="First prompt" rows="2"></textarea>
        <div class="stp-h" style="margin-bottom:6px">Permission mode</div>
        <div class="modes" role="radiogroup">${B.modes.map(md => `<button class="${md.label === m.mode ? "on" : ""}" role="radio" aria-checked="${md.label === m.mode}" data-act="nmMode" data-mode="${esc(md.label)}"><i></i>${esc(md.label)}<span>${esc(md.hint)}</span></button>`).join("")}</div>`;
    }
    const primary = m.step === 1 ? "Next" : m.step === 2 ? (isClaude ? "Next" : "Create terminal") : "Create session";
    return { cls: "modal", label: "newTitle", html: `
      <h2 id="newTitle">New session<kbd>⌘N</kbd></h2>
      <div class="stp ${st(1)}"><div class="stp-h"><span class="n">${m.step > 1 ? "✓" : "1"}</span>Kind${m.step > 1 ? `<span class="val">${isClaude ? "Claude session" : "Terminal"}</span>${chg(1)}` : ""}</div>${s1}</div>
      <div class="stp ${st(2)}"><div class="stp-h"><span class="n">${m.step > 2 ? "✓" : "2"}</span>Directory${m.step > 2 ? `<span class="val">${esc(path)}</span>${chg(2)}` : ""}</div>${s2}</div>
      ${isClaude ? `<div class="stp ${st(3)}"><div class="stp-h"><span class="n">3</span>First prompt <span style="font-weight:400;color:var(--ink3)">optional</span></div>${s3}</div>` : ""}
      <div class="modal-foot"><button class="btn" data-act="closeModal">Cancel</button><button class="btn primary" data-act="nmNext" data-fk="nm:next"${m.busy ? " disabled" : ""}>${primary}</button></div>` };
  }

  function normalizePath(p) {
    p = String(p || "").trim().replace(/\/+$/, "");
    if (!p) return "";
    if (B.home && (p === B.home || p.startsWith(`${B.home}/`))) p = `~${p.slice(B.home.length)}`;
    if (!p.startsWith("~") && !p.startsWith("/")) p = `~/work/${p}`;
    return p;
  }
  function pathStatusHTML(path) {
    if (!path) return `<span class="bad">Pick or type a folder</span>`;
    const info = S.dirInfo[path];
    if (!info) { checkDir(path); return `<span class="newf">Checking…</span>`; }
    if (info.exists && !info.isDir) return `<span class="bad">That is a file</span>`;
    return info.exists ? `<span class="ok">Folder exists</span>` : `<span class="newf">New folder, will be created</span>`;
  }
  function checkDir(path) {
    if (S.dirInfo[path] || S.dirInfo[`?${path}`]) return;
    S.dirInfo[`?${path}`] = true;
    B.dirStatus(path).then(info => {
      S.dirInfo[path] = info;
      const st = $("nmPathStatus");
      if (st && normalizePath(S.drafts["nm:path"]) === path) st.innerHTML = pathStatusHTML(path);
    }).catch(() => { delete S.dirInfo[`?${path}`]; });
  }

  function renderModal() {
    const root = $("modalRoot");
    const m = modalHTML();
    if (!m) {
      if (root._shell) { root.innerHTML = ""; root._shell = null; }
      return;
    }
    if (root._shell !== m.cls) {
      root.innerHTML = `<div class="scrim" data-act="scrim"><div class="${m.cls}" role="dialog" aria-modal="true" aria-labelledby="${m.label}"></div></div>`;
      root._shell = m.cls;
    }
    patch(root.querySelector(".modal"), m.html);
  }

  let raf = 0;
  function schedule() { if (!raf) raf = requestAnimationFrame(() => { raf = 0; renderAll(); }); }

  function renderAll() {
    if (!B.ready) return;
    if (S.view !== "feed" && !ses(S.view)) S.view = "feed";
    if (S.view !== "feed") S.seenAt[S.view] = Date.now();
    renderHeader();
    renderList();
    renderCenter();
    renderTray();
    pruneTerminals();
    renderModal();
    tick();
    S.firstRender = false;
    if (S.focusKey) {
      const key = S.focusKey;
      S.focusKey = null;
      const n = scr.querySelector(`[data-fk="${CSS.escape(key)}"]`);
      if (n) {
        n.focus({ preventScroll: false });
        if (n.dataset.fk === "rename") n.select();
      } else if (key.startsWith("term:")) {
        T.focus(key.slice(5));
      }
    }
    if (S.autoFocus) { S.autoFocus = false; autoFocusSession(); }
  }

  function autoFocusSession() {
    const s = ses(S.view);
    if (!s) return;
    const sv = $("sessionView");
    if (s.kind === "shell") { T.focus(`main:${s.id}`); return; }
    let el = null;
    if (s.status === "needs_you") el = sv.querySelector(".askp");
    else el = sv.querySelector(".cmp-text");
    if (el) el.focus({ preventScroll: true });
    else T.focus(`main:${s.id}`);
  }

  const toastsEl = $("toasts");
  function toast(o) {
    if (o.attention && B.prefs.dnd) return;
    const el = document.createElement("div");
    el.className = "toast";
    el.setAttribute("role", "status");
    el.innerHTML = `${o.shape ? shapeSt(o.shape) : ""}<span class="msg">${o.html}</span>${o.action ? `<button class="tb">${esc(o.action.label)}</button>` : ""}<button class="x" aria-label="Dismiss">✕</button>`;
    const close = () => dismiss(el);
    if (o.action) el.querySelector(".tb").addEventListener("click", () => { o.action.fn(); close(); });
    el.querySelector(".x").addEventListener("click", close);
    const ms = o.ms || 6000;
    el._t = setTimeout(close, ms);
    el.addEventListener("mouseenter", () => clearTimeout(el._t));
    el.addEventListener("mouseleave", () => { el._t = setTimeout(close, 2500); });
    toastsEl.appendChild(el);
    while (toastsEl.children.length > 4) toastsEl.firstElementChild.remove();
    return el;
  }
  function dismiss(el) {
    if (!el.isConnected || el._out) return;
    el._out = true;
    clearTimeout(el._t);
    if (reduced) { el.remove(); return; }
    el.classList.add("out");
    setTimeout(() => el.remove(), 190);
  }
  const fail = err => toast({ html: esc(errText(err)), ms: 4000 });

  function askPhrase(s) {
    if (!s.ask) return "needs you";
    if (s.ask.type !== "permission") return "asked a question";
    if (/^Allow Bash/.test(s.ask.text)) return "needs permission to run a command";
    if (/^Allow (Edit|Write|MultiEdit)/.test(s.ask.text)) return "needs permission to edit a file";
    return "needs permission";
  }

  function onStatus({ s, to }) {
    if (S.view === s.id || s.muted) return;
    if (to === "needs_you") toast({ attention: true, shape: "needs_you", html: `<b>${esc(s.name)}</b> ${askPhrase(s)}`, action: { label: "Answer", fn: () => openSession(s.id) } });
  }

  B.on((kind, data) => {
    if (kind === "event") {
      if (data.type !== "think" && S.view !== "feed" && S.view !== data.sid) S.awayCount++;
      if (S.view === data.sid) S.seenAt[data.sid] = Date.now();
    } else if (kind === "status") {
      onStatus(data);
    } else if (kind === "menu") {
      if (data.action === "open") openSession(data.sid);
      else if (data.action === "new") { if (S.modal) closeModal(); openNew(data.kind === "shell" ? { kind: "shell", step: 2 } : { kind: "claude" }); }
      else if (data.action === "settings") openPrefs();
    } else if (kind === "toast") {
      toast({ html: esc(data.text), ms: 5000 });
    } else if (kind === "error") {
      return;
    } else if (kind === "reset") {
      S.trayOpen = new Set(Array.from(S.trayOpen).filter(id => ses(id)));
    }
    schedule();
  });

  function openSession(sid) {
    if (!ses(sid)) return;
    if (S.view === "feed") S.awayCount = 0;
    S.view = sid;
    S.seenAt[sid] = Date.now();
    if (S.renaming && S.renaming !== sid) S.renaming = null;
    S.autoFocus = true;
    schedule();
  }
  function goFeed() {
    if (S.view === "feed") return;
    const hadFocus = $("sessionView").contains(document.activeElement);
    S.view = "feed";
    S.awayCount = 0;
    S.renaming = null;
    renderAll();
    if (hadFocus) $("allAct").focus({ preventScroll: true });
  }
  function nextNeeding() {
    const q = laneSessions();
    if (!q.length) { toast({ html: "Nothing needs you right now", ms: 3000 }); return; }
    const idx = q.findIndex(s => s.id === S.view);
    openSession(q[(idx + 1) % q.length].id);
  }

  function setStyle(k) {
    S.style = k;
    scr.dataset.style = k;
    storageSet("tm-style", k);
    T.applyTheme();
    schedule();
  }

  function clearTypingFor(sid) {
    ["lane", "qa", "ans"].forEach(w => { delete S.typing[`${w}:${sid}`]; delete S.drafts[`${w}:${sid}`]; });
  }
  function pickOption(sid, i, where) {
    const s = ses(sid);
    if (!s || !s.ask || !s.ask.answerable || i < 0 || i >= s.ask.options.length) return;
    if (/^Type an answer$/i.test(s.ask.options[i])) {
      S.typing[`${where}:${sid}`] = true;
      S.focusKey = `${where}:${sid}`;
      schedule();
      return;
    }
    clearTypingFor(sid);
    B.answer(sid, i).catch(fail);
  }
  function sendTyped(sid, key) {
    const text = (S.drafts[key] || "").trim();
    if (!text) return;
    clearTypingFor(sid);
    B.answer(sid, null, text).catch(fail);
  }
  function sendComposer(sid) {
    const s = ses(sid);
    const key = `cmp:${sid}`;
    const text = (S.drafts[key] || "").trim();
    if (!s || !text || s.status === "needs_you" || s.status === "exited") return;
    S.drafts[key] = "";
    const ta = scr.querySelector(`[data-draft="${key}"]`);
    if (ta) { ta.value = ""; autoGrow(ta); }
    B.send(sid, text).catch(fail);
  }
  function sendLane(sid) {
    const key = `lane:${sid}`;
    const text = (S.drafts[key] || "").trim();
    if (!text) return;
    delete S.drafts[key];
    B.send(sid, text).catch(fail);
  }

  function startRename(sid) {
    const s = ses(sid);
    if (!s) return;
    if (S.view !== sid) openSession(sid);
    S.renaming = sid;
    S.drafts.rename = s.name;
    S.focusKey = "rename";
    schedule();
  }
  function commitRename() {
    if (!S.renaming) return;
    const sid = S.renaming;
    S.renaming = null;
    const s = ses(sid);
    const name = String(S.drafts.rename || "").trim();
    if (s && name && name !== s.name) B.rename(sid, name).catch(fail);
    schedule();
  }
  function cancelRename() {
    S.renaming = null;
    S.focusKey = null;
    schedule();
  }

  function openModal(m) {
    S.modalReturn = document.activeElement;
    S.modal = m;
    renderAll();
    const first = m.type === "new" ? (m.step === 1 ? `nm:k:${m.kind}` : m.step === 2 ? "nm:path" : "nm:prompt") : "m:cancel";
    const n = scr.querySelector(`[data-fk="${first}"]`);
    if (n) n.focus();
  }
  function closeModal() {
    S.modal = null;
    renderAll();
    const r = S.modalReturn;
    S.modalReturn = null;
    if (r && r.isConnected && r.focus) r.focus({ preventScroll: true });
  }
  function openPrefs() {
    if (S.modal && S.modal.type === "prefs") return;
    if (S.modal) S.modal = null;
    openModal({ type: "prefs" });
  }
  function openNew(preset) {
    const cur = ses(S.view);
    S.drafts["nm:path"] = cur ? (cur.kind === "shell" ? cur.cwd : cur.dir) : (S.folders[0] || "");
    S.drafts["nm:prompt"] = "";
    S.dirInfo = {};
    openModal(Object.assign({ type: "new", step: 1, kind: "claude", mode: B.defaultMode }, preset || {}));
    B.folders().then(list => {
      S.folders = list;
      if (!S.drafts["nm:path"] && list.length) S.drafts["nm:path"] = list[0];
      if (S.modal && S.modal.type === "new") renderAll();
    }).catch(() => {});
  }
  function nmGo(step) {
    S.modal.step = step;
    renderAll();
    const k = step === 1 ? `nm:k:${S.modal.kind}` : step === 2 ? "nm:path" : "nm:prompt";
    const n = scr.querySelector(`[data-fk="${k}"]`);
    if (n) { n.focus(); if (n.select && step === 2) n.select(); }
  }
  function nmNext() {
    const m = S.modal;
    if (!m || m.type !== "new" || m.busy) return;
    if (m.step === 1) { nmGo(2); return; }
    if (m.step === 2) {
      const path = normalizePath(S.drafts["nm:path"]);
      const info = S.dirInfo[path];
      if (!path || (info && info.exists && !info.isDir)) { const n = scr.querySelector('[data-fk="nm:path"]'); if (n) n.focus(); return; }
      if (m.kind === "claude") { nmGo(3); return; }
    }
    const path = normalizePath(S.drafts["nm:path"]);
    m.busy = true;
    renderAll();
    B.create({ kind: m.kind, dir: path, prompt: m.kind === "claude" ? S.drafts["nm:prompt"] : "", mode: m.mode }).then(id => {
      S.seenAt[id] = Date.now();
      S.modal = null;
      S.modalReturn = null;
      if (m.kind === "shell") S.trayOpen.delete(id);
      waitForSession(id, () => openSession(id));
    }).catch(err => {
      m.busy = false;
      fail(err);
      renderAll();
    });
  }
  function waitForSession(id, fn, tries) {
    if (ses(id)) { fn(); return; }
    if ((tries || 0) > 40) return;
    setTimeout(() => waitForSession(id, fn, (tries || 0) + 1), 50);
  }

  function act(name, el, ev) {
    const sid = el.dataset.sid;
    switch (name) {
      case "feed": goFeed(); break;
      case "open": openSession(sid); break;
      case "openTerm": openSession(sid); S.focusKey = `term:main:${sid}`; break;
      case "next": nextNeeding(); break;
      case "dnd": {
        const on = !B.prefs.dnd;
        B.setPrefs({ dnd: on }).then(() => toast({ html: on ? "Do not disturb is on. The feed keeps recording." : "Do not disturb is off", ms: 2500 }));
        break;
      }
      case "settings": openPrefs(); break;
      case "pref": {
        const key = el.dataset.pref;
        const now = key === "notifications" ? B.prefs.notifications !== false : !!B.prefs[key];
        B.setPrefs({ [key]: !now }).then(() => schedule());
        break;
      }
      case "new": openNew(); break;
      case "newTerminal": openNew({ kind: "shell", step: 2 }); break;
      case "style": setStyle(el.dataset.style); break;
      case "sfilter": if (S.sessFilter.has(sid)) S.sessFilter.delete(sid); else S.sessFilter.add(sid); schedule(); break;
      case "clearSessFilter": S.sessFilter.clear(); schedule(); break;
      case "filter": S.filter = el.dataset.f; schedule(); break;
      case "pill": {
        const fw = $("feedwrap");
        fw.scrollTo({ top: Math.max(0, $("feedTools").offsetTop - 10), behavior: reduced ? "auto" : "smooth" });
        S.pillCount = 0;
        schedule();
        break;
      }
      case "answer": pickOption(sid, Number(el.dataset.i), el.dataset.where); break;
      case "typeAnswer": pickOption(sid, Number(el.dataset.i), el.dataset.where); break;
      case "sendTyped": sendTyped(sid, el.dataset.key); break;
      case "review": B.review(sid).catch(fail); break;
      case "sendLane": sendLane(sid); break;
      case "send": sendComposer(sid); break;
      case "focusComposer": if (ev.target === el || ev.target.classList.contains("cmp-foot") || ev.target.classList.contains("hint")) { const t = el.querySelector("textarea"); if (t) t.focus(); } break;
      case "bell": { const s = ses(sid); if (s) { const muted = !s.muted; B.setMuted(sid, muted).then(() => toast({ html: muted ? `<b>${esc(s.name)}</b> is muted. It stays quiet.` : `<b>${esc(s.name)}</b> can notify you again`, ms: 2500 })).catch(fail); } break; }
      case "rename": startRename(sid); break;
      case "restart": B.restart(sid).then(() => { if (S.view === sid) S.focusKey = `term:main:${sid}`; schedule(); }).catch(fail); break;
      case "stop": B.stop(sid).catch(fail); break;
      case "delete": openModal({ type: "delete", sid }); break;
      case "confirmDelete": S.modal = null; S.modalReturn = null; removeSession(sid); break;
      case "removeShell": removeSession(sid); break;
      case "finder": B.finder(sid).catch(fail); break;
      case "copyPath": B.copyPath(sid).then(p => toast({ html: `Copied <b>${esc(p)}</b>`, ms: 2500 })).catch(fail); break;
      case "resume": B.resume(el.dataset.cid).then(id => waitForSession(id, () => openSession(id))).catch(fail); break;
      case "trayToggle":
        if (S.trayOpen.has(sid)) S.trayOpen.delete(sid); else { S.trayOpen.add(sid); S.focusKey = `term:tray:${sid}`; }
        saveTray();
        schedule();
        break;
      case "scrim": if (ev.target === el) closeModal(); break;
      case "closeModal": closeModal(); break;
      case "nmKind": S.modal.kind = el.dataset.kind; renderAll(); { const n = scr.querySelector(`[data-fk="nm:k:${S.modal.kind}"]`); if (n) n.focus(); } break;
      case "nmDir": S.drafts["nm:path"] = el.dataset.dir; renderAll(); break;
      case "nmChoose": B.chooseFolder().then(p => { if (p && S.modal) { S.drafts["nm:path"] = p; renderAll(); } }).catch(() => {}); break;
      case "nmMode": S.modal.mode = el.dataset.mode; renderAll(); break;
      case "nmGo": nmGo(Number(el.dataset.step)); break;
      case "nmNext": nmNext(); break;
    }
  }

  function removeSession(sid) {
    const s = ses(sid);
    if (!s) return;
    const name = s.name, toClosed = s.kind === "claude" && s.canResume;
    S.sessFilter.delete(sid);
    S.trayOpen.delete(sid);
    saveTray();
    if (S.view === sid) { S.view = "feed"; S.awayCount = 0; }
    B.remove(sid).then(() => toast({ html: `<b>${esc(name)}</b> ${toClosed ? "moved to Recently closed" : "deleted"}`, ms: 4000 })).catch(fail);
    schedule();
  }

  const inTerminal = el => !!(el && el.closest && el.closest(".xterm"));

  document.addEventListener("click", e => {
    const el = e.target.closest("[data-act]");
    if (el && scr.contains(el)) {
      if (el.disabled) return;
      act(el.dataset.act, el, e);
      return;
    }
    const evRow = e.target.closest(".ev");
    if (evRow && scr.contains(evRow)) openSession(evRow.dataset.sid);
  });

  document.addEventListener("change", e => {
    const el = e.target;
    if (el.dataset && el.dataset.change === "mode") {
      B.setMode(el.dataset.sid, el.value).then(() => toast({ html: `Permission mode: <b>${esc(el.value)}</b>. It applies at the next restart, which keeps the conversation.`, ms: 4000 })).catch(fail);
    }
  });

  document.addEventListener("input", e => {
    const el = e.target;
    if (!el.dataset || !el.dataset.draft) return;
    S.drafts[el.dataset.draft] = el.value;
    if (el.tagName === "TEXTAREA" && el.classList.contains("cmp-text")) autoGrow(el);
    if (el.dataset.draft === "nm:path") {
      const path = normalizePath(el.value);
      const st = $("nmPathStatus");
      if (st) st.innerHTML = pathStatusHTML(path);
      scr.querySelectorAll(".dirs button").forEach(b => b.classList.toggle("on", b.dataset.dir === path));
    }
  });

  document.addEventListener("focusout", e => {
    const el = e.target;
    if (el.dataset && el.dataset.fk === "rename") {
      setTimeout(() => {
        const a = document.activeElement;
        if (a && a.dataset && a.dataset.fk === "rename") return;
        commitRename();
      }, 0);
    }
  });

  function isTextField(el) {
    return !!el && (el.tagName === "TEXTAREA" || (el.tagName === "INPUT" && !["button", "checkbox", "radio"].includes(el.type)) || el.tagName === "SELECT");
  }

  function trapFocus(e) {
    const modal = scr.querySelector(".modal");
    if (!modal) return;
    const f = Array.from(modal.querySelectorAll("button, input, textarea, select")).filter(n => !n.disabled && n.offsetParent !== null);
    if (!f.length) return;
    const first = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    else if (!modal.contains(document.activeElement)) { e.preventDefault(); first.focus(); }
  }

  document.addEventListener("keydown", e => {
    const a = document.activeElement;
    const mod = e.metaKey && !e.ctrlKey;
    const k = e.key;

    if (S.modal) {
      if (k === "Escape") { e.preventDefault(); closeModal(); return; }
      if (k === "Tab") { trapFocus(e); return; }
      if (k === "Enter" && S.modal.type === "new") {
        if (a && a.dataset && a.dataset.draft === "nm:prompt") { if (!e.shiftKey) { e.preventDefault(); nmNext(); } return; }
        if (a && a.dataset && a.dataset.enter === "nmNext") { e.preventDefault(); nmNext(); return; }
        if (a && a.dataset && a.dataset.act === "nmKind") { e.preventDefault(); S.modal.kind = a.dataset.kind; nmNext(); return; }
      }
      if (S.modal.type === "new" && S.modal.step === 1 && (k === "ArrowLeft" || k === "ArrowRight" || k === "ArrowUp" || k === "ArrowDown")) {
        e.preventDefault();
        S.modal.kind = S.modal.kind === "claude" ? "shell" : "claude";
        renderAll();
        const n = scr.querySelector(`[data-fk="nm:k:${S.modal.kind}"]`);
        if (n) n.focus();
      }
      return;
    }

    if (mod && !e.altKey && (k === "j" || k === "J")) { e.preventDefault(); nextNeeding(); return; }
    if (mod && !e.altKey && (k === "n" || k === "N")) { e.preventDefault(); openNew(); return; }
    if (mod && k === ",") { e.preventDefault(); openPrefs(); return; }
    if (mod && k === "0") { e.preventDefault(); goFeed(); return; }
    if (mod && /^[1-9]$/.test(k)) {
      e.preventDefault();
      const s = listOrder().all[Number(k) - 1];
      if (s) openSession(s.id);
      return;
    }
    if (inTerminal(a)) return;

    if (a && a.dataset && a.dataset.composer) {
      if (k === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); sendComposer(a.dataset.composer); return; }
      if (k === "Escape") {
        e.preventDefault();
        const s = ses(a.dataset.composer);
        if (s && s.status === "working") B.interrupt(s.id).catch(fail); else a.blur();
        return;
      }
    }
    if (a && a.dataset && a.dataset.enter && a.classList.contains("field")) {
      if (k === "Enter") { e.preventDefault(); act(a.dataset.enter, a, e); return; }
      if (k === "Escape") {
        e.preventDefault();
        const key = a.dataset.key;
        if (S.typing[key]) { delete S.typing[key]; schedule(); }
        a.blur();
        return;
      }
    }
    if (a && a.dataset && a.dataset.fk === "rename") {
      if (k === "Enter") { e.preventDefault(); commitRename(); return; }
      if (k === "Escape") { e.preventDefault(); cancelRename(); return; }
      return;
    }
    if (k === "Escape") {
      if (isTextField(a)) { a.blur(); return; }
      if (S.view !== "feed") { e.preventDefault(); goFeed(); }
      return;
    }
    if (isTextField(a) || e.metaKey || e.ctrlKey || e.altKey) return;
    if (k === "F2") { if (S.view !== "feed") { e.preventDefault(); startRename(S.view); } return; }
    if (k === "?") { e.preventDefault(); openModal({ type: "help" }); return; }
    if (k === "Enter" && a && a.classList && a.classList.contains("ev")) { e.preventDefault(); openSession(a.dataset.sid); return; }
    if (/^[1-9]$/.test(k)) {
      const holder = a && a.closest && a.closest('[data-ask]:not([data-ask=""])');
      let sid = holder ? holder.dataset.ask : null;
      let where = holder ? holder.dataset.where : "ans";
      if (!sid && S.view !== "feed") { sid = S.view; where = "ans"; }
      const s = ses(sid);
      if (!s || s.status !== "needs_you" || !s.ask) return;
      e.preventDefault();
      pickOption(sid, Number(k) - 1, where);
    }
  });

  $("feedwrap").addEventListener("scroll", () => {
    if (S.pillCount && isFeedLive()) {
      S.pillCount = 0;
      $("newPill").hidden = true;
    }
  }, { passive: true });

  window.addEventListener("error", e => B.log(`page error: ${e.message} at ${e.filename}:${e.lineno}`));

  setInterval(tick, 1000);

  S.style = initialStyle();
  S.trayOpen = initialTray();
  scr.dataset.style = S.style;
  window.__app = { S, B, T, renderAll, openSession, openNew, openPrefs, goFeed };
  B.start().catch(err => {
    document.body.insertAdjacentHTML("beforeend", `<p style="position:fixed;bottom:12px;left:12px;font:12px system-ui;color:#999">Native bridge unavailable: ${esc(err && err.message)}</p>`);
  });
})();
