import AppKit
import SwiftUI

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PopoverView: View {
    @ObservedObject var store: Store
    @State private var expanded: Int?
    @State private var contentHeight: CGFloat = 420
    @State private var hoveredTotal: Sample?
    @AppStorage(ChartRange.key) private var range = ChartRange.two
    @State private var hoveredHog: [String: Sample] = [:]

    init(store: Store) { self.store = store }

    // The popover grows with its content up to the screen height; beyond that it scrolls.
    private var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 40 }

    var body: some View {
        ScrollView {
            content
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        }
        .scrollIndicators(.never)
        .scrollDisabled(contentHeight <= maxHeight)
        .frame(width: 380, height: min(contentHeight, maxHeight))
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .font(.system(size: 12))
    }

    @ViewBuilder private var content: some View {
        if let s = store.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                header(s)
                tiles(s)
                sessions(s)
                if !s.hogs.isEmpty { hogs(s.hogs) }
                footer
            }
            .padding(12)
        } else {
            Text("Loading…").foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(40)
        }
    }

    private func header(_ s: Snapshot) -> some View {
        HStack(spacing: 8) {
            Text("AI PAUSE").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.muted)
            Text(s.active ? "PAUSED · \(modeTitle(s.mode).uppercased())" : "RUNNING")
                .font(.system(size: 10, weight: .bold)).tracking(0.6)
                .foregroundStyle(s.active ? Theme.bg : Color(hex: 0xd9f7e1))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(s.active ? Theme.orange : Theme.goBorder))
            Spacer()
            if s.active {
                Text(s.until != 0 ? "until \(clock(s.until))" : "since \(clock(s.since))")
                    .font(.mono(11)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func tiles(_ s: Snapshot) -> some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                stateTile(s).cell()
                totalTile(s).cell()
            }
            GridRow {
                modeTile(s).cell()
                autoTile(s).cell()
            }
        }
    }

    private func stateTile(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: s.active ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(s.active ? Theme.bg : Theme.green)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(s.active ? Theme.orange : Theme.goFill))
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.active ? "Paused" : "Running").font(.system(size: 13, weight: .semibold))
                    Text(stateSubtitle(s)).font(.system(size: 11)).foregroundStyle(Theme.muted2).lineLimit(1)
                }
            }
            if s.active {
                Pill(title: "Resume", kind: .go) { Bridge.click("resume") }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Cap("PAUSE FOR")
                    HStack(spacing: 4) {
                        Pill(title: "15m") { Bridge.click("pause:15m") }
                        Pill(title: "1h") { Bridge.click("pause:1h") }
                        Pill(title: "2h") { Bridge.click("pause:2h") }
                        Pill(title: "∞") { Bridge.click("pause:0") }.accessibilityLabel("Until resumed")
                    }
                }
            }
        }
    }

    private func stateSubtitle(_ s: Snapshot) -> String {
        guard s.active else { return "\(s.sessions.count) sessions" }
        let counts = s.frozenCount > 0 ? "\(s.frozenCount) frozen" : s.throttledCount > 0 ? "\(s.throttledCount) throttled" : ""
        return [s.reason.isEmpty ? "manual" : s.reason, counts].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func totalTile(_ s: Snapshot) -> some View {
        let total = s.total.suffix(range.sampleCount)
        let values = total.map(\.p)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Cap("ALL AGENTS")
                Spacer()
                Text(hoveredTotal.map { pct($0.p) } ?? values.last.map(pct) ?? "–").font(.mono(15, .semibold))
                    .historic(hoveredTotal != nil)
            }
            BarChart(samples: s.total) { hoveredTotal = $0 }.frame(height: 34)
            (Text("avg ") + Text(values.isEmpty ? "–" : pct(values.reduce(0, +) / Double(values.count))).bold().foregroundColor(Theme.text)
                + Text(" · peak ") + Text(values.max().map(pct) ?? "–").bold().foregroundColor(Theme.text))
                .font(.mono(10)).foregroundStyle(Theme.muted)
        }
    }

    private func modeTile(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Cap("MODE")
            VStack(spacing: 4) {
                ForEach(modes, id: \.key) { m in
                    Pill(title: m.title, kind: s.config.mode == m.key ? .on : .normal) { Bridge.click("mode:\(m.key)") }
                }
            }
        }
    }

    private func autoTile(_ s: Snapshot) -> some View {
        let auto = s.config.auto
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Cap("AUTO-PAUSE")
                Spacer()
                MiniToggle(on: auto.enabled, label: "Auto-pause") { Bridge.click("auto") }
            }
            if !auto.enabled {
                Text("Off").foregroundStyle(Theme.muted).font(.system(size: 12, weight: .medium))
                Text("Pause manually from here").font(.system(size: 11)).foregroundStyle(Theme.muted)
            } else if let first = s.reasons.first {
                Label(first, systemImage: "video").lineLimit(1)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.orange)
                Text(s.suppressAuto ? "Snoozed until it ends" : s.reasons.count > 1 ? "+\(s.reasons.count - 1) more" : "Pausing while active")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
            } else {
                Label("Watching", systemImage: "video")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted2)
                Text("Calls, presentations, games").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func sessions(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Cap("SESSION").frame(maxWidth: .infinity, alignment: .leading)
                Cap("STATE").frame(width: 70, alignment: .leading)
                Cap(range.label).frame(width: 92, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { range = range.next }
                    .help("Click to show 2, 5 or 15 minutes")
                Cap("NOW").frame(width: 38, alignment: .trailing)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            if s.sessions.isEmpty {
                Text("No agent sessions running").foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 14).topRule()
            } else {
                VStack(spacing: 0) {
                    ForEach(s.sessions.sorted { $0.avg > $1.avg }) { x in
                        SessionRow(session: x, expanded: expanded == x.pid) {
                            expanded = expanded == x.pid ? nil : x.pid
                        }
                    }
                }
            }
        }
    }

    // Non-agent processes (e.g. Microsoft Defender) that are busy right now. Shown only, never paused.
    private func hogs(_ hogs: [Hog]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Cap("OTHER CPU HOGS").padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(hogs) { h in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.name == "wdavdaemon" ? "Microsoft Defender" : h.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(h.top.prefix(2).map { "\($0.name) \(pct($0.pct))" }.joined(separator: " · "))
                                .font(.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("NOT AN AGENT").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                            .frame(width: 70, alignment: .leading).lineLimit(1).minimumScaleFactor(0.8)
                        BarChart(samples: h.history, color: Theme.red) { hoveredHog[h.id] = $0 }.frame(width: 92, height: 22)
                        Text(pct(hoveredHog[h.id]?.p ?? h.current)).font(.mono(12, .semibold)).foregroundStyle(Theme.red)
                            .historic(hoveredHog[h.id] != nil)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .topRule()
                    .help("Can't be paused by AI Pause. Watched processes are set in Settings.")
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Pill(title: "Settings…") { Bridge.click("dashboard") }
            Pill(title: "Quit AI Pause") { Bridge.click("quit") }
        }
        .padding(.top, 10)
        .topRule(color: Color.white.opacity(0.08))
    }
}

