package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

const (
	SourceManual = "manual"
	SourceAuto   = "auto"
)

// State is the shared "broadcast" all agents and hooks read.
type State struct {
	Paused bool      `json:"paused"`
	Mode   string    `json:"mode,omitempty"`
	Reason string    `json:"reason,omitempty"`
	Source string    `json:"source,omitempty"`
	Since  time.Time `json:"since,omitzero"`
	Until  time.Time `json:"until,omitzero"` // zero: until resumed

	// Bookkeeping so any process (tray or CLI) can undo what was applied.
	Frozen    []int `json:"frozen,omitempty"`
	Throttled []int `json:"throttled,omitempty"`

	// Agent root pids frozen individually from the menu, independent of Paused.
	FrozenSessions []int `json:"frozen_sessions,omitempty"`
}

func statePath() string { return filepath.Join(configDir(), "state.json") }

func loadState() State {
	var s State
	if data, err := os.ReadFile(statePath()); err == nil {
		_ = json.Unmarshal(data, &s)
	}
	return s
}

func saveState(s State) error {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(statePath(), data)
}

func (s State) Active(now time.Time) bool {
	return s.Paused && (s.Until.IsZero() || now.Before(s.Until))
}

func (s State) Describe() string {
	if !s.Active(time.Now()) {
		return "AI agents running normally"
	}
	msg := "Paused (" + s.Mode + ")"
	if s.Reason != "" {
		msg += " – " + s.Reason
	}
	if s.Until.IsZero() {
		msg += " – until resumed"
	} else {
		msg += " – until " + s.Until.Format("15:04")
	}
	return msg
}

func (s State) AgentMessage() string {
	until := "until the user resumes"
	if !s.Until.IsZero() {
		until = "until about " + s.Until.Format("15:04")
	}
	reason := ""
	if s.Reason != "" {
		reason = fmt.Sprintf(" (%s)", s.Reason)
	}
	return fmt.Sprintf("ai-pause: The user has paused AI agents%s %s, e.g. for a presentation, call or game. "+
		"Do NOT run tests, builds, dev servers, browsers or anything CPU-intensive or that opens windows. "+
		"You may keep reading and editing files. If you cannot continue without running commands, "+
		"stop and tell the user you are waiting for the pause to be lifted. Do not poll or retry.", reason, until)
}
