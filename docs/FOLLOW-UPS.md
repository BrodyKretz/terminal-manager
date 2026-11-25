# Follow-ups

Deferred from milestone 1 on purpose, then minors found while building it. Nothing here blocks M1.

## Deferred features (agreed scope)

1. **Since you last looked digest.** The prototype's summary card above the feed. The feed and the
   per-row "N new" badges are built; the digest card is not.
2. **Pins.** Pinning feed events (the prototype's pin button and Pinned box). The column is still in
   the feed grid, empty.
3. **Sessions started outside the app.** Claude sessions started in Terminal.app (seen through the
   registry in `~/.claude/sessions/`) and the "Outside the app" list group.
4. **Cost.** The meta row hides it rather than guessing. A real number needs pricing per model from
   the transcript's usage lines.
5. **Typing `claude` in a terminal turns it into a Claude session.** Today that Claude runs inside the
   shell session, shows as a terminal, and loads whatever plugins the login shell gives it (see
   HANDOFF, "Shells and plugin folders from the shell profile").

## Minors and ideas

6. **Live permission-mode switch.** The mode select changes the mode for the next restart (Restart
   keeps the conversation with `--resume`). Switching a running session would mean sending Shift+Tab
   until the hooks' `permission_mode` reports the wanted mode.
7. **Multi-part and multi-select questions** go to the terminal (the card says so). The card could
   render all questions with checkboxes.
8. **Copying from a terminal** works with Option-drag (xterm.js selection, then ⌘C). A plain drag goes
   to tmux copy mode, whose buffer is not the macOS clipboard. An OSC 52 clipboard addon would fix it.
9. **Feed for terminals** knows the foreground command (from the tty's process group) but not each
   command typed at the prompt. Shell integration (precmd/preexec marks) would give per-command
   events with exit codes.
10. **Menu bar dropdown screenshot.** Not in the README: an NSMenu cannot be rendered offscreen.
11. **Fonts** load from Google Fonts like the prototype. Offline, the page falls back to the system
    UI font and SF Mono. Vendoring Instrument Sans and JetBrains Mono (both OFL) would make it exact.
12. **Window position** is remembered by AppKit's autosave; no per-display handling yet.
13. **A turn's last reply** can reach the transcript just after its Stop hook; the app re-reads at 0.4,
    1.2 and 3 s, so the reply's feed line can land a moment after "Finished its turn".
14. **tmux killed while the app runs** shows the Claude sessions as Exited with Resume; only a launch
    resumes them by itself.
15. **Cards show file paths relative to the hook's cwd** (the folder the card names). An absolute path
    outside it usually makes the card terminal-only by width.
16. **Other plugins.** A settings `env` block that sets CLAUDE_CODE_PLUGIN_DIRS still loads its own
    plugin into the app's Claude sessions alongside the app's (seen in testing: another plugin printing
    render errors into the TUI). Not the app's to change.
17. **Security review nits** from now on are parked here instead of more fix rounds.
