import Foundation

// Mirrors the snapshot Go sends (ui.go). Go encodes nil slices as null, so lists default to [].

extension KeyedDecodingContainer {
    func list<T: Decodable>(_ key: Key) throws -> [T] {
        try decodeIfPresent([T].self, forKey: key) ?? []
    }
}

struct Sample: Decodable {
    let t: Int64
    let p: Double
    let z: Bool
}

struct ProcUsage: Decodable {
    let pid: Int
    let name: String
    let pct: Double
}

struct Verdict: Decodable {
    let text: String
    let warn: Bool
    let ok: Bool
}

struct Session: Decodable, Identifiable {
    let pid: Int
    let name: String
    let status: String
    let cwd: String
    let cwdShort: String
    let current: Double
    let avg: Double
    let paused: Bool
    let verdict: Verdict
    let history: [Sample]
    let top: [ProcUsage]
    var id: Int { pid }

    enum CodingKeys: String, CodingKey { case pid, name, status, cwd, cwdShort, current, avg, paused, verdict, history, top }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int.self, forKey: .pid)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(String.self, forKey: .status)
        cwd = try c.decode(String.self, forKey: .cwd)
        cwdShort = try c.decode(String.self, forKey: .cwdShort)
        current = try c.decode(Double.self, forKey: .current)
        avg = try c.decode(Double.self, forKey: .avg)
        paused = try c.decode(Bool.self, forKey: .paused)
        verdict = try c.decode(Verdict.self, forKey: .verdict)
        history = try c.list(.history)
        top = try c.list(.top)
    }
}

struct Hog: Decodable, Identifiable {
    let name: String
    let current: Double
    let avg: Double
    let history: [Sample]
    let top: [ProcUsage]
    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, current, avg, history, top }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        current = try c.decode(Double.self, forKey: .current)
        avg = try c.decode(Double.self, forKey: .avg)
        history = try c.list(.history)
        top = try c.list(.top)
    }
}

struct AutoConfig: Codable, Equatable {
    var enabled: Bool
    var mode: String
    var displaySleepApps: [String]
    var runningApps: [String]
    var games: Bool
    var microphoneInUse: Bool
    var microphoneIgnore: [String]
    var resumeDelaySeconds: Int

    enum CodingKeys: String, CodingKey {
        case enabled, mode
        case displaySleepApps = "display_sleep_apps"
        case runningApps = "running_apps"
        case games
        case microphoneInUse = "microphone_in_use"
        case microphoneIgnore = "microphone_ignore"
        case resumeDelaySeconds = "resume_delay_seconds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        mode = try c.decode(String.self, forKey: .mode)
        displaySleepApps = try c.list(.displaySleepApps)
        runningApps = try c.list(.runningApps)
        games = try c.decodeIfPresent(Bool.self, forKey: .games) ?? true
        microphoneInUse = try c.decode(Bool.self, forKey: .microphoneInUse)
        microphoneIgnore = try c.list(.microphoneIgnore)
        resumeDelaySeconds = try c.decode(Int.self, forKey: .resumeDelaySeconds)
    }
}

struct Config: Codable, Equatable {
    var mode: String
    var agentProcesses: [String]
    var watchProcesses: [String]
    var watchThreshold: Double
    var hookBlockTools: String
    var hookAllowCommands: String
    var auto: AutoConfig

    enum CodingKeys: String, CodingKey {
        case mode, auto
        case agentProcesses = "agent_processes"
        case watchProcesses = "watch_processes"
        case watchThreshold = "watch_threshold_percent"
        case hookBlockTools = "hook_block_tools"
        case hookAllowCommands = "hook_allow_commands"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(String.self, forKey: .mode)
        agentProcesses = try c.list(.agentProcesses)
        watchProcesses = try c.list(.watchProcesses)
        watchThreshold = try c.decodeIfPresent(Double.self, forKey: .watchThreshold) ?? 30
        hookBlockTools = try c.decode(String.self, forKey: .hookBlockTools)
        hookAllowCommands = try c.decode(String.self, forKey: .hookAllowCommands)
        auto = try c.decode(AutoConfig.self, forKey: .auto)
    }
}

struct Observation: Decodable {
    let displaySleep: [String]
    let microphone: [String]

    enum CodingKeys: String, CodingKey { case displaySleep, microphone }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displaySleep = try c.list(.displaySleep)
        microphone = try c.list(.microphone)
    }
}

struct Notice: Decodable, Equatable {
    let ok: Bool
    let message: String
}

struct Snapshot: Decodable {
    let active: Bool
    let mode: String
    let reason: String
    let since: Int64
    let until: Int64
    let frozenCount: Int
    let throttledCount: Int
    let config: Config
    let reasons: [String]
    let suppressAuto: Bool
    let observed: Observation
    let sessions: [Session]
    let hogs: [Hog]
    let total: [Sample]
    let hookInstalled: Bool
    let notice: Notice?

    enum CodingKeys: String, CodingKey {
        case active, mode, reason, since, until, frozenCount, throttledCount, config, reasons, suppressAuto, observed, sessions, hogs, total, hookInstalled, notice
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = try c.decode(Bool.self, forKey: .active)
        mode = try c.decode(String.self, forKey: .mode)
        reason = try c.decode(String.self, forKey: .reason)
        since = try c.decode(Int64.self, forKey: .since)
        until = try c.decode(Int64.self, forKey: .until)
        frozenCount = try c.decode(Int.self, forKey: .frozenCount)
        throttledCount = try c.decode(Int.self, forKey: .throttledCount)
        config = try c.decode(Config.self, forKey: .config)
        reasons = try c.list(.reasons)
        suppressAuto = try c.decode(Bool.self, forKey: .suppressAuto)
        observed = try c.decode(Observation.self, forKey: .observed)
        sessions = try c.list(.sessions)
        hogs = try c.list(.hogs)
        total = try c.list(.total)
        hookInstalled = try c.decode(Bool.self, forKey: .hookInstalled)
        notice = try c.decodeIfPresent(Notice.self, forKey: .notice)
    }
}

let modes: [(key: String, title: String)] = [("polite", "Polite"), ("throttle", "Throttle"), ("freeze", "Freeze")]

func modeTitle(_ key: String) -> String { modes.first { $0.key == key }?.title ?? key }

func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

func clock(_ ms: Int64) -> String {
    Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .omitted, time: .shortened)
}
