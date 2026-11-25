# Terminal Manager handoff

Milestone 1, built 2026-11-24. Read this first if the session that built it is gone.

## What it is

A menu bar app that runs every terminal in one window. Each session is either a Claude Code session or
a plain zsh terminal in a chosen folder. The window shows which Claude sessions are working, which need
you (a permission prompt or a question) and which are ready for review, and lets you create, delete,
answer and type into all of them. No terminal windows on the desktop: every session lives in a private
tmux server and is drawn in the window with xterm.js.

The UI is the approved "09 Activity feed" prototype with the demo panel and fake backend removed:
the three stylings (Lavender default, Log, Slate), the session list with live statuses and counts, the
live feed with filters, the Waiting on you lane, the terminal tray, toasts, the per-session bell and
Do not disturb.

## How to run

- **Tests:** `cd app && swift test` (61 XCTests). UI check against a mock bridge in headless Chromium:
  `PLAYWRIGHT_CORE=<path to node_modules/playwright-core> node app/web/test/ui-check.js <out-dir>`
  (25 checks, fails on any console error, writes screenshots).
- **Dev run:** `app/scripts/run-dev.sh` (debug build, copied to `app/build/dev/`, page served from
  `app/web` so a reload picks up page edits). Logs in `app/build/dev.log`. Without arguments it uses the
  real folders and the real tmux server; for a scratch run add
  `--support-dir <dir> --tmux-socket <name>`.
- **Install:** `app/scripts/install.sh` builds `app/build/Terminal Manager.app`, quits a running copy
  (sessions survive in tmux), installs to `~/Applications/Terminal Manager.app` and opens it. Its first
  launch turns Open at login on.
