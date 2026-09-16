import Foundation

/// One Instagram Reel the phone was handed, and what became of it. A document of the
/// `factcheck` collection, keyed by the Reel's shortcode.
///
/// The phone runs its own pipeline and almost always fails at the first step — Instagram
/// serves the video to a residential IP on a good day and to nothing on the others — so most of
/// what it writes is `pending` or `failed`. This Mac is on the same kind of IP and has yt-dlp,
/// which does better; `ReelCheck` finishes what the phone started, on the same document.
struct Reel: Identifiable {
    var id: String
    var url: String
    var title: String
    var author: String
    var caption: String
    var verdict: String
    var summary: String
    var transcript: String
    /// `pending`, `done` or `failed` — the phone's own three, see its `FactCheckRepo`.
    var status: String
    var error: String
    var createdAt: Date
    /// Put away from here. Not deleted: the phone still lists it, and the verdict is still
    /// there to reread on the day the Reel comes up in conversation.
    var seen: Bool
    /// When this Mac last tried and failed. A check that failed is not retried on its own —
    /// the same private account is private tomorrow — so this is what keeps a broken link
    /// from costing a download attempt every five minutes.
    var fleetTriedAt: Date?
    var fleetError: String
    /// Written by the sparkle, for a Reel that was not something to do: what kind of thing it
    /// was, from `Category`, and the one line worth remembering it by. Both absent until then.
    var category: String
    var reminder: String

    init(_ doc: Firestore.Document) {
        id = doc.id
        url = doc.string("url")
        title = doc.string("title")
        author = doc.string("author")
        caption = doc.string("caption")
        verdict = doc.string("verdict")
        summary = doc.string("summary")
        transcript = doc.string("transcript")
        status = doc.fields["status"]?.stringValue ?? "done"
        error = doc.string("error")
        // The phone writes epoch milliseconds, not a timestamp.
        let millis = doc.int("createdAt")
        createdAt = millis > 0 ? Date(timeIntervalSince1970: Double(millis) / 1000) : .distantPast
        seen = doc.bool("seen")
        fleetTriedAt = doc.date("fleetTriedAt")
        fleetError = doc.string("fleetError")
        category = doc.string("category")
        reminder = doc.string("reminder")
    }

    /// The shelves a filed Reel goes on, in the order the card pages through them. The names
    /// are what the model is asked for and what the heading shows, so the list is the schema.
    static let categories = [
        "politics", "fake news", "real info", "business / marketing", "tech", "health",
        "culture", "entertainment", "other",
    ]

    var filed: Bool { !category.isEmpty }

    /// Unfiled first, newest first — those are the ones to read — then shelf by shelf.
    static func before(_ a: Reel, _ b: Reel) -> Bool {
        if a.filed != b.filed { return !a.filed }
        let ia = categories.firstIndex(of: a.category) ?? categories.count
        let ib = categories.firstIndex(of: b.category) ?? categories.count
        if ia != ib { return ia < ib }
        return a.createdAt > b.createdAt
    }

    var checked: Bool { status == "done" }
    var needsCheck: Bool { !checked && fleetTriedAt == nil && !seen }

    /// The phone's six verdicts folded to the four colours the panel has.
    enum Kind { case yes, no, mixed, unknown }

    var kind: Kind {
        guard checked else { return .unknown }
        switch verdict {
        case "vrai", "plutot_vrai": return .yes
        case "faux", "plutot_faux": return .no
        case "melange": return .mixed
        default: return .unknown
        }
    }

    /// What the row is called: the phone's title when it read one, else the account, else
    /// the shortcode — a list of URLs is a list nobody recognises.
    var label: String {
        let clean = Self.unescaped(title).trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        if !clean.isEmpty { return clean }
        if !author.isEmpty { return "@" + author }
        return id
    }

