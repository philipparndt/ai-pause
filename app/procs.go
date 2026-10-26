package main

import (
	"bufio"
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

type proc struct {
	pid, ppid int
	name      string  // basename of the executable
	cpu       float64 // accumulated CPU seconds
}

// session is an agent process together with everything it spawned.
type session struct {
	root proc
	desc []proc
}

func (s session) pids() []int {
	pids := []int{s.root.pid}
	for _, p := range s.desc {
		pids = append(pids, p.pid)
	}
	return pids
}

func listProcs() ([]proc, error) {
	out, err := exec.Command("ps", "-axo", "pid=,ppid=,time=,comm=").Output()
	if err != nil {
		return nil, err
	}
	var procs []proc
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 4 {
			continue
		}
		pid, _ := strconv.Atoi(f[0])
		ppid, _ := strconv.Atoi(f[1])
		comm := strings.Join(f[3:], " ")
		procs = append(procs, proc{pid: pid, ppid: ppid, cpu: parseCPUTime(f[2]), name: filepath.Base(comm)})
	}
	return procs, nil
}

// parseCPUTime parses ps time values like "12:34.56" or "1:02:03.45".
func parseCPUTime(s string) float64 {
	var total float64
	for part := range strings.SplitSeq(strings.ReplaceAll(s, "-", ":"), ":") {
		v, _ := strconv.ParseFloat(part, 64)
		total = total*60 + v
	}
	return total
}

// agentSessions groups processes by the agent that started them. Processes in
// skip (and everything they started) are left out of every session.
func agentSessions(procs []proc, agentNames []string, skip map[int]bool) []session {
	children := map[int][]proc{}
	byPid := map[int]proc{}
	for _, p := range procs {
		children[p.ppid] = append(children[p.ppid], p)
		byPid[p.pid] = p
	}
	isAgent := func(p proc) bool { return slices.Contains(agentNames, p.name) }
	// An agent started by another agent belongs to the outer session.
	hasAgentAncestor := func(p proc) bool {
		for q, ok := byPid[p.ppid]; ok && q.pid > 1; q, ok = byPid[q.ppid] {
			if isAgent(q) {
				return true
			}
		}
		return false
	}
	self := os.Getpid()

	var sessions []session
	for _, p := range procs {
		if !isAgent(p) || hasAgentAncestor(p) {
			continue
		}
		s := session{root: p}
		var walk func(pid int)
		walk = func(pid int) {
			for _, c := range children[pid] {
				if c.pid == self || c.name == "ai-pause" || skip[c.pid] {
					continue
				}
				s.desc = append(s.desc, c)
				walk(c.pid)
			}
		}
		walk(p.pid)
		sessions = append(sessions, s)
	}
	return sessions
}

func setBackground(pid int, bg bool) error {
	prio := 0
	if bg {
		prio = unix.PRIO_DARWIN_BG
	}
	return unix.Setpriority(unix.PRIO_DARWIN_PROCESS, pid, prio)
}

// enforce applies the effects of the state to the current process table and
// returns the updated bookkeeping. It is idempotent and called periodically,
// so processes spawned after the pause started are caught as well.
func enforce(s State, cfg Config) State {
	now := time.Now()
	if s.Paused && !s.Active(now) {
		s.Paused = false // expired
	}
	globalMode := ""
	if s.Paused {
		globalMode = s.Mode
	}

	var sessions []session
	// Processes that triggered the pause (a game, a call) and the processes that
	// started them keep running at full speed.
	keep := map[int]bool{}
	if procs, err := listProcs(); err == nil && (modeRank(globalMode) > modeRank(ModePolite) || len(s.PausedSessions) > 0) {
		triggers := triggerPids(cfg.Auto)
		sessions = agentSessions(procs, cfg.AgentProcesses, triggers)
		parent := map[int]int{}
		for _, p := range procs {
			parent[p.pid] = p.ppid
		}
		for pid := range triggers {
			for p := parent[pid]; p > 1 && !keep[p]; p = parent[p] {
				keep[p] = true
			}
		}
	}

	// Agent roots themselves are never stopped: they are usually the foreground
	// job of a terminal, and the shell would treat them as suspended (needing `fg`).
	// Stopping their children is enough to halt tests, builds and browsers.
	var frozen, throttled, pausedSessions []int
	for _, sess := range sessions {
		mode := globalMode
		if slices.Contains(s.PausedSessions, sess.root.pid) {
			pausedSessions = append(pausedSessions, sess.root.pid)
			if modeRank(cfg.Mode) > modeRank(mode) {
				mode = cfg.Mode
			}
		}
		if mode == ModeFreeze {
			for _, p := range sess.desc {
				if !keep[p.pid] && syscall.Kill(p.pid, syscall.SIGSTOP) == nil {
					frozen = append(frozen, p.pid)
				}
			}
		}
		if modeRank(mode) >= modeRank(ModeThrottle) {
			for _, pid := range sess.pids() {
				if !keep[pid] && setBackground(pid, true) == nil {
					throttled = append(throttled, pid)
				}
			}
		}
	}
	for _, pid := range s.Frozen {
		if !slices.Contains(frozen, pid) {
			_ = syscall.Kill(pid, syscall.SIGCONT)
		}
	}
	for _, pid := range s.Throttled {
		if !slices.Contains(throttled, pid) {
			_ = setBackground(pid, false)
		}
	}

	s.Frozen, s.Throttled, s.PausedSessions = frozen, throttled, pausedSessions
	return s
}

// processCwd returns the working directory of a process.
func processCwd(pid int) string {
	out, err := exec.Command("lsof", "-a", "-p", strconv.Itoa(pid), "-d", "cwd", "-Fn").Output()
	if err != nil {
		return ""
	}
	for line := range strings.SplitSeq(string(out), "\n") {
		if dir, ok := strings.CutPrefix(line, "n"); ok {
			return dir
		}
	}
	return ""
}
