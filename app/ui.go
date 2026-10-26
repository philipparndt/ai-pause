package main

/*
void aipause_ui_push(char *json, int length);
void aipause_ui_close_popover(void);
void aipause_ui_show_settings(void);
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strings"
	"time"
	"unsafe"
)

// The popover and settings window are SwiftUI views (ui/*.swift). Go sends
// them snapshots as JSON and receives actions as JSON messages.

// uiLibHash is set by the Makefile so Go relinks when the Swift library changes.
var uiLibHash string

var onUIMessage func(msg string)
var onUIVisibility func(view string, visible bool)

func showSettings() { C.aipause_ui_show_settings() }

func closePopover() { C.aipause_ui_close_popover() }

// pushToUI sends a snapshot to the SwiftUI views.
func pushToUI(v any) {
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	C.aipause_ui_push((*C.char)(unsafe.Pointer(&data[0])), C.int(len(data)))
}

//export uiMessage
func uiMessage(msg *C.char) {
	s := C.GoString(msg)
	go onUIMessage(s)
}

//export uiVisibility
func uiVisibility(view *C.char, visible C.int) {
	name := C.GoString(view)
	go onUIVisibility(name, visible != 0)
}

type dashSample struct {
	T int64   `json:"t"`           // unix ms
	P float64 `json:"p"`           // CPU %, 100 = one core
	Z bool    `json:"z"`           // paused
	W int     `json:"w,omitempty"` // windows opened
}

type dashSession struct {
	PID       int          `json:"pid"`
	Name      string       `json:"name"`
	Status    string       `json:"status"`
	Agent     string       `json:"agent"`
	Cwd       string       `json:"cwd"`
	CwdShort  string       `json:"cwdShort"`
	Processes int          `json:"processes"`
	Windows   int          `json:"windows"`
	Current   float64      `json:"current"`
	Avg       float64      `json:"avg"`
	Peak      float64      `json:"peak"`
	Paused    bool         `json:"paused"`
	Verdict   verdict      `json:"verdict"`
	History   []dashSample `json:"history"`
	Top       []procUsage  `json:"top"`
}

type dashSnapshot struct {
	Active         bool          `json:"active"`
	Mode           string        `json:"mode"`
	Reason         string        `json:"reason"`
	Source         string        `json:"source"`
	Since          int64         `json:"since"`
	Until          int64         `json:"until"`
	FrozenCount    int           `json:"frozenCount"`
	ThrottledCount int           `json:"throttledCount"`
	Config         Config        `json:"config"`
	Reasons        []string      `json:"reasons"`
	SuppressAuto   bool          `json:"suppressAuto"`
	Observed       observation   `json:"observed"`
	Sessions       []dashSession `json:"sessions"`
	Total          []dashSample  `json:"total"`
	Hogs           []dashHog     `json:"hogs"`
	HookInstalled  bool          `json:"hookInstalled"`
	Notice         *notice       `json:"notice,omitempty"`
}

// dashHog is a watched non-agent process group that currently uses a lot of CPU.
type dashHog struct {
	Name    string       `json:"name"`
	Current float64      `json:"current"`
	Avg     float64      `json:"avg"`
	History []dashSample `json:"history"`
	Top     []procUsage  `json:"top"`
}

type notice struct {
	OK      bool   `json:"ok"`
	Message string `json:"message"`
}

func toDashSamples(h []sample) []dashSample {
	out := make([]dashSample, len(h))
	for i, s := range h {
		out[i] = dashSample{T: s.at.UnixMilli(), P: s.pct, Z: s.paused, W: s.opened}
	}
	return out
}

func unixMilli(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UnixMilli()
}

func claudeHookInstalled() bool {
	data, err := os.ReadFile(claudeSettingsPath())
	return err == nil && strings.Contains(string(data), "ai-pause") && strings.Contains(string(data), "hook claude")
}

// snapshot collects everything the dashboard shows. Called with t.mu held.
func (t *tray) snapshot(cfg Config, s State) dashSnapshot {
	snap := dashSnapshot{
		Active: s.Active(time.Now()), Mode: s.Mode, Reason: s.Reason, Source: s.Source,
		Since: unixMilli(s.Since), Until: unixMilli(s.Until),
		FrozenCount: len(s.Frozen), ThrottledCount: len(s.Throttled),
		Config: cfg, Reasons: t.reasons, SuppressAuto: t.suppressAuto,
		Observed: observe(), Total: toDashSamples(t.sampler.total),
		HookInstalled: claudeHookInstalled(), Sessions: []dashSession{}, Hogs: []dashHog{},
	}
	for _, pat := range cfg.WatchProcesses {
		ws := t.sampler.watched[pat]
		if ws == nil || len(ws.history) == 0 {
			continue
		}
		cur := ws.history[len(ws.history)-1].pct
		if recent := avg(ws.history, 10); recent >= cfg.WatchThreshold || cur >= cfg.WatchThreshold {
			snap.Hogs = append(snap.Hogs, dashHog{
				Name: pat, Current: cur, Avg: recent, History: toDashSamples(ws.history), Top: ws.top,
			})
		}
	}
	if snap.Reasons == nil {
		snap.Reasons = []string{}
	}
	home, _ := os.UserHomeDir()
	for _, sess := range t.sessions {
		pid := sess.root.pid
		st := t.sampler.stats[pid]
		if st == nil {
			continue
		}
		reg := t.registry[pid]
		cwd := cmpOr(reg.Cwd, t.cwds[pid])
		paused := slices.Contains(s.PausedSessions, pid)
		snap.Sessions = append(snap.Sessions, dashSession{
			PID: pid, Name: cmpOr(reg.Name, baseName(cwd)), Status: reg.Status, Agent: sess.root.name,
			Cwd: cwd, CwdShort: strings.Replace(cwd, home, "~", 1), Processes: len(sess.desc) + 1, Windows: sess.windows(t.windows), Current: st.current(),
			Avg: avg(st.history, historyLen), Peak: peak(st.history), Paused: paused,
			Verdict: st.compliance(snap.Active || paused), History: toDashSamples(st.history),
			Top: st.topProcs(sess, 8),
		})
	}
	return snap
}

// handleUIMessage processes actions sent by the popover and settings window.
func (t *tray) handleUIMessage(raw string) {
	var msg struct {
		Action string          `json:"action"`
		ID     string          `json:"id"`
		Config json.RawMessage `json:"config"`
	}
	if json.Unmarshal([]byte(raw), &msg) != nil {
		return
	}
	var n *notice
	switch msg.Action {
	case "click":
		t.click(msg.ID)
		return
	case "saveConfig":
		cfg := loadConfig()
		if err := json.Unmarshal(msg.Config, &cfg); err != nil {
			n = &notice{Message: "Invalid settings: " + err.Error()}
		} else if err := validateConfig(cfg); err != nil {
			n = &notice{Message: err.Error()}
		} else if err := saveConfig(cfg); err != nil {
			n = &notice{Message: "Could not save: " + err.Error()}
		} else {
			n = &notice{OK: true, Message: "Settings saved"}
		}
	case "installHook":
		if err := installClaudeHook(); err != nil {
			n = &notice{Message: "Could not install hook: " + err.Error()}
		} else {
			n = &notice{OK: true, Message: "Claude Code hook installed. New tool calls in all sessions will honour pauses."}
		}
	}
	t.refreshDashboard(n)
}

func validateConfig(cfg Config) error {
	for _, m := range []string{cfg.Mode, cfg.Auto.Mode} {
		if _, ok := modeInfo[m]; !ok {
			return fmt.Errorf("unknown mode %q", m)
		}
	}
	for name, re := range map[string]string{"blocked tools": cfg.HookBlockTools, "allowed commands": cfg.HookAllowCommands} {
		if _, err := regexp.Compile(re); err != nil {
			return fmt.Errorf("invalid regex for %s: %v", name, err)
		}
	}
	if cfg.WatchThreshold < 0 {
		return fmt.Errorf("the CPU threshold for watched processes can't be negative")
	}
	if len(cfg.AgentProcesses) == 0 {
		return fmt.Errorf("at least one agent process name is required")
	}
	return nil
}

func (t *tray) refreshDashboard(n *notice) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if len(t.views) == 0 {
		return
	}
	snap := t.snapshot(loadConfig(), loadState())
	snap.Notice = n
	pushToUI(snap)
}

func cmpOr(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func baseName(p string) string {
	if i := strings.LastIndex(p, "/"); i >= 0 {
		return p[i+1:]
	}
	return p
}
