import Foundation

/// The Epitech side of the day, read off `~/.epitech/state.json`.
///
/// That file is the epitech-scan agent's own snapshot — my.epitech, the intra, edsquare and the
/// @epitech.eu mailbox, reconciled three times a day by launchd and left on this disk. Fleet
/// reads it and nothing else: the logins it would otherwise need are a Microsoft session, a
/// cookie jar and an MFA prompt, and every answer they would give is already in the file.
enum Epitheque {
    /// One module you are registered to and in the middle of.
    struct Module: Identifiable {
        var id: String
        var name: String
        var end: Date
    }

    struct Snapshot {
        var modules: [Module]
        /// Projects still wanting a rendu, whatever module they hang off.
        var projectsDue: Int
        /// When the scan last wrote the file — the block says so when it goes stale.
        var readAt: Date
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
            let date: String
            let kind: String
        }

        let generatedAt: String
        let registrations: [Registration]
        let deadlines: [Deadline]
    }

    static var file: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".epitech/state.json")
    }

    /// Nil when the scan has never run on this machine — which is a different thing from a term
    /// with no modules in it, and the block says so.
    static func read(now: Date = Date()) -> Snapshot? {
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }

        let modules = state.registrations.compactMap { registration -> Module? in
            guard let start = date(registration.start), let end = date(registration.end),
                  start <= now, now <= end else { return nil }
            return Module(id: registration.code + registration.instance,
                          name: registration.name, end: end)
        }.sorted { $0.end < $1.end }

        // By id: one project shows up once per unit it is listed under, and the file keeps all
        // of them — counting rows would say seventeen where there are fourteen.
        var due: Set<String> = []
        for deadline in state.deadlines where deadline.kind == "project-due" {
            if let at = date(deadline.date), at > now { due.insert(deadline.id) }
        }

        return Snapshot(modules: modules, projectsDue: due.count,
                        readAt: date(state.generatedAt) ?? .distantPast)
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
