import SwiftUI

// What each mode does: [polite, throttle, freeze] as (kind, label).
private enum Cell { case yes, no, part }

private let matrix: [(String, [(Cell, String)])] = [
    ("Claude agents told to hold off (hook)", [(.yes, "✓"), (.yes, "✓"), (.yes, "✓")]),
    ("Agent sessions stay responsive", [(.yes, "✓"), (.yes, "✓"), (.yes, "✓")]),
    ("Works for non-Claude agents", [(.no, "–"), (.yes, "✓"), (.yes, "✓")]),
    ("Lower CPU and I/O priority", [(.no, "–"), (.yes, "✓"), (.yes, "✓")]),
    ("Running tests and builds", [(.no, "keep going"), (.part, "slowed"), (.yes, "stopped")]),
    ("Tool processes suspended", [(.no, "–"), (.no, "–"), (.yes, "✓")]),
    ("Side effects", [(.yes, "none"), (.yes, "none"), (.part, "timeouts possible")]),
]

/// Same substring rule the app uses for matching.
private func covered(_ list: [String], _ name: String) -> Bool {
    list.contains { name.localizedCaseInsensitiveContains($0) }
}

struct SettingsView: View {
    @ObservedObject var store: Store
    @State private var draft: Config?
    @State private var dirty = false
    @State private var toast: NoticeEvent?

