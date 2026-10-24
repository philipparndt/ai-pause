package main

/*
void openSettings(char *html, int length);
void setPopoverHTML(char *html, int length);
void closePopover(void);
void pushWeb(char *json, int length);
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

	_ "embed"
)

//go:embed web/settings.html
var settingsHTML []byte

//go:embed web/popover.html
var popoverHTML []byte

var onWebMessage func(msg string)
var onWebVisibility func(view string, visible bool)

func initWebViews() {
	C.setPopoverHTML((*C.char)(unsafe.Pointer(&popoverHTML[0])), C.int(len(popoverHTML)))
}

func showSettings() {
	C.openSettings((*C.char)(unsafe.Pointer(&settingsHTML[0])), C.int(len(settingsHTML)))
}

func closePopover() { C.closePopover() }

// pushToWeb sends a snapshot to every visible web view (popover, settings).
func pushToWeb(v any) {
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	C.pushWeb((*C.char)(unsafe.Pointer(&data[0])), C.int(len(data)))
}

//export webMessage
func webMessage(msg *C.char) {
	s := C.GoString(msg)
	go onWebMessage(s)
}

//export webVisibility
func webVisibility(view *C.char, visible C.int) {
	name := C.GoString(view)
	go onWebVisibility(name, visible != 0)
}

type dashSample struct {
	T int64   `json:"t"` // unix ms
	P float64 `json:"p"` // CPU %, 100 = one core
	Z bool    `json:"z"` // paused
}

type dashSession struct {
	PID       int          `json:"pid"`
	Name      string       `json:"name"`
	Status    string       `json:"status"`
	Agent     string       `json:"agent"`
	Cwd       string       `json:"cwd"`
	CwdShort  string       `json:"cwdShort"`
	Processes int          `json:"processes"`
	Current   float64      `json:"current"`
	Avg       float64      `json:"avg"`
	Peak      float64      `json:"peak"`
	Frozen    bool         `json:"frozen"`
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
	HookInstalled  bool          `json:"hookInstalled"`
	Notice         *notice       `json:"notice,omitempty"`
}

type notice struct {
	OK      bool   `json:"ok"`
	Message string `json:"message"`
}

func toDashSamples(h []sample) []dashSample {
	out := make([]dashSample, len(h))
	for i, s := range h {
		out[i] = dashSample{T: s.at.UnixMilli(), P: s.pct, Z: s.paused}
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
		HookInstalled: claudeHookInstalled(), Sessions: []dashSession{},
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
		frozen := slices.Contains(s.FrozenSessions, pid)
		snap.Sessions = append(snap.Sessions, dashSession{
			PID: pid, Name: cmpOr(reg.Name, baseName(cwd)), Status: reg.Status, Agent: sess.root.name,
			Cwd: cwd, CwdShort: strings.Replace(cwd, home, "~", 1), Processes: len(sess.desc) + 1, Current: st.current(),
			Avg: avg(st.history, historyLen), Peak: peak(st.history), Frozen: frozen,
			Verdict: st.compliance(snap.Active || frozen), History: toDashSamples(st.history),
			Top: st.topProcs(sess, 8),
		})
	}
	return snap
}

// handleWebMessage processes actions sent by the dashboard page.
func (t *tray) handleWebMessage(raw string) {
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
	if len(cfg.AgentProcesses) == 0 {
		return fmt.Errorf("at least one agent process name is required")
	}
	return nil
}

func (t *tray) refreshDashboard(n *notice) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if len(t.webViews) == 0 {
		return
	}
	snap := t.snapshot(loadConfig(), loadState())
	snap.Notice = n
	pushToWeb(snap)
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
