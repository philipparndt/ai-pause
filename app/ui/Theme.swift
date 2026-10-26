import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

enum Theme {
    static let bg = Color(hex: 0x141416)
    static let tile = Color(hex: 0x1e1e21)
    static let field = Color(hex: 0x26262a)
    static let fieldHover = Color(hex: 0x2e2e33)
    static let line = Color.white.opacity(0.07)
    static let line2 = Color.white.opacity(0.14)
    static let rule = Color.white.opacity(0.06)
    static let text = Color(hex: 0xe8e8ea)
    static let muted = Color(hex: 0x8e8e93)
    static let muted2 = Color(hex: 0xb0b0b5)
    static let blue = Color(hex: 0x4cc2ff)
    static let orange = Color(hex: 0xffb340)
    static let green = Color(hex: 0x7ee29a)
    static let frozen = Color(hex: 0x8ad6ff)
    static let dim = Color(hex: 0x7a6a55)
    static let red = Color(hex: 0xff6961)
    static let onFill = Color(hex: 0x173a52)
    static let onBorder = Color(hex: 0x2f6f99)
    static let onText = Color(hex: 0x8ad6ff)
    static let goFill = Color(hex: 0x1f4d2b)
    static let goBorder = Color(hex: 0x2f7a43)
    static let band = Color(hex: 0xffb340, alpha: 0.12)
}

extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct Cap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
    }
}

struct TileBackground: ViewModifier {
    var padding: EdgeInsets = EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.tile))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
    }
}

extension View {
    func tile(_ padding: EdgeInsets = EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)) -> some View {
        modifier(TileBackground(padding: padding))
    }

    /// Thin separator along the top edge, like the HTML row borders.
    func topRule(_ show: Bool = true, color: Color = Theme.rule) -> some View {
        overlay(alignment: .top) { if show { Rectangle().fill(color).frame(height: 1) } }
    }
}

enum PillKind { case normal, on, go, primary }

struct Pill: View {
    let title: String
    var kind: PillKind = .normal
    var small = false
    var fill = true
    let action: () -> Void
    @State private var hover = false

    init(title: String, kind: PillKind = .normal, small: Bool = false, fill: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.small = small
        self.fill = fill
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: kind == .go ? 12 : small ? 10 : 11, weight: kind == .normal ? .regular : .semibold))
                .lineLimit(1)
                .frame(maxWidth: fill ? .infinity : nil)
                .padding(.vertical, kind == .go ? 5 : small ? 3 : 4)
                .padding(.horizontal, small ? 8 : 6)
                .foregroundStyle(foreground)
                .background(RoundedRectangle(cornerRadius: kind == .go ? 7 : 6).fill(background))
                .overlay(RoundedRectangle(cornerRadius: kind == .go ? 7 : 6).strokeBorder(border))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .normal: Theme.text
        case .on, .primary: Theme.onText
        case .go: Theme.green
        }
    }

    private var background: Color {
        switch kind {
        case .normal: hover ? Theme.fieldHover : Theme.field
        case .on, .primary: Theme.onFill
        case .go: hover ? Color(hex: 0x255c33) : Theme.goFill
        }
    }

    private var border: Color {
        switch kind {
        case .normal: Theme.line2
        case .on, .primary: Theme.onBorder
        case .go: Theme.goBorder
        }
    }
}

struct MiniToggle: View {
    let on: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Color(hex: 0x30d158) : Color(hex: 0x48484a))
                Circle().fill(.white).frame(width: 12, height: 12).padding(2)
            }
            .frame(width: 28, height: 16)
            .animation(.easeOut(duration: 0.15), value: on)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// The time span every chart shows, switched by clicking a chart.
enum ChartRange: Int, CaseIterable {
    case two = 2, five = 5, fifteen = 15

    static let key = "chartRange"
    static let sampleSeconds = 3

