window.TM = {
  statuses: {
    working: { label: "Working", meaning: "Claude is mid-turn, nothing needed from you" },
    needs_you: { label: "Needs you", meaning: "Blocked on a question or a permission prompt" },
    ready: { label: "Ready for review", meaning: "Finished its turn, waiting for your feedback" },
    process: { label: "Running", meaning: "Shell has a foreground process running" },
    idle: { label: "Idle", meaning: "Shell sitting at the prompt" },
    exited: { label: "Exited", meaning: "Process ended; can be restarted or removed" }
  },
  permissionModes: ["Ask before edits", "Accept edits", "Plan only"],
  sessions: [
    {
      id: "c1", kind: "claude", name: "api-server", dir: "~/work/api-server", host: "app",
      status: "needs_you", since: "2m", started: "1h 12m", context: 64, cost: "$1.84", mode: "Ask before edits",
      summary: "Wants to run npm run build",
      ask: { type: "permission", text: "Allow Bash: npm run build?", options: ["Allow once", "Always allow", "Deny"] },
      files: [{ path: "src/routes/sessions.ts", add: 18, del: 6 }],
      lines: [
        "⏺ I'll rebuild the API with the new sessions route.",
        "⏺ Read(src/routes/sessions.ts)",
        "  ⎿ Read 214 lines",
        "⏺ Update(src/routes/sessions.ts)",
        "  ⎿ Updated with 18 additions and 6 removals",
        "⏺ Bash(npm run build)",
        "  ⎿ Waiting for permission…"
      ],
      reply: ["⏺ Bash(npm run build)", "  ⎿ Build complete (41.2s)", "⏺ Build is green. The route now groups sessions by status."]
    },
    {
      id: "c2", kind: "claude", name: "mailer", dir: "~/work/mailer", host: "app",
      status: "needs_you", since: "6m", started: "38m", context: 31, cost: "$0.62", mode: "Accept edits",
      summary: "Asking when the digest should send",
      ask: { type: "question", text: "Should the daily digest go out at 7:00 or 8:00 am?", options: ["7:00 am", "8:00 am", "Type an answer"] },
      files: [{ path: "pipeline/schedule.py", add: 42, del: 3 }, { path: "pipeline/config.toml", add: 4, del: 1 }],
      lines: [
        "⏺ The scheduler is wired up. One thing I can't infer:",
        "  the old cron ran at 7:00, but the handoff doc says 8:00.",
        "⏺ Should the daily digest go out at 7:00 or 8:00 am?"
      ],
      reply: ["⏺ Update(pipeline/config.toml)", "  ⎿ Updated with 1 addition and 1 removal", "⏺ Digest time set. Running the dry-run send next."]
    },
    {
      id: "c3", kind: "claude", name: "chess-app", dir: "~/work/chess-app/app", host: "app",
      status: "working", since: "4m", started: "2h 05m", context: 78, cost: "$3.10", mode: "Accept edits",
      summary: "Writing tests for the move parser",
      files: [{ path: "tests/test_move_parser.py", add: 86, del: 0 }, { path: "app/move_parser.py", add: 9, del: 4 }],
      lines: [
        "⏺ Write(tests/test_move_parser.py)",
        "  ⎿ Wrote 86 lines",
        "⏺ Bash(pytest tests/test_move_parser.py -q)",
        "  ⎿ 11 passed, 2 failed",
        "⏺ Two failures are castling edge cases. Fixing parse_san()…",
        "✻ Thinking… (34s · ↓ 1.2k tokens)"
      ],
      reply: ["⏺ Bash(pytest -q)", "  ⎿ 13 passed", "⏺ All green. Castling now handles O-O-O with check."]
    },
    {
      id: "c4", kind: "claude", name: "web-app", dir: "~/work/web-app", host: "app",
      status: "ready", since: "11m", started: "52m", context: 45, cost: "$0.97", mode: "Accept edits",
      summary: "Done: new project card, preview deployed",
      files: [{ path: "src/components/ProjectGrid.tsx", add: 27, del: 2 }, { path: "src/data/projects.ts", add: 14, del: 0 }, { path: "public/chess-app.png", add: 0, del: 0, binary: true }],
      lines: [
        "⏺ Added the Chess app card to the projects grid.",
        "⏺ Bash(npm run build)",
        "  ⎿ Built in 3.1s",
        "⏺ Preview is live at example.dev (push-to-deploy).",
        "  Want me to tighten the card copy next?"
      ],
      reply: ["⏺ Update(src/data/projects.ts)", "  ⎿ Updated with 3 additions and 3 removals", "⏺ Tightened the copy to two lines. Anything else?"]
    },
    {
      id: "c5", kind: "claude", name: "mobile-app", dir: "~/work/mobile-app", host: "app",
      status: "working", since: "1m", started: "14m", context: 22, cost: "$0.41", mode: "Plan only",
      summary: "Planning the onboarding refactor",
      files: [],
      lines: [
        "⏺ Read(src/onboarding/Flow.tsx)",
        "  ⎿ Read 302 lines",
        "⏺ Splitting step state out of the component…",
        "✻ Thinking… (12s)"
      ],
      reply: ["⏺ Here's the plan: 1) extract useOnboardingStep, 2) move copy to strings.ts, 3) add tests.", "  Want me to start?"]
    },
    {
      id: "c6", kind: "claude", name: "scheduler", dir: "~/work/scheduler", host: "outside",
      status: "needs_you", since: "1m", started: "3h 40m", context: 88, cost: "$4.25", mode: "Ask before edits",
      summary: "In a Terminal.app window: wants to edit a file",
      ask: { type: "permission", text: "Allow Edit: src/api/routes.ts?", options: ["Allow once", "Always allow", "Deny"] },
      files: [{ path: "src/api/routes.ts", add: 12, del: 5 }],
      lines: [
        "⏺ Found the double-booking bug in the slot check.",
        "⏺ Edit(src/api/routes.ts)",
        "  ⎿ Waiting for permission…"
      ],
      reply: ["⏺ Edit(src/api/routes.ts)", "  ⎿ Updated with 12 additions and 5 removals", "⏺ Fixed. Want me to add a regression test?"]
    },
    {
      id: "t1", kind: "shell", name: "dev server", dir: "~/work/web-app", host: "app",
      status: "process", since: "48m", command: "npm run dev",
      lines: [
        "me@mac web-app % npm run dev",
        "  ▲ Next.js 15.2  - Local: http://localhost:3000",
        " ✓ Ready in 1.4s",
        " GET / 200 in 82ms"
      ]
    },
    {
      id: "t2", kind: "shell", name: "zsh", dir: "~/work/chess-app", host: "app",
      status: "idle", since: "20m",
      lines: [
        "(venv) me@mac chess-app % git status -sb",
        "## main...origin/main",
        " M app/move_parser.py",
        "(venv) me@mac chess-app % █"
      ]
    },
    {
      id: "t3", kind: "shell", name: "jupyter", dir: "~/work/ml-notebook", host: "app",
      status: "process", since: "2h", command: "jupyter lab",
      lines: [
        "(venv) me@mac ml-notebook % jupyter lab",
        "[I 14:02:11 ServerApp] Jupyter Server 2.14 is running at:",
        "[I 14:02:11 ServerApp] http://localhost:8888/lab"
      ]
    },
    {
      id: "t4", kind: "shell", name: "tests", dir: "~/work/data-pipeline", host: "app",
      status: "exited", since: "5m", command: "pytest", exitCode: 1,
      lines: [
        "(venv) me@mac data-pipeline % pytest",
        "FAILED tests/test_extract.py::test_rent_parse - KeyError: 'monthly_rent'",
        "======= 1 failed, 23 passed in 4.81s =======",
        "[process exited with code 1]"
      ]
    }
  ],
  recentlyClosed: [
    { kind: "claude", name: "tv-app", dir: "~/work/tv-app", closed: "yesterday", lastLine: "Shipped the Fire TV build." },
    { kind: "claude", name: "cli-tool", dir: "~/work/cli-tool", closed: "2 days ago", lastLine: "Added the per-model breakdown." },
    { kind: "shell", name: "zsh", dir: "~/work/dotfiles", closed: "3 days ago", lastLine: "git push origin main" }
  ],
  recentDirs: ["~/work/api-server", "~/work/chess-app", "~/work/mailer", "~/work/web-app", "~/work/mobile-app", "~/work/ml-notebook", "~/work/scheduler", "~/work/data-pipeline"],
  shellReplies: {
    "ls": ["README.md  app  docs  tests"],
    "git status": ["On branch main", "nothing to commit, working tree clean"],
    "default": ["zsh: command not found in mockup — real terminals run anything"]
  }
};