- **Debug switches** (debug builds only; a release build refuses them): `--offscreen` (window placed past
  every display, never activated), `--no-status-item`, `--debug-script <js>` (runs as an async function
  in the page; prints `DEBUG_RESULT <json>`), `--snapshot <png>`, `--exit-after-debug`, `--debug-menu`
  (prints the dropdown's items). The page has a debug-only `debugSnapshot {path}` op for scripts.

## Architecture

```
app/
  Package.swift            HookWire (lib), PtySpawn (C), TerminalManager (app), TerminalManagerHook (helper), tests
  Sources/HookWire/        line protocol between helper and app (shared so they can't disagree), JSON scan/depth
  Sources/TerminalManagerHook/main.swift   the hook helper Claude Code runs
  Sources/PtySpawn/        forkpty + execve in C (nothing may run between fork and exec)
  Sources/TerminalManager/
    AppDelegate, main          wiring; LSUIElement accessory app
    MainWindow                 the window + WKWebView; closing only hides it; the hidden main menu (⌘C/⌘V/⌘W)
    StatusItem                 the + in the menu bar and its dropdown (StatusIconStyle holds the color rules)
    WebBridge                  page ops in (with replies), events out (window.TMNative.receive)
    SessionManager             sessions.json, tmux calls, hook handling, feed, polling
    SessionRecord, AppSettings sessions.json / settings.json models; FolderSuggestions
    ClaudeStatus               the pure status reducer (ClaudeSignal -> ClaudeActivity)
    Tmux                       every tmux argv (pure), pane parsing, ProcessRunner
    SessionLaunch              login environment, the env -i command, claude arguments
    HookServer, HookCenter     the socket (peer checks), routing, held PermissionRequests
    Approvals, AskDisplay      ask cards, answer outputs, the strict rule for answer buttons
    Transcript, Feed, GitChanges  transcript follower (replies, context %), feed log, changed files
    PtyClient                  one `tmux attach` per visible terminal, output coalesced per frame
    LoginItem, Notifier        open at login; macOS banners
  web/                     index.html, styles.css, js/{backend,terminals,app}.js, vendor/xterm, test/
  scripts/                 build.sh, install.sh, run-dev.sh, Info.plist
```

Files on disk:
- `~/Library/Application Support/Terminal Manager/`: `sessions.json` (sessions and Recently closed),
  `settings.json` (banners, Do not disturb, folders used), `feed.json` (last 900 events), `tmux.conf`.
- `~/.terminal-manager/claude-plugin/` (plugin.json, hooks/hooks.json, bin/terminal-manager-hook) and
  `~/.terminal-manager/run/hooks.sock`. Rewritten at every launch, only where bytes change.
- tmux: `tmux -L terminal-manager` (socket in `/private/tmp/tmux-<uid>/`), one session per app session,
  named `tm-<id>`.

### Sessions

- Created with `tmux new-session -d -s tm-<id> -c <dir> -x 160 -y 45 <argv>`; the argv is
  `/usr/bin/env -i K=V … program`, never through a shell, so the environment is exactly what the app
  builds: the login environment (read once at launch with `zsh -lic` from an emptied environment)
  minus anything of the process that started the app (CLAUDECODE, TMUX, TERM_PROGRAM, …), plus
  `TERM=xterm-256color`, `TERMINAL_MANAGER_SESSION=<id>`, and for Claude
  `CLAUDE_CODE_PLUGIN_DIRS=~/.terminal-manager/claude-plugin`.
- Claude: `claude --permission-mode <mode> --plugin-dir ~/.terminal-manager/claude-plugin
  --session-id <uuid> [first prompt]`. The app picks the session id, so it can always resume.
  Modes: Auto `auto` (the default), Ask before edits `manual`, Accept edits `acceptEdits`, Plan only
  `plan` (the exact values `claude --help` lists on 2.1.331; `default` is no longer one).
- Terminals: `/bin/zsh -l` in the folder.
- tmux config: no status line, escape-time 0, 50k history, xterm-256color, remain-on-exit (an exited
  program keeps its output and code), mouse on (the wheel scrolls tmux history), window-size latest.
- Polling: `list-panes -a` every second (dead panes and exit codes, current path, the shell's foreground
  job from `ps -t <tty>`); `capture-pane` every 2 s for the tray's last line.
- Quit leaves tmux running. At launch the app reconciles with `list-sessions`: sessions come back as
  they were (their last status is in sessions.json). A Claude session whose tmux session is gone
  (reboot, `kill-server`) is restarted at once with `claude --resume <session id>` in the same folder
  and mode. One whose process exited shows Exited with a Resume button. Deleted Claude sessions that had
  a conversation go to Recently closed, where Resume does the same.

### Display

Each visible terminal (the main pane, each open tray card) is its own `tmux -u attach` on a pty made
with forkpty. Output is read off the main thread, coalesced to one base64 message per frame, written to
xterm.js; keystrokes go back as `ptyInput`; xterm's fit addon drives `TIOCSWINSZ`. Terminals exist only
while shown. ⌘ shortcuts stay with the app; every other key goes to the terminal.

### Status from hooks

The plugin's hooks.json runs the helper for SessionStart, UserPromptSubmit, PreToolUse,
PermissionRequest, PermissionDenied, PostToolUse, PostToolUseFailure, Notification, Stop, StopFailure
and SessionEnd. The helper forwards one JSON line (with TERMINAL_MANAGER_SESSION) to the socket, always
exits 0, prints nothing unless it was holding a PermissionRequest that the app answered, and talks only
to a listener that the kernel says runs the app binary as the same user. The server checks the peer's
uid and that the sender is a direct child of the claude process it names. Routing: the session variable
first, then Claude's session id, the claude pid, then a folder with exactly one Claude session.

Statuses (pure reducer, `ClaudeStatus.swift`): prompt or tool → Working; PermissionRequest or
AskUserQuestion or a `permission_prompt` notification → Needs you; Stop → Ready for review; StopFailure →
Ready with an error; SessionEnd or a dead pane → Exited; "Looks good" → Reviewed. Viewing never clears
Ready. An interrupt (Esc) fires no hook, so the app also reads Claude Code's own registry
(`~/.claude/sessions/<pid>.json`, read only): idle for two reads in a row, 3 s after the last hook, ends
the turn as Interrupted.

### Answering

An interactive PermissionRequest of the main conversation is held: the helper waits on the socket and
the terminal shows its own dialog at the same time; the first answer wins. From the app the answer goes
back as the hook's output (`allow`, `deny` with a message, `allow` plus the echoed suggestion for Always,
or `updatedInput.answers` for a question). Answered in the terminal instead, Claude Code kills the helper
(the app sees the connection drop) or the tool's PostToolUse arrives; the card goes and the feed marks
it "Answered in the terminal". Each answer names the exact ask the card showed; if that one is gone the
app says so and never answers another.

