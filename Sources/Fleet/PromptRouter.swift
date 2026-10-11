import AppKit
import Combine

/// Turns a typed sentence into an action: a new Claude Code session in the right project, or
/// an answer shown on the panel.
///
/// The routing decision is a model call rather than a keyword list. "Fix the thing where the
/// tiles swap" is code work with no code words in it, and "what should I cook tonight" is not,
/// and no amount of matching on `bug|deploy|repo` tells those apart.
@MainActor
final class PromptController: ObservableObject {

    enum Status: Equatable {
        case idle
        case routing                    // classifier in flight
        case thinking                   // general question being answered
        case launched(String)           // a session was started in this directory
        case answer(String)
        case failed(String)
    }

    let field = PromptField()
    @Published private(set) var status: Status = .idle

    /// Directory names Fleet knows about, refreshed from the live fleet before each routing
    /// call so the classifier can match what you write against real projects.
    var knownProjects: () -> [String] = { [] }

    private var forwarding: AnyCancellable?

    init() {
        // One observable object for the view to watch; the field's own state changes are
        // republished rather than making every call site observe both.
        forwarding = field.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        field.onSubmit = { [weak self] written in
            self?.route(written)
        }
    }

    /// Return on the panel: send what is in the field, if anything. A Return on an empty field
    /// is not ours — it falls through to whatever else wants it.
    @discardableResult
    func submit() -> Bool { field.submit() }

    /// Esc, while the panel is up. Consumed here only when there is a half-written prompt to
    /// throw away; with the field empty the panel takes it and closes. The field is always open
    /// now, so "is anything being edited" has to mean the draft rather than the field itself —
    /// otherwise Esc would never dismiss the panel again.
    func escape() -> Bool {
        guard !field.isEmpty else { return false }
        field.clear()
        status = .idle
        return true
    }

    /// The panel is on screen: an empty field with the caret in it. A finished answer is left
    /// alone, so it is still readable if the panel comes straight back.
    func panelOpened() {
        field.opened()
    }

    /// The panel is closing: drop the half-written prompt.
    func panelClosed() {
        field.clear()
    }

    // MARK: - Routing

    private func route(_ written: String) {
        status = .routing
        let projects = knownProjects()

        Task {
            do {
                let route = try await Claude.classify(written, projects: projects)
                await MainActor.run { self.perform(route, written: written) }
            } catch {
                await MainActor.run { self.status = .failed(Self.describe(error)) }
            }
        }
    }

    private func perform(_ route: Claude.Route, written: String) {
        switch route.kind {
        case .existingProject:
            guard let dir = resolve(project: route.project) else {
                // Classified as code work, but nothing on disk matches. Falling back to the
                // project root would start a session in the wrong place silently, which is
                // worse than saying so.
                status = .failed("No project matching “\(route.project)”. "
                    + "Name the directory, or start it as a new project.")
                return
            }
            launch(directory: dir, prompt: route.prompt)

        case .newProject:
            guard let dir = confirmNewProject(named: route.project) else {
                status = .idle
                return
            }
            launch(directory: dir, prompt: route.prompt)

        case .general:
            answer(route.prompt.isEmpty ? written : route.prompt)
        }
    }

    private func launch(directory: String, prompt: String) {
        guard TerminalLaunch.startSession(in: directory, prompt: prompt) else {
            status = .failed("Could not open a terminal window.")
            return
        }
        status = .launched((directory as NSString).lastPathComponent)
    }

    private func answer(_ question: String) {
        status = .thinking
        Task {
            do {
                let reply = try await Claude.answer(question)
                await MainActor.run { self.status = .answer(reply) }
            } catch {
                await MainActor.run { self.status = .failed(Self.describe(error)) }
            }
        }
    }

    // MARK: - Projects

    /// Maps a written project name onto a real directory. Live sessions first — a session
    /// running somewhere unusual is still a project you can name — then the project root.
    private func resolve(project: String) -> String? {
        let wanted = project.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }

        for path in liveDirectories() where (path as NSString).lastPathComponent.lowercased() == wanted {
            return path
        }

        let root = Config.projectRoot
        let candidate = (root as NSString).appendingPathComponent(project)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
            return candidate
        }

        // Case and punctuation drift between what is written and what is on disk ("my hub" vs
        // "my-hub"), so fall back to a normalised compare across the root's directories.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        let target = Self.normalise(wanted)
        for name in names where Self.normalise(name) == target {
            let path = (root as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return path
            }
        }
        return nil
    }

    private static func normalise(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Working directories of the sessions currently running, supplied by the controller.
    var liveDirectories: () -> [String] = { [] }

    /// Creating a directory is the one thing here the user cannot undo by closing a window,
    /// so it is the one thing that asks first. It also gives a chance to fix a name the
    /// classifier guessed.
    private func confirmNewProject(named suggestion: String) -> String? {
        let name = suggestion.isEmpty ? "new-project" : suggestion
        let path = (Config.projectRoot as NSString).appendingPathComponent(name)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Start a new project?"
        alert.informativeText = "Fleet will create \(displayPath(path)) and open a Claude Code "
            + "session there."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = name
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let chosen = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chosen.isEmpty else { return nil }
        let target = (Config.projectRoot as NSString).appendingPathComponent(chosen)

        do {
            try FileManager.default.createDirectory(atPath: target,
                                                    withIntermediateDirectories: true)
        } catch {
            status = .failed("Could not create \(displayPath(target)): "
                + error.localizedDescription)
            return nil
        }
        return target
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
