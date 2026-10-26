package main

/*
#cgo LDFLAGS: -framework CoreGraphics -framework CoreFoundation
#include <CoreGraphics/CoreGraphics.h>

// Fills ids and pids with the windows and dialogs on screen. Owners and bounds are
// readable without the Screen Recording permission. Returns the number of windows written.
static int listWindows(int *ids, int *pids, int max) {
	CFArrayRef list = CGWindowListCopyWindowInfo(
		kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
	if (!list) return 0;
	int found = 0;
	for (CFIndex i = 0; i < CFArrayGetCount(list) && found < max; i++) {
		CFDictionaryRef w = CFArrayGetValueAtIndex(list, i);
		int layer = -1;
		CFNumberRef n = CFDictionaryGetValue(w, kCGWindowLayer);
		// Normal windows up to modal panels (dialogs, alerts); not menus or overlays.
		if (!n || !CFNumberGetValue(n, kCFNumberIntType, &layer) || layer < 0 || layer > kCGModalPanelWindowLevel) continue;
		double alpha = 1;
		if ((n = CFDictionaryGetValue(w, kCGWindowAlpha))) CFNumberGetValue(n, kCFNumberDoubleType, &alpha);
		if (alpha == 0) continue;
		// Skip tiny helper windows.
		CGRect r;
		CFDictionaryRef b = CFDictionaryGetValue(w, kCGWindowBounds);
		if (!b || !CGRectMakeWithDictionaryRepresentation(b, &r) || r.size.width < 50 || r.size.height < 50) continue;
		int pid = 0, id = 0;
		if (!(n = CFDictionaryGetValue(w, kCGWindowOwnerPID)) || !CFNumberGetValue(n, kCFNumberIntType, &pid)) continue;
		if (!(n = CFDictionaryGetValue(w, kCGWindowNumber)) || !CFNumberGetValue(n, kCFNumberIntType, &id)) continue;
		ids[found] = id;
		pids[found] = pid;
		found++;
	}
	CFRelease(list);
	return found;
}
*/
import "C"

import (
	"sync"
	"time"
)

const (
	windowPoll = 250 * time.Millisecond
	// Windows off screen (other Space, minimized) are remembered this long, so
	// bringing them back doesn't count as opening them. Window numbers aren't reused.
	windowMemory = time.Hour
)

// windowWatcher polls the windows on screen far more often than CPU is sampled, so
// windows that open and close again between two samples are still counted.
type windowWatcher struct {
	mu     sync.Mutex
	seen   map[int]time.Time // window number -> last seen on screen
	roots  map[int]bool      // agent session roots, from the last sample
	opened map[int]int       // windows opened per session root since the last take
	counts map[int]int       // windows on screen per pid
}

func newWindowWatcher() *windowWatcher {
	return &windowWatcher{seen: map[int]time.Time{}, opened: map[int]int{}, counts: map[int]int{}}
}

func (w *windowWatcher) run() {
	for range time.Tick(windowPoll) {
		w.mu.Lock()
		idle := len(w.roots) == 0
		w.mu.Unlock()
		if !idle {
			w.poll()
		}
	}
}

func (w *windowWatcher) poll() {
	var ids, pids [2048]C.int
	n := int(C.listWindows(&ids[0], &pids[0], C.int(len(ids))))
	now := time.Now()

	w.mu.Lock()
	defer w.mu.Unlock()
	first := len(w.seen) == 0
	counts := map[int]int{}
	for i := range n {
		id, pid := int(ids[i]), int(pids[i])
		counts[pid]++
		if _, known := w.seen[id]; !known && !first {
			if root := ancestorIn(pid, func(p int) bool { return w.roots[p] }); root != 0 {
				w.opened[root]++
			}
		}
		w.seen[id] = now
	}
	for id, at := range w.seen {
		if now.Sub(at) > windowMemory {
			delete(w.seen, id)
		}
	}
	w.counts = counts
}

// take returns the windows opened per session root since the last call and the
// windows on screen per pid, and sets the session roots for the next interval.
func (w *windowWatcher) take(sessions []session) (opened, counts map[int]int) {
	w.mu.Lock()
	defer w.mu.Unlock()
	opened, counts = w.opened, w.counts
	w.opened = map[int]int{}
	w.roots = map[int]bool{}
	for _, s := range sessions {
		w.roots[s.root.pid] = true
	}
	return opened, counts
}

// windows returns how many windows the session's processes have on screen.
func (s session) windows(counts map[int]int) int {
	n := 0
	for _, pid := range s.pids() {
		n += counts[pid]
	}
	return n
}
