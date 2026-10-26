package main

import (
	"cmp"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	tick               = 3 * time.Second
	topProcsPerSession = 6
)

var modeInfo = map[string]struct{ title, desc, symbol string }{
	ModePolite:   {"Polite", "Agents are asked to hold off", "hand.raised"},
	ModeThrottle: {"Throttle", "Also lowest CPU priority", "tortoise"},
	ModeFreeze:   {"Freeze", "Also stop running tests, builds, browsers", "snowflake"},
}

// trayLock stays open for the life of the tray; the OS drops the lock when the process ends.
var trayLock *os.File

// singleInstance reports whether this is the only tray. Opening the app while the
// login item already runs it would otherwise put a second icon in the menu bar.
func singleInstance() bool {
	_ = os.MkdirAll(configDir(), 0o755)
	f, err := os.OpenFile(filepath.Join(configDir(), "tray.lock"), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return true // can't tell; better two icons than none
	}
	if syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		f.Close()
		return false
	}
	trayLock = f
	return true
}

func runTray() {
	if !singleInstance() {
		fmt.Fprintln(os.Stderr, "ai-pause: already running in the menu bar")
		return
	}
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	go func() {
		<-sig
		releaseProcesses()
		os.Exit(0)
	}()
	t := &tray{sampler: newSampler(), cwds: map[int]string{}, views: map[string]bool{}, watcher: newWindowWatcher()}
	go t.watcher.run()
	onUIMessage = t.handleUIMessage
	onUIVisibility = func(view string, visible bool) {
		t.mu.Lock()
		if visible {
			t.views[view] = true
		} else {
			delete(t.views, view)
		}
		t.mu.Unlock()
		if visible {
			t.refreshDashboard(nil)
		}
	}
	runMenuBar(t.run, t.click, t.menuOpened, t.menuClosed)
}

// releaseProcesses never leaves processes stopped or throttled behind when the
// app exits. The pause itself stays in the state file, so agent hooks keep
// honouring a manual pause.
func releaseProcesses() {
	s := loadState()
	active := s.Paused
	s.Paused, s.PausedSessions = false, nil
	s = enforce(s, loadConfig())
	s.Paused = active
	_ = saveState(s)
}

type tray struct {
	mu           sync.Mutex
	lastTrigger  time.Time
	suppressAuto bool // user resumed during an auto pause; wait until triggers clear
	reasons      []string
	sampler      *sampler
	sessions     []session
	registry     map[int]claudeSession
	windows      map[int]int // on-screen windows per pid
	watcher      *windowWatcher
	cwds         map[int]string
	menuOpen     bool
	views        map[string]bool // visible popover / settings window
	order        []int           // session order shown while the menu is open
}

func (t *tray) menuOpened() {
	t.mu.Lock()
	t.menuOpen = true
	t.mu.Unlock()
}

func (t *tray) menuClosed() {
	t.mu.Lock()
	t.menuOpen = false
	t.mu.Unlock()
	t.refresh(false)
}

func (t *tray) run() {
	t.refresh(true)
	for range time.Tick(tick) {
		t.refresh(true)
	}
}

func (t *tray) click(id string) {
	t.mu.Lock()
	cfg, s := loadConfig(), loadState()
	action, arg, _ := strings.Cut(id, ":")
	switch action {
	case "pause":
		d, _ := time.ParseDuration(arg)
		s.Paused, s.Mode, s.Source, s.Reason, s.Since = true, cfg.Mode, SourceManual, "", time.Now()
		s.Until = time.Time{}
		if d > 0 {
			s.Until = time.Now().Add(d)
		}
	case "resume":
		if s.Source == SourceAuto && len(t.reasons) > 0 {
			t.suppressAuto = true
		}
		s.Paused = false
	case "mode":
		cfg.Mode = arg
		_ = saveConfig(cfg)
		if s.Active(time.Now()) && s.Source == SourceManual {
			s.Mode = arg
		}
	case "auto":
		cfg.Auto.Enabled = !cfg.Auto.Enabled
		_ = saveConfig(cfg)
	case "pauseSession":
		pid, _ := strconv.Atoi(arg)
		if i := slices.Index(s.PausedSessions, pid); i >= 0 {
			s.PausedSessions = slices.Delete(s.PausedSessions, i, i+1)
		} else {
			s.PausedSessions = append(s.PausedSessions, pid)
		}
	case "reveal":
		closePopover()
		_ = exec.Command("open", arg).Start()
	case "config":
		_ = exec.Command("open", "-t", configPath()).Start()
	case "dashboard":
		showSettings()
	case "quit":
		releaseProcesses()
		os.Exit(0)
	}
	_ = saveState(s)
	t.mu.Unlock()
	t.refresh(false)
}

