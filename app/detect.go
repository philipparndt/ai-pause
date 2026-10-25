package main

/*
#cgo LDFLAGS: -framework CoreAudio
#include <CoreAudio/CoreAudio.h>
#include <stdlib.h>

// Fills pids with processes currently recording audio input (macOS 14+).
// Returns the number of pids written.
static int micUsers(pid_t *pids, int max) {
	AudioObjectPropertyAddress addr = {
		kAudioHardwarePropertyProcessObjectList,
		kAudioObjectPropertyScopeGlobal,
		kAudioObjectPropertyElementMain,
	};
	UInt32 size = 0;
	if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr) return 0;
	int n = size / sizeof(AudioObjectID);
	if (n == 0) return 0;
	AudioObjectID *objs = malloc(size);
	if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, objs) != noErr) {
		free(objs);
		return 0;
	}
	int found = 0;
	for (int i = 0; i < n && found < max; i++) {
		UInt32 running = 0, rsize = sizeof(running);
		AudioObjectPropertyAddress raddr = {
			kAudioProcessPropertyIsRunningInput,
			kAudioObjectPropertyScopeGlobal,
			kAudioObjectPropertyElementMain,
		};
		if (AudioObjectGetPropertyData(objs[i], &raddr, 0, NULL, &rsize, &running) != noErr || !running) continue;
		pid_t pid = 0;
		UInt32 psize = sizeof(pid);
		AudioObjectPropertyAddress paddr = {
			kAudioProcessPropertyPID,
			kAudioObjectPropertyScopeGlobal,
			kAudioObjectPropertyElementMain,
		};
		if (AudioObjectGetPropertyData(objs[i], &paddr, 0, NULL, &psize, &pid) == noErr) pids[found++] = pid;
	}
	free(objs);
	return found;
}
*/
import "C"

import (
	"bufio"
	"bytes"
	"cmp"
	"encoding/json"
	"fmt"
	"os/exec"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

var assertionLine = regexp.MustCompile(`pid (\d+)\((.+?)\): \[[^\]]*\] \S+ (\w+) named: "(.*)"`)

type assertion struct {
	pid        int
	owner      string // process name
	kind, name string // e.g. PreventUserIdleDisplaySleep, "game"
}

// powerAssertions lists the power assertions processes hold (pmset -g assertions).
func powerAssertions() []assertion {
	out, err := exec.Command("pmset", "-g", "assertions").Output()
	if err != nil {
		return nil
	}
	var list []assertion
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		if m := assertionLine.FindStringSubmatch(sc.Text()); m != nil {
			pid, _ := strconv.Atoi(m[1])
			list = append(list, assertion{pid: pid, owner: m[2], kind: m[3], name: m[4]})
		}
	}
	return list
}

func preventsDisplaySleep(a assertion) bool {
	return a.kind == "PreventUserIdleDisplaySleep" || a.kind == "NoDisplaySleepAssertion"
}

// isGame reports whether an assertion says it's a game keeping the Mac awake.
func isGame(a assertion) bool { return strings.Contains(strings.ToLower(a.name), "game") }

// displaySleepHolders returns the names of processes preventing display sleep.
func displaySleepHolders() []string {
	var names []string
	for _, a := range powerAssertions() {
		if preventsDisplaySleep(a) {
			names = append(names, a.owner)
		}
	}
	return names
}

func micUserPids() []int {
	var buf [64]C.pid_t
	n := int(C.micUsers(&buf[0], C.int(len(buf))))
	pids := make([]int, n)
	for i := range n {
		pids[i] = int(buf[i])
	}
	return pids
}

func containsFold(list []string, name string, substring bool) bool {
	return slices.ContainsFunc(list, func(s string) bool {
		if substring {
			return strings.Contains(strings.ToLower(name), strings.ToLower(s))
		}
		return strings.EqualFold(name, s)
	})
}

// trigger is a reason for an automatic pause and the process causing it.
type trigger struct {
	reason string
	pid    int
}

// The tray, enforce and the CLI all ask within the same tick; pmset and
// CoreAudio are only queried once per second.
var detectCache struct {
	sync.Mutex
	at       time.Time
	cfg      string
	triggers []trigger
}

// detect returns what auto-detection currently sees.
func detect(cfg AutoConfig) []trigger {
	key, _ := json.Marshal(cfg)
	detectCache.Lock()
	defer detectCache.Unlock()
	if time.Since(detectCache.at) < time.Second && detectCache.cfg == string(key) {
		return detectCache.triggers
	}

	var triggers []trigger
	add := func(reason string, pid int) { triggers = append(triggers, trigger{reason, pid}) }
	for _, a := range powerAssertions() {
		switch {
		case preventsDisplaySleep(a) && containsFold(cfg.DisplaySleepApps, a.owner, true):
			add(a.owner+" active", a.pid)
		case cfg.Games && isGame(a):
			add(a.owner+" (game) running", a.pid)
		}
	}
	if procs, err := listProcs(); err == nil {
		names := map[int]string{}
		for _, p := range procs {
			names[p.pid] = p.name
			if containsFold(cfg.RunningApps, p.name, false) {
				add(p.name+" running", p.pid)
			}
		}
		if cfg.MicrophoneInUse {
			for _, pid := range micUserPids() {
				if name := names[pid]; name != "" && !containsFold(cfg.MicrophoneIgnore, name, true) {
					add("microphone used by "+name, pid)
				}
			}
		}
	}
	detectCache.at, detectCache.cfg, detectCache.triggers = time.Now(), string(key), triggers
	return triggers
}

// detectTriggers returns human-readable reasons why an automatic pause should be active.
func detectTriggers(cfg AutoConfig) []string {
	var reasons []string
	for _, t := range detect(cfg) {
		if !slices.Contains(reasons, t.reason) {
			reasons = append(reasons, t.reason)
		}
	}
	return reasons
}

// triggerPids returns the processes that cause an automatic pause. They are
// never paused themselves, even when an agent started them (e.g. a game
// launched from a Claude session).
func triggerPids(cfg AutoConfig) map[int]bool {
	pids := map[int]bool{}
	for _, t := range detect(cfg) {
		pids[t.pid] = true
	}
	return pids
}

// observation is the raw input of auto-detection, shown in the dashboard to help configure it.
type observation struct {
	DisplaySleep []string `json:"displaySleep"`
	Microphone   []string `json:"microphone"`
}

func observe() observation {
	o := observation{DisplaySleep: displaySleepHolders(), Microphone: []string{}}
	if o.DisplaySleep == nil {
		o.DisplaySleep = []string{}
	}
	if pids := micUserPids(); len(pids) > 0 {
		procs, _ := listProcs()
		names := map[int]string{}
		for _, p := range procs {
			names[p.pid] = p.name
		}
		for _, pid := range pids {
			o.Microphone = append(o.Microphone, cmp.Or(names[pid], fmt.Sprintf("pid %d", pid)))
		}
	}
	return o
}
