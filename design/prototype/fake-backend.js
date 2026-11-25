(function () {
  "use strict";

  const DATA = window.TM;
  const clone = x => JSON.parse(JSON.stringify(x));
  const rand = (a, b) => a + Math.random() * (b - a);
  const int = (a, b) => Math.floor(rand(a, b + 1));
  const pick = arr => arr[Math.floor(Math.random() * arr.length)];
  const mins = str => { let m = 0; const re = /(\d+)\s*([hm])/g; let x; while ((x = re.exec(str || ""))) m += +x[1] * (x[2] === "h" ? 60 : 1); return m; };
  const basename = p => { const parts = String(p).replace(/\/+$/, "").split("/"); return parts[parts.length - 1] || p; };
  const pad = n => String(n).padStart(2, "0");
  const now = () => Date.now();

  const FS = {
    "~": ["Desktop/", "Documents/", "Downloads/", "work/"],
    "~/work": ["mobile-app/", "web-app/", "chess-app/", "scheduler/", "ml-notebook/", "data-pipeline/", "api-server/", "mailer/", "terminal-manager/"],
    "~/work/chess-app": ["README.md", "app/", "media-kit/", "pyproject.toml", "tests/"],
    "~/work/chess-app/app": ["__init__.py", "engine.py", "move_parser.py", "ui.py"],
    "~/work/web-app": ["README.md", "next.config.js", "node_modules/", "package.json", "public/", "src/"],
    "~/work/ml-notebook": ["README.md", "data/", "models/", "notebooks/", "requirements.txt"],
    "~/work/data-pipeline": ["README.md", "data-pipeline/", "pyproject.toml", "tests/"],
    "~/work/api-server": ["package.json", "README.md", "src/", "tests/"],
    "~/work/mailer": ["README.md", "pipeline/", "pyproject.toml", "tests/"],
    "~/work/mobile-app": ["README.md", "node_modules/", "package.json", "src/", "tsconfig.json"],
    "~/work/scheduler": ["README.md", "package.json", "src/", "tests/"],
    "~/work/terminal-manager": ["design-options/", "prototypes/"]
  };
  const PY_DIR = /chess-app|ml-notebook|data-pipeline|mailer/;
  const TAG_COLORS = ["#7AA2F7", "#F7768E", "#9ECE6A", "#E0AF68", "#BB9AF7", "#7DCFFF", "#FF9E64", "#73DACA", "#C0CAF5", "#F4B8E4"];

  const SUMMARIES = [
    "Done. The change is small, have a look at the diff.",
    "That's in. Want me to add a test for it?",
    "Updated, and the existing tests still pass.",
    "Fixed. I kept the public API the same.",
    "Done. I also removed an unused import while I was there."
  ];
  const ANSWERS = [
    "It comes from a default in the config, not the code. Nothing to change.",
    "Short answer: yes, it's safe. Nothing else reads that value.",
    "It's only called from one place, so I'd inline it. Want me to?"
  ];
  const WORDS = ["config", "parser", "session", "layout", "cache", "router"];
  const ASK_POOL = [
    s => ({ type: "permission", text: `Allow Bash: ${testCmd(s)}?`, options: ["Allow once", "Always allow", "Deny"], lines: [`⏺ Bash(${testCmd(s)})`, "  ⎿ Waiting for permission…"] }),
    s => { const f = pickFile(s); return { type: "permission", text: `Allow Edit: ${f}?`, options: ["Allow once", "Always allow", "Deny"], lines: [`⏺ Edit(${f})`, "  ⎿ Waiting for permission…"] }; },
    () => ({ type: "question", text: "Keep the old behaviour behind a flag, or remove it?", options: ["Keep a flag", "Remove it", "Type an answer"], lines: ["⏺ Keep the old behaviour behind a flag, or remove it?"] })
  ];
  const OUTSIDE_POOL = [
    { name: "scratch", dir: "~/work/scratch" },
    { name: "dotfiles", dir: "~/dotfiles" },
    { name: "kaggle-s5", dir: "~/work/kaggle-s5" },
    { name: "dotfiles", dir: "~/work/dotfiles" }
  ];
  const DEV_PATHS = ["/", "/projects", "/about", "/projects/chess-app", "/_next/static/chunks/main.js", "/favicon.ico"];

  const listeners = [];
  const B = {
    sessions: [], closed: [], events: [], recentDirs: [], fs: FS, seq: 0, idc: 0, tagIdx: 0, demoTimers: [],
    on(fn) { listeners.push(fn); },
    byId(id) { return B.sessions.find(s => s.id === id); },
    tagOf(id) { const s = B.byId(id); return s ? s.tag : "#999"; }
  };
  const notify = (kind, data) => listeners.forEach(fn => fn(kind, data));
  const changed = () => notify("change");

  function testCmd(s) {
    if (/api-server/.test(s.dir)) return "npm run build";
    return PY_DIR.test(s.dir) ? "pytest -q" : "npm test";
  }
  function testResult(s) {
    if (/api-server/.test(s.dir)) return `Build complete (${rand(20, 45).toFixed(1)}s)`;
    const n = int(12, 60);
    return PY_DIR.test(s.dir) ? `${n} passed in ${rand(1, 6).toFixed(2)}s` : `Tests: ${n} passed, ${n} total`;
  }
  function pickFile(s) {
    const own = (s.files || []).filter(f => !f.binary).map(f => f.path);
    if (own.length) return pick(own);
    return PY_DIR.test(s.dir) ? pick(["app/main.py", "app/utils.py"]) : pick(["src/index.ts", "src/App.tsx", "src/lib/utils.ts"]);
  }

  function addEvent(s, ev) {
    ev.seq = ++B.seq;
    ev.sid = s.id;
    ev.sname = s.name;
    if (!ev.at) ev.at = now();
    B.events.push(ev);
    if (B.events.length > 900) B.events.splice(0, B.events.length - 900);
    notify("event", ev);
    return ev;
  }

  function setStatus(s, status, summary) {
    const from = s.status;
    if (summary !== undefined) s.summary = summary;
    if (from === status) return;
    s.status = status;
    s.statusAt = now();
    if (from === "working") B.events = B.events.filter(e => !(e.sid === s.id && e.type === "think"));
    notify("status", { s, from, to: status });
  }

  function clearTimers(s) {
    (s.timers || []).forEach(t => clearTimeout(t));
    s.timers = [];
    if (s.proc) { clearInterval(s.proc); s.proc = null; }
  }
  function later(s, ms, fn) { const t = setTimeout(fn, ms); s.timers.push(t); return t; }

  function ingest(s, line) {
    s.lines.push(line);
    if (line.startsWith("⏺ ")) {
      const body = line.slice(2), m = /^(\w+)\((.*)\)$/.exec(body);
      s.cur = addEvent(s, m ? { type: "tool", tool: m[1], args: m[2], detail: "" } : { type: "say", text: body, detail: "" });
    } else if (s.cur && line.trim() && !/Waiting for permission/.test(line)) {
      s.cur.detail += (s.cur.detail ? "\n" : "") + line.replace(/^\s*⎿\s?/, "").trim();
    }
  }

  function filesFrom(lines) {
    const out = [];
    lines.forEach((l, i) => {
      const m = /^⏺ (Update|Edit|Write)\((.*)\)$/.exec(l);
      if (!m) return;
      const res = lines[i + 1] || "";
      const a = /(\d+) addition/.exec(res), d = /(\d+) removal/.exec(res), w = /Wrote (\d+) lines/.exec(res);
      out.push({ path: m[2], add: a ? +a[1] : w ? +w[1] : int(2, 20), del: d ? +d[1] : 0 });
    });
    return out;
  }
  function mergeFiles(s, files) {
    files.forEach(f => {
      const ex = s.files.find(x => x.path === f.path);
      if (ex) { ex.add += f.add; ex.del += f.del; } else s.files.push(Object.assign({}, f));
    });
  }

  function poolReply(s, text) {
    const file = pickFile(s), test = testCmd(s), a = int(2, 24), d = int(0, 8);
    const word = pick(WORDS);
    const newFile = PY_DIR.test(s.dir) ? `tests/test_${word}.py` : `src/${word}.test.ts`;
    const templates = [
      () => [`⏺ Read(${file})`, `  ⎿ Read ${int(60, 320)} lines`, `⏺ Update(${file})`, `  ⎿ Updated with ${a} additions and ${d} removals`, `⏺ ${pick(SUMMARIES)}`],
      () => [`⏺ Update(${file})`, `  ⎿ Updated with ${a} additions and ${d} removals`, `⏺ Bash(${test})`, `  ⎿ ${testResult(s)}`, `⏺ ${pick(SUMMARIES)}`],
      () => [`⏺ Search(pattern: "${word}")`, `  ⎿ Found ${int(2, 9)} files`, `⏺ Read(${file})`, `  ⎿ Read ${int(60, 320)} lines`, `⏺ ${pick(ANSWERS)}`],
      () => [`⏺ Write(${newFile})`, `  ⎿ Wrote ${int(20, 90)} lines`, `⏺ Bash(${test})`, `  ⎿ ${testResult(s)}`, `⏺ Added ${newFile} and it passes.`]
    ];
    if (/test/i.test(text || "")) return templates[pick([1, 3])]();
    return pick(templates)();
  }

  function replyFor(s, text) {
    if (!s.replied && s.reply && s.reply.length) { s.replied = true; return s.reply.slice(); }
    s.replied = true;
    return poolReply(s, text);
  }

  function startTurn(s, replyLines, label) {
    clearTimers(s);
    setStatus(s, "working", label || "Working on your message");
    addEvent(s, { type: "think" });
    s.cur = null;
    later(s, rand(2000, 4000), () => stream(s, replyLines, () => finishTurn(s, replyLines)));
    changed();
  }

  function stream(s, lines, done) {
    let i = 0;
    const step = () => {
      if (i >= lines.length) { done(); return; }
      ingest(s, lines[i++]);
      changed();
      later(s, 250, step);
    };
    step();
  }

  function lastSay(lines) {
    const says = lines.filter(l => l.startsWith("⏺ ") && !/^⏺ \w+\(/.test(l));
    return says.length ? says[says.length - 1].slice(2) : "Turn finished";
  }

  function finishTurn(s, lines) {
    clearTimers(s);
    mergeFiles(s, filesFrom(lines));
    s.context = Math.min(97, s.context + int(2, 6));
    s.cost += rand(0.04, 0.18);
    s.cur = null;
    setStatus(s, "ready", `Done: ${lastSay(lines)}`);
    s.lastDone = addEvent(s, { type: "done" }).seq;
    changed();
  }

  function promptOf(s) { return `${s.conda}me@mac ${basename(s.cwd)} % `; }

  function makeSession(o) {
    const s = Object.assign({
      host: "app", files: [], lines: [], timers: [], context: 0, cost: 0, mode: DATA.permissionModes[1],
      summary: "", history: [], conda: "(venv) ", interacted: false, muted: false
    }, o);
    s.tag = TAG_COLORS[B.tagIdx++ % TAG_COLORS.length];
    s.cwd = s.cwd || s.dir;
    if (!s.statusAt) s.statusAt = now();
    if (!s.startedAt) s.startedAt = now();
    return s;
  }

  function welcome(dir) { return ["✻ Welcome to Claude Code", `  cwd: ${dir}`, "⎯ Waiting for your first message"]; }

  function seed() {
    const t0 = now();
    B.sessions = []; B.events = []; B.seq = 0; B.tagIdx = 0;
    B.closed = clone(DATA.recentlyClosed).map(c => Object.assign(c, { closedAt: null }));
    B.recentDirs = DATA.recentDirs.slice();
    const seedEvents = [];
    DATA.sessions.forEach(raw => {
      const d = clone(raw);
      const s = makeSession(Object.assign(d, {
        statusAt: t0 - mins(d.since) * 60000,
        startedAt: t0 - mins(d.started || d.since) * 60000,
        cost: d.cost ? parseFloat(d.cost.replace("$", "")) : 0,
        context: d.context || 0,
        interacted: d.status === "working"
      }));
      const out = [];
      if (s.kind === "shell") {
        const pl = s.lines.find(l => l.includes("% "));
        s.conda = pl && pl.startsWith("(venv) ") ? "(venv) " : "";
        const last = s.lines[s.lines.length - 1];
        if (last.endsWith("% █")) s.lines.pop();
        const cmdLine = s.lines.find(l => l.includes("% "));
        const cmd = cmdLine ? cmdLine.split("% ").pop() : s.command;
        if (cmd) { s.history.push(cmd); out.push({ type: "cmd", text: cmd, detail: s.lines.filter(l => l !== cmdLine && !l.startsWith("[process")).slice(0, 2).join("\n") }); }
        if (s.status === "exited") out.push({ type: "exit", code: s.exitCode });
      } else {
        let thinkSecs = 0;
        s.lines = s.lines.filter(l => {
          if (!l.startsWith("✻")) return true;
          const m = /\((\d+)s/.exec(l);
          thinkSecs = m ? +m[1] : 10;
          return false;
        });
        let cur = null;
        for (const line of s.lines) {
          if (line.startsWith("⏺ ")) {
            const body = line.slice(2), m = /^(\w+)\((.*)\)$/.exec(body);
            cur = m ? { type: "tool", tool: m[1], args: m[2], detail: "" } : { type: "say", text: body, detail: "" };
            out.push(cur);
          } else if (cur && !/Waiting for permission/.test(line)) {
            cur.detail += (cur.detail ? "\n" : "") + line.replace(/^\s*⎿\s?/, "").trim();
          }
        }
        if (s.status === "needs_you" && s.ask) out.push({ type: s.ask.type === "permission" ? "perm" : "ask", text: s.ask.text, isAsk: true });
        else if (s.status === "ready") out.push({ type: "done", isDone: true });
        if (s.status === "working") out.push({ type: "think", secs: thinkSecs });
      }
      const endMin = s.status === "working" ? 0.35 : mins(d.since);
      const end = t0 - endMin * 60000;
      const n = out.length;
      out.forEach((e, i) => {
        e.at = e.type === "think" ? t0 - e.secs * 1000 : end - (n - 1 - i) * 42000 - (i * 7 % 13) * 1000;
        e.sid = s.id; e.sname = s.name; e.seedKey = `${s.id}:${i}`;
        seedEvents.push({ e, s });
      });
      B.sessions.push(s);
    });
    seedEvents.sort((a, b) => a.e.at - b.e.at).forEach(({ e, s }) => {
      e.seq = ++B.seq;
      if (e.isAsk) s.askSeq = e.seq;
      if (e.isDone) s.lastDone = e.seq;
      B.events.push(e);
    });
    B.idc = 10;
  }

  function devLogLine() { return ` GET ${pick(DEV_PATHS)} 200 in ${int(8, 140)}ms`; }
  function httpLogLine() { const d = new Date(); return `::1 - - [${pad(d.getDate())}/${d.toLocaleString("en", { month: "short" })}/${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}] "GET ${pick(["/", "/index.html", "/data.json", "/favicon.ico"])} HTTP/1.1" ${pick([200, 200, 200, 304, 404])} -`; }
  function jupyterLine() { const d = new Date(); return `[I ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())} ServerApp] ${pick(["Saving file at /notebooks/eda.ipynb", "Kernel started: 4f1c2a", "Saving file at /notebooks/model_v3.ipynb", "Kernel restarted: 4f1c2a"])}`; }

  function processLine(s, line) {
    s.lines.push(line);
    addEvent(s, { type: "out", text: line.trim() });
    changed();
  }

  function startProcess(s, command, intro, lineFn, every) {
    s.command = command;
    setStatus(s, "process", command);
    intro.forEach(l => s.lines.push(l));
    s.proc = setInterval(() => processLine(s, lineFn()), every);
  }

  function shellOutput(s, cmd, args) {
    const resolve = p => {
      if (!p || p === "~") return "~";
      if (p.startsWith("~") || p.startsWith("/")) return p.replace(/\/+$/, "").replace(/^\/Users\/me/, "~");
      let base = s.cwd;
      p.replace(/\/+$/, "").split("/").forEach(part => {
        if (part === "..") base = base.includes("/") ? base.slice(0, base.lastIndexOf("/")) : base;
        else if (part && part !== ".") base = `${base}/${part}`;
      });
      return base;
    };
    const isDir = p => p === "~" || !!FS[p] || (FS[p.slice(0, p.lastIndexOf("/"))] || []).includes(`${basename(p)}/`) || B.recentDirs.includes(p);
    const listing = p => (FS[p] || (isDir(p) ? ["README.md", "src/", "tests/"] : null));
    switch (cmd) {
      case "ls": {
        const l = listing(args[0] ? resolve(args[0]) : s.cwd);
        return l ? [l.map(x => x.replace(/\/$/, "")).join("  ")] : [`ls: ${args[0]}: No such file or directory`];
      }
      case "pwd": return [s.cwd.replace(/^~/, "/Users/me")];
      case "cd": {
        const target = resolve(args[0]);
        if (!isDir(target)) return [`cd: no such file or directory: ${args[0]}`];
        s.cwd = target;
        return [];
      }
      case "echo": return [args.join(" ").replace(/^["']|["']$/g, "")];
      case "date": {
        const d = new Date();
        return [`${d.toLocaleString("en", { weekday: "short" })} ${d.toLocaleString("en", { month: "short" })} ${String(d.getDate()).padStart(2, " ")} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())} MST ${d.getFullYear()}`];
      }
      case "whoami": return ["me"];
      case "cat": {
        if (!args[0]) return [];
        const l = listing(s.cwd) || [];
        if (!l.includes(args[0])) return [`cat: ${args[0]}: No such file or directory`];
        return args[0] === "README.md" ? [`# ${basename(s.cwd)}`, "", "Run it locally with the steps below."] : ["…"];
      }
      case "git": {
        if (args[0] !== "status") return args[0] ? [`git ${args.join(" ")}: done`] : ["usage: git [--version] [--help] <command> [<args>]"];
        if (s.cwd === "~" || s.cwd === "~/work") return ["fatal: not a git repository (or any of the parent directories): .git"];
        if (/chess-app/.test(s.cwd)) return ["On branch main", "Your branch is up to date with 'origin/main'.", "", "Changes not staged for commit:", "        modified:   app/move_parser.py"];
        return DATA.shellReplies["git status"].slice();
      }
    }
    return null;
  }

  function convertToClaude(s) {
    clearTimers(s);
    s.kind = "claude";
    s.dir = s.cwd;
    const old = s.name;
    s.name = uniqueName(basename(s.cwd));
    s.lines.push(...welcome(s.dir));
    s.context = 4; s.cost = 0; s.files = []; s.startedAt = now();
    s.mode = DATA.permissionModes[1];
    setStatus(s, "idle", "Waiting for your first message");
    addEvent(s, { type: "life", text: `Started Claude Code in ${old}`, detail: s.dir });
    notify("converted", s);
  }

  function uniqueName(name) {
    let n = name, i = 2;
    while (B.sessions.some(s => s.name === n)) n = `${name} ${i++}`;
    return n;
  }

  B.shellRun = function (sid, input) {
    const s = B.byId(sid);
    if (!s || s.kind !== "shell" || s.status !== "idle") return;
    const raw = String(input);
    const line = raw.trim();
    s.lines.push(promptOf(s) + raw);
    if (!line) { changed(); return; }
    if (s.history[s.history.length - 1] !== line) s.history.push(line);
    const [cmd, ...args] = line.split(/\s+/);
    let out = null;
    if (cmd === "clear") { s.lines = []; changed(); return; }
    if (cmd === "exit") {
      s.lines.push("[process exited with code 0]");
      s.exitCode = 0; s.command = "zsh";
      setStatus(s, "exited", "code 0");
      addEvent(s, { type: "exit", code: 0 });
      changed(); return;
    }
    if (cmd === "claude") { addEvent(s, { type: "cmd", text: line, detail: "" }); convertToClaude(s); changed(); return; }
    if (line === "npm run dev") {
      addEvent(s, { type: "cmd", text: line, detail: "Next.js dev server on http://localhost:3000" });
      startProcess(s, line, [`> ${basename(s.cwd)}@0.1.0 dev`, "> next dev", "", "  ▲ Next.js 15.2  - Local: http://localhost:3000", " ✓ Ready in 1.3s"], devLogLine, 3500);
      changed(); return;
    }
    if (/^python3? -m http\.server/.test(line)) {
      const port = args[3] || "8000";
      addEvent(s, { type: "cmd", text: line, detail: `Serving on port ${port}` });
      startProcess(s, line, [`Serving HTTP on :: port ${port} (http://[::]:${port}/) ...`], httpLogLine, 3000);
      changed(); return;
    }
    out = shellOutput(s, cmd, args);
    if (out === null) out = [`zsh: command not found: ${cmd}`];
    s.lines.push(...out);
    addEvent(s, { type: "cmd", text: line, detail: out.filter(Boolean).slice(0, 2).join("\n") });
    changed();
  };

  B.ctrlC = function (sid, typed) {
    const s = B.byId(sid);
    if (!s || s.kind !== "shell") return;
    if (s.status === "process") {
      clearInterval(s.proc); s.proc = null;
      s.lines.push("^C");
      const cmd = s.command;
      setStatus(s, "idle", "");
      addEvent(s, { type: "life", text: `Stopped ${cmd}` });
    } else if (s.status === "idle") {
      s.lines.push(`${promptOf(s)}${typed || ""}^C`);
    }
    changed();
  };

  B.shellClear = function (sid) { const s = B.byId(sid); if (s) { s.lines = []; changed(); } };
  B.prompt = sid => { const s = B.byId(sid); return s ? promptOf(s) : "% "; };

  B.send = function (sid, text) {
    const s = B.byId(sid);
    if (!s || s.kind !== "claude" || s.host === "outside" || s.status === "working" || s.status === "needs_you") return;
    s.interacted = true;
    s.lines.push(`> ${text}`);
    addEvent(s, { type: "you", verb: "replied", text });
    s.context = Math.min(97, s.context + int(1, 3));
    startTurn(s, replyFor(s, text), text.length > 48 ? `${text.slice(0, 46)}…` : text);
  };

  B.answer = function (sid, idx, typed) {
    const s = B.byId(sid);
    if (!s || s.status !== "needs_you" || !s.ask) return;
    const ask = s.ask;
    const opt = typed !== undefined ? typed : ask.options[idx];
    const ev = B.events.find(e => e.seq === s.askSeq);
    const stamp = ask.type === "permission" ? ({ "Allow once": "Allowed once", "Always allow": "Always allowed", "Deny": "Denied" })[opt] || opt : `Answered: ${opt}`;
    if (ev) ev.answer = stamp;
    s.ask = null; s.askSeq = null;
    s.interacted = true;
    s.lines.push(`> ${opt}`);
    addEvent(s, { type: "you", verb: ask.type === "permission" ? "chose" : "answered", text: opt });
    if (opt === "Deny") {
      startTurn(s, ["⏺ Okay, I won't run that.", "  Tell me how you'd like to go instead."], "Denied, rethinking");
      return;
    }
    if (s.pendingReply) { const r = s.pendingReply; s.pendingReply = null; startTurn(s, r, ask.type === "permission" ? "Continuing after permission" : `Answered: ${opt}`); return; }
    startTurn(s, replyFor(s, opt), ask.type === "permission" ? "Continuing after permission" : `Answered: ${opt}`);
  };

  B.interrupt = function (sid) {
    const s = B.byId(sid);
    if (!s || s.status !== "working") return;
    clearTimers(s);
    s.lines.push("  ⎿ Interrupted by user");
    s.cur = null;
    setStatus(s, "ready", "Interrupted");
    addEvent(s, { type: "life", text: "Interrupted", flag: "needs" });
    changed();
  };

  B.review = function (sid) {
    const s = B.byId(sid);
    if (!s || s.status !== "ready") return;
    setStatus(s, "reviewed", "Reviewed, nothing owed");
    addEvent(s, { type: "you", verb: "marked the turn reviewed", text: "" });
    changed();
  };

  B.rename = function (sid, name) {
    const s = B.byId(sid);
    name = String(name || "").trim();
    if (!s || !name || name === s.name) return;
    const old = s.name;
    s.name = name;
    addEvent(s, { type: "life", text: `Renamed from ${old}` });
    changed();
  };

  B.setMode = function (sid, mode) {
    const s = B.byId(sid);
    if (!s || s.mode === mode) return;
    s.mode = mode;
    addEvent(s, { type: "life", text: `Permission mode set to ${mode}` });
    changed();
  };

  B.setMuted = function (sid, muted) { const s = B.byId(sid); if (s) { s.muted = muted; changed(); } };

  B.restart = function (sid) {
    const s = B.byId(sid);
    if (!s || s.host === "outside") return;
    clearTimers(s);
    if (s.kind === "shell") {
      s.lines = []; s.cwd = s.dir; s.command = null; s.exitCode = null;
      setStatus(s, "idle", "");
    } else {
      s.lines.push("⎯ Restarted · conversation kept");
      s.ask = null; s.askSeq = null; s.context = Math.max(4, Math.round(s.context / 3));
      setStatus(s, "idle", "Restarted, waiting for a message");
    }
    addEvent(s, { type: "life", text: "Restarted" });
    changed();
  };

  B.stop = function (sid) {
    const s = B.byId(sid);
    if (!s) return;
    if (s.kind === "shell") B.ctrlC(sid);
    else B.interrupt(sid);
  };

  B.remove = function (sid, toClosed) {
    const idx = B.sessions.findIndex(s => s.id === sid);
    if (idx < 0) return null;
    const s = B.sessions[idx];
    clearTimers(s);
    B.sessions.splice(idx, 1);
    let entry = null;
    if (toClosed) {
      const snap = Object.assign({}, s, { timers: [], proc: null, cur: null, lines: s.lines.slice(), files: clone(s.files) });
      entry = { kind: s.kind, name: s.name, dir: s.dir, closedAt: now(), closed: "just now", lastLine: s.lines[s.lines.length - 1] || "", snap };
      B.closed.unshift(entry);
    }
    addEvent(s, { type: "life", text: s.host === "outside" ? "Removed from the list" : "Deleted", flag: "needs" });
    changed();
    return { s, idx, entry };
  };

  B.undoRemove = function (token) {
    if (!token) return;
    const { s, idx, entry } = token;
    if (entry) B.closed = B.closed.filter(c => c !== entry);
    if (s.status === "working") { s.status = "ready"; s.summary = "Interrupted"; s.statusAt = now(); }
    if (s.status === "process") { s.status = "idle"; s.lines.push("^C"); s.statusAt = now(); }
    s.timers = [];
    B.sessions.splice(Math.min(idx, B.sessions.length), 0, s);
    addEvent(s, { type: "life", text: "Restored" });
    changed();
  };

  B.resume = function (entry) {
    B.closed = B.closed.filter(c => c !== entry);
    let s;
    const id = `${entry.kind === "claude" ? "c" : "t"}${++B.idc}`;
    if (entry.kind === "claude") {
      const base = entry.snap ? Object.assign({}, entry.snap) : {
        kind: "claude", name: entry.name, dir: entry.dir, files: [], lines: [`⏺ ${entry.lastLine}`], context: int(20, 50), cost: rand(0.4, 2), mode: DATA.permissionModes[1]
      };
      s = makeSession(Object.assign(base, { id, timers: [], proc: null, ask: null, askSeq: null, statusAt: now(), status: "ready", summary: `Resumed: ${entry.lastLine}` }));
      s.name = uniqueName(entry.name);
      s.lines = s.lines.slice();
      s.lines.push("⎯ Resumed · conversation intact");
      B.sessions.push(s);
      addEvent(s, { type: "life", text: "Resumed from Recently closed" });
    } else {
      s = makeSession({ id, kind: "shell", name: uniqueName(entry.name), dir: entry.dir, status: "idle", conda: "(venv) " });
      B.sessions.push(s);
      addEvent(s, { type: "life", text: "Reopened as a fresh zsh" });
    }
    changed();
    return s;
  };

  B.create = function ({ kind, dir, prompt, mode }) {
    if (!B.recentDirs.includes(dir)) B.recentDirs.unshift(dir);
    B.addDir(dir);
    const id = `${kind === "claude" ? "c" : "t"}${++B.idc}`;
    let s;
    if (kind === "claude") {
      s = makeSession({ id, kind, name: uniqueName(basename(dir)), dir, status: "idle", summary: "Waiting for your first message", context: 3, cost: 0, mode: mode || DATA.permissionModes[1], lines: welcome(dir) });
    } else {
      s = makeSession({ id, kind: "shell", name: uniqueName("zsh"), dir, status: "idle" });
    }
    B.sessions.push(s);
    addEvent(s, { type: "life", text: kind === "claude" ? "Created a Claude session" : "Opened a terminal", detail: dir });
    if (kind === "claude" && prompt && prompt.trim()) {
      s.lines.pop();
      B.send(s.id, prompt.trim());
    }
    changed();
    return s;
  };

  B.dirExists = p => !!FS[p] || B.recentDirs.includes(p) || (FS[p.slice(0, p.lastIndexOf("/"))] || []).includes(`${basename(p)}/`);
  B.addDir = function (p) {
    if (!FS[p] && !B.dirExists(p)) {
      FS[p] = [];
      const parent = p.slice(0, p.lastIndexOf("/"));
      if (FS[parent] && !FS[parent].includes(`${basename(p)}/`)) FS[parent].push(`${basename(p)}/`);
    }
  };

  B.demoNeedYou = function (sid) {
    const s = B.byId(sid);
    if (!s || s.kind !== "claude" || s.status === "needs_you") return;
    clearTimers(s);
    const a = pick(ASK_POOL)(s);
    a.lines.forEach(l => ingest(s, l));
    s.ask = { type: a.type, text: a.text, options: a.options };
    setStatus(s, "needs_you", a.type === "permission" ? `Wants to ${a.text.replace(/^Allow (\w+): (.*)\?$/, (m, t, x) => (t === "Bash" ? `run ${x}` : `edit ${x}`))}` : "Asking a question");
    s.askSeq = addEvent(s, { type: a.type === "permission" ? "perm" : "ask", text: a.text }).seq;
    changed();
  };

  B.demoFinish = function (sid) {
    const s = B.byId(sid);
    if (!s) return;
    if (s.kind === "shell") {
      if (s.status !== "process") return;
      clearTimers(s);
      s.lines.push("[process exited with code 0]");
      s.exitCode = 0;
      setStatus(s, "exited", "code 0");
      addEvent(s, { type: "exit", code: 0 });
      changed(); return;
    }
    if (s.status === "ready" || s.status === "reviewed") return;
    if (s.status === "needs_you") {
      const ev = B.events.find(e => e.seq === s.askSeq);
      if (ev) ev.answer = "Resolved in its window";
      s.ask = null; s.askSeq = null;
    }
    clearTimers(s);
    const lines = replyFor(s, "");
    lines.forEach(l => ingest(s, l));
    finishTurn(s, lines);
  };

  B.demoFail = function (sid) {
    const s = B.byId(sid);
    if (!s) return;
    clearTimers(s);
    if (s.kind === "shell") {
      if (s.status === "exited") return;
      s.lines.push("Error: something went wrong (simulated)", "[process exited with code 1]");
      s.exitCode = 1;
      setStatus(s, "exited", "code 1");
      addEvent(s, { type: "exit", code: 1 });
      changed(); return;
    }
    if (s.status === "needs_you") { const ev = B.events.find(e => e.seq === s.askSeq); if (ev) ev.answer = "Abandoned"; s.ask = null; s.askSeq = null; }
    const test = testCmd(s);
    [`⏺ Bash(${test})`, "  ⎿ Error: 2 tests failed", "⏺ The run failed and I stopped so you can look."].forEach(l => ingest(s, l));
    setStatus(s, "ready", "Stopped on an error");
    addEvent(s, { type: "life", text: "Failed: 2 tests failed", flag: "needs" });
    s.lastDone = addEvent(s, { type: "done" }).seq;
    changed();
  };

  B.demoAddOutside = function () {
    const free = OUTSIDE_POOL.filter(o => !B.sessions.some(s => s.dir === o.dir));
    const o = free.length ? pick(free) : { name: `outside ${B.idc + 1}`, dir: "~/work/outside" };
    const s = makeSession({ id: `c${++B.idc}`, kind: "claude", host: "outside", name: uniqueName(o.name), dir: o.dir, status: "working", context: int(20, 70), cost: rand(0.2, 2), mode: DATA.permissionModes[0], startedAt: now() - int(5, 90) * 60000 });
    B.sessions.push(s);
    addEvent(s, { type: "life", text: "Discovered in a Terminal.app window", detail: o.dir });
    ingest(s, `⏺ Read(${pickFile(s)})`);
    ingest(s, `  ⎿ Read ${int(60, 300)} lines`);
    B.demoNeedYou(s.id);
    return s;
  };

  B.reset = function () {
    B.sessions.forEach(clearTimers);
    B.demoTimers.forEach(t => { clearTimeout(t); clearInterval(t); });
    B.demoTimers = [];
    seed();
    startDemo();
    notify("reset");
  };

  function startDemo() {
    const t = (ms, fn) => B.demoTimers.push(setTimeout(fn, ms));
    t(40000, () => {
      const s = B.byId("c3");
      if (!s || s.status !== "working") return;
      clearTimers(s);
      const lines = replyFor(s, "");
      stream(s, lines, () => finishTurn(s, lines));
    });
    t(70000, () => {
      const s = B.byId("c5");
      if (!s || s.status !== "working") return;
      clearTimers(s);
      ingest(s, "⏺ Step state and copy can live in one useOnboarding hook, or split into two.");
      s.ask = { type: "question", text: "Split into two hooks or one?", options: ["Two hooks", "One hook", "Type an answer"] };
      setStatus(s, "needs_you", "Asking how to split the hooks");
      s.askSeq = addEvent(s, { type: "ask", text: s.ask.text }).seq;
      changed();
    });
    const dev = B.byId("t1");
    if (dev) dev.proc = setInterval(() => { if (dev.status === "process" && B.byId("t1")) processLine(dev, devLogLine()); }, 8000);
    const jup = () => B.demoTimers.push(setTimeout(() => {
      const s = B.byId("t3");
      if (s && s.status === "process") processLine(s, jupyterLine());
      jup();
    }, rand(16000, 30000)));
    jup();
    B.demoTimers.push(setInterval(() => {
      let any = false;
      B.sessions.forEach(s => { if (s.status === "working") { s.cost += rand(0.002, 0.008); any = true; } });
      if (any) notify("tick");
    }, 1000));
  }

  B.promptOf = promptOf;
  B.basename = basename;
  seed();
  startDemo();
  window.Backend = B;
})();
