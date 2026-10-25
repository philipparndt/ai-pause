import AppKit
import SwiftUI

// Shared state for the SwiftUI views and the way back to Go: actions are sent as
// JSON messages (see handleUIMessage in ui.go). The C entry points are in Exports.swift.

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    @Published var snapshot: Snapshot?
    @Published var notice: NoticeEvent?
    private var noticeCount = 0

    func apply(_ s: Snapshot) {
        snapshot = s
        if let n = s.notice {
            noticeCount += 1
            notice = NoticeEvent(id: noticeCount, notice: n)
        }
    }
}

struct NoticeEvent: Equatable {
    let id: Int
    let notice: Notice
}

enum Bridge {
    static func send(_ json: String) {
        json.withCString { uiMessage(UnsafeMutablePointer(mutating: $0)) }
    }

    static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(String(decoding: data, as: UTF8.self))
    }

    static func click(_ id: String) { send(["action": "click", "id": id]) }

    static func saveConfig(_ config: Config) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        send(#"{"action":"saveConfig","config":\#(String(decoding: data, as: UTF8.self))}"#)
    }

    static func visibility(_ view: String, _ visible: Bool) {
        view.withCString { uiVisibility(UnsafeMutablePointer(mutating: $0), visible ? 1 : 0) }
    }
}

@MainActor
final class PopoverController: NSObject, NSPopoverDelegate {
    let popover = NSPopover()

    override init() {
        super.init()
        let hosting = NSHostingController(rootView: PopoverView(store: Store.shared))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        _ = hosting.view // build the view now so the first click opens instantly
    }

    func toggle(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidShow(_ notification: Notification) { Bridge.visibility("popover", true) }
    func popoverDidClose(_ notification: Notification) { Bridge.visibility("popover", false) }
}

@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "AI Pause Settings"
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(srgbRed: 0.078, green: 0.078, blue: 0.086, alpha: 1)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.minSize = NSSize(width: 520, height: 400)
            w.contentView = NSHostingView(rootView: SettingsView(store: Store.shared))
            w.setFrameAutosaveName("settings")
            if !w.setFrameUsingName("settings") { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Bridge.visibility("settings", true)
    }

    func windowWillClose(_ notification: Notification) { Bridge.visibility("settings", false) }
}

@MainActor
enum UI {
    static var popover: PopoverController?
    static let settings = SettingsController()
}
