package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// claudeSession is what Claude Code publishes about each running session in
// ~/.claude/sessions/<pid>.json.
type claudeSession struct {
	PID    int    `json:"pid"`
	Name   string `json:"name"`
	Status string `json:"status"` // idle, busy, …
	Cwd    string `json:"cwd"`
	Kind   string `json:"kind"`
}

func claudeRegistry() map[int]claudeSession {
	home, _ := os.UserHomeDir()
	files, _ := filepath.Glob(filepath.Join(home, ".claude", "sessions", "*.json"))
	sessions := map[int]claudeSession{}
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var s claudeSession
		if json.Unmarshal(data, &s) == nil && s.PID > 0 {
			sessions[s.PID] = s
		}
	}
	return sessions
}
