(function () {
  "use strict";

  const B = window.Backend;
  const DATA = window.TM;
  const $ = id => document.getElementById(id);
  const scr = $("scr");
  const esc = s => String(s == null ? "" : s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const pad = n => String(n).padStart(2, "0");
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const STATUS = Object.assign({}, DATA.statuses, { reviewed: { label: "Reviewed" } });
  const VERB = { Read: "Read", Update: "Edited", Edit: "Edited", Write: "Wrote", Bash: "Ran", Search: "Searched", Glob: "Listed" };
  const MODE_HINT = ["Asks before every change", "Edits freely, asks for commands", "Reads and plans, changes nothing"];
  const GLYPHS = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"];
  const IC = {
    bell: '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M8 2.2a3.8 3.8 0 0 0-3.8 3.8v2.4L3 10.6h10l-1.2-2.2V6A3.8 3.8 0 0 0 8 2.2ZM6.4 12.4a1.7 1.7 0 0 0 3.2 0" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>',
    bellOff: '<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path d="M8 2.2a3.8 3.8 0 0 0-3.8 3.8v2.4L3 10.6h10l-1.2-2.2V6A3.8 3.8 0 0 0 8 2.2ZM6.4 12.4a1.7 1.7 0 0 0 3.2 0M2.5 2.5l11 11" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>',
    pin: '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M10 2l4 4-1.6.6-2.6 2.6.3 2.8-1.1 1.1L6.4 10.5 3 14M5.5 9.6 3 7.1l1.1-1.1 2.8.3L9.4 3.6Z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>',
    pinOn: '<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M10 2l4 4-1.6.6-2.6 2.6.3 2.8-1.1 1.1-6-6 1.1-1.1 2.8.3L9.4 3.6Z" fill="currentColor"/><path d="M6.4 10.5 3 14" stroke="currentColor" stroke-width="1.4"/></svg>',
    funnel: '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M2.5 3h11L9.3 8.2V13l-2.6-1.3V8.2Z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>'
  };

  const S = {
    view: "feed", style: "a", filter: "all", sessFilter: new Set(), pins: new Set(), seenAt: {}, lastLook: Date.now() - 15 * 60000,
    drafts: {}, typing: {}, renaming: null, modal: null, modalReturn: null, dnd: false, trayOpen: new Set(["t2"]),
    awayCount: 0, pillCount: 0, feedMaxSeq: 0, firstRender: true, feedWasHidden: false, histPos: {}, focusKey: null, focusEv: null, autoFocus: false, closedIds: 0
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
    const st = storageGet("tm-activity-feed-style");
    return /^[abc]$/.test(st || "") ? st : "a";
  }

  const ses = id => B.byId(id);
  const seenOf = sid => (S.seenAt[sid] != null ? S.seenAt[sid] : S.lastLook);
  const isUnseen = e => e.type !== "think" && e.at > seenOf(e.sid);
  const shapeSt = st => `<span class="shape s-${st}" aria-hidden="true"></span>`;
  const shape = s => (s ? `<span class="shape s-${s.status}${s.status === "exited" && s.exitCode ? " bad" : ""}" aria-hidden="true"></span>` : shapeSt("exited"));
  const askHTML = t => esc(t).replace(/(Bash|Edit|Write): (.+)\?$/, "$1: <code>$2</code>?");
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
    return `${Math.floor(m / 60)} h ago`;
  }

  function tickText(spec) {
    const i = spec.indexOf(":");
    const kind = spec.slice(0, i), id = spec.slice(i + 1);
    const t = Date.now();
    if (kind === "ago") return fmtAgo(t - Number(id));
    if (kind === "ev") { const e = B.events.find(x => x.seq === Number(id)); return e ? fmtShort(t - e.at) : ""; }
    if (kind === "closed") { const c = B.closed.find(x => x._id === Number(id)); return c ? (c.closedAt ? fmtAgo(t - c.closedAt) : c.closed) : ""; }
    const s = ses(id);
    if (!s) return "";
    if (kind === "since") return fmtShort(t - s.statusAt);
    if (kind === "pill") return s.status === "working" ? fmtClock(t - s.statusAt) : fmtShort(t - s.statusAt);
    if (kind === "total") return fmtShort(t - s.startedAt);
    if (kind === "cost") return `$${s.cost.toFixed(2)}`;
    if (kind === "secs") return fmtShort(t - s.statusAt);
    return "";
  }
  function tick(root) {
    (root || scr).querySelectorAll("[data-tick]").forEach(el => {
      const txt = tickText(el.dataset.tick);
      if (el.textContent !== txt) el.textContent = txt;
    });
  }

  const FOCUS_ATTRS = ["act", "sid", "i", "f", "where", "step", "kind", "dir", "mode", "seq", "cid", "style"];
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
    if (n.classList.contains("shin-i")) updateMirror(n);
  }
  function hydrate(root) {
    root.querySelectorAll("[data-draft]").forEach(i => {
      const v = S.drafts[i.dataset.draft] || "";
      if (i.value !== v) i.value = v;
      if (i.classList.contains("shin-i")) updateMirror(i);
      if (i.tagName === "TEXTAREA") autoGrow(i);
    });
    tick(root);
  }
  function patch(el, html) {
    if (!el || el._h === html) return false;
    const f = captureFocus(el);
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

  function updateMirror(input) {
    const m = input.nextElementSibling;
    if (!m) return;
    const v = input.value;
    const p = typeof input.selectionStart === "number" ? input.selectionStart : v.length;
    m.innerHTML = `${esc(v.slice(0, p))}<span class="cur">${esc(v[p] || " ")}</span>${esc(v.slice(p + 1))}`;
  }
  function autoGrow(t) {
    t.style.height = "auto";
    t.style.height = `${Math.min(Math.max(t.scrollHeight, 38), 140)}px`;
  }

  function cat(e) {
    if (e.type === "tool") return e.tool === "Bash" ? "command" : /^(Update|Edit|Write)$/.test(e.tool) ? "edit" : "other";
    if (e.type === "cmd") return "command";
    if (e.type === "perm" || e.type === "ask") return "ask";
    if (e.type === "done") return "finished";
    if (e.type === "you") return "you";
    return "other";
  }
  function kindLabel(e) {
    const c = ({ edit: "edit", command: "run", ask: "ask", finished: "done", you: "you" })[cat(e)];
    if (c) return c;
    return ({ say: "note", think: "think", tool: "read", out: "out", exit: "exit", life: "info" })[e.type] || "info";
  }

  function listOrder() {
    const order = { needs_you: 0, ready: 1, working: 2, idle: 3, reviewed: 4 };
    const sortSt = arr => arr.map((s, i) => [s, i]).sort((a, b) => ((order[a[0].status] ?? 5) - (order[b[0].status] ?? 5)) || a[1] - b[1]).map(x => x[0]);
    const claude = sortSt(B.sessions.filter(s => s.kind === "claude" && s.host !== "outside"));
    const outside = sortSt(B.sessions.filter(s => s.host === "outside"));
    const shells = B.sessions.filter(s => s.kind === "shell");
    return { claude, outside, shells, all: claude.concat(outside, shells) };
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
    d.classList.toggle("on", S.dnd);
    d.setAttribute("aria-checked", String(S.dnd));
    $("styleSeg").querySelectorAll("button").forEach(b => { const on = b.dataset.style === S.style; b.classList.toggle("on", on); b.setAttribute("aria-checked", String(on)); });
  }

  function rowItem(s) {
    const nNew = S.view === s.id ? 0 : unseenCount(s.id);
    const sub = s.kind === "shell" ? (s.status === "process" ? s.command : s.status === "exited" ? `code ${s.exitCode}` : s.cwd) : s.summary;
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
    const html = `<button class="row-main" data-act="open" data-sid="${s.id}"><span class="r-1">${shape(s)}<span class="r-name">${esc(s.name)}</span>${s.host === "outside" ? `<span class="r-badge">Terminal.app</span>` : ""}${s.muted ? `<span class="r-muted" title="Notifications muted">${IC.bellOff}</span>` : ""}${nNew ? `<span class="r-new">${nNew} new</span>` : ""}<span class="r-time" data-tick="since:${s.id}"></span></span><span class="r-sub"><span class="r-st">${statusLabel(s)}</span>${sub ? ` · ${esc(sub)}` : ""}</span></button><button class="r-filter" data-act="sfilter" data-sid="${s.id}" aria-pressed="${filtering}" title="${filtering ? "Stop filtering the feed to this session" : "Show only this session in the feed"}" aria-label="${filtering ? "Stop filtering the feed" : `Show only ${esc(s.name)} in the feed`}">${IC.funnel}</button>${qa}`;
    return {
      key: `r:${s.id}`, html,
      cls: `row st-${s.status}${S.view === s.id ? " on" : ""}${filtering ? " filtering" : ""}${S.typing[`qa:${s.id}`] ? " qa-open" : ""}`,
      attrs: { "data-ask": s.status === "needs_you" ? s.id : "", "data-where": "qa" }
    };
  }

  function renderList() {
    const { claude, outside, shells } = listOrder();
    const items = [];
    items.push({ key: "h:claude", cls: "l-h", html: `Claude <span class="c">${claude.length}</span>` });
    if (!claude.length) items.push({ key: "e:claude", cls: "l-empty", html: "No Claude sessions. Press ⌘N to start one." });
    claude.forEach(s => items.push(rowItem(s)));
    if (outside.length) {
      items.push({ key: "h:outside", cls: "l-h", html: `Outside the app <span class="c">${outside.length}</span>` });
      items.push({ key: "n:outside", cls: "l-note", tag: "p", html: "Seen through Claude Code hooks. Answer here; type in its own window." });
      outside.forEach(s => items.push(rowItem(s)));
    }
    items.push({ key: "h:term", cls: "l-h", html: `Terminals <span class="c">${shells.length}</span>` });
    shells.forEach(s => items.push(rowItem(s)));
    items.push({ key: "h:closed", cls: "l-h", html: `Recently closed <span class="c">${B.closed.length}</span>` });
    if (!B.closed.length) items.push({ key: "e:closed", cls: "l-empty", html: "Deleted sessions wait here." });
    B.closed.slice(0, 6).forEach(c => {
      if (!c._id) c._id = ++S.closedIds;
      const fresh = c.closedAt && Date.now() - c.closedAt < 60000;
      items.push({
        key: `x:${c._id}`, cls: `closed-row${fresh ? " hl" : ""}`,
        html: `${c.kind === "claude" ? shapeSt("idle") : shapeSt("exited")}<span class="nm">${esc(c.name)}</span><span class="when" data-tick="closed:${c._id}"></span><button class="btn" data-act="resume" data-cid="${c._id}">${c.kind === "claude" ? "Resume" : "Reopen"}</button>`
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
    const msg = s.lines.filter(l => !l.trim().startsWith("⎿") && !/^⏺ \w+\(/.test(l) && !l.startsWith("> ") && !l.startsWith("⎯") && l.trim())
      .slice(-2).map(l => l.replace(/^⏺\s*/, "").trim()).join(" ");
    return msg || s.summary || "";
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
      const add = s.files.reduce((a, f) => a + f.add, 0), del = s.files.reduce((a, f) => a + f.del, 0);
      html = `<div class="wc-top">${shape(s)}<span class="wc-kind">Ready for review</span><span class="wc-t" data-tick="since:${s.id}"></span></div>
        <button class="wc-name" data-act="open" data-sid="${s.id}">${esc(s.name)}<small>${esc(s.dir)}</small></button>
        <div class="wc-msg">${esc(lastMessage(s))}</div>
        <div class="wc-files">${s.files.length} file${s.files.length === 1 ? "" : "s"} <span class="add">+${add}</span><span class="del">−${del}</span><button class="btn sm ok" data-act="review" data-sid="${s.id}">Looks good</button></div>
        ${s.host === "outside" ? "" : inrowHTML(`lane:${s.id}`, s.id, `Feedback for ${s.name}`, "sendLane")}`;
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

  function digestHTML() {
    let oldest = Infinity;
    const rows = listOrder().all.map(s => {
      const seen = seenOf(s.id);
      const evs = B.events.filter(e => e.sid === s.id && e.type !== "think" && e.at > seen);
      if (!evs.length) return "";
      oldest = Math.min(oldest, seen);
      const c = {};
      evs.forEach(e => { const k = e.type === "out" ? "out" : cat(e); c[k] = (c[k] || 0) + 1; });
      const parts = [];
      if (c.edit) parts.push(`${c.edit} edit${c.edit > 1 ? "s" : ""}`);
      if (c.command) parts.push(`${c.command} command${c.command > 1 ? "s" : ""}`);
      if (c.other && !c.edit && !c.command) parts.push(`${c.other} note${c.other > 1 ? "s" : ""}`);
      if (c.out) parts.push(`${c.out} line${c.out > 1 ? "s" : ""} of output`);
      const nowTxt = {
        needs_you: s.ask && s.ask.type === "permission" ? "waiting on a permission" : "waiting on your answer",
        ready: "ready for review", working: "still working", reviewed: "reviewed", idle: s.kind === "claude" ? "waiting for a message" : "at the prompt",
        process: "still running", exited: `exited with code ${s.exitCode}`
      }[s.status] || s.status;
      return `<button class="dg-row st-${s.status}" data-act="open" data-sid="${s.id}" title="Open ${esc(s.name)}">${shape(s)}<b>${esc(s.name)}</b><span>${parts.length ? `${parts.join(", ")}, ` : ""}<em>${nowTxt}</em></span></button>`;
    }).join("");
    if (!rows) return `<div class="digest empty"><b>You're caught up.</b> Activity from sessions you haven't opened collects here.</div>`;
    return `<div class="digest"><div class="dg-head"><h3>Since you last looked</h3><span class="ago" data-tick="ago:${oldest}"></span><button class="btn sm" data-act="markAll">Mark all seen</button></div><div class="dg-grid">${rows}</div></div>`;
  }

  function evText(e) {
    switch (e.type) {
      case "tool": return `<span class="v">${VERB[e.tool] || e.tool}</span> <code>${esc(e.args)}</code>`;
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
    const pinned = S.pins.has(e.seq);
    const name = s ? s.name : e.sname;
    const html = `<span class="ev-time"><b>${pad(t.getHours())}:${pad(t.getMinutes())}</b><span class="sec">:${pad(t.getSeconds())}</span></span><span class="ev-tag" style="--tag:${s ? s.tag : "#8A8C95"}">${shape(s)}<span class="nm">${esc(name)}</span></span><div class="ev-what"><span class="ev-kind">${kindLabel(e)}</span><span class="ev-text">${evText(e)}</span>${e.detail ? `<span class="ev-detail">${esc(e.detail)}</span>` : ""}</div><button class="ev-pin" data-act="pin" data-seq="${e.seq}" title="${pinned ? "Unpin" : "Pin"} (P)" aria-label="${pinned ? "Unpin this event" : "Pin this event"}" aria-pressed="${pinned}">${pinned ? IC.pinOn : IC.pin}</button>`;
    return {
      key: String(e.seq), html, fresh: e.seq > S.feedMaxSeq,
      cls: `ev k-${cat(e)}${pending ? " pending" : ""}${live ? " live" : ""}${cont ? " cont" : ""}${isUnseen(e) ? " new" : ""}${pinned ? " pinned" : ""}`,
      attrs: { tabindex: "0", "data-key": String(e.seq), "data-sid": e.sid }
    };
  }

  function feedData() {
    const visible = B.events.filter(e => e.type !== "think" || (ses(e.sid) || {}).status === "working");
    const scoped = S.sessFilter.size ? visible.filter(e => S.sessFilter.has(e.sid)) : visible;
    const counts = { all: scoped.length };
    scoped.forEach(e => { const k = cat(e); counts[k] = (counts[k] || 0) + 1; });
    const filtered = scoped.filter(e => S.filter === "all" || cat(e) === S.filter).sort((a, b) => (b.at - a.at) || (b.seq - a.seq));
    return { counts, pinned: filtered.filter(e => S.pins.has(e.seq)), rest: filtered.filter(e => !S.pins.has(e.seq)).slice(0, 250) };
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

    patch($("digest"), digestHTML());

    const { counts, pinned, rest } = feedData();
    const chips = [["all", "All"], ["ask", "Asks"], ["edit", "Edits"], ["command", "Commands"], ["finished", "Finished"], ["you", "From you"]];
    const names = Array.from(S.sessFilter).map(id => (ses(id) || { name: "closed" }).name);
    patch($("feedTools"), `<h2>Activity</h2>${chips.map(([k, n]) => `<button class="chip ${S.filter === k ? "on" : ""}" data-act="filter" data-f="${k}" aria-pressed="${S.filter === k}">${n}<span class="n">${counts[k] || 0}</span></button>`).join("")}${names.length ? `<button class="chip sess" data-act="clearSessFilter" title="Show every session again">Only ${esc(names.join(", "))}<span class="x" aria-hidden="true">✕</span></button>` : ""}<span class="live"><i></i>Live</span>`);

    const pb = $("pinnedBox");
    pb.hidden = !pinned.length;
    patch(pb.firstElementChild, `${IC.pinOn} Pinned <span style="font-family:var(--mono);font-weight:400">${pinned.length}</span>`);
    reconcile($("pinList"), pinned.map(e => evItem(e, false)));

    let prev = null, added = 0;
    const items = rest.map(e => { const it = evItem(e, prev === e.sid); prev = e.sid; return it; });
    reconcile($("evlist"), items, {
      enter: (n, it) => {
        if (quiet || !it.fresh) return;
        if (live) animateEvIn(n); else added++;
      }
    });
    if (added) S.pillCount += added;
    $("feedEmpty").hidden = !!(rest.length || pinned.length);
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

  const PROMPT_RE = /^((?:\([\w.-]+\) )?\S+@\S+ \S+ % )/;
  function termLine(l) {
    const pm = PROMPT_RE.exec(l);
    if (pm) return `<div><span class="l-prompt">${esc(pm[1])}</span>${esc(l.slice(pm[1].length))}</div>`;
    if (l === "^C" || /^\[process/.test(l) || l.startsWith("⎯ ") || /^ {2}cwd: /.test(l)) return `<div class="l-dim">${esc(l)}</div>`;
    if (l.startsWith("> ")) return `<div class="l-user">${esc(l)}</div>`;
    if (l.startsWith("⏺ ")) {
      const body = l.slice(2), m = /^(\w+)\((.*)\)$/.exec(body);
      return `<div><span class="l-dot">⏺</span> ${m ? `<span class="l-tool">${esc(m[1])}</span><span class="l-args">(${esc(m[2])})</span>` : esc(body)}</div>`;
    }
    if (l.trim().startsWith("⎿")) return `<div class="l-res">${esc(l)}</div>`;
    if (l.startsWith("✻")) return `<div class="l-think">${esc(l)}</div>`;
    return `<div>${esc(l) || " "}</div>`;
  }

  function nearBottom(el) { return el.scrollHeight - el.scrollTop - el.clientHeight < 40; }

  function renderTermLines(s, termEl, linesEl, max) {
    const st = linesEl._st;
    if (!st || st.arr !== s.lines || st.n > s.lines.length) {
      linesEl.innerHTML = s.lines.slice(-max).map(termLine).join("");
      linesEl._st = { arr: s.lines, n: s.lines.length };
      termEl.scrollTop = termEl.scrollHeight;
    } else if (st.n < s.lines.length) {
      const stick = nearBottom(termEl);
      linesEl.insertAdjacentHTML("beforeend", s.lines.slice(st.n).map(termLine).join(""));
      st.n = s.lines.length;
      if (stick) termEl.scrollTop = termEl.scrollHeight;
    }
  }

  function shellInputHTML(s, where) {
    return `<label class="txt shin"><input class="shin-i" data-draft="sh:${s.id}" data-fk="sh:${s.id}:${where}" data-shell="${s.id}" spellcheck="false" autocomplete="off" aria-label="Command line for ${esc(s.name)}"><span class="shin-m" aria-hidden="true"></span></label>`;
  }

  function composerHTML(s, ph) {
    const working = s.status === "working";
    return `<div class="composer" data-act="focusComposer"><textarea class="cmp-text" rows="1" data-draft="cmp:${s.id}" data-fk="cmp:${s.id}" data-composer="${s.id}" placeholder="${esc(ph)}" aria-label="${esc(ph)}"></textarea><div class="cmp-foot"><span class="hint">⏎ send · ⇧⏎ new line${working ? " · Esc interrupts" : ""}</span><button class="btn sm primary" data-act="send" data-sid="${s.id}"${working ? " disabled" : ""}>Send</button></div></div>`;
  }

  function barHTML(s) {
    const outside = s.host === "outside", shell = s.kind === "shell";
    const label = s.status === "exited" ? `Exited · code ${s.exitCode}` : statusLabel(s);
    const acts = [`<button class="btn icon" data-act="bell" data-sid="${s.id}" aria-pressed="${s.muted}" title="${s.muted ? "Unmute notifications" : "Mute notifications"}" aria-label="${s.muted ? "Unmute notifications" : "Mute notifications"}">${s.muted ? IC.bellOff : IC.bell}</button>`];
    acts.push(`<button class="btn sm" data-act="rename" data-sid="${s.id}">Rename</button>`);
    if (outside) {
      acts.push(`<button class="btn sm" data-act="showWindow" data-sid="${s.id}">Show its window</button>`, `<button class="btn sm danger" data-act="removeOutside" data-sid="${s.id}">Remove from list</button>`);
    } else if (shell) {
      if (s.status === "process") acts.push(`<button class="btn sm" data-act="stop" data-sid="${s.id}">Stop<kbd>⌃C</kbd></button>`);
      acts.push(`<button class="btn sm" data-act="restart" data-sid="${s.id}">Restart</button>`);
      acts.push(s.status === "exited" ? `<button class="btn sm danger" data-act="removeShell" data-sid="${s.id}">Remove</button>` : `<button class="btn sm danger" data-act="delete" data-sid="${s.id}">Delete</button>`);
    } else {
      acts.push(`<button class="btn sm" data-act="restart" data-sid="${s.id}">Restart</button>`, `<button class="btn sm" data-act="stop" data-sid="${s.id}"${s.status === "working" ? "" : " disabled"}>Stop</button>`, `<button class="btn sm danger" data-act="delete" data-sid="${s.id}">Delete</button>`);
    }
    const title = S.renaming === s.id
      ? `<input class="rename" data-fk="rename" data-draft="rename" data-sid="${s.id}" aria-label="Session name" spellcheck="false">`
      : `<h2 title="F2 to rename">${esc(s.name)}</h2>`;
    return `<button class="back" data-act="feed">All activity${S.awayCount ? `<span class="r-new">${S.awayCount} new</span>` : ""}</button>
      <div class="sv-title">${shape(s)}${title}<span class="pill st-${s.status}">${label} · <span class="tm" data-tick="pill:${s.id}"></span></span>${outside ? `<span class="r-badge">Terminal.app</span>` : ""}</div>
      <div class="sv-acts">${acts.join("")}</div>`;
  }

  function metaHTML(s) {
    const dir = `<span class="m"><span class="dir">${esc(s.kind === "shell" ? s.cwd : s.dir)}</span><button class="lnk" data-act="finder" data-sid="${s.id}">Open in Finder</button><button class="lnk" data-act="copyPath" data-sid="${s.id}">Copy path</button></span>`;
    if (s.kind === "shell") {
      return `<span class="m"><span class="k">In status</span><b data-tick="since:${s.id}"></b></span>${s.command && s.status !== "idle" ? `<span class="m"><span class="k">Command</span><b>${esc(s.command)}</b></span>` : ""}<span class="m"><span class="k">Shell</span><b>zsh</b></span>${dir}`;
    }
    const ctx = Math.round(s.context || 0);
    const modeCtl = s.host === "outside"
      ? `<b>${esc(s.mode)}</b>`
      : `<span class="sel"><select data-change="mode" data-sid="${s.id}" data-fk="mode:${s.id}" aria-label="Permission mode">${DATA.permissionModes.map(m => `<option${m === s.mode ? " selected" : ""}>${esc(m)}</option>`).join("")}</select></span>`;
    return `<span class="m"><span class="k">In status</span><b data-tick="since:${s.id}"></b></span>
      <span class="m"><span class="k">Total</span><b data-tick="total:${s.id}"></b></span>
      <span class="m"><span class="k">Context</span><span class="meter ${ctx >= 80 ? "hot" : ""}"><i style="width:${ctx}%"></i></span><b>${ctx}%</b>${ctx >= 80 ? `<span style="color:var(--needs)">near limit</span>` : ""}</span>
      <span class="m"><span class="k">Cost</span><b data-tick="cost:${s.id}"></b></span>
      <span class="m"><span class="k">Mode</span>${modeCtl}</span>${dir}`;
  }

  function cmdHTML(s) {
    if (s.kind !== "shell") return "";
    if (s.status === "process") return `<div class="cmdline"><span class="muted">${esc(s.command)} is running. Stop it to get a prompt back.</span><button class="tbtn warn" data-act="stop" data-sid="${s.id}">Stop (⌃C)</button></div>`;
    if (s.status === "exited") return `<div class="cmdline"><span class="muted">Process exited with code ${s.exitCode}.</span><button class="tbtn" data-act="restart" data-sid="${s.id}">Restart</button><button class="tbtn" data-act="removeShell" data-sid="${s.id}">Remove</button></div>`;
    return `<div class="cmdline"><span class="pfx">${esc(B.promptOf(s))}</span>${shellInputHTML(s, "full")}</div>`;
  }

  function bottomHTML(s) {
    if (s.kind === "shell") return "";
    const outside = s.host === "outside";
    let out = "";
    if (s.status === "needs_you" && s.ask) {
      const typing = S.typing[`ans:${s.id}`];
      out += `<div class="askp" data-ask="${s.id}" data-where="ans" tabindex="-1"><div class="askp-k">${shape(s)}${s.ask.type === "permission" ? "Needs permission" : "Asked a question"}<span class="t">waiting <span data-tick="since:${s.id}"></span></span></div>
        <div class="askp-q">${askHTML(s.ask.text)}</div>
        <div class="opts">${optsHTML(s, "ans", true)}<span class="askp-foot">${outside ? "Your answer is relayed to its Terminal.app window" : `Press 1–${s.ask.options.length} to choose`}</span></div>
        ${typing ? inrowHTML(`ans:${s.id}`, s.id, "Type your answer", "sendTyped", "Send answer") : ""}</div>`;
    } else if (s.status === "ready") {
      const add = s.files.reduce((a, f) => a + f.add, 0), del = s.files.reduce((a, f) => a + f.del, 0);
      out += `<div class="review"><div class="rv-head">${shape(s)}<b>Review this turn</b><span class="sum">${s.files.length} file${s.files.length === 1 ? "" : "s"} changed · <span class="add">+${add}</span> <span class="del">−${del}</span></span><button class="btn sm ok" data-act="review" data-sid="${s.id}">Looks good</button></div>
        ${s.files.length ? `<div class="rv-files">${s.files.map(f => `<div><span class="p">${esc(f.path)}</span>${f.binary ? `<span class="bin">binary</span>` : `<span class="add">+${f.add}</span><span class="del">−${f.del}</span>`}</div>`).join("")}</div>` : `<p class="rv-none">No files changed this turn.</p>`}
        ${outside ? "" : composerHTML(s, `Feedback for ${s.name}`)}</div>`;
    } else if (!outside) {
      out += composerHTML(s, `Message ${s.name}`);
    }
    if (outside) out += `<div class="note">Typing to ${esc(s.name)} happens in its Terminal.app window.<button class="btn sm" data-act="showWindow" data-sid="${s.id}">Show its window</button></div>`;
    return out;
  }

  function renderSession(s) {
    const sv = $("sessionView");
    if (sv._sid !== s.id || sv._kind !== s.kind) {
      sv.innerHTML = `<div class="sv-bar" id="svBar"></div><div class="sv-meta" id="svMeta"></div><div id="svOutside" hidden></div>
        <div class="termbox"><div class="term" id="svTerm" tabindex="-1"><div class="tl" id="svLines"></div><div class="live" id="svLive"></div></div><div id="svCmd"></div></div>
        <div class="bottom" id="svBottom" hidden></div>`;
      sv._sid = s.id;
      sv._kind = s.kind;
    }
    patch($("svBar"), barHTML(s));
    patch($("svMeta"), metaHTML(s));
    const so = $("svOutside");
    so.hidden = s.host !== "outside";
    patch(so, s.host === "outside" ? `<div class="outside">${shapeSt("idle")}<span><b>Running outside the app.</b> ${esc(s.name)} was started in Terminal.app. The app sees it through Claude Code hooks, so you can answer its prompts here but can't type to, restart or stop it.</span></div>` : "");
    const term = $("svTerm");
    renderTermLines(s, term, $("svLines"), 400);
    const stick = nearBottom(term);
    if (patch($("svLive"), s.kind === "claude" && s.status === "working" ? `<div class="l-think"><span class="glyph">✻</span> Working… (<span data-tick="secs:${s.id}"></span> · esc to interrupt)</div>` : "") && stick) term.scrollTop = term.scrollHeight;
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
    const label = s.status === "exited" ? `Exited · code ${s.exitCode}` : statusLabel(s);
    const last = s.lines.length ? s.lines[s.lines.length - 1] : B.promptOf(s);
    let body = "";
    if (open) {
      body = `<div class="term"><div class="tl">${s.lines.slice(-40).map(termLine).join("") || `<div class="l-dim">Fresh shell in ${esc(s.cwd)}</div>`}</div></div>`;
      if (s.status === "idle") body += `<div class="cmdline"><span class="pfx">%</span>${shellInputHTML(s, "tray")}</div><div class="tsh-acts"><button class="lnk" data-act="open" data-sid="${s.id}">Open full</button></div>`;
      else if (s.status === "process") body += `<div class="tsh-acts"><button class="btn sm" data-act="stop" data-sid="${s.id}">Stop (⌃C)</button><button class="lnk" data-act="open" data-sid="${s.id}">Open full</button></div>`;
      else body += `<div class="tsh-acts"><button class="btn sm" data-act="restart" data-sid="${s.id}">Restart</button><button class="btn sm danger" data-act="removeShell" data-sid="${s.id}">Remove</button><button class="lnk" data-act="open" data-sid="${s.id}">Open full</button></div>`;
    }
    const html = `<button class="tsh-tog" data-act="trayToggle" data-sid="${s.id}" aria-expanded="${open}" title="${open ? "Collapse" : "Expand"} ${esc(s.name)}"><span class="tsh-head">${shape(s)}<span class="nm">${esc(s.name)}</span><span class="st"><b>${label}</b> · <span data-tick="since:${s.id}"></span></span></span>${open ? "" : `<span class="tsh-last">${esc(last)}</span>`}</button>${body}`;
    return { key: s.id, cls: `tsh${open ? " open" : ""}`, html, attrs: { "data-shellcard": s.id } };
  }

  function renderTray() {
    const shells = B.sessions.filter(s => s.kind === "shell");
    $("trayN").textContent = shells.length;
    const stick = n => { const t = n.querySelector(".term"); if (t) t.scrollTop = t.scrollHeight; };
    reconcile($("trayList"), shells.map(trayItem), { enter: stick, update: stick });
  }

  function modalHTML() {
    const m = S.modal;
    if (!m) return null;
    if (m.type === "delete") {
      const s = ses(m.sid);
      if (!s) return null;
      return { cls: "modal delm", label: "delTitle", html: `
        <h2 id="delTitle">Delete ${esc(s.name)}?</h2>
        <p class="sub">Ends the process. Claude sessions can be resumed later from Recently closed.</p>
        <div class="what">${shape(s)}<b>${esc(s.name)}</b><code>${esc(s.dir)}</code></div>
        <div class="modal-foot"><button class="btn" data-act="closeModal" data-fk="m:cancel">Cancel</button><button class="btn danger-fill" data-act="confirmDelete" data-sid="${s.id}" data-fk="m:ok">End and delete</button></div>` };
    }
    if (m.type === "help") {
      const rows = [
        ["⌘J", "Next session needing you, then ready ones"], ["⌘N", "New session sheet"], ["⌘0 · Esc", "Back to All activity"],
        ["⌘1 … ⌘9", "Open the nth session in the list"], ["1 2 3", "Pick an option on the focused prompt"], ["⏎ · ⇧⏎", "Send / new line in the composer"],
        ["Esc", "Interrupt a working session; closes sheets"], ["⌃C", "Stop a shell's foreground process"], ["⌃L", "Clear the focused shell"],
        ["↑ ↓", "Shell history"], ["F2", "Rename the open session inline"], ["P", "Pin or unpin the focused feed event"], ["?", "This list"]
      ];
      return { cls: "modal help", label: "helpTitle", html: `
        <h2 id="helpTitle">Keyboard shortcuts</h2>
        <p class="sub">Ctrl works in place of ⌘, since the browser keeps some ⌘ shortcuts for itself.</p>
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
      s2 = `<div class="dirs">${B.recentDirs.slice(0, 9).map(d => `<button class="${d === path ? "on" : ""}" data-act="nmDir" data-dir="${esc(d)}">${esc(d)}</button>`).join("")}</div>
        <label class="pathf"><input data-draft="nm:path" data-fk="nm:path" data-enter="nmNext" placeholder="~/work/new-project" spellcheck="false" autocomplete="off" aria-label="Folder path"><span id="nmPathStatus">${pathStatusHTML(path)}</span></label>`;
    }
    if (m.step === 3) {
      s3 = `<textarea class="ta" data-draft="nm:prompt" data-fk="nm:prompt" placeholder="What should Claude start on? Leave empty to just open it." aria-label="First prompt" rows="2"></textarea>
        <div class="stp-h" style="margin-bottom:6px">Permission mode</div>
        <div class="modes" role="radiogroup">${DATA.permissionModes.map((md, i) => `<button class="${md === m.mode ? "on" : ""}" role="radio" aria-checked="${md === m.mode}" data-act="nmMode" data-mode="${esc(md)}"><i></i>${esc(md)}<span>${MODE_HINT[i]}</span></button>`).join("")}</div>`;
    }
    const primary = m.step === 1 ? "Next" : m.step === 2 ? (isClaude ? "Next" : "Create terminal") : "Create session";
    return { cls: "modal", label: "newTitle", html: `
      <h2 id="newTitle">New session<kbd>⌘N</kbd></h2>
      <div class="stp ${st(1)}"><div class="stp-h"><span class="n">${m.step > 1 ? "✓" : "1"}</span>Kind${m.step > 1 ? `<span class="val">${isClaude ? "Claude session" : "Terminal"}</span>${chg(1)}` : ""}</div>${s1}</div>
      <div class="stp ${st(2)}"><div class="stp-h"><span class="n">${m.step > 2 ? "✓" : "2"}</span>Directory${m.step > 2 ? `<span class="val">${esc(path)}</span>${chg(2)}` : ""}</div>${s2}</div>
      ${isClaude ? `<div class="stp ${st(3)}"><div class="stp-h"><span class="n">3</span>First prompt <span style="font-weight:400;color:var(--ink3)">optional</span></div>${s3}</div>` : ""}
      <div class="modal-foot"><button class="btn" data-act="closeModal">Cancel</button><button class="btn primary" data-act="nmNext" data-fk="nm:next">${primary}</button></div>` };
  }

  function normalizePath(p) {
    p = String(p || "").trim().replace(/\/+$/, "");
    if (!p) return "";
    if (p.startsWith("/Users/me")) p = `~${p.slice("/Users/me".length)}`;
    if (!p.startsWith("~") && !p.startsWith("/")) p = `~/work/${p}`;
    return p;
  }
  function pathStatusHTML(path) {
    if (!path) return `<span class="bad">Pick or type a folder</span>`;
    return B.dirExists(path) ? `<span class="ok">Folder exists</span>` : `<span class="newf">New folder, will be created</span>`;
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

  function renderDemo() {
    const sel = $("demoSess");
    const opts = B.sessions.map(s => `<option value="${s.id}">${esc(s.name)} · ${esc(statusLabel(s))}</option>`).join("");
    if (sel._h !== opts) {
      const v = sel.value;
      sel.innerHTML = opts;
      sel._h = opts;
      if (B.byId(v)) sel.value = v;
    }
    const s = ses(sel.value);
    $("demoNeed").disabled = !s || s.kind !== "claude" || s.status === "needs_you";
    $("demoFinish").disabled = !s || (s.kind === "shell" ? s.status !== "process" : s.status === "ready" || s.status === "reviewed");
    $("demoFail").disabled = !s || (s.kind === "shell" && s.status === "exited");
  }

  let raf = 0;
  function schedule() { if (!raf) raf = requestAnimationFrame(() => { raf = 0; renderAll(); }); }

  function renderAll() {
    if (S.view !== "feed" && !ses(S.view)) S.view = "feed";
    if (S.view !== "feed") S.seenAt[S.view] = Date.now();
    renderHeader();
    renderList();
    renderCenter();
    renderTray();
    renderModal();
    renderDemo();
    tick();
    S.firstRender = false;
    if (S.focusKey) {
      const n = scr.querySelector(`[data-fk="${CSS.escape(S.focusKey)}"]`);
      S.focusKey = null;
      if (n) {
        n.focus({ preventScroll: false });
        if (n.dataset.fk === "rename") n.select();
        if (n.classList.contains("shin-i")) updateMirror(n);
      }
    }
    if (S.focusEv) {
      const n = scr.querySelector(`.ev[data-key="${S.focusEv}"]`);
      S.focusEv = null;
      if (n) n.focus({ preventScroll: true });
    }
    if (S.autoFocus) { S.autoFocus = false; autoFocusSession(); }
  }

  function autoFocusSession() {
    const s = ses(S.view);
    if (!s) return;
    const sv = $("sessionView");
    let el = null;
    if (s.kind === "shell") el = sv.querySelector(".shin-i");
    else if (s.status === "needs_you") el = sv.querySelector(".askp");
    else el = sv.querySelector(".cmp-text");
    if (!el) el = $("svTerm");
    if (el) el.focus({ preventScroll: true });
    if (el && el.classList.contains("shin-i")) updateMirror(el);
  }

  const toastsEl = $("toasts");
  function toast(o) {
    if (o.attention && S.dnd) return;
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

  function askPhrase(s) {
    if (!s.ask) return "needs you";
    if (s.ask.type !== "permission") return "asked a question";
    if (/^Allow Bash/.test(s.ask.text)) return "needs permission to run a command";
    if (/^Allow (Edit|Write)/.test(s.ask.text)) return "needs permission to edit a file";
    return "needs permission";
  }

  function onStatus({ s, from, to }) {
    if (S.view === s.id || s.muted) return;
    if (to === "needs_you") toast({ attention: true, shape: "needs_you", html: `<b>${esc(s.name)}</b> ${askPhrase(s)}`, action: { label: "Answer", fn: () => openSession(s.id) } });
    else if (to === "ready" && from === "working" && s.interacted && s.summary !== "Interrupted") toast({ attention: true, shape: "ready", html: `<b>${esc(s.name)}</b> is ready for review`, action: { label: "Open", fn: () => openSession(s.id) } });
  }

  B.on((kind, data) => {
    if (kind === "event") {
      if (data.type !== "think" && S.view !== "feed") S.awayCount++;
      if (S.view === data.sid) S.seenAt[data.sid] = Date.now();
    } else if (kind === "status") {
      onStatus(data);
    } else if (kind === "converted") {
      S.trayOpen.delete(data.id);
      S.view = data.id;
      S.seenAt[data.id] = Date.now();
      S.autoFocus = true;
    } else if (kind === "tick") {
      tick();
      return;
    } else if (kind === "reset") {
      resetUi();
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
    storageSet("tm-activity-feed-style", k);
    const u = new URL(location.href);
    u.searchParams.set("style", k);
    history.replaceState(null, "", u);
    schedule();
  }

  function clearTypingFor(sid) {
    ["lane", "qa", "ans"].forEach(w => { delete S.typing[`${w}:${sid}`]; delete S.drafts[`${w}:${sid}`]; });
  }
  function pickOption(sid, i, where) {
    const s = ses(sid);
    if (!s || !s.ask || i < 0 || i >= s.ask.options.length) return;
    if (/^Type an answer$/i.test(s.ask.options[i])) {
      S.typing[`${where}:${sid}`] = true;
      S.focusKey = `${where}:${sid}`;
      schedule();
      return;
    }
    clearTypingFor(sid);
    B.answer(sid, i);
  }
  function sendTyped(sid, key) {
    const text = (S.drafts[key] || "").trim();
    if (!text) return;
    clearTypingFor(sid);
    B.answer(sid, null, text);
  }
  function sendComposer(sid) {
    const s = ses(sid);
    const key = `cmp:${sid}`;
    const text = (S.drafts[key] || "").trim();
    if (!s || !text || s.status === "working" || s.status === "needs_you") return;
    S.drafts[key] = "";
    const ta = scr.querySelector(`[data-draft="${key}"]`);
    if (ta) { ta.value = ""; autoGrow(ta); }
    B.send(sid, text);
  }
  function sendLane(sid) {
    const key = `lane:${sid}`;
    const text = (S.drafts[key] || "").trim();
    if (!text) return;
    delete S.drafts[key];
    B.send(sid, text);
  }

  function togglePin(seq) {
    if (S.pins.has(seq)) S.pins.delete(seq); else S.pins.add(seq);
    const a = document.activeElement;
    if (a && a.closest && a.closest(".ev")) S.focusEv = seq;
    schedule();
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
    B.rename(sid, S.drafts.rename);
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
  function openNew(preset) {
    const cur = ses(S.view);
    S.drafts["nm:path"] = cur ? (cur.kind === "shell" ? cur.cwd : cur.dir) : B.recentDirs[0];
    S.drafts["nm:prompt"] = "";
    openModal(Object.assign({ type: "new", step: 1, kind: "claude", mode: DATA.permissionModes[1] }, preset || {}));
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
    if (!m || m.type !== "new") return;
    if (m.step === 1) { nmGo(2); return; }
    if (m.step === 2) {
      const path = normalizePath(S.drafts["nm:path"]);
      if (!path) { const n = scr.querySelector('[data-fk="nm:path"]'); if (n) n.focus(); return; }
      if (m.kind === "claude") { nmGo(3); return; }
    }
    const path = normalizePath(S.drafts["nm:path"]);
    const s = B.create({ kind: m.kind, dir: path, prompt: m.kind === "claude" ? S.drafts["nm:prompt"] : "", mode: m.mode });
    S.seenAt[s.id] = Date.now();
    S.modal = null;
    S.modalReturn = null;
    openSession(s.id);
  }

  function copyText(text) {
    const fallback = () => {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      ta.remove();
    };
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text).catch(fallback);
    fallback();
    return Promise.resolve();
  }

  function removeWithUndo(sid, toClosed) {
    const s = ses(sid);
    if (!s) return;
    const name = s.name;
    const token = B.remove(sid, toClosed);
    S.sessFilter.delete(sid);
    S.trayOpen.delete(sid);
    if (S.view === sid) { S.view = "feed"; S.awayCount = 0; }
    toast({ html: `<b>${esc(name)}</b> ${toClosed ? "moved to Recently closed" : "removed from the list"}`, action: { label: "Undo", fn: () => B.undoRemove(token) }, ms: 6000 });
    schedule();
  }

  function act(name, el, ev) {
    const sid = el.dataset.sid;
    switch (name) {
      case "feed": goFeed(); break;
      case "open": openSession(sid); break;
      case "next": nextNeeding(); break;
      case "dnd": S.dnd = !S.dnd; toast({ html: S.dnd ? "Do not disturb is on. The feed keeps recording." : "Do not disturb is off", ms: 2500 }); schedule(); break;
      case "new": openNew(); break;
      case "newTerminal": openNew({ kind: "shell", step: 2 }); break;
      case "style": setStyle(el.dataset.style); break;
      case "sfilter": if (S.sessFilter.has(sid)) S.sessFilter.delete(sid); else S.sessFilter.add(sid); schedule(); break;
      case "clearSessFilter": S.sessFilter.clear(); schedule(); break;
      case "filter": S.filter = el.dataset.f; schedule(); break;
      case "pin": ev.stopPropagation(); togglePin(Number(el.dataset.seq)); break;
      case "pill": {
        const fw = $("feedwrap");
        fw.scrollTo({ top: Math.max(0, $("feedTools").offsetTop - 10), behavior: reduced ? "auto" : "smooth" });
        S.pillCount = 0;
        schedule();
        break;
      }
      case "markAll": {
        const t = Date.now();
        B.sessions.forEach(s => { S.seenAt[s.id] = t; });
        S.lastLook = t;
        schedule();
        break;
      }
      case "answer": pickOption(sid, Number(el.dataset.i), el.dataset.where); break;
      case "typeAnswer": pickOption(sid, Number(el.dataset.i), el.dataset.where); break;
      case "sendTyped": sendTyped(sid, el.dataset.key); break;
      case "review": B.review(sid); break;
      case "sendLane": sendLane(sid); break;
      case "send": sendComposer(sid); break;
      case "focusComposer": if (ev.target === el || ev.target.classList.contains("cmp-foot") || ev.target.classList.contains("hint")) { const t = el.querySelector("textarea"); if (t) t.focus(); } break;
      case "bell": { const s = ses(sid); if (s) { B.setMuted(sid, !s.muted); toast({ html: s.muted ? `<b>${esc(s.name)}</b> is muted. Its toasts stay quiet.` : `<b>${esc(s.name)}</b> can notify you again`, ms: 2500 }); } break; }
      case "rename": startRename(sid); break;
      case "restart": B.restart(sid); S.autoFocus = S.view === sid; break;
      case "stop": B.stop(sid); break;
      case "delete": openModal({ type: "delete", sid }); break;
      case "confirmDelete": S.modal = null; S.modalReturn = null; removeWithUndo(sid, true); break;
      case "removeShell": removeWithUndo(sid, true); break;
      case "removeOutside": removeWithUndo(sid, false); break;
      case "showWindow": toast({ html: "Would bring the Terminal.app window forward", ms: 3000 }); break;
      case "finder": { const s = ses(sid); if (s) toast({ html: `Would open <b>${esc(s.kind === "shell" ? s.cwd : s.dir)}</b> in Finder`, ms: 3000 }); break; }
      case "copyPath": {
        const s = ses(sid);
        if (!s) break;
        const p = (s.kind === "shell" ? s.cwd : s.dir).replace(/^~/, "/Users/me");
        copyText(p).then(() => toast({ html: `Copied <b>${esc(p)}</b>`, ms: 2500 }));
        break;
      }
      case "resume": {
        const entry = B.closed.find(c => c._id === Number(el.dataset.cid));
        if (!entry) break;
        const s = B.resume(entry);
        S.seenAt[s.id] = Date.now();
        openSession(s.id);
        break;
      }
      case "trayToggle": if (S.trayOpen.has(sid)) S.trayOpen.delete(sid); else { S.trayOpen.add(sid); S.focusKey = `sh:${sid}:tray`; } schedule(); break;
      case "scrim": if (ev.target === el) closeModal(); break;
      case "closeModal": closeModal(); break;
      case "nmKind": S.modal.kind = el.dataset.kind; renderAll(); { const n = scr.querySelector(`[data-fk="nm:k:${S.modal.kind}"]`); if (n) n.focus(); } break;
      case "nmDir": S.drafts["nm:path"] = el.dataset.dir; renderAll(); break;
      case "nmMode": S.modal.mode = el.dataset.mode; renderAll(); break;
      case "nmGo": nmGo(Number(el.dataset.step)); break;
      case "nmNext": nmNext(); break;
    }
  }

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
      B.setMode(el.dataset.sid, el.value);
      toast({ html: `Permission mode: <b>${esc(el.value)}</b>`, ms: 2500 });
    }
  });

  document.addEventListener("input", e => {
    const el = e.target;
    if (!el.dataset || !el.dataset.draft) return;
    S.drafts[el.dataset.draft] = el.value;
    if (el.classList.contains("shin-i")) { updateMirror(el); S.histPos[el.dataset.shell] = null; }
    if (el.tagName === "TEXTAREA" && el.classList.contains("cmp-text")) autoGrow(el);
    if (el.dataset.draft === "nm:path") {
      const path = normalizePath(el.value);
      const st = $("nmPathStatus");
      if (st) st.innerHTML = pathStatusHTML(path);
      scr.querySelectorAll(".dirs button").forEach(b => b.classList.toggle("on", b.dataset.dir === path));
    }
  });

  ["keyup", "click", "select", "focusin", "focusout"].forEach(t => document.addEventListener(t, e => {
    if (e.target && e.target.classList && e.target.classList.contains("shin-i")) setTimeout(() => updateMirror(e.target), 0);
  }));

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

  function shellKeys(e, input) {
    const sid = input.dataset.shell;
    const s = ses(sid);
    if (!s) return;
    if (e.key === "Enter") {
      e.preventDefault();
      const v = input.value;
      S.drafts[`sh:${sid}`] = "";
      input.value = "";
      S.histPos[sid] = null;
      updateMirror(input);
      B.shellRun(sid, v);
      return;
    }
    if (e.ctrlKey && (e.key === "c" || e.key === "C")) {
      e.preventDefault();
      B.ctrlC(sid, input.value);
      S.drafts[`sh:${sid}`] = "";
      input.value = "";
      updateMirror(input);
      return;
    }
    if (e.ctrlKey && (e.key === "l" || e.key === "L")) { e.preventDefault(); B.shellClear(sid); return; }
    if (e.key === "ArrowUp" || e.key === "ArrowDown") {
      e.preventDefault();
      const h = s.history;
      if (!h.length) return;
      let p = S.histPos[sid];
      if (p == null) p = h.length;
      p = e.key === "ArrowUp" ? Math.max(0, p - 1) : Math.min(h.length, p + 1);
      S.histPos[sid] = p;
      input.value = p >= h.length ? "" : h[p];
      S.drafts[`sh:${sid}`] = input.value;
      input.setSelectionRange(input.value.length, input.value.length);
      updateMirror(input);
      return;
    }
    if (e.key === "Tab") { e.preventDefault(); return; }
    if (e.key === "Escape") { e.preventDefault(); input.blur(); }
  }

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
    const mod = e.metaKey || e.ctrlKey;
    const k = e.key;

    if (a && a.classList && a.classList.contains("shin-i") && !e.metaKey) { shellKeys(e, a); if (e.defaultPrevented) return; }

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

    if (a && a.dataset && a.dataset.composer) {
      if (k === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); sendComposer(a.dataset.composer); return; }
      if (k === "Escape") {
        e.preventDefault();
        const s = ses(a.dataset.composer);
        if (s && s.status === "working") B.interrupt(s.id); else a.blur();
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

    if (mod && !e.altKey && (k === "j" || k === "J")) { e.preventDefault(); nextNeeding(); return; }
    if (mod && !e.altKey && (k === "n" || k === "N")) { e.preventDefault(); openNew(); return; }
    if (mod && k === "0") { e.preventDefault(); goFeed(); return; }
    if (mod && /^[1-9]$/.test(k)) {
      e.preventDefault();
      const s = listOrder().all[Number(k) - 1];
      if (s) openSession(s.id);
      return;
    }
    if (e.ctrlKey && (k === "c" || k === "C") && !isTextField(a)) {
      const card = a && a.closest && a.closest("[data-shellcard]");
      const sid = card ? card.dataset.shellcard : S.view;
      const s = ses(sid);
      if (s && s.kind === "shell" && s.status === "process") { e.preventDefault(); B.ctrlC(sid); }
      return;
    }
    if (k === "Escape") {
      if (isTextField(a)) { a.blur(); return; }
      const s = ses(S.view);
      if (s && s.status === "working") { e.preventDefault(); B.interrupt(s.id); return; }
      if (S.view !== "feed") { e.preventDefault(); goFeed(); }
      return;
    }
    if (isTextField(a) || mod || e.altKey) return;
    if (k === "F2") { if (S.view !== "feed") { e.preventDefault(); startRename(S.view); } return; }
    if (k === "?") { e.preventDefault(); openModal({ type: "help" }); return; }
    if ((k === "p" || k === "P") && a && a.classList && a.classList.contains("ev")) { e.preventDefault(); togglePin(Number(a.dataset.key)); return; }
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

  const demoBtn = $("demoBtn"), demoPanel = $("demoPanel");
  demoBtn.addEventListener("click", () => {
    demoPanel.hidden = !demoPanel.hidden;
    demoBtn.setAttribute("aria-expanded", String(!demoPanel.hidden));
    renderDemo();
  });
  $("demoSess").addEventListener("change", renderDemo);
  $("demoNeed").addEventListener("click", () => B.demoNeedYou($("demoSess").value));
  $("demoFinish").addEventListener("click", () => B.demoFinish($("demoSess").value));
  $("demoFail").addEventListener("click", () => B.demoFail($("demoSess").value));
  $("demoOutside").addEventListener("click", () => { const s = B.demoAddOutside(); $("demoSess").value = s.id; schedule(); });
  $("demoHelp").addEventListener("click", () => openModal({ type: "help" }));
  $("demoReset").addEventListener("click", () => B.reset());

  function seedPins() {
    const e = B.events.find(x => x.sid === "c4" && x.type === "say" && /^Preview/.test(x.text));
    if (e) S.pins.add(e.seq);
  }

  function resetUi() {
    Object.assign(S, {
      view: "feed", filter: "all", sessFilter: new Set(), pins: new Set(), seenAt: {}, lastLook: Date.now() - 15 * 60000,
      drafts: {}, typing: {}, renaming: null, modal: null, dnd: false, trayOpen: new Set(["t2"]), awayCount: 0, pillCount: 0,
      feedMaxSeq: 0, firstRender: true, histPos: {}
    });
    ["listItems", "laneCards", "pinList", "evlist", "trayList", "toasts"].forEach(id => { $(id).innerHTML = ""; });
    $("sessionView")._sid = null;
    $("feedwrap").scrollTop = 0;
    seedPins();
    toast({ html: "Demo reset", ms: 2000 });
  }

  setInterval(tick, 1000);
  if (!reduced) {
    let gi = 0;
    setInterval(() => {
      const gs = scr.querySelectorAll(".glyph");
      if (!gs.length) return;
      gi = (gi + 1) % GLYPHS.length;
      gs.forEach(g => { g.textContent = GLYPHS[gi]; });
    }, 140);
  }

  S.style = initialStyle();
  scr.dataset.style = S.style;
  seedPins();
  renderAll();
  window.__app = { S, B, renderAll };
})();
