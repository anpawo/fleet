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
    /// The line, as wide as its text and never cut, and under it the date, the count and the round buttons with
    /// their names. The window is wider than any line and clear around them, for the shadow.
    static let barHeight: CGFloat = 56
    static let bubble: CGFloat = 38
    static let gap: CGFloat = 12
    static let window = NSSize(width: 1380, height: 210)
    static let margin: CGFloat = 30
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

    /// The line ⌫ was pressed on once: a second ⌫ removes it for good, any other key keeps it.
    @Published private(set) var confirming: String?

    /// Every key the panel takes, and what each button sends; the others go on. ↵ opens, ←→ move and keep every
    /// line, ↑ sets the shown one aside as done for now (`done/`, still on disk), ⌫ twice removes it.
    func key(_ code: UInt16) -> Bool {
        let armed = confirming
        confirming = nil
        switch Int(code) {
        case kVK_Escape: if armed == nil { hide() }
        case kVK_LeftArrow: step(-1)
        case kVK_RightArrow: step(1)
        case kVK_Return, kVK_ANSI_KeypadEnter: openCurrent()
        case kVK_UpArrow: if let item = current { take(item, keep: true) }
        case kVK_Delete, kVK_ForwardDelete:
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
        let size = Self.window
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
    static func render(_ items: [InboxItem], index: Int = 0, confirming: Bool = false, dark: Bool = false, to path: String) {
        flat = true
        let inbox = Inbox(folder: URL(fileURLWithPath: "/nonexistent"))
        inbox.items = items
        inbox.index = index
        inbox.confirming = confirming ? inbox.current?.id : nil
        let backdrop = LinearGradient(colors: dark ? [Color(red: 0.05, green: 0.15, blue: 0.40), Color(red: 0.10, green: 0.30, blue: 0.60)]
                                                   : [Color(red: 0.55, green: 0.70, blue: 0.85), Color(red: 0.85, green: 0.82, blue: 0.70)],
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
    /// Today's line by its hour alone, written the French way (10h40); an older one with its day (13/10 10h40).
    static func when(_ ms: Double, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH'h'mm" : "dd/MM HH'h'mm"
        return f.string(from: date)
    }

    var body: some View {
        // Fixed to its ideal size, the stack is as wide as the line, and the row under it spreads to that width.
        VStack(spacing: 12) {
            bar.frame(maxWidth: .infinity)
            controls.frame(maxWidth: .infinity)
        }
        .fixedSize()
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
        .padding(.top, Inbox.margin)
        .frame(width: Inbox.window.width, height: Inbox.window.height, alignment: .top)
    }

    /// The line itself, whole: what it is about, then where it stands. Every line of the list is laid under it,
    /// unseen, with the question ⌫ asks: the bar keeps the widest, so neither the arrows nor ⌫ move anything.
    private var bar: some View {
        ZStack(alignment: .leading) {
            ForEach(inbox.items, id: \.id) { line($0, asking: false).hidden() }
            if let item = inbox.current {
                line(item, asking: true).hidden()
                line(item, asking: inbox.confirming == item.id)
            } else {
                Text("Nothing from the watcher")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 15))
        .lineLimit(1)
        .padding(.horizontal, 24)
        // Never narrower than the row under it needs, the count centred between the date and the keys.
        .frame(minWidth: 720, minHeight: Inbox.barHeight, alignment: .leading)
        .glass(in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { _ = inbox.key(UInt16(kVK_Return)) }
    }

    private func line(_ item: InboxItem, asking: Bool) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(item.kind == "done" ? Self.done : Self.needs)
                .frame(width: 8, height: 8)
            Text(item.subject)
                .fontWeight(.semibold)
            Divider().frame(height: 22)
            Text(asking ? "Remove it for good? ⌫ again, any other key keeps it." : item.line)
                .foregroundStyle(asking ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        }
    }

    /// Under the line: when it came on the left, which one of how many in the middle between the arrows that move
    /// through them, what can be done with it on the right.
    private var controls: some View {
        HStack(alignment: .top) {
            if let item = inbox.current {
                Text(Self.when(item.at)).chip()
            }
            Spacer(minLength: 24)
            HStack(alignment: .top, spacing: Inbox.gap) {
                key("return", "open", kVK_Return)
                key("checkmark", "done", kVK_UpArrow)
                key("trash", inbox.confirming == nil ? "trash" : "sure?", kVK_Delete,
                    tint: inbox.confirming == nil ? nil : .red)
            }
        }
        .overlay(alignment: .top) {
            HStack(alignment: .top, spacing: Inbox.gap) {
                key("chevron.left", "prev", kVK_LeftArrow)
                Text("\(inbox.items.isEmpty ? 0 : inbox.index + 1) / \(inbox.items.count)")
                    .monospacedDigit()
                    .chip()
                key("chevron.right", "next", kVK_RightArrow)
            }
        }
    }

    private func key(_ symbol: String, _ label: String, _ code: Int, tint: Color? = nil) -> some View {
        let off = inbox.current == nil || ((code == kVK_LeftArrow || code == kVK_RightArrow) && inbox.items.count < 2)
        return KeyBubble(symbol: symbol, label: label, off: off, tint: tint) { _ = inbox.key(UInt16(code)) }
    }
}

/// One of the keys, as a round glass button, as Spotlight puts its own, and its name under it in the desktop's
/// label style (white, with a shadow): it stands on the wallpaper, whatever its colour.
private struct KeyBubble: View {
    let symbol: String
    let label: String
    var off = false
    var tint: Color?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint ?? .primary.opacity(0.8))
                    .frame(width: Inbox.bubble, height: Inbox.bubble)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glass(in: Circle(), tint: tint?.opacity(0.25), interactive: true)
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
                .fixedSize()
        }
        .frame(width: Inbox.bubble)
        .opacity(off ? 0.45 : 1)
        .disabled(off)
    }
}

private extension View {
    /// A small glass block for the date and the count, as tall as the buttons beside it.
    func chip() -> some View {
        font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: Inbox.bubble)
            .glass(in: Capsule())
    }

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
