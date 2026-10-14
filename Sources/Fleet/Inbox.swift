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

/// Echo: what the watcher found, counted in the menu bar and shown one line at a time on ⌘⌥K, Spotlight-like. Arrows
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
    static let window = NSSize(width: 1380, height: 260)
    static let margin: CGFloat = 30
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
        item.button?.toolTip = "Echo: what the awaited answers brought back — \(Self.chord.label)"
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

    /// What ↑ or ↓ asked about the line shown: ↑ to set it aside as done, ↓ to remove it for good. Only ↵ (or the
    /// yes button) says yes: the same key twice, a double click, a key held down only ask again. Any other key keeps
    /// the line as it is.
    struct Ask: Equatable {
        let id: String
        let trash: Bool
    }
    @Published private(set) var asking: Ask?
    /// The key just pressed on the keyboard, for a moment: its button gives under it, as under a click.
    @Published private(set) var pressed: Int?

    /// Every key the panel takes, and what each button sends; the others go on. ↵ opens, or says yes to a question;
    /// ←→ move and keep every line; ↑ asks to set the shown one aside as done (`done/`, still on disk), ↓ asks to
    /// remove it for good.
    func key(_ code: UInt16) -> Bool {
        let was = asking
        asking = nil
        switch Int(code) {
        case kVK_Escape: if was == nil { hide() }
        case kVK_LeftArrow: step(-1)
        case kVK_RightArrow: step(1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let was, let item = current, was.id == item.id { take(item, keep: !was.trash) } else { openCurrent() }
        case kVK_UpArrow: ask(trash: false, was)
        case kVK_DownArrow: ask(trash: true, was)
        default: return false
        }
        let code = Int(code)
        pressed = code
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            if self?.pressed == code { self?.pressed = nil }
        }
        return true
    }

    private func ask(trash: Bool, _ was: Ask?) {
        guard let item = current else { return }
        asking = Ask(id: item.id, trash: trash)
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
        Self.present(panel, at: place(panel))
        panel.makeKey()
    }

    /// Where Spotlight sits: centred, a third of the way down the screen the pointer is on.
    private func place(_ panel: NSWindow) -> NSRect {
        let screen = OverlayWindowController.activeScreen().visibleFrame
        let size = panel.frame.size
        return NSRect(x: screen.midX - size.width / 2, y: screen.maxY - screen.height / 3 - size.height / 2,
                      width: size.width, height: size.height)
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

    /// `--render-inbox <png>`: the panel as it would show `items`, drawn offscreen over a light backdrop, as his desktop is.
    /// What the render stands on: his wallpaper's kind of light gradient, a dark one, or a white window.
    static let backdrops: [String: [Color]] = [
        "light": [Color(red: 0.55, green: 0.70, blue: 0.85), Color(red: 0.85, green: 0.82, blue: 0.70)],
        "dark": [Color(red: 0.05, green: 0.15, blue: 0.40), Color(red: 0.10, green: 0.30, blue: 0.60)],
        "white": [.white, .white],
    ]

    static func render(_ items: [InboxItem], index: Int = 0, asking: Bool? = nil, on backdrop: String = "light", to path: String) {
        let inbox = Inbox(folder: URL(fileURLWithPath: "/nonexistent"))
        inbox.items = items
        inbox.index = index
        inbox.asking = asking.flatMap { trash in inbox.current.map { Ask(id: $0.id, trash: trash) } }
        let backdrop = LinearGradient(colors: backdrops[backdrop] ?? [.gray], startPoint: .top, endPoint: .bottom)
        // SwiftUI's own renderer: a hosting view's `cacheDisplay` drew a short line off both ends of every stroked
        // capsule, which the screen does not.
        let renderer = ImageRenderer(content: InboxView(inbox: inbox).background(backdrop).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(image.size)")
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
    /// A key held down repeats only for the arrows: a repeated ⌫ answered its own question.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.isARepeat, ![123, 124].contains(event.keyCode) { return }
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

    /// The icon of the key that comes next: ↵ when the line needs him, ✓ when it only tells him something is done.
    private static let open = Color(red: 0.40, green: 0.70, blue: 1.00)
    private static let done = Color(red: 0.24, green: 0.82, blue: 0.35)
    /// Today's line by its hour alone, written the French way (10h40); an older one with its day (13/10 10h40).
    static func when(_ ms: Double, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH'h'mm" : "dd/MM HH'h'mm"
        return f.string(from: date)
    }

    var body: some View {
        // Fixed to its ideal size, the stack is as wide as the line, and the row under it spreads to that width.
        VStack(spacing: 10) {
            subject
            bar.frame(maxWidth: .infinity)
            controls.frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
        .fixedSize()
        .foregroundStyle(Spotlight.ink)
        .padding(.top, Inbox.margin)
        .frame(width: Inbox.window.width, height: Inbox.window.height, alignment: .top)
    }

    /// What the line is about, in its own block above it. Every subject of the list is laid under it unseen: the
    /// block keeps the widest, so the arrows change its words and not its size.
    private var subject: some View {
        ZStack {
            ForEach(inbox.items, id: \.id) { Text($0.subject).hidden() }
            Text(inbox.current?.subject ?? "Echo")
        }
        .font(.system(size: 14, weight: .semibold))
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 22)
        .frame(height: 34)
        .block(in: Capsule())
    }

    /// Where it stands, whole and centred. Every line of the list is laid under it unseen, with the questions ↑ and
    /// ↓ ask: the bar keeps the widest, so nothing moves.
    private var bar: some View {
        ZStack {
            ForEach(inbox.items, id: \.id) { Text($0.line).hidden() }
            if let item = inbox.current {
                Text(Self.question(trash: false)).hidden()
                Text(Self.question(trash: true)).hidden()
                if let ask = inbox.asking, ask.id == item.id {
                    Text(Self.question(trash: ask.trash))
                } else {
                    Text(item.line)
                }
            } else {
                Text("Nothing has come back")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 15))
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .frame(minWidth: 620, minHeight: Inbox.barHeight)
        .block(in: Capsule(), fill: inbox.asking.map { Spotlight.fill.mix(with: $0.trash ? Self.trash : Self.yes, by: 0.4) })
        .contentShape(Capsule())
        .onTapGesture { _ = inbox.key(UInt16(kVK_Return)) }
    }

    private static let trash = Color(red: 0.92, green: 0.20, blue: 0.20)
    /// The dot's green, deeper: under a white tick the dot's own is too pale to read.
    private static let yes = Color(red: 0.16, green: 0.62, blue: 0.28)

    private static func question(trash: Bool) -> String {
        (trash ? "Remove it for good?" : "Set it aside as done?") + " ↵ to confirm, any other key keeps it."
    }

    /// Under the line: when it came on the left, which one of how many in the middle between the arrows that move
    /// through them, what can be done with it on the right.
    private var controls: some View {
        HStack(alignment: .top) {
            // Every date of the list laid under it unseen: the block keeps the widest, so it does not change size.
            if let item = inbox.current {
                ZStack {
                    ForEach(inbox.items, id: \.id) { Text(Self.when($0.at)).hidden() }
                    Text(Self.when(item.at))
                }
                .monospacedDigit()
                .chip()
            }
            Spacer(minLength: 24)
            HStack(alignment: .top, spacing: Inbox.gap) {
                // While ↑ or ↓ asks, ↵ is the yes: its button says so in the question's colour.
                let ask = inbox.asking
                let colour = ask.map { $0.trash ? Self.trash : Self.yes }
                let needs = ask == nil && inbox.current?.kind == "needs"
                let done = ask == nil && inbox.current?.kind == "done"
                key("return", ask == nil ? "open" : "yes", kVK_Return, tint: colour, icon: needs ? Self.open : nil)
                key("checkmark", ask?.trash == false ? "sure?" : "done", kVK_UpArrow,
                    tint: ask?.trash == false ? Self.yes : nil, icon: done ? Self.done : nil)
                key("trash", ask?.trash == true ? "sure?" : "trash", kVK_DownArrow,
                    tint: ask?.trash == true ? Self.trash : nil)
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

    private func key(_ symbol: String, _ label: String, _ code: Int, tint: Color? = nil, icon: Color? = nil) -> some View {
        let off = inbox.current == nil || ((code == kVK_LeftArrow || code == kVK_RightArrow) && inbox.items.count < 2)
        return KeyBubble(symbol: symbol, label: label, off: off, tint: tint, icon: icon, pressed: inbox.pressed == code) {
            _ = inbox.key(UInt16(code))
        }
    }
}

/// One of the keys, as a round button, as Spotlight puts its own, with its name under it on a chip of its own: on
/// the wallpaper bare, white or black, it was lost on one colour or the other. Filled with its colour when it has
/// one, the icon white on it; or with only its icon coloured, when it is the key to press next.
private struct KeyBubble: View {
    let symbol: String
    let label: String
    var off = false
    var tint: Color?
    var icon: Color?
    var pressed = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(tint == nil ? icon ?? Spotlight.ink : .white)
            }
            .buttonStyle(Bouncy(tint: tint, pressed: pressed, hovering: hovering && !off))
            .onHover { hovering = $0 }
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .block(in: Capsule())
        }
        .frame(width: Inbox.bubble)
        .opacity(off ? 0.45 : 1)
        .disabled(off)
    }
}

/// Round and springy: it swells a little under the pointer and gives under a click or its key, overshooting on the
/// way back.
private struct Bouncy: ButtonStyle {
    let tint: Color?
    let pressed: Bool
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed || pressed
        // The fill comes from the circle's frame, so the circle itself grows and shrinks, around its centre,
        // inside a frame that does not move: a scale effect grew the icon and left the fill where it was.
        let scale: CGFloat = down ? 0.84 : hovering ? 1.1 : 1
        configuration.label
            .scaleEffect(scale)
            .frame(width: Inbox.bubble * scale, height: Inbox.bubble * scale)
            .block(in: Circle(), fill: tint)
            .frame(width: Inbox.bubble, height: Inbox.bubble)
            .contentShape(Circle())
            .animation(.spring(response: 0.3, dampingFraction: down ? 0.42 : 0.55), value: scale)
    }
}

/// Spotlight's own colours, read off his screen: a flat grey, no blur and no edge, and the text near white.
private enum Spotlight {
    static let fill = Color(white: 94 / 255)
    static let ink = Color(white: 237 / 255)
}

private extension View {
    /// A small block for the date and the count, as tall as the buttons beside it.
    func chip() -> some View {
        font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(height: Inbox.bubble)
            .block(in: Capsule())
    }

    func block<S: Shape>(in shape: S, fill: Color? = nil) -> some View {
        background(fill ?? Spotlight.fill, in: shape)
    }
}
