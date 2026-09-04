import AppKit
import SwiftUI

/// The menu bar presence: a plain paper plane with a single coloured dot in its bottom-right
/// corner, carrying how full the machine's memory is. This is the only place Fleet is visible
/// when the panel is down, so it doubles as the "yes, it is running" indicator.
///
/// The dot used to name whichever session most wanted your attention. Memory won the spot for
/// a simple reason: a session that needs you already has a notification and a panel that comes
/// up by itself, while a machine filling up has nothing at all — and it is the thing you want
/// to have noticed *before* it matters.
@MainActor
final class StatusItemController {

    private let item: NSStatusItem
    private unowned let controller: AppController
    private let dot = NSView()

    private static let dotSize: CGFloat = 4

    /// What colour the dot currently is. The refresh tick fires every few seconds and the
    /// colour almost never changes, so this avoids redrawing the menu bar for nothing.
    private var shown: NSColor?
    /// Same idea for the muted look, which swaps the whole glyph.
    private var shownMuted: Bool?

    init(controller: AppController) {
        self.controller = controller
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = item.button {
            button.image = Self.planeImage(filled: true)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Fleet — click for the panel, right-click for settings"
            install(dot: dot, on: button)
        }
        update(ram: MemoryPressure.footprint())
    }

    /// The dot is a sibling view rather than part of the image on purpose: the plane is a
    /// template, so the menu bar repaints it black or white to match the bar, and anything drawn
    /// into that image would be repainted along with it. A separate layer keeps its own colour
    /// while the plane keeps adapting.
    private func install(dot: NSView, on button: NSStatusBarButton) {
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSize / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dot)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
            // Placed off the button's centre rather than its leading edge: the button carries
            // several points of padding around the glyph, and anchoring to its edge left the dot
            // floating in the gap looking like a separate menu bar item. The offsets put it in
            // the bottom-left, sitting on the line of the plane's fold rather than square in the
            // corner — so it reads as trailing the plane instead of stuck beside it.
            dot.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: -5.5),
            dot.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: 6.5),
        ])
    }

    deinit {
        // `deinit` is nonisolated; the status bar API is main-actor. Hop rather than capture
        // self, which is already gone by the time the block runs.
        let item = self.item
        MainActor.assumeIsolated { NSStatusBar.system.removeStatusItem(item) }
    }

    // MARK: - Appearance

    func update(ram: MemoryPressure.Footprint, muted: Bool = false) {
        // A hollow plane while muted: the chord is pressed with nothing on screen, so the menu
        // bar is the only place that can acknowledge it.
        if shownMuted != muted {
            shownMuted = muted
            item.button?.image = Self.planeImage(filled: !muted)
        }
        let colour = NSColor(MemoryStrip.loadTint(ram))
        guard shown != colour else { return }
        shown = colour
        dot.layer?.backgroundColor = colour.cgColor
    }

    /// `paperplane.fill` rather than anything boat-shaped: at 15pt a hull and mast collapse into
    /// a smudge, while the plane stays a clean silhouette. Template mode hands the menu bar
    /// control of its colour, so it inverts correctly in light and dark.
    private static func planeImage(filled: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: filled ? "paperplane.fill" : "paperplane",
                            accessibilityDescription: "Fleet")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    // MARK: - Interaction

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            controller.showControlCenter()
        } else {
            controller.toggleOnDemand()
        }
    }
}
