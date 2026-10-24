# ai-pause

A macOS menu bar app that tells AI coding agents (Claude Code, Codex, Gemini CLI, aider, …) and everything
they spawned to stop CPU-intensive work, e.g. while you present in a Teams call or play a game.
It also shows live CPU usage for each agent session, so you can see which ones are expensive.

## Pause modes

| Mode       | Effect |
|------------|--------|
| `polite`   | Agents are told to hold off: the Claude Code hook refuses `Bash` and browser tools (cheap read-only commands stay allowed) and explains why, so the agent keeps editing but stops running things. |
| `throttle` | `polite` + every agent process tree runs at macOS background priority (lowest CPU/IO, efficiency cores). |
| `freeze`   | `throttle` + everything the agents spawned (test suites, builds, dev servers, browsers, MCP servers) is stopped with `SIGSTOP` and continued on resume. The agent processes themselves are not stopped, so terminals don't treat them as suspended jobs. |

The checks are re-applied every 3 seconds, so processes started after the pause began are caught too.
Quitting the app always resumes and un-throttles everything it touched.

## Auto-detection

While enabled (menu: *Auto-pause during calls & apps*), the app pauses on its own (default mode: `freeze`) when:

- a listed app keeps the display awake (Teams/Zoom/Webex/FaceTime during calls, Keynote/PowerPoint while presenting),
- any app records from the microphone (calls), or
- a listed process is running (add games to `running_apps`).

It resumes 60 seconds after the last trigger disappears. If you click *Resume* during an automatic pause, auto-pause is
snoozed until the trigger goes away. Run `ai-pause triggers` to see what is currently detected.

## Session CPU graphs

The menu lists every agent session (the agent process plus everything it spawned) with a 2-minute CPU graph,
sorted by load. Hover over a session to see:

- its busiest processes,
- after a pause starts, whether it backed off: `✓ backed off: 180% before pause → 4% since` or `⚠ still busy` (the paused period is shaded orange in the graph),
- *Freeze this session*, to stop the tasks of just this one session.

`ai-pause sessions` prints the same information in the terminal.

## Popover and settings

Click the menu bar icon for the popover (right-click for the classic menu):

- tiles for pause state / resume, total agent CPU, mode, and auto-pause with what it currently detects,
- one row per session with its state (`STILL BUSY`, `BACKED OFF`, `FROZEN`, `BUSY`, `IDLE`), a 2-minute bar chart
  and current CPU; click a row for its busiest processes, the before/after verdict, *Freeze* and *Show in Finder*.

*Settings…* opens a small window with all options and a *Detected right now* panel listing apps that keep the display
awake or use the microphone, so you can add them with one click during a call or game. It also installs the Claude
Code hook.

Both are web views talking to the app through WebKit's script message bridge; there is no local HTTP server.

## Install

Requires macOS 14.2+ and Go.

```sh
make install                  # → ~/Applications/AI Pause.app, ~/.local/bin/ai-pause, starts at login
ai-pause install-claude-hook  # adds the PreToolUse hook to ~/.claude/settings.json (backup is written first)
```

### Other agents

Agents without hooks are still covered by `throttle`/`freeze`. For polite behaviour, add something like this to
`AGENTS.md`/`CLAUDE.md`:

> Before running tests, builds or anything that opens windows, run `ai-pause check`. If it fails, don't run them.

Scripts can use `ai-pause wait && npm test` to wait until the pause is over.

## CLI

```
ai-pause pause [-mode M] [-for 1h] [-reason TEXT]
ai-pause resume | status [-json] | check | wait | sessions | triggers
```

## Config

`~/.config/ai-pause/config.json` (menu: *Edit config…*). It's reloaded on every tick. Shared state lives in
`~/.config/ai-pause/state.json`.
