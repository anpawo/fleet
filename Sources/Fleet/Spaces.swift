import AppKit
import ApplicationServices
import MachO

/// Making a desktop — a real Space, the one Mission Control's `+` creates.
///
/// There is no API for this, and the private ones answer without doing anything, which is
/// worse than refusing. Measured here on macOS 26, linking SkyLight directly:
///
/// - `SLSSpaceCreate` returns a genuine space id (105, on the run this was written from), and
///   the space it makes is a ghost. It never appears in `SLSCopyManagedDisplaySpaces` — the
///   Dock's list of what the displays actually hold — so Mission Control has no thumbnail for
///   it, no window can be sent to it, and nothing can go there. `SLSSpaceSetType` on it fails
///   outright. Space *membership* is the Dock's, behind
///   `com.apple.private.skylight.universal-owner`; making the object is not.
/// - `SLSManagedDisplaySetCurrentSpace` is the one that lies. It returns success, and
///   `SLSManagedDisplayGetCurrentSpace` then agrees you have moved — while the screen has not
///   changed and `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` still lists the windows of
///   the desktop you are standing on. All it moves is bookkeeping the Dock is not party to.
/// - `CoreDockSetWorkspacesCount` is an eight-byte stub returning -50 without so much as
///   contacting the Dock, and Dock's own `createSpaces` XPC message is gated on
///   `com.apple.private.dock.spaces`, which nothing shipping on the machine holds.
///
/// That is why yabai injects a scripting addition into the Dock and calls an unexported
/// function found by byte-pattern scan — and why it costs a partly disabled SIP.
///
/// What is left is to press the button ourselves. Mission Control's Spaces bar lives in the
/// Dock's accessibility tree, and its `+` is an ordinary `AXButton`. Nothing is faked and no
/// coordinates are guessed: it is the same press, dispatched by us, under the Accessibility
/// grant Fleet already needs to raise a terminal across a desktop.
///
/// The panel's `+` does not come through here: a fullscreen window gets a desktop from macOS
/// itself, with no Dock driving at all, which is what `TerminalLaunch.openTerminal` asks for.
/// This is the route to an *empty* Space, which nothing but `--new-desktop --spaces-bar` wants
/// today — kept because it is the only one there is, and it is not rediscoverable cheaply.
@MainActor
enum Spaces {

    /// Adds a desktop to `display`, and optionally goes to it.
    ///
    /// Mission Control has to be on screen for the button to exist at all, so it is opened,
    /// pressed, and toggled shut again — about half a second of it flashing past, which is not
    /// suppressible: every route to a new Space ends at driving the Dock's own interface.
    ///
    /// `switchingTo` leaves by the front door instead: the new desktop's own thumbnail is
    /// pressed, which is the gesture that both goes there and dismisses Mission Control. Worth
    /// the extra press rather than a keystroke — Control-→ would need the grant for
    /// synthesizing events, and counting arrows is guesswork about where the new desktop
    /// landed. Returns once macOS has actually arrived, so whatever comes next opens *there*.
    @discardableResult
    static func addDesktop(on display: CGDirectDisplayID = CGMainDisplayID(),
                           switchingTo switching: Bool = false) -> Bool {
        guard Desktop.accessibilityTrusted() else { return false }

        // Left alone if it was already up — closing something the user opened would be rude,
        // and Fleet's own `+` is only reachable with Mission Control down anyway.
        let opened = missionControl() == nil
        if opened { toggleMissionControl() }

        guard let button = waitForAddButton(on: display) else {
            if opened { toggleMissionControl() }
            NSLog("Fleet: no add-desktop button in Mission Control — the Dock's accessibility "
                  + "tree has moved, or Mission Control never came up")
            return false
        }

        let before = desktops(on: display).count
        let pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success

        if pressed, switching, let desktop = waitForNewDesktop(on: display, beyond: before) {
            if AXUIElementPerformAction(desktop, kAXPressAction as CFString) == .success {
                waitForMissionControlToClose()
                return true
            }
            NSLog("Fleet: the new desktop refused the press — it exists, we are not on it")
        }

        // The press is dispatched by now; this is politeness to the animation, so the new
        // thumbnail lands before the window is torn down from under it.
        if opened || switching {
            usleep(250_000)
            toggleMissionControl()
        }
        if !pressed { NSLog("Fleet: the add-desktop button refused the press") }
        return pressed
    }

