import AppKit
import Carbon.HIToolbox
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
    static let size = NSSize(width: 1000, height: 56)

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

    /// The menu bar item, hidden while there is nothing. Not in `init`: `--render-inbox` and the selftest build an
    /// inbox too, and must put nothing in his menu bar.
    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: "Watcher")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggle)
            button.toolTip = "What the watcher of awaited answers found — \(Self.chord.label)"
        }
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
        status?.isVisible = !items.isEmpty
        status?.button?.title = items.isEmpty ? "" : " \(items.count)"
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

    private func step(_ by: Int) {
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
        panel.setFrameOrigin(NSPoint(x: screen.midX - Self.size.width / 2,
                                     y: screen.maxY - screen.height / 3 - Self.size.height / 2))
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() { panel?.orderOut(nil) }

    /// Non-activating, as Spotlight: it takes the keys without taking the app in front away from him.
    private func makePanel() -> InboxPanel {
        let panel = InboxPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.onKey = { [weak self] code in self?.key(code) ?? false }
        panel.contentView = NSHostingView(rootView: InboxView(inbox: self))
        return panel
    }

    // MARK: - Render

    /// `--render-inbox <png>`: the panel as it would show `items`, drawn offscreen.
    static func render(_ items: [InboxItem], index: Int = 0, to path: String) {
        let inbox = Inbox(folder: URL(fileURLWithPath: "/nonexistent"))
        inbox.items = items
        inbox.index = index
        let view = NSHostingView(rootView: InboxView(inbox: inbox).padding(30).background(Color(white: 0.35)))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(view.bounds.size)")
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
        HStack(spacing: 12) {
            if let item = inbox.current {
                Circle()
                    .fill(item.kind == "done" ? Self.done : Self.needs)
                    .frame(width: 9, height: 9)
                (Text(item.subject).foregroundColor(.white.opacity(0.5))
                 + Text("   ")
                 + Text(item.line).foregroundColor(.white))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("\(item.subject) — \(item.line)")
                Spacer(minLength: 12)
                if inbox.items.count > 1 {
                    Text("\(inbox.index + 1)/\(inbox.items.count)")
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.45))
                }
                Text("↩ open  ⌫ clear")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.3))
            } else {
                Text("Nothing from the watcher")
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
            }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 20)
        .frame(width: Inbox.size.width, height: Inbox.size.height)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(red: 0.07, green: 0.07, blue: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12)))
        .contentShape(Rectangle())
        .onTapGesture { inbox.openCurrent() }
    }
}
