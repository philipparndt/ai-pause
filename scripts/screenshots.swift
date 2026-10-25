// Renders the popover and settings window offscreen with docs/demo.json (made-up data).
// Run through `make screenshots`.
import AppKit
import SwiftUI

// Stand-ins for the Go exports the views would call.
func uiMessage(_ msg: UnsafeMutablePointer<CChar>!) {}
func uiVisibility(_ view: UnsafeMutablePointer<CChar>!, _ visible: Int32) {}

@main
struct Screenshots {
    @MainActor static func main() {
        let args = CommandLine.arguments
        let data = try! Data(contentsOf: URL(fileURLWithPath: args[1]))
        Store.shared.snapshot = try! JSONDecoder().decode(Snapshot.self, from: data)
        render(PopoverView(store: Store.shared), width: 380, to: "\(args[2])/popover.png")
        render(SettingsView(store: Store.shared), width: 640, height: 900, to: "\(args[2])/settings.png")
    }

    @MainActor static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, to path: String) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = CGSize(width: width, height: height ?? host.fittingSize.height)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if height == nil { host.frame.size.height = host.fittingSize.height; host.layoutSubtreeIfNeeded() }
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}
