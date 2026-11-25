// A stand-in for the native bridge so the page runs in a plain browser: generic demo sessions, a feed,
// fake terminal output, and ops that move statuses the way the real app does. Injected by ui-check.js
// (Playwright's addInitScript); never loaded by the app.
(function () {
  "use strict";

  const HOME = "/Users/you";
  const now = Date.now();
  const min = m => now - m * 60000;
  let seq = 0;
  let ptySeq = 0;
  const ptys = new Map();

  const sessions = [
    { id: "a1", kind: "claude", name: "api-server", dir: "~/work/api-server", status: "needs_you", statusAt: min(2), startedAt: min(72), summary: "Wants to run npm run test:unit", context: 64, mode: "Ask before edits", files: [], canResume: true,
      ask: { id: "q1", type: "permission", text: "Allow Bash: npm run test:unit?", heading: "Allow Bash?", detail: "npm run test:unit", options: ["Allow once", "Always allow", "Deny"], answerable: true, compact: true, tool: "Bash" } },
    { id: "a2", kind: "claude", name: "web-app", dir: "~/work/web-app", status: "needs_you", statusAt: min(6), startedAt: min(38), summary: "Asking a question", context: 31, mode: "Auto", files: [], canResume: true,
      ask: { id: "q2", type: "question", text: "Tabs or one long form?", heading: "Claude asks", detail: "Tabs or one long form?\n- Tabs\n- One long form", options: ["Tabs", "One long form", "Type an answer"], answerable: true, compact: true, tool: "AskUserQuestion" } },
    { id: "a3", kind: "claude", name: "notes", dir: "~/work/notes", status: "working", statusAt: min(4), startedAt: min(125), summary: "Running pytest -q", context: 78, mode: "Accept edits", files: [], canResume: true },
    { id: "a4", kind: "claude", name: "docs-site", dir: "~/work/docs-site", status: "ready", statusAt: min(11), startedAt: min(52), summary: "Done: the new guide page is in", context: 45, mode: "Auto", canResume: true,
      lastReply: "Added the getting-started guide and linked it from the sidebar. Want me to tighten the intro next?",
      files: [{ path: "src/pages/guide.md", add: 64, del: 0 }, { path: "src/nav.ts", add: 3, del: 1 }, { path: "public/diagram.png", add: 0, del: 0, binary: true }] },
    { id: "a5", kind: "claude", name: "data-pipeline", dir: "~/work/data-pipeline", status: "reviewed", statusAt: min(30), startedAt: min(200), summary: "Reviewed, nothing owed", context: 22, mode: "Plan only", files: [], canResume: true },
    { id: "t1", kind: "shell", name: "dev server", dir: "~/work/web-app", cwd: "~/work/web-app", status: "process", statusAt: min(48), startedAt: min(48), summary: "npm run dev", command: "npm run dev", lastLine: " GET / 200 in 41ms", files: [] },
    { id: "t2", kind: "shell", name: "zsh", dir: "~/work/api-server", cwd: "~/work/api-server", status: "idle", statusAt: min(20), startedAt: min(20), summary: "", lastLine: "you@mac api-server % git status -sb", files: [] },
    { id: "t3", kind: "shell", name: "tests", dir: "~/work/notes", cwd: "~/work/notes", status: "exited", statusAt: min(5), startedAt: min(9), summary: "code 1", exitCode: 1, lastLine: "1 failed, 23 passed in 4.81s", files: [] }
  ];
  const closed = [
    { id: "c1", kind: "claude", name: "cli-tool", dir: "~/work/cli-tool", closedAt: min(60 * 26), lastLine: "Shipped the release build." },
    { id: "c2", kind: "claude", name: "blog", dir: "~/work/blog", closedAt: min(60 * 50), lastLine: "Added the archive page." }
  ];
  const events = [];
  function ev(sid, type, at, extra) {
    const s = sessions.find(x => x.id === sid);
    const e = Object.assign({ seq: ++seq, sid, sname: s.name, type, at }, extra || {});
    events.push(e);
    return e;
  }
  ev("a5", "you", min(41), { verb: "sent", text: "Sketch a plan for the nightly import" });
  ev("a5", "tool", min(40), { tool: "Read", args: "pipeline/import.py" });
  ev("a5", "say", min(38), { text: "Plan: split fetch and load, add a retry around the API call, then a dry-run flag." });
  ev("a5", "done", min(37));
  ev("a4", "you", min(18), { verb: "sent", text: "Write a getting-started guide page" });
  ev("a4", "tool", min(17), { tool: "Write", args: "src/pages/guide.md" });
  ev("a4", "tool", min(15), { tool: "Edit", args: "src/nav.ts" });
  ev("a4", "tool", min(13), { tool: "Bash", args: "npm run build" });
  ev("a4", "say", min(12), { text: "Added the getting-started guide and linked it from the sidebar. Want me to tighten the intro next?" });
  sessions[3].lastDone = ev("a4", "done", min(11)).seq;
  ev("a2", "tool", min(8), { tool: "Read", args: "src/settings/Page.tsx" });
  sessions[1].askSeq = ev("a2", "ask", min(6), { text: "Tabs or one long form?" }).seq;
  ev("t1", "cmd", min(48), { text: "npm run dev" });
  ev("t3", "cmd", min(9), { text: "pytest" });
  ev("t3", "exit", min(5), { code: 1 });
  ev("a3", "you", min(4.5), { verb: "sent", text: "Add tests for the tag parser" });
  ev("a3", "tool", min(4), { tool: "Write", args: "tests/test_tags.py" });
  ev("a3", "tool", min(3), { tool: "Bash", args: "pytest -q" });
  ev("a1", "tool", min(5), { tool: "Edit", args: "src/routes/users.ts" });
  ev("a1", "tool", min(3), { tool: "Bash", args: "npm run lint" });
  sessions[0].askSeq = ev("a1", "perm", min(2), { text: "Allow Bash: npm run test:unit?" }).seq;
  ev("a3", "think", min(0.4));

  const prefs = { dnd: false, notifications: true, openAtLogin: true, openAtLoginAvailable: true };
  const modes = [
    { label: "Auto", hint: "Claude decides, asks when it's unsure", value: "auto" },
    { label: "Ask before edits", hint: "Asks before every change", value: "manual" },
    { label: "Accept edits", hint: "Edits freely, asks for commands", value: "acceptEdits" },
    { label: "Plan only", hint: "Reads and plans, changes nothing", value: "plan" }
  ];

  const enc = s => btoa(unescape(encodeURIComponent(s)));
  const strip = t => t.replace(/\x1b\[[0-9;]*m/g, "");
  function box(lines, width, color, title) {
    const top = title ? `╭─ ${title} ${"─".repeat(width - title.length - 3)}╮` : `╭${"─".repeat(width)}╮`;
    const row = l => `${color}│\x1b[0m ${l}${" ".repeat(Math.max(0, width - 1 - strip(l).length))}${color}│\x1b[0m`;
    return [color + top + "\x1b[0m"].concat(lines.map(row), [`${color}╰${"─".repeat(width)}╯\x1b[0m`]);
  }
  const CLAUDE_SCREEN = name => box(["\x1b[1m* Welcome to Claude Code\x1b[0m", "", `  cwd: ~/work/${name}`], 47, "\x1b[38;5;174m").concat([
    "",
    "\x1b[2m>\x1b[0m Run the tests and fix what fails",
    "",
    "\x1b[38;5;75m⏺\x1b[0m \x1b[1mEdit\x1b[0m(src/routes/users.ts)",
    "  \x1b[2m⎿  Updated with 6 additions and 2 removals\x1b[0m",
    "\x1b[38;5;75m⏺\x1b[0m \x1b[1mBash\x1b[0m(npm run test:unit)",
    ""
  ], box(["  npm run test:unit", "", "Do you want to proceed?", "\x1b[36m> 1. Yes\x1b[0m", "  2. Yes, and don't ask again for npm test", "  3. No, and tell Claude what to do differently"], 50, "\x1b[38;5;214m", "Bash command")).join("\r\n");
  const SHELL_SCREEN = s => s.status === "process"
    ? `you@mac web-app % npm run dev\r\n\r\n> web-app@0.1.0 dev\r\n> vite\r\n\r\n  \x1b[32mVITE\x1b[0m ready in 312 ms\r\n  ➜  Local: \x1b[36mhttp://localhost:5173/\x1b[0m\r\n GET / 200 in 41ms\r\n`
    : s.status === "exited"
      ? `you@mac notes % pytest\r\n\x1b[31mFAILED\x1b[0m tests/test_tags.py::test_split - KeyError: 'name'\r\n\x1b[31m======= 1 failed, 23 passed in 4.81s =======\x1b[0m\r\n\r\nPane is dead (status 1)\r\n`
      : `you@mac api-server % git status -sb\r\n## main...origin/main\r\n M src/routes/users.ts\r\nyou@mac api-server % `;

  function emit(evt) { setTimeout(() => window.TMNative && window.TMNative.receive(evt), 0); }
  function emitSessions() { emit({ type: "sessions", sessions: JSON.parse(JSON.stringify(sessions)), closed }); }
  function setStatus(s, to, summary) {
    const from = s.status;
    s.status = to;
    s.statusAt = Date.now();
    if (summary !== undefined) s.summary = summary;
    emit({ type: "status", sid: s.id, from, to });
  }

  const ops = {
    hello: () => ({ version: 1, home: HOME, sessions, closed, events, permissionModes: modes, defaultMode: "Auto", prefs }),
    folders: () => ({ folders: ["~/work/api-server", "~/work/web-app", "~/work/notes", "~/work/docs-site", "~/work/data-pipeline", "~/work/cli-tool", "~/work/blog", "~/work/scratch"] }),
    dirStatus: m => ({ path: m.path, exists: !/new/.test(m.path), isDir: true }),
    chooseFolder: () => ({ path: "~/work/scratch" }),
    setPrefs: m => { Object.keys(m).forEach(k => { if (k !== "op") prefs[k] = m[k]; }); return prefs; },
    answer: m => {
      const s = sessions.find(x => x.id === m.id);
      if (!s.ask || s.ask.id !== m.ask) return Promise.reject(new Error("already-answered"));
      const label = m.text != null ? m.text : s.ask.options[m.index];
      const e = events.find(x => x.seq === s.askSeq);
      if (e) e.answer = s.ask.type === "permission" ? ({ "Allow once": "Allowed once", "Always allow": "Always allowed", Deny: "Denied" })[label] : `Answered: ${label}`;
      s.ask = null;
      setStatus(s, "working", "Continuing");
      emit({ type: "feed", events: [e, ev(s.id, "you", Date.now(), { verb: "chose", text: label }), ev(s.id, "think", Date.now())].filter(Boolean), removed: [] });
      emitSessions();
      return { ok: true };
    },
    review: m => { const s = sessions.find(x => x.id === m.id); setStatus(s, "reviewed", "Reviewed, nothing owed"); emitSessions(); return { ok: true }; },
    create: m => {
      const id = `n${++seq}`;
      const dir = m.dir;
      sessions.push({ id, kind: m.kind, name: dir.split("/").pop(), dir, cwd: dir, status: "idle", statusAt: Date.now(), startedAt: Date.now(), summary: m.kind === "claude" ? "Waiting for your first message" : "", mode: m.mode, files: [] });
      emitSessions();
      return { id };
    },
    ptyOpen: m => {
      const pty = ++ptySeq;
      const s = sessions.find(x => x.id === m.id);
      ptys.set(pty, s);
      const text = s.kind === "claude" ? CLAUDE_SCREEN(s.name) : SHELL_SCREEN(s);
      setTimeout(() => emit({ type: "pty", pty, data: enc(text) }), 30);
      return { pty };
    },
    ptyInput: m => { const s = ptys.get(m.pty); if (s && s.kind === "shell" && m.data) emit({ type: "pty", pty: m.pty, data: enc(m.data === "\r" ? "\r\n" : m.data) }); return { ok: true }; }
  };

  window.webkit = {
    messageHandlers: {
      tm: {
        postMessage(message) {
          const fn = ops[message.op];
          try {
            return Promise.resolve(fn ? fn(message) : { ok: true });
          } catch (err) {
            return Promise.reject(err);
          }
        }
      }
    }
  };
})();