    /// The thumbnail of the desktop the `+` has just made, once the Spaces bar has grown it.
    ///
    /// The last one, and identified as such rather than by name: the tiles carry no
    /// `AXIdentifier` at all and their titles are localized ("Bureau 7" here), while a new
    /// desktop is always appended at the end of the bar. Waiting on the *count* is what makes
    /// the last one the right one — read too early and it is the desktop you are already on.
    private static func waitForNewDesktop(on display: CGDirectDisplayID, beyond count: Int,
                                          within timeout: TimeInterval = 2) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let desktops = desktops(on: display)
            if desktops.count > count { return desktops.last }
            usleep(20_000)
        }
        NSLog("Fleet: the Spaces bar never grew a desktop — the `+` was pressed, nothing came")
        return nil
    }

    /// Blocks until Mission Control is off screen, which is the end of the switch: the `mc`
    /// group outlives the animation, so its disappearance is as close to "we have arrived" as
    /// can be had without asking the window server.
    private static func waitForMissionControlToClose(within timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if missionControl() == nil { return }
            usleep(20_000)
        }
        NSLog("Fleet: Mission Control stayed up after entering the new desktop")
    }

    /// The `+`, once Mission Control has drawn it. Polled rather than slept against: the
    /// notification returns immediately and the Spaces bar is the last thing to appear.
    ///
    /// Blocking is deliberate. The whole thing is under a second, the panel is already gone by
    /// the time it starts, and every alternative — a detached task, an async ladder — buys
    /// nothing while there is no interface left to keep responsive.
    private static func waitForAddButton(on display: CGDirectDisplayID,
                                         within timeout: TimeInterval = 2) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let button = addButton(on: display) { return button }
            usleep(20_000)
        }
        return nil
    }

    private static func addButton(on display: CGDirectDisplayID) -> AXUIElement? {
        guard let spaces = spacesBar(on: display) else { return nil }
        return children(spaces).first { identifier($0) == "mc.spaces.add" }
    }

    /// Every desktop's thumbnail, left to right, as the Spaces bar has them.
    private static func desktops(on display: CGDirectDisplayID) -> [AXUIElement] {
        guard let spaces = spacesBar(on: display),
              let list = children(spaces).first(where: { identifier($0) == "mc.spaces.list" })
        else { return [] }
        return children(list)
    }

    /// `Dock → mc → mc.display → mc.spaces`, the bar holding the desktops and the `+`.
    ///
    /// Navigated by `AXIdentifier` and never by title or position, which is the whole
    /// difference between this working and the snippets that do not. The descriptions are
    /// localized — Dock's `Accessibility.strings` gives "add desktop" as "ajouter le bureau" in
    /// French — and positional indexing (`group 2 of group 1 of group 1`) is exactly what broke
    /// between Ventura and Sonoma. The `mc.*` identifiers have held since Monterey.
    private static func spacesBar(on display: CGDirectDisplayID) -> AXUIElement? {
        guard let mc = missionControl() else { return nil }

        // One `mc.display` per screen. Falling back to the first rather than failing: on a
        // single display the match is a formality, and no desktop at all is a worse answer
        // than one on the wrong screen.
        let displays = children(mc).filter { identifier($0) == "mc.display" }
        let screen = displays.first {
            (attribute($0, "AXDisplayID") as? NSNumber)?.uint32Value == display
        } ?? displays.first

        guard let screen else { return nil }
        return children(screen).first { identifier($0) == "mc.spaces" }
    }

    /// The `mc` group, which exists only while Mission Control is on screen — making its
    /// presence the honest test of whether Mission Control is up. Asking the window server is
    /// no use: Mission Control owns no window anyone else can see.
    private static func missionControl() -> AXUIElement? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let element = AXUIElementCreateApplication(dock.processIdentifier)
        return children(element).first { identifier($0) == "mc" }
    }

    /// Show Mission Control, or dismiss it if it is showing.
    ///
    /// The same notification `Mission Control.app` posts — that app is a 100 KB stub whose
    /// entire job this is. Preferred over launching it, or over synthesizing the F3 key: no
    /// Apple Events, so no Automation prompt on top of the Accessibility one, and no
    /// `kTCCServicePostEvent` grant for injecting keystrokes.
    private static func toggleMissionControl() {
        CoreDockSendNotification("com.apple.expose.awake" as CFString, 0)
    }

    // MARK: - Accessibility reads

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
    }

    private static func identifier(_ element: AXUIElement) -> String? {
        attribute(element, "AXIdentifier") as? String
    }
}