// refresh runs auto-detection, enforces the state and redraws the menu.
// Sampling is skipped for refreshes triggered by clicks to keep the CPU history evenly spaced.
func (t *tray) refresh(sample bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	cfg, s, now := loadConfig(), loadState(), time.Now()

	if sample {
		t.reasons = nil
		if cfg.Auto.Enabled {
			t.reasons = detectTriggers(cfg.Auto)
		}
		if len(t.reasons) == 0 {
			t.suppressAuto = false
		} else {
			t.lastTrigger = now
		}
	}
	switch {
	case len(t.reasons) > 0 && !t.suppressAuto && (!s.Active(now) || s.Source == SourceAuto):
		if !s.Active(now) {
			s.Since = now
		}
		s.Paused, s.Mode, s.Source, s.Until = true, cfg.Auto.Mode, SourceAuto, time.Time{}
		s.Reason = strings.Join(t.reasons, ", ")
	case len(t.reasons) == 0 && s.Active(now) && s.Source == SourceAuto &&
		now.Sub(t.lastTrigger) >= time.Duration(cfg.Auto.ResumeDelaySeconds)*time.Second:
		s.Paused = false
	}
	s = enforce(s, cfg)
	_ = saveState(s)

	if sample {
		if procs, err := listProcs(); err == nil {
			t.sessions = agentSessions(procs, cfg.AgentProcesses, triggerPids(cfg.Auto))
			t.registry = claudeRegistry()
			var opened map[int]int
			opened, t.windows = t.watcher.take(t.sessions)
			active := s.Active(now)
			t.sampler.update(procs, t.sessions, func(root int) bool {
				return active || slices.Contains(s.PausedSessions, root)
			}, opened)
			t.sampler.updateWatched(procs, t.sessions, cfg.WatchProcesses)
		}
	}
	setMenuModel(t.model(cfg, s))
	if len(t.views) > 0 {
		pushToUI(t.snapshot(cfg, s))
	}
}

func (t *tray) model(cfg Config, s State) MenuModel {
	now := time.Now()
	active := s.Active(now)
	m := MenuModel{Icon: "cpu"}
	if active {
		m.Icon = "pause.circle.fill"
		if !s.Until.IsZero() {
			m.ButtonTitle = shortDuration(s.Until.Sub(now))
		}
	}

	// Status header
	header := MenuItem{Title: "Agents running normally", Symbol: "circle.fill", Color: "green", Bold: true,
		Subtitle: fmt.Sprintf("%d sessions", len(t.sessions))}
	if active {
		header.Title = "Paused · " + modeInfo[s.Mode].title
		header.Color = "orange"
		var parts []string
		if s.Reason != "" {
			parts = append(parts, s.Reason)
		}
		if s.Until.IsZero() {
			parts = append(parts, "until resumed")
		} else {
			parts = append(parts, "until "+s.Until.Format("15:04"))
		}
		if len(s.Frozen) > 0 {
			parts = append(parts, fmt.Sprintf("%d tasks frozen", len(s.Frozen)))
		} else if len(s.Throttled) > 0 {
			parts = append(parts, fmt.Sprintf("%d processes throttled", len(s.Throttled)))
		}
		header.Subtitle = strings.Join(parts, " · ")
	}
	items := []MenuItem{header, {ID: "dashboard", Title: "Settings…", Symbol: "gearshape"}}
	if active {
		items = append(items, MenuItem{ID: "resume", Title: "Resume now", Symbol: "play.fill", Color: "green"})
	}

	// Pause actions
	items = append(items, separator(), section("Pause"),
		MenuItem{ID: "pause:15m", Title: "For 15 minutes", Symbol: "timer"},
		MenuItem{ID: "pause:1h", Title: "For 1 hour", Symbol: "clock"},
		MenuItem{ID: "pause:2h", Title: "For 2 hours", Symbol: "clock.arrow.circlepath"},
		MenuItem{ID: "pause:0", Title: "Until resumed", Symbol: "infinity"},
	)
	modeItem := MenuItem{Title: "Mode: " + modeInfo[cfg.Mode].title, Subtitle: modeInfo[cfg.Mode].desc,
		Symbol: modeInfo[cfg.Mode].symbol}
	for _, mode := range []string{ModePolite, ModeThrottle, ModeFreeze} {
		info := modeInfo[mode]
		modeItem.Children = append(modeItem.Children, MenuItem{ID: "mode:" + mode, Title: info.title,
			Subtitle: info.desc, Symbol: info.symbol, Checked: mode == cfg.Mode})
	}
	items = append(items, modeItem, t.autoItem(cfg))

	// Sessions
	items = append(items, separator(), section("Sessions · CPU last 2 min"))
	// Busiest first, but keep the order stable while the menu is open so rows
	// don't jump under the mouse.
	sessions := slices.Clone(t.sessions)
	rank := func(pid int) int {
		if i := slices.Index(t.order, pid); i >= 0 {
			return i
		}
		return len(t.order)
	}
	slices.SortStableFunc(sessions, func(a, b session) int {
		if t.menuOpen {
			return cmp.Compare(rank(a.root.pid), rank(b.root.pid))
		}
		return cmp.Compare(t.avgOf(b.root.pid), t.avgOf(a.root.pid))
	})
	t.order = t.order[:0]
	for _, sess := range sessions {
		t.order = append(t.order, sess.root.pid)
	}
	if len(sessions) == 0 {
		items = append(items, MenuItem{Title: "No agent sessions running", Disabled: true})
	}
	for _, sess := range sessions {
		items = append(items, t.sessionItem(sess, s, active))
	}

	items = append(items, separator(),
		MenuItem{ID: "config", Title: "Edit Config File…", Symbol: "doc.text"},
		MenuItem{ID: "quit", Title: "Quit AI Pause", Symbol: "power"},
	)
	m.Items = items
	return m
}

