import AppKit
import SwiftUI

/// Borderless full-screen window hosting the session grid.
@MainActor
final class OverlayWindowController {

    private var window: PanelWindow?
    private unowned let controller: AppController

    init(controller: AppController) {
        self.controller = controller
    }

    func show() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let window = self.window ?? makeWindow()
        self.window = window

        window.setFrame(screen.frame, display: true)
        // Accessory apps need an explicit activation to take key focus and receive clicks.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
        NSApp.hide(nil)
    }

    private func makeWindow() -> PanelWindow {
        let window = PanelWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.onCancel = { [weak self] in self?.controller.hidePanel() }

        let root = OverlayView(controller: controller)
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        return window
    }
}

/// Borderless windows refuse key focus by default, and Esc has to reach us.
final class PanelWindow: NSWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {          // Esc
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}
