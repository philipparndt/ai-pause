package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

const usage = `ai-pause – tell AI agents to stop CPU-intensive work

Usage:
  ai-pause [tray]                 run the menu bar app
  ai-pause pause [-mode M] [-for 1h] [-reason TEXT]
                                  pause agents (mode: polite|throttle|freeze)
  ai-pause resume                 resume agents
  ai-pause status [-json]         show the current state
  ai-pause check                  exit 1 (and explain) while paused – for scripts/agents
  ai-pause wait                   block until not paused, e.g. "ai-pause wait && npm test"
  ai-pause sessions               show CPU usage per agent session (3s sample)
  ai-pause triggers               show what auto-detection currently sees
  ai-pause hook claude            Claude Code PreToolUse hook (reads JSON on stdin)
  ai-pause install-claude-hook    register the hook in ~/.claude/settings.json
  ai-pause install-login          start the menu bar app at login
  ai-pause uninstall-login        stop starting it at login
  ai-pause version                print the version
`

// version is set at build time from the VERSION file.
var version = "dev"

func main() {
	if len(os.Args) < 2 {
		runTray()
		return
	}
	cmd, args := os.Args[1], os.Args[2:]
	switch cmd {
	case "tray":
		runTray()
	case "pause":
		cfg := loadConfig()
		fs := flag.NewFlagSet("pause", flag.ExitOnError)
		mode := fs.String("mode", cfg.Mode, "polite|throttle|freeze")
		dur := fs.Duration("for", 0, "duration, e.g. 45m (default: until resumed)")
		reason := fs.String("reason", "", "reason shown to agents")
		_ = fs.Parse(args)
		if *mode != ModePolite && *mode != ModeThrottle && *mode != ModeFreeze {
			fail("invalid mode %q", *mode)
		}
		s := loadState()
		s.Paused, s.Mode, s.Reason, s.Source, s.Since = true, *mode, *reason, SourceManual, time.Now()
		s.Until = time.Time{}
		if *dur > 0 {
			s.Until = time.Now().Add(*dur)
		}
		check(saveState(enforce(s, cfg)))
		fmt.Println(s.Describe())
	case "resume":
		s := loadState()
		s.Paused = false
		check(saveState(enforce(s, loadConfig())))
		fmt.Println("Resumed")
	case "status":
		fs := flag.NewFlagSet("status", flag.ExitOnError)
		asJSON := fs.Bool("json", false, "print JSON")
		_ = fs.Parse(args)
		s := loadState()
		if *asJSON {
			_ = json.NewEncoder(os.Stdout).Encode(map[string]any{
				"active": s.Active(time.Now()), "mode": s.Mode, "reason": s.Reason,
				"source": s.Source, "until": s.Until,
			})
			return
		}
		fmt.Println(s.Describe())
	case "check":
		if s := loadState(); s.Affects(os.Getppid()) {
			fmt.Fprintln(os.Stderr, s.AgentMessage())
			os.Exit(1)
		}
	case "wait":
		for loadState().Affects(os.Getppid()) {
			time.Sleep(5 * time.Second)
		}
	case "sessions":
		cfg := loadConfig()
		sm := newSampler()
		var sessions []session
		for range 2 {
			procs, err := listProcs()
			check(err)
			sessions = agentSessions(procs, cfg.AgentProcesses, triggerPids(cfg.Auto))
			sm.update(procs, sessions, func(int) bool { return false })
			time.Sleep(3 * time.Second)
		}
		for _, sess := range sessions {
			st := sm.stats[sess.root.pid]
			if st == nil {
				continue
			}
			fmt.Printf("%6.0f%%  %s (%d)  %s\n", st.current(), sess.root.name, sess.root.pid, processCwd(sess.root.pid))
			for _, line := range st.topProcs(sess, 3) {
				fmt.Println("          " + line.String())
			}
		}
	case "triggers":
		reasons := detectTriggers(loadConfig().Auto)
		if len(reasons) == 0 {
			fmt.Println("no triggers")
		}
		for _, r := range reasons {
			fmt.Println(r)
		}
	case "hook":
		if len(args) == 0 || args[0] != "claude" {
			fail("usage: ai-pause hook claude")
		}
		runClaudeHook()
	case "install-claude-hook":
		check(installClaudeHook())
	case "install-login":
		check(installLoginItem())
	case "uninstall-login":
		_ = exec.Command("launchctl", "bootout", fmt.Sprintf("gui/%d/%s", os.Getuid(), launchAgentLabel)).Run()
		check(os.Remove(launchAgentPath()))
		fmt.Println("Removed", launchAgentPath())
	case "version", "-v", "--version":
		fmt.Println("ai-pause", version)
	case "-h", "--help", "help":
		fmt.Print(usage)
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
}

const launchAgentLabel = "de.philipparndt.ai-pause"

// bundleID matches CFBundleIdentifier in Info.plist. Naming it in the LaunchAgent makes
// System Settings list the login item as AI Pause instead of the signing developer.
const bundleID = "de.philipparndt.ai-pause"

func launchAgentPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", launchAgentLabel+".plist")
}

func installLoginItem() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, _ = filepath.EvalSymlinks(exe)
	plist := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>AssociatedBundleIdentifiers</key><string>%s</string>
  <key>ProgramArguments</key><array><string>%s</string><string>tray</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
`, launchAgentLabel, bundleID, exe)
	if err := writeFileAtomic(launchAgentPath(), []byte(plist)); err != nil {
		return err
	}
	domain := fmt.Sprintf("gui/%d", os.Getuid())
	_ = exec.Command("launchctl", "bootout", domain+"/"+launchAgentLabel).Run()
	// bootout returns before the old instance is gone; bootstrap fails until then.
	for attempt := 0; ; attempt++ {
		out, err := exec.Command("launchctl", "bootstrap", domain, launchAgentPath()).CombinedOutput()
		if err == nil {
			break
		}
		if attempt == 20 {
			return fmt.Errorf("launchctl bootstrap: %v: %s", err, out)
		}
		time.Sleep(250 * time.Millisecond)
	}
	fmt.Println("Installed and started", launchAgentPath())
	return nil
}

func check(err error) {
	if err != nil {
		fail("%v", err)
	}
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "ai-pause: "+format+"\n", a...)
	os.Exit(1)
}
