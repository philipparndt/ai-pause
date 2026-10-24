package main

import (
	"cmp"
	"fmt"
	"slices"
	"strings"
	"time"
)

const (
	historyLen  = 200 // samples kept per session (10 minutes at 3s ticks), shown in the dashboard
	menuHistory = 40  // samples shown in the menu (2 minutes)
)

type sample struct {
	at     time.Time
	pct    float64 // CPU usage, 100 = one core
	paused bool
}

type sessionStats struct {
	history []sample
	procPct map[int]float64 // latest usage per process of the session
	// Averages around the most recent pause start, to see whether the agent complied.
	before, after  float64
	afterN         int
	pauseStartedAt time.Time
}

// sampler turns cumulative CPU times into per-session usage history.
type sampler struct {
	prevCPU map[int]float64
	prevAt  time.Time
	stats   map[int]*sessionStats // by agent root pid
	total   []sample              // all agent sessions together
	procPct map[int]float64       // latest usage of every process
	watched map[string]*watchStats
}

// watchStats tracks a group of non-agent processes matching one watch pattern.
type watchStats struct {
	history []sample
	top     []procUsage
}

func newSampler() *sampler {
	return &sampler{prevCPU: map[int]float64{}, stats: map[int]*sessionStats{}, watched: map[string]*watchStats{}}
}

func appendSample(h []sample, s sample) []sample {
	h = append(h, s)
	if len(h) > historyLen {
		h = h[len(h)-historyLen:]
	}
	return h
}

func (sm *sampler) update(procs []proc, sessions []session, isPaused func(root int) bool) {
	now := time.Now()
	elapsed := now.Sub(sm.prevAt).Seconds()
	first := sm.prevAt.IsZero()

	procPct := map[int]float64{}
	cur := map[int]float64{}
	for _, p := range procs {
		cur[p.pid] = p.cpu
		if prev, ok := sm.prevCPU[p.pid]; ok && !first && p.cpu >= prev {
			procPct[p.pid] = (p.cpu - prev) / elapsed * 100
		}
	}
	sm.prevCPU, sm.prevAt, sm.procPct = cur, now, procPct
	if first {
		return
	}

	alive := map[int]bool{}
	var sum float64
	anyPaused := false
	for _, sess := range sessions {
		alive[sess.root.pid] = true
		st := sm.stats[sess.root.pid]
		if st == nil {
			st = &sessionStats{}
			sm.stats[sess.root.pid] = st
		}
		st.procPct = map[int]float64{}
		paused := isPaused(sess.root.pid)
		anyPaused = anyPaused || paused
		var total float64
		for _, pid := range sess.pids() {
			total += procPct[pid]
			st.procPct[pid] = procPct[pid]
		}
		sum += total

		wasPaused := len(st.history) > 0 && st.history[len(st.history)-1].paused
		if paused && !wasPaused {
			// Baseline: average of the last ~30s before the pause.
			st.before = avg(st.history, 10)
			st.after, st.afterN, st.pauseStartedAt = 0, 0, now
		}
		// Give the agent ~10s to react before judging compliance.
		if paused && now.Sub(st.pauseStartedAt) > 10*time.Second {
			st.after = (st.after*float64(st.afterN) + total) / float64(st.afterN+1)
			st.afterN++
		}
		st.history = appendSample(st.history, sample{at: now, pct: total, paused: paused})
	}
	sm.total = appendSample(sm.total, sample{at: now, pct: sum, paused: anyPaused})
	for pid := range sm.stats {
		if !alive[pid] {
			delete(sm.stats, pid)
		}
	}
}

// updateWatched samples the processes matching the watch patterns that don't
// belong to an agent session. Call after update.
func (sm *sampler) updateWatched(procs []proc, sessions []session, patterns []string) {
	if sm.prevAt.IsZero() || sm.procPct == nil {
		return
	}
	inSession := map[int]bool{}
	for _, sess := range sessions {
		for _, pid := range sess.pids() {
			inSession[pid] = true
		}
	}
	seen := map[string]bool{}
	for _, pat := range patterns {
		if pat == "" {
			continue
		}
		var matched []procUsage
		var total float64
		for _, p := range procs {
			if !inSession[p.pid] && strings.Contains(strings.ToLower(p.name), strings.ToLower(pat)) {
				matched = append(matched, procUsage{PID: p.pid, Name: p.name, Pct: sm.procPct[p.pid]})
				total += sm.procPct[p.pid]
			}
		}
		if len(matched) == 0 {
			continue
		}
		seen[pat] = true
		ws := sm.watched[pat]
		if ws == nil {
			ws = &watchStats{}
			sm.watched[pat] = ws
		}
		slices.SortStableFunc(matched, func(a, b procUsage) int { return cmp.Compare(b.Pct, a.Pct) })
		ws.top = matched[:min(6, len(matched))]
		ws.history = appendSample(ws.history, sample{at: sm.prevAt, pct: total})
	}
	for pat := range sm.watched {
		if !seen[pat] {
			delete(sm.watched, pat)
		}
	}
}

func avg(h []sample, n int) float64 {
	h = h[max(0, len(h)-n):]
	if len(h) == 0 {
		return 0
	}
	var sum float64
	for _, s := range h {
		sum += s.pct
	}
	return sum / float64(len(h))
}

func peak(h []sample) float64 {
	var p float64
	for _, s := range h {
		p = max(p, s.pct)
	}
	return p
}

type verdict struct {
	Text   string  `json:"text"`
	Warn   bool    `json:"warn"`
	OK     bool    `json:"ok"`
	Before float64 `json:"before"`
	After  float64 `json:"after"`
}

// compliance summarizes whether a session reduced its load after the pause started.
func (st *sessionStats) compliance(paused bool) verdict {
	if !paused || st.pauseStartedAt.IsZero() {
		return verdict{}
	}
	if st.afterN == 0 {
		return verdict{Text: fmt.Sprintf("before pause %.0f%% – waiting for reaction…", st.before), Before: st.before}
	}
	v := verdict{Before: st.before, After: st.after}
	if st.after < 25 || st.after < st.before/3 {
		v.OK, v.Text = true, "✓ backed off"
	} else {
		v.Warn, v.Text = true, "⚠ still busy"
	}
	v.Text = fmt.Sprintf("%s: %.0f%% before pause → %.0f%% since", v.Text, st.before, st.after)
	return v
}

func (st *sessionStats) current() float64 {
	if len(st.history) == 0 {
		return 0
	}
	return st.history[len(st.history)-1].pct
}

type procUsage struct {
	PID  int     `json:"pid"`
	Name string  `json:"name"`
	Pct  float64 `json:"pct"`
}

// topProcs returns the busiest processes of a session.
func (st *sessionStats) topProcs(sess session, n int) []procUsage {
	var all []procUsage
	for _, p := range append([]proc{sess.root}, sess.desc...) {
		all = append(all, procUsage{PID: p.pid, Name: p.name, Pct: st.procPct[p.pid]})
	}
	slices.SortStableFunc(all, func(a, b procUsage) int { return cmp.Compare(b.Pct, a.Pct) })
	return all[:min(n, len(all))]
}

func (p procUsage) String() string {
	return fmt.Sprintf("%5.0f%%  %s (%d)", p.Pct, p.Name, p.PID)
}
