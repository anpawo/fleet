import AppKit
import Carbon.HIToolbox
import QuartzCore
import SwiftUI

/// One line the watcher of awaited answers (`~/.claude/skills/checker`) left for Marius: a headless follow-up that
/// finished something (`done`) or stopped on something of his (`needs`), and the session it ended in.
struct InboxItem: Decodable, Equatable {
    let id: String
    let at: Double
    let kind: String
    let subject: String
    let line: String
    let dir: String
    /// What `claude` takes to come back to it: `--resume <id>`, or the run's own options when it broke.
    let options: [String]
    /// Only for a run that broke: its task, handed to the session again.
    let prompt: String?
}

/// What the watcher found, counted in the menu bar and shown one line at a time on ⌘⌥K, Spotlight-like. Arrows
/// only move, so what was skipped stays; a line goes once it is opened (its session resumed in a terminal) or
/// cleared with ⌫.
@MainActor
final class Inbox: NSObject, ObservableObject {

    static let chord = Settings.Chord(keyCode: UInt16(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey))
    /// The bar, and the clear room around it that its shadow is drawn in.
    static let bar = NSSize(width: 1000, height: 56)
    static let margin: CGFloat = 40
    /// It fades in while rising these last points into its place.
    static let rise: CGFloat = 14
    static let entrance: TimeInterval = 0.22

    @Published private(set) var items: [InboxItem] = []
    @Published private(set) var index = 0
    var current: InboxItem? { items.indices.contains(index) ? items[index] : nil }

    /// What opening does. A stand-in in the selftest, which must not start a terminal.
    var launch: (InboxItem) -> Bool = Inbox.resume
    private let folder: URL
    private var seen: Date?
    private var status: NSStatusItem?
    private var panel: InboxPanel?

    init(folder: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/state/checker/inbox")) {
        self.folder = folder
    }

