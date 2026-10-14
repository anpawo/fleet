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
    /// The text block, the round buttons beside it with their names under them, and the clear room around
    /// them all that their shadow is drawn in.
    static let bar = NSSize(width: 940, height: 56)
    static let bubble: CGFloat = 56
    static let gap: CGFloat = 12
    static let row = NSSize(width: bar.width + 5 * (bubble + gap), height: bubble + 21)
    static let margin: CGFloat = 40
    /// It fades in while rising these last points into its place.
    static let rise: CGFloat = 14
    static let entrance: TimeInterval = 0.22
    /// `--render-inbox` only: a plain light fill where the glass goes. Glass is drawn by the window server from
    /// what is behind a window on screen, and an offscreen picture has neither, so it would show nothing at all.
    static var flat = false

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

    /// The line ↓ was pressed on once: a second ↓ removes it for good, any other key keeps it.
    @Published private(set) var confirming: String?

    /// Every key the panel takes, and what each button sends; the others go on. ↵ opens, ←→ move and keep every
    /// line, ↑ sets the shown one aside as done for now (`done/`, still on disk), ↓ twice removes it.
    func key(_ code: UInt16) -> Bool {
        let armed = confirming
        confirming = nil
        switch Int(code) {
        case kVK_Escape: if armed == nil { hide() }
        case kVK_LeftArrow: step(-1)
        case kVK_RightArrow: step(1)
        case kVK_Return, kVK_ANSI_KeypadEnter: openCurrent()
        case kVK_UpArrow: if let item = current { take(item, keep: true) }
        case kVK_DownArrow:
            guard let item = current else { break }
            if armed == item.id { take(item, keep: false) } else { confirming = item.id }
        default: return false
        }
        return true
    }

    private func step(_ by: Int) {
        guard !items.isEmpty else { return }
        index = (index + by + items.count) % items.count
    }

    /// Opened is handled: the line is set aside as done once its terminal has started.
    private func openCurrent() {
        guard let item = current else { return }
        hide()
        if launch(item) { take(item, keep: true) }
    }

    private func take(_ item: InboxItem, keep: Bool) {
        let file = folder.appending(path: "\(item.id).json")
        if keep {
            let done = folder.appending(path: "done")
            try? FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: done.appending(path: "\(item.id).json"))
            try? FileManager.default.moveItem(at: file, to: done.appending(path: "\(item.id).json"))
        } else {
            try? FileManager.default.removeItem(at: file)
        }
        refresh(force: true)
        if items.isEmpty { hide() }
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
        let size = NSSize(width: Self.row.width + 2 * Self.margin, height: Self.row.height + 2 * Self.margin)
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

    /// `--render-inbox <png>`: the panel as it would show `items`, drawn offscreen over a light backdrop, as his desktop is. The glass
    /// is not in it: it blurs what is behind a window on screen, and an offscreen view has nothing behind it.
    static func render(_ items: [InboxItem], index: Int = 0, confirming: Bool = false, to path: String) {
        flat = true
        let inbox = Inbox(folder: URL(fileURLWithPath: "/nonexistent"))
        inbox.items = items
        inbox.index = index
        inbox.confirming = confirming ? inbox.current?.id : nil
        let backdrop = LinearGradient(colors: [Color(red: 0.55, green: 0.70, blue: 0.85), Color(red: 0.85, green: 0.82, blue: 0.70)],
                                      startPoint: .top, endPoint: .bottom)
        let view = NSHostingView(rootView: InboxView(inbox: inbox).background(backdrop))
        view.appearance = NSAppearance(named: .aqua)
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
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        return f
    }()

    var body: some View {
        GlassGroup {
            HStack(alignment: .top, spacing: Inbox.gap) {
                bar
                let none = inbox.current == nil, alone = inbox.items.count < 2
                KeyBubble(symbol: "chevron.left", label: "prev", off: alone) { _ = inbox.key(UInt16(kVK_LeftArrow)) }
                KeyBubble(symbol: "chevron.right", label: "next", off: alone) { _ = inbox.key(UInt16(kVK_RightArrow)) }
                KeyBubble(symbol: "return", label: "open", off: none) { _ = inbox.key(UInt16(kVK_Return)) }
                KeyBubble(symbol: "checkmark", label: "done", off: none) { _ = inbox.key(UInt16(kVK_UpArrow)) }
                KeyBubble(symbol: "trash", label: inbox.confirming == nil ? "trash" : "sure?", off: none,
                          tint: inbox.confirming == nil ? nil : .red) { _ = inbox.key(UInt16(kVK_DownArrow)) }
            }
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .padding(Inbox.margin)
    }

    /// The text block: when it came, what it is about, where it stands, each in its own column of one line.
    private var bar: some View {
        HStack(spacing: 14) {
            if let item = inbox.current {
                Circle()
                    .fill(item.kind == "done" ? Self.done : Self.needs)
                    .frame(width: 8, height: 8)
                Text(Self.day.string(from: Date(timeIntervalSince1970: item.at / 1000)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(item.subject)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .fixedSize()
                Divider().frame(height: 22)
                Text(inbox.confirming == item.id ? "Remove it for good? ↓ again, any other key keeps it." : item.line)
                    .foregroundStyle(inbox.confirming == item.id ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(item.line)
                Spacer(minLength: 8)
                if inbox.items.count > 1 {
                    Text("\(inbox.index + 1)/\(inbox.items.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Nothing from the watcher")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 22)
        .frame(width: Inbox.bar.width, height: Inbox.bar.height)
        .glass(in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { _ = inbox.key(UInt16(kVK_Return)) }
    }
}

/// One of the keys, as a round glass button beside the bar, as Spotlight puts its own, with its name under it.
private struct KeyBubble: View {
    let symbol: String
    let label: String
    var off = false
    var tint: Color?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(tint ?? .primary.opacity(0.75))
                    .frame(width: Inbox.bubble, height: Inbox.bubble)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glass(in: Circle(), tint: tint?.opacity(0.25), interactive: true)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.7))
        }
        .opacity(off ? 0.45 : 1)
        .disabled(off)
    }
}

/// Spotlight's own material: Liquid Glass on macOS 26, grouped so that the shapes blend as Spotlight's do; the
/// frosted material before it.
private struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: Inbox.gap) { content }
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if Inbox.flat {
            background((tint ?? .white).opacity(0.55), in: shape)
        } else if #available(macOS 26.0, *) {
            glassEffect(liquid(tint, interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}

@available(macOS 26.0, *)
private func liquid(_ tint: Color?, _ interactive: Bool) -> Glass {
    let glass = tint.map { Glass.regular.tint($0) } ?? .regular
    return interactive ? glass.interactive() : glass
}