    var label: String { "\(rawValue) MIN" }
    var next: ChartRange { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
    /// Samples taken during the range.
    var sampleCount: Int { rawValue * 60 / Self.sampleSeconds }

    /// Merges samples into at most `count` bars, each holding the highest value of its
    /// slice of time. Slices follow the clock, so bars don't shift as samples arrive.
    func bars(_ samples: [Sample], count: Int) -> [Sample] {
        guard sampleCount > count else { return Array(samples.suffix(count)) }
        let slice = Int64(rawValue) * 60_000 / Int64(count)
        var out: [Sample] = []
        var last: Int64?
        for s in samples {
            let id = s.t / slice
            if id == last, let prev = out.last {
                out[out.count - 1] = Sample(t: s.t, p: max(prev.p, s.p), z: prev.z || s.z, w: (prev.w ?? 0) + (s.w ?? 0))
            } else {
                out.append(s)
                last = id
            }
        }
        return Array(out.suffix(count))
    }
}

/// Bar chart of the last `capacity` bars of the chosen range. Samples taken while
/// paused are dimmed and the paused span is shaded.
struct BarChart: View {
    let samples: [Sample]
    var warn = false
    var color: Color = Theme.blue
    var capacity = 40
    /// Called with the bar under the pointer, nil when it leaves.
    var onHover: (Sample?) -> Void = { _ in }
    @State private var hovered: Int?
    @AppStorage(ChartRange.key) private var range = ChartRange.two

    var body: some View {
        let pts = range.bars(samples, count: capacity)
        GeometryReader { geo in
            chart(pts, hovered: hovered)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    var i: Int?
                    if case .active(let p) = phase { i = index(at: p.x, width: geo.size.width, count: pts.count) }
                    guard i != hovered else { return }
                    hovered = i
                    onHover(i.map { pts[$0] })
                }
                .onTapGesture { range = range.next }
        }
        .help("Click to show 2, 5 or 15 minutes")
        .accessibilityHidden(true)
    }

    /// Index into the bars under x, or nil over the empty left part.
    private func index(at x: CGFloat, width: CGFloat, count n: Int) -> Int? {
        let i = Int(x / (width / CGFloat(capacity))) - (capacity - n)
        return n > 0 && i >= 0 ? min(i, n - 1) : nil
    }

    private func chart(_ pts: [Sample], hovered: Int?) -> some View {
        Canvas { ctx, size in
            guard !pts.isEmpty else { return }
            // 1 CPU at the top; a chart that ever needs more switches to 10 CPUs and turns red.
            let high = (pts.map(\.p).max() ?? 0) > 100
            let top: Double = high ? 1000 : 100
            let step = size.width / CGFloat(capacity)
            let off = CGFloat(capacity - pts.count) * step
            var i = 0
            while i < pts.count {
                if pts[i].z {
                    var j = i
                    while j + 1 < pts.count && pts[j + 1].z { j += 1 }
                    ctx.fill(Path(CGRect(x: off + CGFloat(i) * step, y: 0, width: CGFloat(j - i + 1) * step, height: size.height)), with: .color(Theme.band))
                    i = j + 1
                } else {
                    i += 1
                }
            }
            if let h = hovered {
                ctx.fill(Path(CGRect(x: off + CGFloat(h) * step, y: 0, width: max(1, step - 1), height: size.height)), with: .color(Theme.line2))
            }
            for (i, s) in pts.enumerated() {
                let h = max(1, min(s.p, top) / top * (size.height - 2))
                let color = i == hovered ? Theme.text : warn ? Theme.orange : s.z ? Theme.dim : high ? Theme.red : self.color
                ctx.fill(Path(CGRect(x: off + CGFloat(i) * step, y: size.height - h, width: max(1, step - 1), height: h)), with: .color(color))
            }
            // A dot on top of the chart where an agent opened windows.
            let d = min(4, max(3, step))
            for (i, s) in pts.enumerated() where (s.w ?? 0) > 0 {
                let x = off + CGFloat(i) * step + (step - 1) / 2
                ctx.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: 0, width: d, height: d)), with: .color(Theme.text))
            }
        }
    }
}

extension View {
    /// Marks a value read from the chart history, so it doesn't pass for the live one.
    func historic(_ on: Bool) -> some View {
        background {
            if on {
                RoundedRectangle(cornerRadius: 3).fill(Theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line2))
                    .padding(.horizontal, -4).padding(.vertical, -1)
            }
        }
    }
}

/// Wraps its children onto new lines; the last child stretches over the rest of its line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? 400, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(bounds.width, subviews)
        for (i, v) in subviews.enumerated() {
            v.place(at: CGPoint(x: bounds.minX + r.frames[i].minX, y: bounds.minY + r.frames[i].minY), proposal: ProposedViewSize(r.frames[i].size))
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            var s = v.sizeThatFits(.unspecified)
            s.width = min(s.width, width)
            if x > 0 && x + s.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            if i == subviews.count - 1 { s.width = max(s.width, width - x) }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return (CGSize(width: width, height: y + rowHeight), frames)
    }
}