Answer buttons follow one strict rule (`AskDisplay.swift`): every key of the tool input is shown (the
command or the file and its content or diff, then every other key as compact JSON), the detail fits its
box with no scrolling (100×12 on the session card, 22×5 on the lane and list cards), no long blank runs,
and plain characters only (Bash: printable ASCII plus newline and tab; other tools: printable ASCII,
letters and digits, ordinary spaces; never Cc, Cf, Zl, Zp, Mn, Me, other Zs, default-ignorable code
points or the blank-looking fillers). Otherwise the card says "Answer this one in the terminal" and
offers Open terminal. Multi-part and multi-select questions always go to the terminal.

### Feed

Built natively from the hooks (prompts, tool calls with their file or command, asks and their answers,
finished turns, failures, lifecycle) plus the transcript JSONL (Claude's text replies and the last
message's token usage, which drives the context meter: 200k window, 1M when the model says `[1m]` or the
tokens pass 200k). Changed files on a finished turn: `git diff --numstat HEAD` plus untracked files when
the folder is a repo, else the Edit/Write inputs of that turn. Cost is hidden, not guessed.

### Composer

Text goes into the pane with `tmux load-buffer` + `paste-buffer -p` (bracketed paste when the program
asked for it), then Enter 150 ms later (Claude Code reads an Enter in the same read as the paste as part
of the paste).

### Menu bar, window, notifications

- The status item is a + drawn in code: a template image when idle, orange (not template) when a session
  needs you, green when something is ready and nothing needs you. No count. `StatusIconStyle` holds the
  colors in one place.
- The dropdown: the sessions that need you and the finished ones (a click opens the window on it), New
  Claude session…, New terminal…, Open window, Open at login (checkmark), Settings…, Quit.
- No Dock icon (`LSUIElement`). Closing the window hides it. The window opens at launch unless macOS
  launched the app as a login item (or `--background`).
- Banners: only when a session needs you and the window is not key, never with banners off, Do not
  disturb on, or the session's bell muted. Finished sessions update quietly. Settings (⌘, or the menu)
  has Notification banners, Do not disturb and Open at login. A bare binary (dev runs) has no bundle
  id, so it posts no banners and asks for no permission; the toast still shows.
- Open at login: `SMAppService.mainApp.register()` first; if macOS does not report it enabled (an ad-hoc
  signed app can be refused or left waiting for approval) the app writes
  `~/Library/LaunchAgents/com.brodykretz.terminal-manager.plist` (`/usr/bin/open -a <app>`). Only for the
  bundle in /Applications or ~/Applications; scratch and debug runs never touch it.

## Decisions

- **Standalone project.** Hook helper, socket and plugin code was adapted from an earlier
  project and renamed; nothing is shared at runtime.
- **`/usr/bin/env -i` argv instead of `/bin/sh -c`.** The brief said "via /bin/sh"; the point was never
  zsh. tmux execs a multi-argument command directly, so the environment is exactly the one built,
  with no shell quoting at all.
- **`--plugin-dir` as well as CLAUDE_CODE_PLUGIN_DIRS.** A user's `~/.claude/settings.json` can have an `env`
  block that sets CLAUDE_CODE_PLUGIN_DIRS, and Claude Code applies it over
  the process environment, so the variable alone never loaded the app's plugin (found in the first real
  run: no hooks arrived). `--plugin-dir` adds it on top. `claude plugin list` shows both loaded.
- **Auto-resume when the tmux session is gone, offer Resume when the process exited.** A gone tmux
  session means a reboot or a killed server, so the conversation comes straight back; an exited process
  may have been `/exit` on purpose.
- **Mode changes apply at the next restart** (Restart keeps the conversation with `--resume`).
- **Answer buttons under a strict rule** (see Answering). Many long commands and edits are answered in
  the session's own terminal; the card says so.

