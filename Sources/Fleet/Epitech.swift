import Foundation

/// The Epitech side of the day, read off `~/.epitech/state.json`.
///
/// That file is the epitech-scan agent's own snapshot — my.epitech, the intra, edsquare and the
/// @epitech.eu mailbox, reconciled three times a day by launchd and left on this disk. Fleet
/// reads it and nothing else: the logins it would otherwise need are a Microsoft session, a
/// cookie jar and an MFA prompt, and every answer they would give is already in the file.
enum Epitech {
    /// One module you are registered to and in the middle of.
    struct Module: Identifiable {
        var id: String
        var name: String
        var end: Date
        /// Its code on the intra, `G-ING-910` — what the module is actually called in every
        /// mail about it, and the only thing on the card you could search for.
        var code: String
        var instance: String
        /// What it still wants handed in. The card is a name and a date until you hold ⌘; this
        /// is what is underneath.
        var rendus: [Rendu]
    }

    /// A project of a module, still to hand in.
    struct Rendu: Identifiable {
        var id: String
        var title: String
        var date: Date
        /// The User Groups tag their projects `[PRIMARY]` or `[SECONDARY]` in the name itself:
        /// the primary ones are what the module is graded on, the secondary ones are there to
        /// be taken if you want them. Kept as a flag rather than left in the title, where it
        /// cost a third of the width on every line.
        var optional = false
    }

    struct Snapshot {
        var modules: [Module]
        /// Projects still wanting a rendu, whatever module they hang off.
        var projectsDue: Int
        /// Credits banked this school year, out of the sixty a year is worth. Nil when the scan
        /// predates the intra read, or when the intra would not answer.
        var credits: Int?
        /// What the scan could not reach — a dead cookie, mostly. The block says so out loud:
        /// a session that has quietly expired otherwise looks exactly like a calm week.
        var failure: String?
        /// When the scan last wrote the file — the block says so when it goes stale.
        var readAt: Date
    }

    /// Sixty ECTS is what a year at Epitech is worth. Not read from anywhere: it is the rule,
    /// and the intra reports the year's tally against it without ever stating it.
    static let creditsPerYear = 60

    private struct State: Decodable {
        struct Registration: Decodable {
            let code: String
            let instance: String
            let name: String
            let start: String
            let end: String
        }

        struct Deadline: Decodable {
            let id: String
            let title: String
            let date: String
            let kind: String
            /// The module's code. Absent on the deadlines that belong to no module.
            let unit: String?
        }

        struct Intra: Decodable {
            let ok: Bool
            let credits: Int?
            let error: String?
        }

        struct Edsquare: Decodable {
            let ok: Bool?
        }

        let generatedAt: String
        let registrations: [Registration]
        let deadlines: [Deadline]
        let sessionOk: Bool?
        let errors: [String]?
        let intra: Intra?
        let edsquare: Edsquare?
    }