    /// The phone stores the title as it sits in Instagram's HTML, entities and all. The five
    /// named ones it uses and the numeric form, which covers the curly quotes and the ellipsis.
    static func unescaped(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, char) in [("&quot;", "\""), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&#39;", "'")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        while let range = out.range(of: "&#x[0-9a-fA-F]+;", options: .regularExpression) {
            let hex = out[range].dropFirst(3).dropLast()
            let char = UInt32(hex, radix: 16).flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? ""
            out.replaceSubrange(range, with: char)
        }
        return out
    }

    /// The word under the dot, in the verdict's own colour.
    var badge: String {
        guard checked else { return fleetTriedAt == nil ? "to check" : "out of reach" }
        switch verdict {
        case "vrai": return "true"
        case "plutot_vrai": return "mostly true"
        case "melange": return "mixed"
        case "plutot_faux": return "mostly false"
        case "faux": return "false"
        default: return "unverifiable"
        }
    }
}

/// Link in, verdict out — the phone's pipeline, run from this Mac.
///
///     yt-dlp → .mp4 → ffmpeg → .wav → whisper.cpp → transcript → claude -p (web search) → JSON
///
/// Each step is a binary already installed for other reasons, called by absolute path because a
/// LaunchAgent has no `PATH`. Everything a step writes lands in one directory under the temp
/// folder, kept afterwards: when a check goes wrong the `.err` file of the step that broke is
/// the diagnosis, and the phone's history of "The coroutine scope left the composition" is what
/// a pipeline with no trace looks like.
///
/// ponytail: audio only. A Reel with nothing spoken is handed over on its caption alone; the
/// phone reads three stills with a vision model instead. Add that when a silent Reel matters.
enum ReelCheck {
    enum Failure: LocalizedError {
        case step(String, String)
        var errorDescription: String? {
            if case let .step(name, why) = self { return "\(name): \(why)" }
            return nil
        }
    }

    private static let ytdlp = "/opt/homebrew/bin/yt-dlp"
    private static let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    private static let whisper = "/opt/homebrew/bin/whisper-cli"
    private static let models = NSHomeDirectory() + "/.local/share/whisper"

    /// Run the whole thing on one Reel and write the outcome to its document, whichever way it
    /// went. Never throws: the caller is a timer, and the document is where the answer goes.
    static func run(_ reel: Reel, progress: @escaping (String) -> Void = { _ in }) async {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "fleet-reels").appending(path: reel.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSLog("Fleet: checking reel \(reel.id) in \(dir.path)")
        do {
            let fields = try await check(reel, in: dir, progress: progress)
            try await Firestore.patch("factcheck/\(reel.id)", fields: fields)
            NSLog("Fleet: reel \(reel.id) — \(fields["verdict"].map { "\($0)" } ?? "?")")
        } catch {
            NSLog("Fleet: reel \(reel.id) failed — \(error.localizedDescription)")
            try? await Firestore.patch("factcheck/\(reel.id)", fields: [
                "fleetError": ["stringValue": String(error.localizedDescription.prefix(500))],
                "fleetTriedAt": Firestore.timestamp(Date()),
            ])
        }
    }