## Gotchas

- **Shells and plugin folders from the shell profile.** A shell profile (e.g. `~/.zshenv`) may add other
  plugin folders to CLAUDE_CODE_PLUGIN_DIRS in every zsh. App-launched Claude sessions never go through zsh, so they don't
  get it. A `claude` typed in one of the app's terminals does get whatever the shell setup gives it (and
  a settings.json env block can override the variable anyway). Accepted for M1.
- **Workspace trust.** A folder Claude Code has never seen shows "Is this a project you trust?" with
  "No, exit" selected. Answer it in the session's terminal (↓ then Enter). Plugin hooks only run after.
- **Copying text** from a terminal: Option-drag selects in xterm.js, then ⌘C. A plain drag is tmux copy
  mode (mouse is on so the wheel scrolls history).
- **Fast-exiting commands** given to `new-session` can lose their output before tmux draws the pane;
  sessions here are long-lived, so it does not matter.
- **Socket path** must fit 103 bytes; `~/.terminal-manager/run/hooks.sock` does.
- **Fonts** come from Google Fonts like the prototype; offline the page falls back to system fonts.

## Verification (2026-11-24)

- `swift build` clean, `swift test`: 63 XCTests (hook lines and routing, the status reducer, tmux argv
  and the environment without shell-profile plugins, sessions.json round trip, transcript parsing, the
  answer-button rule with tricky input, answering only the shown ask, resume at launch, open-at-login
  plist).
- `app/web/test/ui-check.js`: 25 checks in headless Chromium at 1440×900 and 1280×800, all three
  stylings, zero console errors; it also measures that every ask detail fits its box.
- Real end to end, debug binary run offscreen against a scratch support folder and its own tmux server
  (`--tmux-socket tm-e2e`), driven by page scripts:
  - Terminal session: typed `echo hi` into the embedded terminal, saw `hi`, status Idle.
  - Claude session in Ask before edits with the first prompt "create a file named hello.txt in the
    current directory containing hi": trust dialog answered in its terminal, then Working → Needs you
    ("Wants to write hello.txt", card detail `hello.txt` / `hi`) → Allow once clicked in the Waiting on
    you lane → Working → Ready for review; the file exists; the TUI shows "Allowed by PermissionRequest
    hook". The composer then sent "Reply with just the word ok…": Working → Ready, reply `ok`.
  - The claude process ran with `--plugin-dir ~/.terminal-manager/claude-plugin` and
    `CLAUDE_CODE_PLUGIN_DIRS` naming only the app's plugin; no plugin from the shell profile, no other hook helper.
  - Quit and relaunch: both sessions came back with their statuses and the terminals re-attached with
    their output and the conversation.
  - Resume for real: killed the tmux server, relaunched: the Claude session resumed by itself
    (`--resume <id>`) with the whole conversation on screen; deleted it, it went to Recently closed,
    Resume brought it back with the conversation again. Then everything was deleted.
  - An earlier run showed an ask the card could not show whole (a Read of a long absolute path): the
    card said "Answer this one in the terminal", answering it in the terminal released the held hook
    ("answered in the terminal") and the turn went on.
- Menu bar dropdown printed with `--debug-menu`. `scripts/build.sh` builds and ad-hoc signs the bundle;
  the release binary refuses debug switches.
- **Not verified:** the installed app (not installed during testing, by instruction), so Open at login
  (whether SMAppService accepts the ad-hoc signed bundle or the LaunchAgent fallback is used: the log
  says which), macOS banners and their permission prompt (a bare binary posts none), the status icon's
  colors on a real menu bar, real mouse and keyboard in the window (scripts used xterm's input path and
  DOM clicks), the Finder chooser.

## To do first (for the lead)

1. `app/scripts/install.sh`, then check `log stream --predicate 'process == "terminal-manager"'` or the
   app's stderr for "open at login: on through …" to see which mechanism took. If SMAppService left it
   waiting for approval, the LaunchAgent is used instead.
2. Allow notifications when macOS asks.
3. Sessions started from the installed app live in `tmux -L terminal-manager`; test runs used
   `tm-e2e`, which is gone.