    init(store: Store) { self.store = store }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                if draft != nil {
                    form.frame(maxWidth: 760).frame(maxWidth: .infinity).padding(14).padding(.bottom, 50)
                }
            }
            if let toast {
                Text(toast.notice.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(toast.notice.ok ? Theme.text : Theme.red)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(toast.notice.ok ? Theme.line2 : Theme.red))
                    .padding(.bottom, dirty ? 58 : 14)
                    .transition(.opacity)
            }
            if dirty { saveBar.transition(.move(edge: .bottom)) }
        }
        .animation(.easeOut(duration: 0.2), value: dirty)
        .animation(.easeOut(duration: 0.2), value: toast)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .font(.system(size: 12))
        .onReceive(store.$snapshot) { s in
            if let s, !dirty { draft = s.config }
        }
        .onChange(of: store.notice) { _, event in
            guard let event else { return }
            if event.notice.ok && event.notice.message.hasPrefix("Settings") { dirty = false }
            toast = event
            DispatchQueue.main.asyncAfter(deadline: .now() + (event.notice.ok ? 2.5 : 6)) {
                if toast == event { toast = nil }
            }
        }
    }

    /// A binding into the draft that marks the form as changed.
    private func bind<V>(_ path: WritableKeyPath<Config, V>) -> Binding<V> {
        Binding(get: { draft![keyPath: path] }, set: { draft![keyPath: path] = $0; dirty = true })
    }

    private var form: some View {
        VStack(spacing: 10) {
            pausing
            autoPause
            detected
            section("AGENTS") {
                row("Agent process names", hint: "Everything they start belongs to their session.", top: true, first: true) {
                    TagEditor(values: bind(\.agentProcesses))
                }
                row("Other processes to watch", hint: "Shown in the popover while busy, e.g. Microsoft Defender (wdavdaemon). Never paused. Substring.", top: true) {
                    TagEditor(values: bind(\.watchProcesses))
                }
                row("Show them above", hint: "Average CPU over 30 s; 100 % = one core.") {
                    HStack(spacing: 6) {
                        TextField("", value: bind(\.watchThreshold), format: .number).fieldStyle().frame(width: 90)
                        Text("% CPU").foregroundStyle(Theme.muted)
                    }
                }
            }
            hook
        }
    }

    private var pausing: some View {
        section("PAUSING") {
            row("Default mode", hint: "Used when you pause manually.", first: true) { modePicker(bind(\.mode)) }
            modeMatrix
        }
    }

    private var autoPause: some View {
        section("AUTO-PAUSE") {
            row("Enabled", hint: "Pause during calls, presentations and games.", first: true) {
                MiniToggle(on: draft!.auto.enabled, label: "Auto-pause enabled") { bind(\.auto.enabled).wrappedValue.toggle() }
            }
            row("Mode while auto-paused") { modePicker(bind(\.auto.mode)) }
            row("Apps keeping the display awake", hint: "Teams/Zoom during calls, Keynote while presenting. Substring.", top: true) {
                TagEditor(values: bind(\.auto.displaySleepApps))
            }
            row("Running apps", hint: "e.g. games. Exact process name.", top: true) { TagEditor(values: bind(\.auto.runningApps)) }
            row("Microphone in use", hint: "Any app recording audio counts as a call.") {
                MiniToggle(on: draft!.auto.microphoneInUse, label: "Microphone trigger") { bind(\.auto.microphoneInUse).wrappedValue.toggle() }
            }
            row("Ignore microphone use by", hint: "Dictation, Siri, … Substring.", top: true) {
                TagEditor(values: bind(\.auto.microphoneIgnore))
            }
            row("Resume after", hint: "Seconds without any trigger.") {
                TextField("", value: bind(\.auto.resumeDelaySeconds), format: .number).fieldStyle().frame(width: 90)
            }
        }
    }

    private var detected: some View {
        let observed = store.snapshot?.observed
        let d = draft!
        return section("DETECTED RIGHT NOW") {
            HStack(alignment: .top, spacing: 10) {
                detectedList("Keeping the display awake", observed?.displaySleep ?? []) { name in
                    if covered(d.auto.displaySleepApps, name) {
                        chip("WATCHED", Theme.green)
                    } else {
                        Pill(title: "Add", small: true, fill: false) { add(name, to: \.auto.displaySleepApps) }
                    }
                }
                detectedList("Using the microphone", observed?.microphone ?? []) { name in
                    if covered(d.auto.microphoneIgnore, name) {
                        chip("IGNORED", Theme.muted)
                    } else {
                        Pill(title: "Ignore", small: true, fill: false) { add(name, to: \.auto.microphoneIgnore) }
                    }
                }
            }
        }
    }

    private var hook: some View {
        section("CLAUDE CODE HOOK") {
            row("Status", hint: "Refuses heavy tools while paused and tells the agent why.", first: true) {
                if store.snapshot?.hookInstalled == true {
                    HStack(spacing: 6) {
                        chip("INSTALLED", Theme.green)
                        Text("in ~/.claude/settings.json").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            chip("NOT INSTALLED", Theme.orange)
                            Pill(title: "Install", kind: .primary, small: true, fill: false) { Bridge.send(["action": "installHook"]) }
                        }
                        Text("Adds a PreToolUse hook to ~/.claude/settings.json (backup first).")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }
                }
            }
            row("Blocked tools", hint: "Regex on the tool name.") {
                TextField("", text: bind(\.hookBlockTools)).font(.mono(11)).fieldStyle()
            }
            row("Still allowed commands", hint: "Regex per shell command segment.") {
                TextField("", text: bind(\.hookAllowCommands)).font(.mono(11)).fieldStyle()
            }
        }
    }

    private var saveBar: some View {
        HStack(spacing: 8) {
            Text("Unsaved changes").foregroundStyle(Theme.muted)
            Spacer()
            Pill(title: "Revert", fill: false) {
                draft = store.snapshot?.config
                dirty = false
            }
            Pill(title: "Save", kind: .primary, fill: false) { if let draft { Bridge.saveConfig(draft) } }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .topRule(color: Theme.line)
    }

    // MARK: building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Cap(title).padding(.bottom, 4)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
    }

    private func row<Content: View>(_ label: String, hint: String? = nil, top: Bool = false, first: Bool = false,
                                    @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: top ? .top : .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12, weight: .medium))
                if let hint { Text(hint).font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(width: 180, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .topRule(!first, color: Color.white.opacity(0.05))
    }

    private func modePicker(_ value: Binding<String>) -> some View {
        HStack(spacing: 4) {
            ForEach(modes, id: \.key) { m in
                Pill(title: m.title, kind: value.wrappedValue == m.key ? .on : .normal) { value.wrappedValue = m.key }
            }
        }
    }

    private var modeMatrix: some View {
        let d = draft!
        let selected = { (k: String) in k == d.mode || k == d.auto.mode }
        return Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow(alignment: .bottom) {
                Color.clear.frame(height: 1).gridCellUnsizedAxes([.horizontal, .vertical])
                ForEach(modes, id: \.key) { m in
                    VStack(spacing: 0) {
                        HStack(spacing: 4) {
                            if m.key == d.mode { badge("DEFAULT") }
                            if m.key == d.auto.mode { badge("AUTO") }
                        }
                        .frame(height: 14)
                        Text(m.title).font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.vertical, 5)
                    .frame(width: 120)
                    .background(selected(m.key) ? Theme.blue.opacity(0.07) : .clear)
                }
            }
            ForEach(matrix, id: \.0) { label, cells in
                GridRow {
                    Text(label).foregroundStyle(Theme.muted2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
                        Text(cell.1)
                            .foregroundStyle(cell.0 == .yes ? Theme.green : cell.0 == .part ? Theme.orange : Color(hex: 0x5a5a5f))
                            .padding(.vertical, 5)
                            .frame(width: 120)
                            .frame(maxHeight: .infinity)
                            .background(selected(modes[i].key) ? Theme.blue.opacity(0.07) : .clear)
                    }
                }
                .topRule(color: Color.white.opacity(0.05))
            }
        }
        .padding(.top, 4)
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(Theme.onText)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(0.4).foregroundStyle(color)
    }

    private func detectedList<Right: View>(_ title: String, _ names: [String], @ViewBuilder right: @escaping (String) -> Right) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.muted)
            VStack(spacing: 0) {
                if names.isEmpty {
                    Text("nothing").font(.mono(11)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
                ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                    HStack(spacing: 6) {
                        Text(name).font(.mono(11)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        right(name)
                    }
                    .padding(.vertical, 4)
                    .topRule(i > 0, color: Color.white.opacity(0.05))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func add(_ value: String, to path: WritableKeyPath<Config, [String]>) {
        let b = bind(path)
        if !b.wrappedValue.contains(value) { b.wrappedValue.append(value) }
    }
}

private extension View {
    func fieldStyle() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2))
    }
}

struct TagEditor: View {
    @Binding var values: [String]
    @State private var input = ""

    init(values: Binding<[String]>) { _values = values }

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                HStack(spacing: 2) {
                    Text(v).font(.mono(11))
                    Button { values.remove(at: i) } label: {
                        Text("×").font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.horizontal, 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(v)")
                }
                .padding(.leading, 6).padding(.trailing, 2).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0x33333a)))
            }
            TextField("add…", text: $input)
                .textFieldStyle(.plain)
                .font(.mono(11))
                .frame(minWidth: 90)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .onSubmit(commit)
                .onChange(of: input) { _, v in if v.contains(",") { commit() } }
                .onKeyPress(.delete) {
                    guard input.isEmpty, !values.isEmpty else { return .ignored }
                    values.removeLast()
                    return .handled
                }
                .accessibilityLabel("Add")
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line2))
    }

    private func commit() {
        let v = input.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        input = ""
        if !v.isEmpty && !values.contains(v) { values.append(v) }
    }
}