/// Undocumented, but exported from HIServices and callable with no entitlement at all.
@_silgen_name("CoreDockSendNotification")
private func CoreDockSendNotification(_ name: CFString, _ reserved: Int32)

// MARK: - Sending a window to the desktop beside it

/// ⌥⌘← and ⌥⌘→ (asked 2026-10-28): the window in front goes to the desktop on that side and
/// you stay where you are, so a pile of windows is sorted one press each.
///
/// macOS 14.5 shut `SLSMoveWindowsToManagedSpace` to everyone but the Dock: it still returns,
/// and moves nothing (measured here on 26.6). What moves a window now is the operation the Dock
/// is handed, performed through a function SkyLight has but does not export, so it is looked up
/// in SkyLight's symbol table, as yabai does since asmvik/yabai#2788. No SIP change.
extension Spaces {

    /// Past the last desktop a new one is made for the window (Mission Control flashes, see
    /// `addDesktop`); past the first nothing happens.
    static func sendFrontWindow(by step: Int) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid(),
              let window = windowsHere().first(where: {
                  $0[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier
              }),
              let id = window[kCGWindowNumber as String] as? CGWindowID else { return }
        send(window: id, by: step)
    }

    @discardableResult
    static func send(window: CGWindowID, by step: Int) -> Bool {
        guard let space = spaces(of: window).first,
              var row = desktops(beside: space),
              let here = row.firstIndex(of: space), here + step >= 0 else { return false }
        if here + step >= row.count {
            guard addDesktop(on: display(of: window)),
                  let grown = waitForDesktops(beside: space, beyond: row.count) else { return false }
            row = grown
        }
        return move(window, to: row[min(here + step, row.count - 1)])
    }

    /// The sessions whose terminal has no window on the desktop in front of you: the panel
    /// leaves them out and counts them (asked 2026-10-28). A session with no terminal at all
    /// belongs to no desktop and shows on every one. Matched by process, which is exact for
    /// Ghostty (one process per window); a Terminal.app holding many windows counts as here
    /// when any one of them is.
    static func elsewhere(_ sessions: [Session]) -> Set<pid_t> {
        let here = Set(windowsHere().compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
        let parents = ProcessScanner.parentMap()
        let hosted = sessions.compactMap { session in
            ProcessScanner.hostApplication(of: session.proc.pid, parents: parents)
                .map { (session: session.id, host: $0.app.processIdentifier) }
        }
        // A fullscreen app with no session in it (a video, a call) is a desktop of its own:
        // hiding every session there left the panel empty over it (2026-10-30), so it hides none.
        guard hosted.contains(where: { here.contains($0.host) }) || !inFullscreen() else { return [] }
        return Set(hosted.filter { !here.contains($0.host) }.map(\.session))
    }

    private static func inFullscreen() -> Bool {
        let connection = CGSMainConnectionID()
        return CGSSpaceGetType(connection, CGSGetActiveSpace(connection)) == 4
    }

    /// The windows on the desktops in front of you, frontmost first, menus and panels left out.
    private static func windowsHere() -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                    kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { $0[kCGWindowLayer as String] as? Int == 0 }
    }

    private static func spaces(of window: CGWindowID) -> [UInt64] {
        (CGSCopySpacesForWindows(CGSMainConnectionID(), 0x7, [window] as CFArray)
            as? [NSNumber] ?? []).map(\.uint64Value)
    }

    /// The desktops of the screen holding `space`, left to right. Fullscreen spaces (type 4)
    /// are stepped over: no window can join one.
    private static func desktops(beside space: UInt64) -> [UInt64]? {
        let screens = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
        return screens.lazy.map { screen in
            (screen["Spaces"] as? [[String: Any]] ?? [])
                .filter { $0["type"] as? Int == 0 }
                .compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        }.first { $0.contains(space) }
    }

