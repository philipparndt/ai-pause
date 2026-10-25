First release.

- Menu bar popover with CPU charts per agent session (Claude Code, Codex, Gemini CLI, aider, …)
- Three pause modes: polite (Claude Code hook), throttle (background priority), freeze (stops what agents started)
- Auto-pause during Teams/Zoom/Webex/FaceTime calls, presentations, games and chosen apps; whatever triggered the pause is never paused itself
- Shows whether agents back off after a pause starts
- Lists other CPU hogs such as Microsoft Defender
- CLI: `ai-pause pause | resume | status | check | wait | sessions | triggers`
