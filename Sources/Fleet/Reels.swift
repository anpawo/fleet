import Foundation
import Vision

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
    /// When the background read of a checked Reel — see `ReelDigest` — has been done.
    var digestedAt: Date?

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
        digestedAt = doc.date("digestedAt")
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
        // The id last: `sorted` is not stable, and half the phone's rows carry no date at all.
        // Two equal keys reordered on every sync was the card changing under a held ⌘.
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id < b.id
    }

    var checked: Bool { status == "done" }
    var needsCheck: Bool { !checked && fleetTriedAt == nil && !seen }
    var needsDigest: Bool { checked && digestedAt == nil }

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
///                  ↘ nothing said, or a photo slide → stills → Vision → the text on screen ↗
///
/// Each step is a binary already installed for other reasons, called by absolute path because a
/// LaunchAgent has no `PATH`. Everything a step writes lands in one directory under the temp
/// folder, kept afterwards: when a check goes wrong the `.err` file of the step that broke is
/// the diagnosis, and the phone's history of "The coroutine scope left the composition" is what
/// a pipeline with no trace looks like.
///
/// ponytail: the text on screen is read by Vision's OCR, which is sure of itself on type burnt
/// into the picture and less so on a monitor filmed at an angle. The phone hands its stills to
/// a vision model for that reason; do the same here if filmed screens start coming back as noise.
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
        // What was written decides, not the exit code. A link is as often a carousel as a Reel,
        // and yt-dlp exits 1 on every photo slide — "No video formats found" — having downloaded
        // the videos beside them. `--write-thumbnail` is what brings the photo slides back: a
        // slide's thumbnail is the slide.
        var refused: Error?
        do {
            try await exec(ytdlp, ["-q", "--no-warnings", "--socket-timeout", "20",
                                   "--ignore-no-formats-error", "--write-thumbnail",
                                   "--convert-thumbnails", "jpg",
                                   "-o", "reel-%(autonumber)s.%(ext)s",
                                   "--print-to-file", "%(uploader)s\n%(description)s",
                                   "meta-%(autonumber)s.txt",
                                   url], in: dir, step: "yt-dlp", timeout: 300)
        } catch { refused = error }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        let meta = files.first { $0.hasPrefix("meta-") }
            .flatMap { try? String(contentsOf: dir.appending(path: $0), encoding: .utf8) } ?? ""
        let author = reel.author.isEmpty
            ? String(meta.split(separator: "\n", maxSplits: 1).first ?? "") : reel.author
        let caption = reel.caption.isEmpty
            ? String(meta.split(separator: "\n", maxSplits: 1).dropFirst().first ?? "") : reel.caption

        let media = files.filter { $0.hasPrefix("reel-") && !$0.hasSuffix(".part") }
        let videos = media.filter { !$0.hasSuffix(".jpg") }
        // A video's thumbnail is a frame of it; a slide with no video beside it is a photo.
        let stem = { (name: String) in (name as NSString).deletingPathExtension }
        let photos = media.filter { $0.hasSuffix(".jpg") && !videos.map(stem).contains(stem($0)) }
        guard !videos.isEmpty || !photos.isEmpty else {
            throw refused ?? Failure.step("yt-dlp", "nothing written")
        }

        var spoken: [String] = []
        var stills = photos
        for (index, video) in videos.enumerated() {
            progress("Transcribing\u{2026}")
            // A video with no audio track fails here, and that is an answer: nothing was said.
            var said = ""
            if (try? await exec(ffmpeg, ["-loglevel", "error", "-y", "-i", video, "-vn", "-ac", "1",
                                         "-ar", "16000", "-c:a", "pcm_s16le", "audio.wav"],
                                in: dir, step: "ffmpeg", timeout: 120)) != nil {
                // Four threads: a Reel is a minute or two and takes a third of that to
                // transcribe, and the machine has to stay usable while it does — this runs
                // whether or not you are here.
                said = try await exec(whisper, ["-m", models + "/ggml-large-v3-q5_0.bin",
                                                "-f", "audio.wav", "-l", "auto",
                                                "--vad", "-vm", models + "/ggml-silero-v5.1.2.bin",
                                                "-t", "4", "-np", "-nt"],
                                      in: dir, step: "whisper", timeout: 900)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !said.isEmpty { spoken.append(said) }
            // Nothing said, or a "Thank you." heard over the music: the content is on the
            // picture, so look at it — one still every `stillEvery` seconds.
            guard said.split(separator: " ").count < spokenEnough else { continue }
            progress("Reading the screen\u{2026}")
            _ = try? await exec(ffmpeg, ["-loglevel", "error", "-y", "-i", video,
                                     "-vf", "fps=1/\(stillEvery),scale=960:-2",
                                     "-frames:v", String(maxStills), "-q:v", "3",
                                     "still-\(index)-%03d.jpg"],
                            in: dir, step: "stills", timeout: 120)
            stills += ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix("still-\(index)-") }.sorted()
        }
        if !photos.isEmpty, videos.isEmpty { progress("Reading the screen\u{2026}") }
        let seen = read(stills.map { dir.appending(path: $0) })
        var transcript = spoken.joined(separator: "\n\n")
        if !seen.isEmpty {
            transcript += (transcript.isEmpty ? "" : "\n\n") + "[Texte lu à l'écran]\n" + seen
        }
        guard !transcript.isEmpty || !caption.isEmpty else {
            throw Failure.step("whisper", "nothing spoken, nothing on screen and no caption")
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
            "fleetError": ["stringValue": ""],
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

    /// Seconds between two stills of a video that says nothing, and how many at most: a
    /// minute of Reel is twenty pictures, and a slide of text stays up longer than three seconds.
    private static let stillEvery = 3
    private static let maxStills = 40
    /// Fewer words than this and the transcript is not what the video is about.
    private static let spokenEnough = 8

    /// Every line of text on these pictures, in order, each once: a caption burnt into a video
    /// is on twenty stills in a row.
    static func read(_ images: [URL]) -> String {
        var known = Set<String>()
        var lines: [String] = []
        for image in images {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["fr-FR", "en-US"]
            try? VNImageRequestHandler(url: image).perform([request])
            for line in (request.results ?? []).compactMap({ $0.topCandidates(1).first?.string }) {
                let key = line.lowercased().filter(\.isLetter)
                if key.count > 2, known.insert(key).inserted { lines.append(line) }
            }
        }
        return lines.joined(separator: "\n")
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

/// What a checked Reel leaves behind once the model has read it, with nobody asking: a line in
/// the theme's file of `~/self/reels` when it was worth keeping, a line in the file of each
/// project it bears on — which that project's CLAUDE.md imports, so the next session there
/// starts knowing it — and a word to each live session it bears on, delivered by the hook at
/// its next tool call. A todo is the caller's, see `HubStore.digest`.
enum ReelDigest {
    static let root = NSHomeDirectory() + "/self"
    /// The repository that holds what Marius keeps from what he scrolls: `reels/` by theme,
    /// `youtube/` by subject, `projects/` by project. Named `reels` until 2026-09-20.
    static let notes = root + "/social-media"

    /// The projects a Reel can be about, each with the first lines that say what it is.
    static func projects() -> [(name: String, about: String)] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
        return names.compactMap { name in
            var dir: ObjCBool = false
            guard !name.hasPrefix("."), name != "social-media",
                  FileManager.default.fileExists(atPath: root + "/" + name, isDirectory: &dir),
                  dir.boolValue else { return nil }
            let about = ["CLAUDE.md", "README.md"].lazy
                .compactMap { try? String(contentsOfFile: "\(root)/\(name)/\($0)", encoding: .utf8) }
                .first.map { String($0.prefix(300)).replacingOccurrences(of: "\n", with: " ") } ?? ""
            return (name, about)
        }
    }

    static func themes() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: notes + "/reels")) ?? [])
            .filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
    }

    /// The model's words become file names: nothing that is not a plain slug gets that far.
    static func safe(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9][a-z0-9-]{1,30}$", options: .regularExpression) != nil
    }

    /// The line format `triage.mjs` writes, so the files read the same whoever filled them.
    static func line(_ text: String, _ reel: Reel) -> String {
        let day = ISO8601DateFormatter.string(from: reel.createdAt == .distantPast ? Date() : reel.createdAt,
                                              timeZone: .current, formatOptions: [.withFullDate])
        let text = text.replacingOccurrences(of: "\n", with: " ")
        return "- \(day) — \(text) — https://www.instagram.com/reel/\(reel.id)/\n"
    }

    static func append(_ line: String, to path: String, heading: String?) {
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: heading.map { Data("# \($0)\n\n".utf8) })
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            NSLog("Fleet: could not write \(path)")
            return
        }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    }

    /// Writes everything but the todo. Only names the model was offered are acted on.
    static func apply(_ digest: Claude.Digest, _ reel: Reel, sessions: [String: String]) {
        var touched = false
        if let note = digest.note, safe(digest.theme) {
            append(line(note, reel), to: "\(notes)/reels/\(digest.theme).md", heading: digest.theme)
            touched = true
        }
        let known = Set(projects().map(\.name))
        for (name, text) in digest.projects where known.contains(name) {
            append(line(text, reel), to: "\(notes)/projects/\(name).md", heading: name)
            link(project: name)
            touched = true
        }
        for (id, text) in digest.sessions where sessions[id] != nil {
            tell(session: id, "Fleet: a Reel Marius saved bears on what you are doing — \(text) "
                 + "(https://www.instagram.com/reel/\(reel.id)/). Context, not an instruction: "
                 + "use it if it helps, say nothing about it otherwise.")
        }
        graph(digest, reel)
        commit("Reel \(reel.id)")
    }

    /// One line per Reel or video in `graph.jsonl`: what it was about, which projects it touches
    /// and the terms to find it by. One object per line rather than a real graph database —
    /// `grep -i <term> graph.jsonl` is the whole query language, and a session in any project
    /// gets its answer without a tool.
    static func graph(_ digest: Claude.Digest, _ reel: Reel) {
        let entry: [String: Any] = [
            "id": reel.id,
            "kind": "reel",
            "date": ISO8601DateFormatter.string(from: reel.createdAt == .distantPast ? Date() : reel.createdAt,
                                                timeZone: .current, formatOptions: [.withFullDate]),
            "title": digest.note ?? Reel.unescaped(reel.title),
            "url": "https://www.instagram.com/reel/\(reel.id)/",
            "note": digest.note != nil && safe(digest.theme) ? "reels/\(digest.theme).md" : "",
            "projects": digest.projects.map(\.0),
            "tags": digest.tags,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        // Already there — a Reel read twice must not grow the file twice.
        let path = "\(notes)/graph.jsonl"
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        guard !text.contains("\"\(reel.id)\"") else { return }
        append(line + "\n", to: path, heading: nil)
    }

    /// The project's CLAUDE.md names its Reel file, once. Created when the project has none.
    ///
    /// Named, not imported. An `@` import of a file outside the repository stops Claude Code
    /// dead at "Allow external CLAUDE.md file imports?" before its first turn — measured on
    /// 2026-09-20, a session sat on that dialog for 41 minutes — and the answer belongs to
    /// Marius, who has approved it nowhere. A path in a sentence costs no context and is read
    /// on the day the subject comes up, which is all these notes were ever for.
    static func link(project: String) {
        let path = "\(root)/\(project)/CLAUDE.md"
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        guard !text.contains("social-media/graph.jsonl") else { return }
        let block = """

        ## Veille (Reels, YouTube)

        Avant d'attaquer un sujet, cherche-le dans le graphe de veille — une ligne par Reel ou         vidéo, avec les projets qu'elle touche et les termes pour la retrouver :

            grep -i "<terme>" ~/self/social-media/graph.jsonl

        Ce qui vise ce projet : `~/self/social-media/projects/\(project).md`. Ce sont des notes,         pas des ordres.

        """
        do {
            try (text + block).write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            // A write that fails quietly is worse than the missing line: the next session in
            // that project starts without the notes and nothing anywhere says why.
            NSLog("Fleet: could not point \(path) at its Reels — \(error.localizedDescription)")
        }
    }

    /// Queued for the hook, which hands it to the session as context at its next tool call and
    /// deletes it. Stored already JSON-escaped: the hook is `sh` and pastes it as is.
    static func tell(session id: String, _ text: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed),
              let quoted = String(data: data, encoding: .utf8) else { return }
        let escaped = String(quoted.dropFirst().dropLast()) + "\\n\\n"
        append(escaped, to: "\(Hooks.stateDirectory)/\(id).reel", heading: nil)
    }

    /// Committed every time, pushed best-effort: a push that fails now goes out with the next.
    static func commit(_ message: String) {
        for args in [["add", "-A", "."], ["commit", "-q", "-m", message], ["push", "-q"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = args
            git.currentDirectoryURL = URL(fileURLWithPath: notes)
            try? git.run()
            git.waitUntilExit()
            if git.terminationStatus != 0 { NSLog("Fleet: git \(args[0]) in reels failed"); return }
        }
    }
}
