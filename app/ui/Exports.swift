import AppKit

// C entry points called from Go (ui.go) and the status item (menubar_darwin.m).
// Kept apart so the screenshot tool can build the views without them.

private func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

@_cdecl("aipause_ui_init")
public func aipauseUIInit() {
    MainActor.assumeIsolated { UI.popover = PopoverController() }
}

@_cdecl("aipause_ui_push")
public func aipauseUIPush(_ json: UnsafePointer<CChar>, _ length: Int32) {
    let data = Data(bytes: json, count: Int(length))
    guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
    onMain { Store.shared.apply(snapshot) }
}

@_cdecl("aipause_ui_toggle_popover")
public func aipauseUITogglePopover(_ button: UnsafeMutableRawPointer) {
    let button = Unmanaged<NSStatusBarButton>.fromOpaque(button).takeUnretainedValue()
    MainActor.assumeIsolated { UI.popover?.toggle(button) }
}

@_cdecl("aipause_ui_close_popover")
public func aipauseUIClosePopover() {
    onMain { UI.popover?.popover.performClose(nil) }
}

@_cdecl("aipause_ui_show_settings")
public func aipauseUIShowSettings() {
    onMain {
        UI.popover?.popover.performClose(nil)
        UI.settings.show()
    }
}
