package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

const (
	ModePolite   = "polite"   // only agent hooks refuse new heavy work
	ModeThrottle = "throttle" // + agent process trees run with background (lowest) CPU/IO priority
	ModeFreeze   = "freeze"   // + processes spawned by agents (tests, builds, browsers) are SIGSTOPped
)

type AutoConfig struct {
	Enabled bool   `json:"enabled"`
	Mode    string `json:"mode"`
	// Pause while one of these apps keeps the display awake (Teams/Zoom do this during calls, Keynote while presenting).
	// Case-insensitive substring match on the process name.
	DisplaySleepApps []string `json:"display_sleep_apps"`
	// Pause while any process with one of these names is running (e.g. games). Case-insensitive exact match.
	RunningApps []string `json:"running_apps"`
	// Pause while a process holds a power assertion that calls itself a game.
	Games bool `json:"games"`
	// Pause while any app records from the microphone (calls), except the ignored ones.
	MicrophoneInUse  bool     `json:"microphone_in_use"`
	MicrophoneIgnore []string `json:"microphone_ignore"`
	// Wait this long after the last trigger disappeared before resuming automatically.
	ResumeDelaySeconds int `json:"resume_delay_seconds"`
}

type Config struct {
	Mode string `json:"mode"`
	// Process names treated as AI agents; they and all their descendants are affected.
	AgentProcesses []string `json:"agent_processes"`
	// Other processes shown in the popover while they use a lot of CPU (e.g. Microsoft Defender's
	// wdavdaemon). They are only shown, never paused. Case-insensitive substring match.
	WatchProcesses []string `json:"watch_processes"`
	// Show a watched process once it averages this much CPU (100 = one core) over ~30s.
	WatchThreshold float64 `json:"watch_threshold_percent"`
	// Tools the Claude Code hook refuses while paused (regex on tool name).
	HookBlockTools string `json:"hook_block_tools"`
	// Bash commands that stay allowed while paused (regex per command segment).
	HookAllowCommands string     `json:"hook_allow_commands"`
	Auto              AutoConfig `json:"auto"`
}

func defaultConfig() Config {
	return Config{
		Mode:              ModeThrottle,
		AgentProcesses:    []string{"claude", "codex", "gemini", "aider", "opencode", "cursor-agent", "amp", "goose", "copilot"},
		WatchProcesses:    []string{"wdavdaemon"},
		WatchThreshold:    30,
		HookBlockTools:    `^(Bash|mcp__.*(browser|playwright|puppeteer|computer|chrome).*)$`,
		HookAllowCommands: `^\s*(ai-pause|ls|cat|head|tail|pwd|echo|grep|rg|find|wc|which|file|stat|git (status|diff|log|show|branch|blame))\b`,
		Auto: AutoConfig{
			Enabled:            true,
			Mode:               ModeFreeze,
			DisplaySleepApps:   []string{"Teams", "zoom.us", "Webex", "FaceTime", "Keynote", "PowerPoint"},
			RunningApps:        []string{},
			Games:              true,
			MicrophoneInUse:    true,
			MicrophoneIgnore:   []string{"corespeechd", "Siri", "assistantd", "SpeechRecognitionCore", "localspeechrecognition"},
			ResumeDelaySeconds: 60,
		},
	}
}

func configDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "ai-pause")
}

func configPath() string { return filepath.Join(configDir(), "config.json") }

// loadConfig reads the config, creating it with defaults on first use.
// Missing fields fall back to defaults.
func loadConfig() Config {
	cfg := defaultConfig()
	data, err := os.ReadFile(configPath())
	if errors.Is(err, os.ErrNotExist) {
		_ = saveConfig(cfg)
		return cfg
	}
	if err == nil {
		_ = json.Unmarshal(data, &cfg)
	}
	return cfg
}

func saveConfig(cfg Config) error {
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(configPath(), data)
}

func writeFileAtomic(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
