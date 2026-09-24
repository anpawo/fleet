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
        /// What it pays in ECTS once it is signed off, when the scan knew.
        var credits: Int?
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
            /// The ECTS the module is worth. Absent until the scan finds where my.epitech
            /// keeps them — the card simply says nothing rather than guessing a number.
            let credits: Int?
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
        /// The probe of calendar access, not a reader: a green run that silently writes nothing
        /// was the failure that actually happened, five times in ten days.
        let calendar: Int?

        /// The ones that failed, each as a sentence: what broke, and what you are therefore
        /// not seeing. The bar over the fleet has a line to say it in, and "edsquare" on its
        /// own left the second half — the part that matters — to be remembered.
        ///
        /// `scanRefuted` drops the scan's own verdict and only that one: when a later rescan
        /// has written a state newer than this file, the scan has been re-run and passed —
        /// while outlook, discord, edsquare and the calendar probe were not re-run at all and
        /// their codes still stand. Dropping all six on one timestamp is how a dead outlook
        /// token would go quiet for six hours.
        /// Said once, read in two places: the bar drops this line — and only this one — as
        /// soon as the network is back, since the readers catch up by themselves.
        static let outage = "no network"

        /// The name of each reader that came back broken, and nothing else. The bar is read
        /// sideways on the way past: what it is for is knowing which run to go and look at,
        /// and a clause of explanation per reader is three of them across the panel.
        ///
        /// A reader whose credential is what died says `login`, because that one is a thing
        /// to go and do rather than a run to look at.
        func broken(scanRefuted: Bool = false) -> [String] {
            // A morning with no wifi fails every reader at once, and the bar then carries three
            // red names that all say the same thing and none of which is something to do.
            if offline(scanRefuted: scanRefuted) { return [Self.outage] }
            var out: [String] = []
            if let scan, scan != 0, !scanRefuted {
                out.append(scan == 3 ? "epitech login" : "epitech scan")
            }
            // Only a 3 is a dead token — `outlook.mjs` exits 3 when Microsoft refuses the
            // refresh, 4 on an IMAP error and 1 when the network is not there. Sending you off
            // to log in for a morning with no wifi is the one mistake the name can make.
            if let outlook, outlook != 0 { out.append(outlook == 3 ? "outlook login" : "outlook") }
            if let edsquare, edsquare != 0 { out.append("edsquare") }
            // Same rule as outlook: 3 is the only code `discord.mjs` uses for a refused token.
            if let discord, discord != 0 { out.append(discord == 3 ? "discord login" : "discord") }
            if let calendar, calendar != 0 { out.append("agenda") }
            return out
        }

        /// A 3 is the one code either reader uses for a refusal that survives the network being
        /// back — `scan.mjs` for a dead my.epitech session, `outlook.mjs` for a refresh Microsoft
        /// turned down. One of those on the run means the keys really are the problem, however
        /// many other readers went down beside it.
        private func offline(scanRefuted: Bool) -> Bool {
            if scan == 3 || outlook == 3 { return false }
            let codes = [scanRefuted ? nil : scan, outlook, edsquare, discord, calendar]
                .compactMap { $0 }
            // One reader that came back with a 0 read the network, so the others fell over
            // something of their own — on 24/09 at 8h my.epitech timed out and edsquare and
            // discord went down with it while outlook was pulling forty mails.
            if codes.contains(0) { return false }
            return codes.filter { $0 != 0 }.count >= 2
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

        // Every module still open, whether or not it wants anything handed in: the card is now
        // the term at a glance — what you are in, what it pays, when it closes — and a module
        // with nothing due is still a module you are registered to. The count on the heading
        // stays a count of rendus, which is why it no longer matches the number of cards.
        let modules = state.registrations.compactMap { registration -> Module? in
            guard let end = date(registration.end), end > now else { return nil }
            let year = Calendar.current.component(.year,
                                                  from: date(registration.start) ?? end)
            let ids: Set<String> = Set((byUnit[registration.code] ?? []).map { $0.id })
            var rendus: [Rendu] = ids.compactMap { due[$0] }
            // What the module is graded on first, then what is merely on offer.
            rendus.sort { (a: Rendu, b: Rendu) in
                if a.date != b.date { return a.date < b.date }
                if a.optional != b.optional { return b.optional }
                return a.title < b.title
            }
            return Module(id: registration.code + registration.instance,
                          name: shortenModule(registration.name), end: end,
                          code: registration.code, instance: registration.instance,
                          credits: registration.credits,
                          year: year, rendus: rendus)
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
    ///
    /// The verdicts are only worth reading while they are about the state on screen: `run.sh`
    /// writes them once, after its readers, and a rescan that repairs the run writes a newer
    /// state.json underneath them — a morning of no wifi that cried all afternoon. Which
    /// verdict that refutes, and which it leaves standing, is `broken(scanRefuted:)`.
    private static func failure(_ state: State, readAt: Date, sources: Sources?) -> String? {
        // A state written after the verdicts means somebody re-ran the scan and it passed —
        // which refutes the scan's verdict and nothing else. A second of slack: `at` is cut to
        // the second while `generatedAt` carries milliseconds, so a run that writes both inside
        // one second would otherwise refute itself.
        let scanRefuted = sources.flatMap { date($0.at).map { $0 < readAt.addingTimeInterval(-1) } }
            ?? false
        if let broken = sources?.broken(scanRefuted: scanRefuted), !broken.isEmpty {
            return broken.joined(separator: ", ")
        }
        if state.sessionOk == false { return "epitech login" }
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

    /// The name my.epitech gives a module, minus the words that are on every card or on none.
    ///
    /// "G5 - EIP Seminar - Technical - Quality Assurance" does not fit on a line at half the
    /// block's width, and what it loses first is the only part that tells it from the other
    /// seminar. So: the year goes — every module this term is G5, and a word repeated twelve
    /// times down a column is furniture — and "Technical", which distinguishes nothing either.
    /// What is left is what the module is called when you talk about it.
    private static func shortenModule(_ name: String) -> String {
        var short = name
        if let dash = short.range(of: " - "), short.prefix(2).hasPrefix("G"),
           short[short.startIndex ..< dash.lowerBound].count <= 3,
           short[short.startIndex ..< dash.lowerBound].dropFirst().allSatisfy(\.isNumber) {
            short = String(short[dash.upperBound...])
        }
        for (long, short_) in [(" - Technical - ", " - "), ("Quality Assurance", "QA"),
                               ("Google Cloud", "GCP"), ("& Communication", "& Comms")] {
            short = short.replacingOccurrences(of: long, with: short_)
        }
        return short
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