private extension View {
    func cell() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).tile()
    }
}

struct SessionRow: View {
    let session: Session
    let expanded: Bool
    let toggle: () -> Void
    @State private var hover = false
    @State private var hoveredSample: Sample?

    init(session: Session, expanded: Bool, toggle: @escaping () -> Void) {
        self.session = session
        self.expanded = expanded
        self.toggle = toggle
    }

    private var state: (String, Color) {
        let s = session
        if s.verdict.warn { return ("STILL BUSY", Theme.orange) }
        if s.paused { return ("PAUSED", Theme.frozen) }
        if s.verdict.ok { return ("BACKED OFF", Theme.green) }
        return s.status == "busy" ? ("BUSY", Theme.text) : ("IDLE", Theme.muted)
    }

    var body: some View {
        let s = session
        let warn = s.verdict.warn
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(s.top.prefix(2).map { "\($0.name) \(pct($0.pct))" }.joined(separator: " · "))
                        .font(.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(state.0).font(.system(size: 10, weight: .semibold)).foregroundStyle(state.1)
                    .frame(width: 70, alignment: .leading)
                BarChart(samples: s.history, warn: warn) { hoveredSample = $0 }.frame(width: 92, height: 22)
                Text(pct(hoveredSample?.p ?? s.current)).font(.mono(12, .semibold)).foregroundStyle(warn ? Theme.orange : Theme.text)
                    .historic(hoveredSample != nil)
                    .frame(width: 38, alignment: .trailing)
            }
            if expanded { detail.padding(.top, 8).padding(.bottom, 2) }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.white.opacity(0.04) : .clear))
        .topRule()
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hover = $0 }
    }

    private var detail: some View {
        let s = session
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(s.processes) \(s.processes == 1 ? "process" : "processes") · \(s.windows) \(s.windows == 1 ? "window" : "windows")")
                .font(.mono(10)).foregroundStyle(Theme.muted)
                .help("Windows on screen; windows on other Spaces or minimized ones aren't counted.")
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(Array(s.top.prefix(6).enumerated()), id: \.offset) { _, p in
                    GridRow {
                        Text(pct(p.pct)).foregroundStyle(Theme.text).frame(width: 44, alignment: .trailing)
                        Text("\(p.name) \(p.pid)").foregroundStyle(Theme.muted2).lineLimit(1)
                    }
                }
            }
            .font(.mono(10))
            if !s.verdict.text.isEmpty {
                Text(s.verdict.text).font(.system(size: 11)).foregroundStyle(s.verdict.warn ? Theme.orange : Theme.muted2)
            }
            HStack(spacing: 4) {
                Pill(title: s.paused ? "Resume" : "Pause", kind: s.paused ? .on : .normal, small: true, fill: false) {
                    Bridge.click("pauseSession:\(s.pid)")
                }
                Pill(title: "Show in Finder", small: true, fill: false) { Bridge.click("reveal:\(s.cwd)") }
                Text(s.cwdShort).font(.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
