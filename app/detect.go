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
	"fmt"
	"os/exec"
	"regexp"
	"slices"
	"strings"
)

var assertionLine = regexp.MustCompile(`pid (\d+)\((.+?)\): \[[^\]]*\] \S+ (\w+) named:`)

// displaySleepHolders returns the names of processes preventing display sleep.
func displaySleepHolders() []string {
	out, err := exec.Command("pmset", "-g", "assertions").Output()
	if err != nil {
		return nil
	}
	var names []string
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		m := assertionLine.FindStringSubmatch(sc.Text())
		if m != nil && (m[3] == "PreventUserIdleDisplaySleep" || m[3] == "NoDisplaySleepAssertion") {
			names = append(names, m[2])
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

// detectTriggers returns human-readable reasons why an automatic pause should be active.
func detectTriggers(cfg AutoConfig) []string {
	var reasons []string
	add := func(r string) {
		if !slices.Contains(reasons, r) {
			reasons = append(reasons, r)
		}
	}
	for _, name := range displaySleepHolders() {
		if containsFold(cfg.DisplaySleepApps, name, true) {
			add(name + " active")
		}
	}

	if len(cfg.RunningApps) == 0 && !cfg.MicrophoneInUse {
		return reasons
	}
	procs, err := listProcs()
	if err != nil {
		return reasons
	}
	names := map[int]string{}
	for _, p := range procs {
		names[p.pid] = p.name
		if containsFold(cfg.RunningApps, p.name, false) {
			add(p.name + " running")
		}
	}
	if cfg.MicrophoneInUse {
		for _, pid := range micUserPids() {
			name := names[pid]
			if name == "" || containsFold(cfg.MicrophoneIgnore, name, true) {
				continue
			}
			add("microphone used by " + name)
		}
	}
	return reasons
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