    /// The Dock writes a new desktop down a moment after its `+` is pressed.
    private static func waitForDesktops(beside space: UInt64, beyond count: Int) -> [UInt64]? {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let row = desktops(beside: space), row.count > count { return row }
            usleep(20_000)
        }
        NSLog("Fleet: Mission Control made no desktop for the window to go to")
        return nil
    }

    /// Where a new desktop has to go for the window: on its own screen.
    private static func display(of window: CGWindowID) -> CGDirectDisplayID {
        var display = CGMainDisplayID()
        var count: UInt32 = 0
        if let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, window)
                        as? [[String: Any]])?.first,
           let bounds = (info[kCGWindowBounds as String] as! CFDictionary?)
               .flatMap({ CGRect(dictionaryRepresentation: $0) }) {
            CGGetDisplaysWithPoint(CGPoint(x: bounds.midX, y: bounds.midY), 1, &display, &count)
        }
        return display
    }

    private static func move(_ window: CGWindowID, to space: UInt64) -> Bool {
        guard let perform = performBridged,
              let type = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation")
                as? NSObject.Type,
              let initialize = class_getMethodImplementation(type, initWithWindows) else {
            NSLog("Fleet: this macOS has no bridged window move, the window stays where it is")
            return false
        }
        let operation = unsafeBitCast(initialize, to: Initializer.self)(
            type.perform(NSSelectorFromString("alloc")).takeRetainedValue(), initWithWindows,
            [window] as CFArray, space)
        _ = perform(Unmanaged.passUnretained(operation).toOpaque())
        // Asynchronous, as its name says: done once the window server agrees.
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if spaces(of: window) == [space] { return true }
            usleep(20_000)
        }
        NSLog("Fleet: window \(window) was sent to desktop \(space) and did not go")
        return false
    }

    private typealias Initializer = @convention(c) (AnyObject, Selector, CFArray, UInt64) -> AnyObject
    private typealias Perform = @convention(c) (UnsafeMutableRawPointer) -> Int64
    private static let initWithWindows = NSSelectorFromString("initWithWindows:spaceID:")

    private static let performBridged: Perform? = symbol(
        "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation",
        in: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    ).map { unsafeBitCast($0, to: Perform.self) }

    /// A symbol of a loaded image, local ones included: what `dlsym` cannot reach.
    private static func symbol(_ name: String, in image: String) -> UnsafeMutableRawPointer? {
        for i in 0..<_dyld_image_count()
        where _dyld_get_image_name(i).map({ String(cString: $0) }) == image {
            guard let header = _dyld_get_image_header(i) else { return nil }
            let slide = _dyld_get_image_vmaddr_slide(i)
            var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            var linkedit: segment_command_64?
            var symtab: symtab_command?
            for _ in 0..<header.pointee.ncmds {
                let kind = command.load(as: load_command.self)
                if kind.cmd == LC_SYMTAB { symtab = command.load(as: symtab_command.self) }
                if kind.cmd == LC_SEGMENT_64 {
                    let segment = command.load(as: segment_command_64.self)
                    let segname = withUnsafeBytes(of: segment.segname) {
                        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
                    }
                    if segname == "__LINKEDIT" { linkedit = segment }
                }
                command = command.advanced(by: Int(kind.cmdsize))
            }
            guard let linkedit, let symtab else { return nil }
            let base = Int(linkedit.vmaddr) - Int(linkedit.fileoff) + slide
            guard let names = UnsafePointer<CChar>(bitPattern: base + Int(symtab.stroff)),
                  let entries = UnsafePointer<nlist_64>(bitPattern: base + Int(symtab.symoff))
            else { return nil }
            for entry in UnsafeBufferPointer(start: entries, count: Int(symtab.nsyms))
            where strcmp(names + Int(entry.n_un.n_strx), name) == 0 {
                return UnsafeMutableRawPointer(bitPattern: Int(entry.n_value) + slide)
            }
        }
        return nil
    }
}

// Re-exported by CoreGraphics from SkyLight.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray
@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ connection: Int32) -> UInt64
@_silgen_name("CGSSpaceGetType")
private func CGSSpaceGetType(_ connection: Int32, _ space: UInt64) -> Int32
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windows: CFArray) -> CFArray