    static var file: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".epitech/state.json")
    }

    /// What each reader came back with on the last run — written by `run.sh`, one exit code per
    /// source. A non-zero code is a key or a token that no longer passes.
    struct Sources: Decodable {
        let at: String
        let scan: Int?
        let edsquare: Int?
        let outlook: Int?
        /// Null on the runs where it does not go out: Discord is read once a day, at eight.
        let discord: Int?

        /// The ones that failed, named as the block should say them.
        var broken: [String] {
            var out: [String] = []
            if let scan, scan != 0 { out.append(scan == 3 ? "epitech session" : "epitech scan") }
            if let outlook, outlook != 0 { out.append("outlook token") }
            if let edsquare, edsquare != 0 { out.append("edsquare") }
            if let discord, discord != 0 { out.append("discord token") }
            return out
        }
    }

    /// Nil when the scan has never run on this machine — which is a different thing from a term
    /// with no modules in it, and the block says so.
    static func read(from file: URL = Epitech.file, now: Date = Date()) -> Snapshot? {
        // Beside state.json, whatever state.json is — so a fixture can carry its own verdicts.
        let sourcesFile = file.deletingLastPathComponent().appending(path: "sources.json")
        let sources = (try? Data(contentsOf: sourcesFile))
            .flatMap { try? JSONDecoder().decode(Sources.self, from: $0) }
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }

        // By id: the file repeats a deadline once per unit it is listed under, so counting rows
        // would say more than there are.
        var due: [String: Rendu] = [:]
        for deadline in state.deadlines where deadline.kind == "project-due" {
            guard let at = date(deadline.date), at > now else { continue }
            due[deadline.id] = Rendu(id: deadline.id, title: shorten(deadline.title), date: at,
                                     optional: deadline.title.contains("[SECONDARY]"))
        }
        let byUnit = Dictionary(grouping: state.deadlines.filter { due[$0.id] != nil },
                                by: { $0.unit ?? "" })

        // Only what still wants handing in. A module with nothing due is a line you read past
        // — School Life runs all year and asks for nothing — and the count on the heading is a
        // count of rendus, so what is listed under it had better add up to it.
        let modules = state.registrations.compactMap { registration -> Module? in
            guard let end = date(registration.end) else { return nil }
            let ids: Set<String> = Set((byUnit[registration.code] ?? []).map { $0.id })
            var rendus: [Rendu] = ids.compactMap { due[$0] }
            guard !rendus.isEmpty else { return nil }
            // What the module is graded on first, then what is merely on offer.
            rendus.sort { (a: Rendu, b: Rendu) in
                if a.date != b.date { return a.date < b.date }
                if a.optional != b.optional { return b.optional }
                return a.title < b.title
            }
            return Module(id: registration.code + registration.instance,
                          name: registration.name, end: end,
                          code: registration.code, instance: registration.instance,
                          rendus: rendus)
        }.sorted { ($0.rendus.first?.date ?? $0.end) < ($1.rendus.first?.date ?? $1.end) }

        let readAt = date(state.generatedAt) ?? .distantPast
        return Snapshot(modules: modules, projectsDue: due.count,
                        credits: state.intra?.ok == true ? state.intra?.credits : nil,
                        failure: failure(state, readAt: readAt, sources: sources),
                        readAt: readAt)
    }

    /// Why what is on screen may not be true any more, in the fewest words that say it.
    ///
    /// A scan whose Microsoft session has died exits before it writes anything, so the loudest
    /// signal is the file's own age: today's modules and last Tuesday's look identical. Six
    /// hours is two missed runs — the scan goes three times a day.
    private static func failure(_ state: State, readAt: Date, sources: Sources?) -> String? {
        if let broken = sources?.broken, !broken.isEmpty { return broken.joined(separator: ", ") }
        if state.sessionOk == false { return "epitech session" }
        if let intra = state.intra, !intra.ok { return "intra cookie" }
        if state.edsquare?.ok == false { return "edsquare" }
        if let errors = state.errors, !errors.isEmpty { return errors[0] }
        // Fourteen hours, not six: the scan goes out at eight, two and eight, so the longest
        // honest silence is the twelve hours of a night. Six would have cried every morning.
        if Date().timeIntervalSince(readAt) > 14 * 3600 {
            return "scan \(shortAge(since: readAt)) old"
        }
        return nil
    }

    /// "Rendu — [PRIMARY] - Cloud Architecting (User Group - AWS)" is the scan's line, written
    /// to stand alone in a todo list. On a card already filed under its module, the word Rendu
    /// and the module's own name in brackets are both things you can read off the card.
    private static func shorten(_ title: String) -> String {
        var short = title
        if let dash = short.range(of: "Rendu \u{2014} ") { short = String(short[dash.upperBound...]) }
        for tag in ["[PRIMARY] - ", "[SECONDARY] - "] where short.hasPrefix(tag) {
            short = String(short.dropFirst(tag.count))
        }
        if short.hasSuffix(")"), let open = short.lastIndex(of: "(") {
            short = String(short[short.startIndex ..< open])
        }
        return short.trimmingCharacters(in: .whitespaces)
    }

    private static let parser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The file mixes both spellings — `2026-09-21T06:00:02.451Z` for the stamp it writes
    /// itself, whole seconds for the dates it copies out of my.epitech.
    private static func date(_ text: String) -> Date? {
        parser.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