    /// The menu bar item, always there, 0 included. Not in `init`: `--render-inbox` and the selftest build an
    /// inbox too, and must put nothing in his menu bar.
    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // macOS keeps a status item's last visibility in the app's defaults, and the first version of this one
        // hid itself at 0: it would come back hidden.
        item.isVisible = true
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.toolTip = "What the watcher of awaited answers found — \(Self.chord.label)"
        status = item
        refresh(force: true)
    }

    /// Cheap enough for every tick: the folder is read again only when its date moved, which a file added or
    /// removed does (the checker renames each one into place whole).
    func refresh(force: Bool = false) {
        let date = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date
        guard force || date != seen else { return }
        seen = date
        let was = current?.id
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        items = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(InboxItem.self, from: Data(contentsOf: $0)) }
            .sorted { $0.at < $1.at }
        index = items.firstIndex { $0.id == was } ?? min(index, max(items.count - 1, 0))
        status?.button?.image = Self.badge(items.count)
    }

    /// The count in a rounded square: drawn hollow at 0, filled with the figure cut out of it once something waits.
    /// A template, so the menu bar paints it to match itself.
    static func badge(_ count: Int) -> NSImage {
        let text = "\(count)" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        let size = text.size(withAttributes: [.font: font])
        let image = NSImage(size: NSSize(width: max(17, ceil(size.width) + 9), height: 16), flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 4.5, yRadius: 4.5)
            let at = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
            NSColor.black.set()
            if count == 0 {
                box.lineWidth = 1.5
                box.stroke()
            } else {
                box.fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            }
            text.draw(at: at, withAttributes: [.font: font, .foregroundColor: NSColor.black])
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Every key the panel takes; the others go on.
    func key(_ code: UInt16) -> Bool {
        switch Int(code) {
        case kVK_Escape: hide()
        case kVK_LeftArrow, kVK_UpArrow: step(-1)
        case kVK_RightArrow, kVK_DownArrow: step(1)
        case kVK_Return, kVK_ANSI_KeypadEnter: openCurrent()
        case kVK_Delete, kVK_ForwardDelete: clearCurrent()
        default: return false
        }
        return true
    }

    func step(_ by: Int) {
        guard !items.isEmpty else { return }
        index = (index + by + items.count) % items.count
    }

    func openCurrent() {
        guard let item = current else { return }
        hide()
        if launch(item) { remove(item) }
    }

    func clearCurrent() {
        guard let item = current else { return }
        remove(item)
        if items.isEmpty { hide() }
    }

    private func remove(_ item: InboxItem) {
        try? FileManager.default.removeItem(at: folder.appending(path: "\(item.id).json"))
        refresh(force: true)
    }

    /// The session it ended in, back in a Ghostty window of his login shell, as `spawn` opens one.
    private static func resume(_ item: InboxItem) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [NSHomeDirectory() + "/.claude/skills/spawn/open.sh", item.dir, item.prompt ?? ""]
            + item.options
        task.standardOutput = FileHandle.nullDevice
        do { try task.run() } catch {
            NSLog("Fleet: could not resume \(item.id) — \(error)")
            return false
        }
        // `open.sh` is back as soon as Ghostty has the request; its status says whether the line may go.
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // MARK: - Panel

    @objc func toggle() {
        if panel?.isVisible == true { return hide() }
        refresh(force: true)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Where Spotlight sits: centred, a third of the way down the screen the pointer is on.
        let screen = OverlayWindowController.activeScreen().visibleFrame
        let size = panel.frame.size
        Self.present(panel, at: NSRect(x: screen.midX - size.width / 2,
                                       y: screen.maxY - screen.height / 3 - size.height / 2,
                                       width: size.width, height: size.height))
        panel.makeKey()
    }

    /// Fades in while it rises the last few points into its place.
    static func present(_ panel: NSWindow, at place: NSRect) {
        panel.alphaValue = 0
        panel.setFrame(place.offsetBy(dx: 0, dy: -rise), display: false)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = entrance
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(place, display: true)
        }
    }

    func hide() { panel?.orderOut(nil) }

    /// Non-activating, as Spotlight: it takes the keys without taking the app in front away from him. No window
    /// shadow: the bar draws its own, in the clear margin around it.
    private func makePanel() -> InboxPanel {
        let size = NSSize(width: Self.bar.width + 2 * Self.margin, height: Self.bar.height + 2 * Self.margin)
        let panel = InboxPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.onKey = { [weak self] code in self?.key(code) ?? false }
        panel.contentView = NSHostingView(rootView: InboxView(inbox: self))
        return panel
    }

    // MARK: - Render

    /// `--render-inbox <png>`: the panel as it would show `items`, drawn offscreen over a dark backdrop. The glass
    /// is not in it: it blurs what is behind a window on screen, and an offscreen view has nothing behind it.
    static func render(_ items: [InboxItem], index: Int = 0, to path: String) {
        let inbox = Inbox(folder: URL(fileURLWithPath: "/nonexistent"))
        inbox.items = items
        inbox.index = index
        let view = NSHostingView(rootView: InboxView(inbox: inbox).background(Color(white: 0.3)))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(view.bounds.size)")
    }

    /// The menu bar badges at 0, 3 and 12, black on white at 4×.
    static func renderBadges(to path: String) {
        let size = NSSize(width: 90, height: 24)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 360, pixelsHigh: 96, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        var x: CGFloat = 6
        for n in [0, 3, 12] {
            let image = badge(n)
            image.draw(in: NSRect(x: x, y: 4, width: image.size.width, height: 16))
            x += image.size.width + 10
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}

final class InboxPanel: NSPanel {
    var onKey: (UInt16) -> Bool = { _ in false }

    override var canBecomeKey: Bool { true }

    /// Ahead of every responder, as `PanelWindow` does: the hosting view would take the arrows first.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey(event.keyCode) { return }
        super.sendEvent(event)
    }

    /// A click anywhere else puts it away, as Spotlight does.
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

struct InboxView: View {
    @ObservedObject var inbox: Inbox

    private static let done = Color(red: 0.24, green: 0.82, blue: 0.35)
    private static let needs = Color(red: 1.00, green: 0.62, blue: 0.15)

    var body: some View {
        HStack(spacing: 10) {
            if let item = inbox.current {
                Circle()
                    .fill(item.kind == "done" ? Self.done : Self.needs)
                    .frame(width: 9, height: 9)
                    .padding(.trailing, 2)
                (Text(item.subject).foregroundColor(.secondary)
                 + Text("   ")
                 + Text(item.line).foregroundColor(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("\(item.subject) — \(item.line)")
                Spacer(minLength: 12)
                if inbox.items.count > 1 {
                    Text("\(inbox.index + 1)/\(inbox.items.count)")
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .padding(.trailing, 2)
                    KeyBubble(glyph: "←", help: "Previous") { inbox.step(-1) }
                    KeyBubble(glyph: "→", help: "Next") { inbox.step(1) }
                }
                KeyBubble(glyph: "↩", help: "Open its session") { inbox.openCurrent() }
                KeyBubble(glyph: "⌫", help: "Clear it") { inbox.clearCurrent() }
            } else {
                Text("Nothing from the watcher")
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .font(.system(size: 15))
        .padding(.leading, 22)
        .padding(.trailing, 13)
        .frame(width: Inbox.bar.width, height: Inbox.bar.height)
        .modifier(Glass())
        .contentShape(Capsule())
        .onTapGesture { inbox.openCurrent() }
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .padding(Inbox.margin)
    }
}

/// A key the bar answers to, in a round bubble at its right end, as Spotlight puts its actions; a click on it
/// does what the key does.
private struct KeyBubble: View {
    let glyph: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Spotlight's glass where the system has it (macOS 26), its frosted material before.
private struct Glass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