func (t *tray) autoItem(cfg Config) MenuItem {
	item := MenuItem{ID: "auto", Title: "Auto-pause during calls & apps", Symbol: "video", Checked: cfg.Auto.Enabled}
	switch {
	case !cfg.Auto.Enabled:
		item.Subtitle = "Off"
	case t.suppressAuto:
		item.Subtitle = "Snoozed until " + strings.Join(t.reasons, ", ") + " ends"
	case len(t.reasons) > 0:
		item.Subtitle = "Triggered: " + strings.Join(t.reasons, ", ")
	default:
		var watch []string
		watch = append(watch, cfg.Auto.DisplaySleepApps...)
		watch = append(watch, cfg.Auto.RunningApps...)
		if cfg.Auto.MicrophoneInUse {
			watch = append(watch, "microphone")
		}
		item.Subtitle = "Watching " + truncate(strings.Join(watch, ", "), 48)
	}
	return item
}

func (t *tray) sessionItem(sess session, s State, active bool) MenuItem {
	pid := sess.root.pid
	reg, known := t.registry[pid]
	cwd := reg.Cwd
	if cwd == "" {
		var ok bool
		if cwd, ok = t.cwds[pid]; !ok {
			cwd = processCwd(pid)
			t.cwds[pid] = cwd
		}
	}
	home, _ := os.UserHomeDir()
	shortCwd := strings.Replace(cwd, home, "~", 1)
	name := filepath.Base(cwd)
	if known && reg.Name != "" {
		name = reg.Name
	}
	paused := slices.Contains(s.PausedSessions, pid)

	var sub []string
	if known && reg.Status != "" {
		sub = append(sub, reg.Status)
	} else {
		sub = append(sub, sess.root.name)
	}
	sub = append(sub, fmt.Sprintf("%d processes", len(sess.desc)+1))
	if w := sess.windows(t.windows); w == 1 {
		sub = append(sub, "1 window")
	} else if w > 1 {
		sub = append(sub, fmt.Sprintf("%d windows", w))
	}
	if paused {
		sub = append(sub, "paused")
	}
	item := MenuItem{ID: "session:" + strconv.Itoa(pid), Title: name, Tooltip: shortCwd}

	st := t.sampler.stats[pid]
	if st == nil {
		st = &sessionStats{}
	}
	v := st.compliance(active || paused)
	warn := v.Warn
	if warn {
		sub = append(sub, "still busy")
	} else if v.OK {
		sub = append(sub, "backed off")
	}
	item.Subtitle = strings.Join(sub, " · ")

	g := &Graph{Capacity: menuHistory, Label: fmt.Sprintf("%.0f%%", st.current()), Warn: warn}
	for _, h := range st.history[max(0, len(st.history)-menuHistory):] {
		g.Values = append(g.Values, h.pct)
		g.Paused = append(g.Paused, h.paused)
	}
	item.Graph = g

	item.Children = append(item.Children, section(shortCwd), section("Busiest processes"))
	// Fixed number of rows (unused ones hidden) so an open submenu is updated
	// in place instead of rebuilt.
	lines := st.topProcs(sess, topProcsPerSession)
	for i := range topProcsPerSession {
		row := MenuItem{Mono: true, Disabled: true, Hidden: i >= len(lines)}
		if i < len(lines) {
			row.Title = lines[i].String()
		}
		item.Children = append(item.Children, row)
	}
	item.Children = append(item.Children,
		MenuItem{Kind: "separator", Hidden: v.Text == ""},
		MenuItem{Title: v.Text, Disabled: true, Hidden: v.Text == ""})
	item.Children = append(item.Children, separator(),
		MenuItem{ID: "pauseSession:" + strconv.Itoa(pid), Title: "Pause This Session", Symbol: "pause.circle", Checked: paused},
		MenuItem{ID: "reveal:" + cwd, Title: "Show in Finder", Symbol: "folder"},
	)
	return item
}

func (t *tray) avgOf(root int) float64 {
	if st := t.sampler.stats[root]; st != nil {
		return avg(st.history, menuHistory)
	}
	return 0
}

func shortDuration(d time.Duration) string {
	if d >= time.Hour {
		return fmt.Sprintf("%dh%02d", int(d.Hours()), int(d.Minutes())%60)
	}
	return fmt.Sprintf("%dm", int(d.Minutes())+1)
}

func truncate(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n-1]) + "…"
	}
	return s
}
