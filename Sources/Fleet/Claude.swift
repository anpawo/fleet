import Foundation

/// Asks Claude things, through the `claude` binary rather than the HTTP API.
///
/// The API would want its own key and its own prepaid credits — a second bill on top of the
/// Claude Code subscription that is already installed on this machine and already paid for.
/// Fleet's whole job is watching `claude` processes, so the binary is guaranteed to be here;
/// `claude -p` runs one headless turn against that same subscription. The cost is a couple of
/// seconds of process startup per request, which for a prompt nobody is watching a
/// spinner through is the right trade.
enum Claude {

    /// What the router decided to do with an utterance.
    struct Route: Decodable {
        enum Kind: String, Decodable {
            case existingProject = "existing_project"
            case newProject = "new_project"
            case general
        }
        var kind: Kind
        /// Directory name of the project, or the proposed name for a new one. Empty for
        /// `general` — a life question has no project.
        var project: String
        /// The utterance cleaned into a prompt: filler and the project name stripped out, so
        /// the session is not handed "hey in fleet can you uh fix the click thing".
        var prompt: String
    }

    enum Failure: LocalizedError {
        case notInstalled
        case failed(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Could not find the claude command. Fleet runs it to route what you say."
            case .failed(let why):
                return "claude exited with an error: \(why)"
            case .malformed(let what):
                return "Unexpected reply from claude: \(what)"
            }
        }
    }

    /// Cheap and fast, because it runs on every prompt before anything visible happens.
    /// The routing decision is a classification, not the work itself.
    private static let classifierModel = "haiku"
    /// The model that actually answers a general question.
    private static let answerModel = "opus"

    /// A headless turn that hangs would leave the panel saying "thinking…" forever.
    private static let timeout: TimeInterval = 90

    // MARK: - Classification

    static func classify(_ written: String, projects: [String]) async throws -> Route {
        let known = projects.isEmpty ? "(none)" : projects.joined(separator: ", ")
        let prompt = """
        You route a written request to one of three destinations. Reply with one JSON object and \
        nothing else: {"kind": ..., "project": ..., "prompt": ...}

        Known projects on this machine: \(known)

        kind is one of:
        - "existing_project": the request is about code, a repository, a bug, a build, a deploy, \
        or anything else that belongs in a working directory. Set project to the closest match \
        from the known list — the request names it directly ("in fleet", "the portfolio site") \
        or implies it. If it is clearly code work but no known project fits, still use \
        existing_project with an empty project.
        - "new_project": the request is to start something that does not exist yet ("build me a \
        CLI that…", "start a new app for…"). Set project to a short kebab-case directory name.
        - "general": anything else — a factual question, a life question, a decision, a piece of \
        writing. Set project to an empty string.

        Set prompt to the request rewritten as a clear instruction: drop filler and the project \
        name, keep every detail that matters. Never answer the request yourself.

        The request is written in \(Config.language), possibly through a dictation tool, so it \
        may contain transcription errors — read through an obvious mis-hearing rather than \
        taking it literally. Write prompt in \(Config.language).

        The request: \(written)
        """

        let text = try await run(prompt: prompt, model: classifierModel)
        guard let json = firstJSONObject(in: text),
              let data = json.data(using: .utf8),
              let route = try? JSONDecoder().decode(Route.self, from: data) else {
            throw Failure.malformed(text)
        }
        return route
    }

    /// The CLI wraps its answer in a fenced code block whatever the prompt says, and may add a
    /// sentence either side of it, so the object is found rather than assumed. Brace counting
    /// rather than a regex: the payload contains quoted prose that can hold braces of its own.
    private static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < text.endIndex {
            let c = text[index]
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Answering

    /// A general question, answered on the panel. The panel is a glance and not a document,
    /// hence the tight instruction.
    static func answer(_ question: String) async throws -> String {
        let prompt = """
        Answer in \(Config.language), in at most four sentences of plain prose. No headings, \
        no bullet lists, no markdown, no code fences: the reply is shown on a small panel, and \
        anything longer than a few lines does not fit on it. Lead with the answer itself; add a \
        caveat only when it changes what the answer means.

        The question may have been dictated, so it can contain transcription errors. If a word \
        is clearly mis-heard, answer what was obviously meant. If the question is genuinely \
        unintelligible, say so in one sentence rather than answering something adjacent.

        \(question)
        """
        return try await run(prompt: prompt, model: answerModel)
    }

    // MARK: - Running the binary

    private static func run(prompt: String, model: String) async throws -> String {
        guard let binary = binaryPath() else { throw Failure.notInstalled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-p", prompt, "--model", model, "--output-format", "json"]
        // Run somewhere disposable. A headless turn writes a transcript into whatever
        // directory it starts in, and starting in a real project would drop a stray session
        // into that project's history — which Fleet itself would then display as a tile.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Drained while the turn runs, not after it. A pipe holds 64KB; past that the child
        // blocks on write until someone reads, and reading only from the termination handler
        // means nobody does until it exits — so it never exits. A verbose answer or a stack
        // trace on stderr is enough to hit that, and the symptom is a hang, not an error.
        let output = PipeDrain(out)
        let errors = PipeDrain(err)

        return try await withCheckedThrowingContinuation { continuation in
            // One resume, whichever of the two paths gets there first: a process that both
            // times out and then exits would otherwise resume the continuation twice, which
            // traps.
            let done = Resumed()

            process.terminationHandler = { proc in
                guard done.claim() else { return }
                let stdout = output.finish()
                let stderr = errors.finish()
                guard proc.terminationStatus == 0 else {
                    continuation.resume(throwing: Failure.failed(
                        stderr.isEmpty ? "exit \(proc.terminationStatus)" : stderr))
                    return
                }
                do {
                    continuation.resume(returning: try text(fromEnvelope: stdout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            do {
                try process.run()
            } catch {
                guard done.claim() else { return }
                continuation.resume(throwing: Failure.failed(error.localizedDescription))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                guard done.claim() else { return }
                continuation.resume(throwing: Failure.failed("timed out after \(Int(timeout))s"))
            }
        }
    }

    /// `--output-format json` wraps the reply in a result envelope carrying cost and timing.
    /// Only the text is wanted; the rest is why this is not just reading stdout.
    private static func text(fromEnvelope stdout: String) throws -> String {
        guard let data = stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed(stdout)
        }
        if object["is_error"] as? Bool == true {
            throw Failure.failed(object["result"] as? String ?? stdout)
        }
        guard let result = object["result"] as? String, !result.isEmpty else {
            throw Failure.malformed(stdout)
        }
        return stripFences(result).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The CLI fences code and JSON even when told not to, and the fence is not part of the
    /// answer in either use.
    private static func stripFences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else { return text }
        var lines = trimmed.components(separatedBy: .newlines)
        lines.removeFirst()                             // ``` or ```json
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Where `claude` lives. A LaunchAgent inherits almost no `PATH`, so the usual install
    /// locations are checked directly rather than trusting a lookup to find anything.
    ///
    /// Resolved once per launch. The miss path spawns a login shell — a fifth of a second of
    /// someone's `.zshrc` — and doing that on every utterance would be felt.
    static func binaryPath() -> String? {
        cacheLock.lock()
        if let cached { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        // Only a hit is remembered. A miss means `claude` is not installed, which is already
        // a dead end for every caller — there is no repeat cost worth caching, and re-probing
        // means an install part-way through a session is picked up.
        let found = locateBinary()
        cacheLock.lock()
        cached = found
        cacheLock.unlock()
        return found
    }

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cached: String?

    private static func locateBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",                 // native installer
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.npm-global/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort for install layouts not listed above: ask a login shell, which does have
        // the user's PATH. Only reached when every known location missed, so the cost of
        // spawning a shell is not on any normal path.
        return loginShellLookup()
    }

    private static func loginShellLookup() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let found, !found.isEmpty,
              FileManager.default.isExecutableFile(atPath: found) else { return nil }
        return found
    }
}

/// Collects a pipe's output as the child writes it, rather than in one read after it exits.
private final class PipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private var closed = false

    init(_ pipe: Pipe) {
        handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return }
            data.append(chunk)
        }
    }

    /// Everything written, once the process is known to be gone. Reads the tail itself rather
    /// than trusting the last callback to have landed: the termination handler and the
    /// readability callback run on different queues and can arrive in either order.
    func finish() -> String {
        handle.readabilityHandler = nil
        let tail = (try? handle.readToEnd()) ?? Data()
        lock.lock()
        defer { lock.unlock() }
        closed = true                       // a callback still in flight appends nothing more
        data.append(tail)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// A one-shot latch, so two racing callbacks cannot resume the same continuation.
private final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
