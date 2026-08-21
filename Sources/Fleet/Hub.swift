import Foundation

/// A triaged mail, as the phone's engine filed it. One document of the `mail` collection.
struct Mail: Identifiable {
    var id: String
    /// The engine's headline for the thread — a few words, already the shortest honest version.
    var gist: String
    /// A sentence or two of what it says, written by the scoring pass.
    var summary: String
    var sender: String
    /// 1–3, the engine's score. 3 is the mail you would be annoyed to have missed.
    var importance: Int
    var receivedAt: Date

    init?(_ doc: Firestore.Document) {
        // `state` is absent on everything the engine has written and nobody has touched, and
        // the phone reads absent as "new" — so this has to, or the column shows only the mail
        // that has already been handled.
        let state = doc.fields["state"]?.stringValue ?? "new"
        guard state == "new",
              !doc.bool("archived"),
              !doc.bool("trashRequested") else { return nil }

        id = doc.id
        gist = doc.string("gist")
        summary = doc.string("summary")
        sender = doc.string("sender")
        importance = doc.int("importance", default: 2)
        receivedAt = doc.date("receivedAt") ?? doc.date("createdAt") ?? .distantPast
    }
}

/// One line of the todo list. The collection has a `state`, but in practice it only ever holds
/// `todo` and `done` — the middle pile the phone's UI offers goes unused — so this is simply
/// everything not yet done.
struct Todo: Identifiable {
    var id: String
    var name: String
    var createdAt: Date

    init?(_ doc: Firestore.Document) {
        guard doc.string("state") != "done" else { return nil }
        id = doc.id
        name = doc.string("name")
        createdAt = doc.date("createdAt") ?? .distantPast
    }

    /// The first line only, for a row one line tall. Some todos are a whole page — a pasted
    /// receipt, a list of refunds to chase — and rendered raw one of them fills the column.
    var title: String {
        name.split(separator: "\n", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// What the panel shows down its sides: the mail worth reading and the list of things to do,
/// both from the same Firestore project the phone uses.
///
/// Deliberately a second window onto one dataset rather than a copy of it — nothing here is
/// stored, merged or reconciled. It is read when a panel opens and forgotten when the process
/// ends, which is the whole reason it can be this small.
@MainActor
final class HubStore: ObservableObject {
    @Published private(set) var mail: [Mail] = []
    @Published private(set) var todos: [Todo] = []
    /// Why the columns are empty, when they are empty for a reason worth saying.
    @Published private(set) var failure: String?
    /// Whether a first answer has ever arrived — an empty inbox and an unfetched one look
    /// identical otherwise, and only one of them is good news.
    @Published private(set) var loaded = false

    /// The panel opens on every idle stretch, which on a quiet afternoon is often. Mail is
    /// triaged every six hours and todos come from a phone in someone's pocket; a minute of
    /// staleness is invisible either way, and it keeps a panel that opens twice in a row from
    /// making four round trips.
    private static let freshness: TimeInterval = 60

    private var fetchedAt = Date.distantPast
    private var inFlight: Task<Void, Never>?

    var isConfigured: Bool { Firestore.isConfigured }

    /// Called when the panel appears. Cheap to call — it does nothing at all most times.
    func refreshIfStale() {
        guard isConfigured,
              inFlight == nil,
              Date().timeIntervalSince(fetchedAt) > Self.freshness else { return }
        refresh()
    }

    func refresh() {
        guard isConfigured else { return }
        inFlight?.cancel()
        inFlight = Task { await load() }
    }

    private func load() async {
        do {
            // Both at once: they are independent collections and the panel is already on
            // screen waiting for them.
            async let mailDocs = Firestore.collection("mail")
            async let todoDocs = Firestore.collection("todos")
            let (mailPage, todoPage) = try await (mailDocs, todoDocs)
            guard !Task.isCancelled else { return }

            mail = mailPage.compactMap(Mail.init)
                .sorted {
                    $0.importance != $1.importance
                        ? $0.importance > $1.importance
                        : $0.receivedAt > $1.receivedAt
                }
            todos = todoPage.compactMap(Todo.init)
                .sorted { $0.createdAt < $1.createdAt }
            failure = nil
            loaded = true
            fetchedAt = Date()
        } catch {
            guard !Task.isCancelled else { return }
            NSLog("Fleet: hub fetch failed — \(error.localizedDescription)")
            // Whatever arrived last stays on screen. Empty piles are a claim, and the wrong
            // one: showing this morning's inbox is a small lie, showing "nothing to read" is
            // a large one.
            failure = loaded ? "offline" : error.localizedDescription
        }
        inFlight = nil
    }
}

/// How long ago, in the fewest characters that still say it: `3d`, `2h`, `now`. A column this
/// narrow has no room for "3 days ago", and the exact figure never matters — the question the
/// eye is asking is only whether this is from today.
func shortAge(since date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    guard seconds.isFinite, seconds > 0, date != .distantPast else { return "" }
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m"
    case ..<86_400: return "\(Int(seconds / 3600))h"
    case ..<(86_400 * 30): return "\(Int(seconds / 86_400))d"
    case ..<(86_400 * 365): return "\(Int(seconds / (86_400 * 30)))mo"
    default: return "\(Int(seconds / (86_400 * 365)))y"
    }
}
