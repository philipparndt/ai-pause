package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type hookInput struct {
	ToolName  string `json:"tool_name"`
	ToolInput struct {
		Command string `json:"command"`
	} `json:"tool_input"`
}

var commandSeparators = regexp.MustCompile(`&&|\|\||;|\||\n`)

// commandAllowed reports whether every segment of a shell command is cheap.
func commandAllowed(cmd string, allow *regexp.Regexp) bool {
	for _, seg := range commandSeparators.Split(cmd, -1) {
		if strings.TrimSpace(seg) == "" {
			continue
		}
		if !allow.MatchString(seg) {
			return false
		}
	}
	return true
}

// runClaudeHook implements a Claude Code PreToolUse hook: while paused it
// denies heavy tools and tells the agent why.
func runClaudeHook() {
	s := loadState()
	if !s.Affects(os.Getppid()) {
		return
	}
	var in hookInput
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		return
	}
	cfg := loadConfig()
	block, err := regexp.Compile(cfg.HookBlockTools)
	if err != nil || !block.MatchString(in.ToolName) {
		return
	}
	if in.ToolName == "Bash" {
		if allow, err := regexp.Compile(cfg.HookAllowCommands); err == nil && commandAllowed(in.ToolInput.Command, allow) {
			return
		}
	}
	out := map[string]any{
		"hookSpecificOutput": map[string]any{
			"hookEventName":            "PreToolUse",
			"permissionDecision":       "deny",
			"permissionDecisionReason": s.AgentMessage(),
		},
	}
	_ = json.NewEncoder(os.Stdout).Encode(out)
}

func claudeSettingsPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude", "settings.json")
}

// installClaudeHook registers `ai-pause hook claude` as a PreToolUse hook in
// ~/.claude/settings.json (a backup of the original is written first).
func installClaudeHook() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, _ = filepath.EvalSymlinks(exe)
	command := fmt.Sprintf("%q hook claude", exe)

	path := claudeSettingsPath()
	settings := map[string]any{}
	data, err := os.ReadFile(path)
	switch {
	case err == nil:
		if err := json.Unmarshal(data, &settings); err != nil {
			return fmt.Errorf("parse %s: %w", path, err)
		}
		if err := os.WriteFile(path+".bak-ai-pause", data, 0o644); err != nil {
			return err
		}
	case !errors.Is(err, os.ErrNotExist):
		return err
	}

	hooks, _ := settings["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	pre, _ := hooks["PreToolUse"].([]any)
	if strings.Contains(fmt.Sprint(pre), "hook claude") && strings.Contains(fmt.Sprint(pre), "ai-pause") {
		fmt.Println("ai-pause hook already installed in", path)
		return nil
	}
	pre = append(pre, map[string]any{
		"matcher": "",
		"hooks":   []any{map[string]any{"type": "command", "command": command}},
	})
	hooks["PreToolUse"] = pre
	settings["hooks"] = hooks

	out, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return err
	}
	if err := writeFileAtomic(path, append(out, '\n')); err != nil {
		return err
	}
	fmt.Println("Installed PreToolUse hook in", path, "(backup: settings.json.bak-ai-pause)")
	return nil
}
