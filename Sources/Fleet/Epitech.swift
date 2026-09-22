import AppKit
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
        /// The school year the intra files it under — the year the registration started, which
        /// is the only part of a module's URL that is not already on the card.
        var year: Int
        var rendus: [Rendu]

        /// Its page on my.epitech — where ⌘-clicking the card lands.
        ///
        /// Not the intra, which files the same module under an instance code of its own
        /// (`PAR-5-1` where my.epitech says `PAR-1`) and answers "Incorrect code Instance" to
        /// the one we hold. This is the site the scan read it off, and the path is the API's.
        var url: URL? {
            URL(string: "https://my.epitech.eu/units/\(year)/\(code)/\(instance)")
        }
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

    /// A mail that asks something, or warns of something, said in the few words it comes down
    /// to. The scan's own agent writes these: deciding which of forty mails matters, and saying
    /// one in six words, is the judgement it is there for. Fleet only draws the line.
    struct Mail: Identifiable {
        var id: String
        var date: Date
        var gist: String
        /// It wants something done, as opposed to telling you something. Drawn louder.
        var action: Bool
        /// Where the mail itself is, when the scan knew how to say so. ⌘-clicking the card
        /// opens it; without one, the copy `run.sh` already left on this disk is opened
        /// instead — see `open(_:)`.
        var url: URL?
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
        /// What the mailbox is saying this fortnight, already sifted and shortened.
        var mails: [Mail] = []
    }

    /// Sixty ECTS is what a year at Epitech is worth. Not read from anywhere: it is the rule,
    /// and the intra reports the year's tally against it without ever stating it.
    static let creditsPerYear = 60

    /// `mails.json`, written beside `state.json` by the same agent — kept apart because the
    /// readers write `state.json` and the judgement about mails is made after they are done.
    private struct MailFile: Decodable {
        struct Item: Decodable {
            let id: String
            let date: String
            let gist: String
            let action: Bool?
            let url: String?
        }
        let mails: [Item]
    }

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

    /// Open a mail, ⌘-clicked on its card.
    ///
    /// The scan's own link when it left one. Otherwise the copy already on this disk:
    /// `run.sh` reads the fortnight's mail over IMAP into `mail.json`, whole body and all, so
    /// the mail can be read in full without a login, a browser or a round trip. Which is the
    /// point of the click — not to visit Outlook, but to see what the six words are about.
    @MainActor static func open(_ mail: Mail) {
        if let url = mail.url {
            NSWorkspace.shared.open(url)
            return
        }
        guard let text = body(ofMailID: mail.id) else { return }
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "fleet-mail-\(mail.id).txt")
        try? text.write(to: path, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(path)
    }

    /// The whole mail, out of the mailbox dump `run.sh` leaves beside `state.json`.
    private static func body(ofMailID id: String) -> String? {
        struct Box: Decodable {
            struct Message: Decodable {
                let id: String
                let date: String?
                let from: String?
                let subject: String?
                let text: String?
            }
            let messages: [Message]
        }
        let box = file.deletingLastPathComponent().appending(path: "mail.json")
        guard let data = try? Data(contentsOf: box),
              let decoded = try? JSONDecoder().decode(Box.self, from: data),
              let message = decoded.messages.first(where: { $0.id == id }) else { return nil }
        return """
        \(message.subject ?? "")
        \(message.from ?? "")
        \(message.date ?? "")

        \(message.text ?? "")
        """
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
        /// The probe of calendar access, not a reader: a green run that silently writes nothing
        /// was the failure that actually happened, five times in ten days.
        let calendar: Int?

        /// The ones that failed, each as a sentence: what broke, and what you are therefore
        /// not seeing. The bar over the fleet has a line to say it in, and "edsquare" on its
        /// own left the second half — the part that matters — to be remembered.
        var broken: [String] {
            var out: [String] = []
            if let scan, scan != 0 {
                out.append(scan == 3 ? "epitech session expired — log in again"
                                     : "epitech scan failed — my.epitech did not answer")
            }
            if let outlook, outlook != 0 { out.append("outlook token expired — no mail since the last run") }
            if let edsquare, edsquare != 0 { out.append("edsquare unreachable — no timetable this run") }
            if let discord, discord != 0 { out.append("discord token expired — announcements not read") }
            if let calendar, calendar != 0 { out.append("agenda not writable — deadlines were not filed") }
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
        let mailsFile = file.deletingLastPathComponent().appending(path: "mails.json")
        let mails = ((try? Data(contentsOf: mailsFile))
            .flatMap { try? JSONDecoder().decode(MailFile.self, from: $0) }?.mails ?? [])
            .compactMap { item -> Mail? in
                guard let at = date(item.date) else { return nil }
                return Mail(id: item.id, date: at, gist: item.gist, action: item.action ?? false,
                            url: item.url.flatMap(URL.init(string:)))
            }
            .sorted { $0.date > $1.date }
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
            let year = Calendar.current.component(.year,
                                                  from: date(registration.start) ?? end)
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
                          year: year, rendus: rendus)
        }.sorted { ($0.rendus.first?.date ?? $0.end) < ($1.rendus.first?.date ?? $1.end) }

        let readAt = date(state.generatedAt) ?? .distantPast
        return Snapshot(modules: modules, projectsDue: due.count,
                        credits: state.intra?.ok == true ? state.intra?.credits : nil,
                        failure: failure(state, readAt: readAt, sources: sources),
                        readAt: readAt,
                        mails: mails)
    }

    /// Why what is on screen may not be true any more, in the fewest words that say it.
    ///
    /// A scan whose Microsoft session has died exits before it writes anything, so the loudest
    /// signal is the file's own age: today's modules and last Tuesday's look identical. Six
    /// hours is two missed runs — the scan goes three times a day.
    ///
    /// The verdicts are only worth reading while they are about the state on screen: `run.sh`
    /// writes them once, after its readers, and a rescan that repairs the run writes a newer
    /// state.json underneath them. Older than what it judges means it is judging a run that
    /// has been replaced — a morning of no wifi that cried all afternoon.
    private static func failure(_ state: State, readAt: Date, sources: Sources?) -> String? {
        let current = sources.flatMap { date($0.at).map { $0 >= readAt } ?? true } ?? false
        if current, let broken = sources?.broken, !broken.isEmpty {
            return broken.joined(separator: ", ")
        }
        if state.sessionOk == false { return "epitech session expired — log in again" }
        if let intra = state.intra, !intra.ok { return "intra cookie expired — no credits" }
        if state.edsquare?.ok == false { return "edsquare unreachable — no timetable this run" }
        if let errors = state.errors, !errors.isEmpty { return errors[0] }
        // Fourteen hours, not six: the scan goes out at eight, two and eight, so the longest
        // honest silence is the twelve hours of a night. Six would have cried every morning.
        if Date().timeIntervalSince(readAt) > 14 * 3600 {
            return "scan \(shortAge(since: readAt)) old — nothing here is current"
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