    /// The fields a finished check writes — the same ones the phone writes, so its own screen
    /// shows this verdict like any of its own, plus two that say who did it.
    static func check(_ reel: Reel, in dir: URL,
                      progress: (String) -> Void = { _ in }) async throws -> [String: Any] {
        let url = reel.url.isEmpty ? "https://www.instagram.com/reel/\(reel.id)/" : reel.url
        progress("Downloading\u{2026}")
        try await exec(ytdlp, ["-q", "--no-warnings", "--socket-timeout", "20", "--no-playlist",
                               "-o", "reel.%(ext)s",
                               "--print-to-file", "%(uploader)s\n%(description)s", "meta.txt",
                               url], in: dir, step: "yt-dlp", timeout: 180)
        let meta = (try? String(contentsOf: dir.appending(path: "meta.txt"), encoding: .utf8)) ?? ""
        let author = reel.author.isEmpty
            ? String(meta.split(separator: "\n", maxSplits: 1).first ?? "") : reel.author
        let caption = reel.caption.isEmpty
            ? String(meta.split(separator: "\n", maxSplits: 1).dropFirst().first ?? "") : reel.caption

        guard let video = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
            .first(where: { $0.hasPrefix("reel.") }) else {
            throw Failure.step("yt-dlp", "no video written")
        }
        progress("Transcribing\u{2026}")
        try await exec(ffmpeg, ["-loglevel", "error", "-y", "-i", video, "-vn", "-ac", "1",
                                "-ar", "16000", "-c:a", "pcm_s16le", "audio.wav"],
                       in: dir, step: "ffmpeg", timeout: 120)
        // Four threads: a Reel is a minute or two and takes a third of that to transcribe, and
        // the machine has to stay usable while it does — this runs whether or not you are here.
        let transcript = try await exec(whisper, ["-m", models + "/ggml-large-v3-q5_0.bin",
                                                  "-f", "audio.wav", "-l", "auto",
                                                  "--vad", "-vm", models + "/ggml-silero-v5.1.2.bin",
                                                  "-t", "4", "-np", "-nt"],
                                        in: dir, step: "whisper", timeout: 900)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty || !caption.isEmpty else {
            throw Failure.step("whisper", "nothing spoken and no caption")
        }

        progress("Checking on the web\u{2026}")
        let verdict = try await Claude.factCheck(transcript: transcript, caption: caption,
                                                 author: author)
        try? JSONSerialization.data(withJSONObject: verdict, options: .prettyPrinted)
            .write(to: dir.appending(path: "verdict.json"))

        let claims = (verdict["claims"] as? [[String: Any]] ?? []).compactMap { claim -> [String: Any]? in
            let statement = (claim["affirmation"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !statement.isEmpty else { return nil }
            let sources = (claim["sources"] as? [String] ?? []).filter { $0.hasPrefix("http") }
            return ["mapValue": ["fields": [
                "statement": ["stringValue": statement],
                "verdict": ["stringValue": Self.verdictOf(claim["verdict"])],
                "explanation": ["stringValue": claim["explication"] as? String ?? ""],
                "sources": ["arrayValue": ["values": sources.map { ["stringValue": $0] }]],
            ]]]
        }
        let confidence = min(max((verdict["confiance"] as? NSNumber)?.intValue ?? 0, 0), 100)
        return [
            "status": ["stringValue": "done"],
            "error": ["stringValue": ""],
            "verdict": ["stringValue": verdictOf(verdict["verdict"])],
            "confidence": ["integerValue": String(confidence)],
            "summary": ["stringValue": (verdict["resume"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)],
            "claims": ["arrayValue": ["values": claims]],
            "transcript": ["stringValue": transcript],
            "author": ["stringValue": author],
            "caption": ["stringValue": caption],
            "checkedBy": ["stringValue": "fleet"],
            "checkedAt": Firestore.timestamp(Date()),
        ]
    }

    /// The phone's six verdicts and nothing else — an unknown word becomes "invérifiable"
    /// rather than a colour the panel has no meaning for.
    private static let verdicts: Set<String> = [
        "vrai", "plutot_vrai", "melange", "plutot_faux", "faux", "invérifiable",
    ]

    private static func verdictOf(_ raw: Any?) -> String {
        let word = (raw as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        return verdicts.contains(word) ? word : "invérifiable"
    }

    /// One step. Output goes to files rather than pipes — nothing to drain, nothing to deadlock
    /// on, and a trace left behind — and a step that overruns is killed and named.
    @discardableResult
    private static func exec(_ binary: String, _ args: [String], in dir: URL, step: String,
                             timeout: TimeInterval) async throws -> String {
        let out = dir.appending(path: step + ".out")
        let err = dir.appending(path: step + ".err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.currentDirectoryURL = dir
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        do { try process.run() } catch {
            throw Failure.step(step, error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw Failure.step(step, "timed out after \(Int(timeout))s")
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard process.terminationStatus == 0 else {
            let tail = ((try? String(contentsOf: err, encoding: .utf8)) ?? "")
                .split(separator: "\n").suffix(3).joined(separator: " ")
            throw Failure.step(step, tail.isEmpty ? "exit \(process.terminationStatus)" : tail)
        }
        return (try? String(contentsOf: out, encoding: .utf8)) ?? ""
    }
}
