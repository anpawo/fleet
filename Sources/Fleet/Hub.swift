import Foundation

/// A triaged mail, as the phone's engine filed it. One document of the `mail` collection.
struct Mail: Identifiable {
    var id: String
    /// The engine's headline for the thread — a few words, already the shortest honest version.
    ///
    /// Not the Gmail subject: the document has no `subject` field. `triage.mjs` has it in hand
    /// when it writes the doc and does not keep it, so this is the closest thing to one that
    /// exists in the collection.
    var gist: String
    var sender: String
    /// 1–3, the engine's score. 3 is the mail you would be annoyed to have missed.
    var importance: Int
    var receivedAt: Date
    var fromEmail: String
    /// `new` — triaged and untouched — or `ongoing`, which the phone calls Seen: something you
    /// have looked at and not finished with.
    var state: String
    /// Starred on the phone — either this mail specifically, or its sender by a standing rule.
    /// Filled in against `rules` after the fetch, since one is a property of the other document.
    var starred: Bool

    init?(_ doc: Firestore.Document) {
        // `state` is absent on everything the engine has written and nobody has touched, and
        // the phone reads absent as "new" — so this has to, or the column shows only the mail
        // that has already been handled.
        let state = doc.fields["state"]?.stringValue ?? "new"
        guard state == "new" || state == "ongoing",
              !doc.bool("archived"),
              !doc.bool("trashRequested") else { return nil }

        self.state = state
        id = doc.id
        gist = doc.string("gist")
        sender = doc.string("sender")
        importance = doc.int("importance", default: 2)
        receivedAt = doc.date("receivedAt") ?? doc.date("createdAt") ?? .distantPast
        fromEmail = doc.string("fromEmail")
        starred = doc.bool("favorite")
    }
}

/// The senders marked "always important" on the phone, from the `rules` collection.
///
/// Worth reading here because the engine only applies a rule to mail it triages *after* the
/// rule was written — a sender starred this morning has a week of mail already scored as
/// ordinary. The panel applies it to what it draws, so starring somebody takes effect on the
/// next glance rather than on the next triage run.
struct StarredSenders {
    private var names: Set<String> = []
    private var emails: Set<String> = []

    init(_ docs: [Firestore.Document]) {
        for doc in docs where doc.string("type") == "star" {
            let name = doc.string("sender").lowercased()
            if !name.isEmpty { names.insert(name) }
            let email = doc.string("email").lowercased()
            if !email.isEmpty { emails.insert(email) }
        }
    }

    func covers(_ mail: Mail) -> Bool {
        names.contains(mail.sender.lowercased()) || emails.contains(mail.fromEmail.lowercased())
    }
}

/// One line of the todo list.
///
/// The collection's `state` is `todo`, `doing` or `done` — the phone's three tabs — plus one
/// this panel writes and nobody displays: see `Pile.past`.
struct Todo: Identifiable {
    var id: String
    var name: String
    var state: String
    var createdAt: Date
    /// When it was finished. Absent on everything finished before Fleet started stamping it —
    /// the phone writes `state` alone.
    var doneAt: Date?

    /// The four values `state` takes. Not an enum on the model: an unknown string must survive
    /// a round trip through here untouched, or a value the phone starts writing tomorrow gets
    /// quietly rewritten to something else by whichever of the two is older.
    enum Pile {
        static let todo = "todo"
        static let doing = "doing"
        static let done = "done"
        static let past = "past"
    }

    /// A todo typed into the panel, on screen before Firestore has confirmed it. The id is a
    /// stand-in until the write comes back with the real one.
    init(pending name: String) {
        id = UUID().uuidString
        self.name = name
        state = Pile.todo
        createdAt = Date()
    }

    init(_ doc: Firestore.Document) {
        id = doc.id
        name = doc.string("name")
        state = doc.string("state")
        createdAt = doc.date("createdAt") ?? .distantPast
        doneAt = doc.date("doneAt")
    }

    /// Still on your plate. In practice the middle pile goes unused — the phone offers it and
    /// nothing is ever in it — so this is everything not yet finished.
    var open: Bool { state != Pile.done && state != Pile.past }

    /// The first line only, for a row one line tall. Some todos are a whole page — a pasted
    /// receipt, a list of refunds to chase — and rendered raw one of them fills the column.
    /// The rest is one ⌘-click away.
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
    /// Whether the mail on show is the Seen pile rather than the new one — which is to say,
    /// whether the inbox is empty.
    @Published private(set) var showingSeen = false
    @Published private(set) var todos: [Todo] = []
    /// Why the columns are empty, when they are empty for a reason worth saying.
    @Published private(set) var failure: String?
    /// Whether the todo column has an empty row open at its top, waiting to be written into.
    @Published private(set) var composing = false
    /// What is in that row.
    @Published var draft = ""
    /// Whether that row holds the caret. Return is claimed by the panel window and handed to
    /// whichever field is being typed into, and clicking back into the prompt moves that without
    /// closing the row — so which of the two owns Return is a question about focus, not about
    /// whether the row exists.
    @Published var composerFocused = false

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

    // MARK: - Writing

    /// The + on the TODO heading.
    func compose() {
        draft = ""
        composing = true
    }

    /// Esc on the new-todo row, or the panel closing. Returns whether there was a row to close,
    /// so an Esc with nothing open falls through to whatever else wants it.
    @discardableResult
    func stopComposing() -> Bool {
        guard composing else { return false }
        composing = false
        composerFocused = false
        draft = ""
        return true
    }

    /// Return in the new-todo row. The row stays open and empty afterwards, so a list you have
    /// in your head goes down in one sitting rather than a click per line.
    func commitDraft() -> Bool {
        guard composing, composerFocused else { return false }
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !name.isEmpty else { return true }
        add(name)
        return true
    }

    /// A todo written from here, in the shape the phone writes them — `manual` and all, so a
    /// line typed on this Mac is indistinguishable from one typed in the app.
    ///
    /// On screen before it is on the network, like the ✕: the panel is a glance, and a line you
    /// just typed that is not there yet reads as a keystroke that missed. Newest last, which is
    /// where the column's own oldest-first order puts it.
    private func add(_ name: String) {
        let pending = Todo(pending: name)
        todos.append(pending)
        Task {
            do {
                let written = try await Firestore.create(in: "todos", fields: [
                    "name": ["stringValue": name],
                    "state": ["stringValue": Todo.Pile.todo],
                    "manual": ["booleanValue": true],
                    "createdAt": Firestore.timestamp(pending.createdAt),
                ])
                // The real id, so a ✕ on the row it has just become lands on the document that
                // exists rather than creating a second one under the stand-in id.
                if let index = todos.firstIndex(where: { $0.id == pending.id }) {
                    todos[index] = Todo(written)
                }
            } catch {
                NSLog("Fleet: could not add todo — \(error.localizedDescription)")
                todos.removeAll { $0.id == pending.id }
                failure = "not saved"
            }
        }
    }

    /// The ✕ on a todo. Finished, not deleted — the row leaves the column either way, and one
    /// of the two is undoable from the phone.
    ///
    /// Applied here before it is applied there, and not reconciled afterwards: the panel is
    /// about to be looked away from, and a row that hangs about for the length of a round trip
    /// reads as a click that missed.
    func markDone(_ todo: Todo) {
        todos.removeAll { $0.id == todo.id }
        Task {
            do {
                try await Firestore.patch("todos/\(todo.id)", fields: [
                    "state": ["stringValue": Todo.Pile.done],
                    "doneAt": Firestore.timestamp(Date()),
                ])
            } catch {
                NSLog("Fleet: could not finish todo \(todo.id) — \(error.localizedDescription)")
                // Put it back rather than leave the panel claiming something that did not
                // happen. The next fetch would do it too, a minute later.
                refresh()
            }
        }
    }

    /// Move whatever has been done long enough out of `done` and into `past`, and put a date on
    /// anything that has none.
    ///
    /// Fire and forget, on the same rhythm as the read: this is filing, not an interaction, and
    /// nothing on screen is waiting for it. There is no engine behind `todos` — no cron, no
    /// Action, nothing but the two apps that read it — so it happens here or it does not happen.
    private func file(_ done: [Todo]) {
        let now = Date()
        for todo in done {
            guard let doneAt = todo.doneAt else {
                stamp(todo, doneAt: now.addingTimeInterval(-Config.todoAssumedDoneAgo))
                continue
            }
            guard now.timeIntervalSince(doneAt) > Config.todoArchiveAfter else { continue }
            Task {
                try? await Firestore.patch("todos/\(todo.id)",
                                           fields: ["state": ["stringValue": Todo.Pile.past]])
                NSLog("Fleet: filed todo \(todo.id) away as past")
            }
        }
    }

    private func stamp(_ todo: Todo, doneAt: Date) {
        Task {
            try? await Firestore.patch("todos/\(todo.id)",
                                       fields: ["doneAt": Firestore.timestamp(doneAt)])
        }
    }

    // MARK: - Reading

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
            // All three at once: they are independent collections and the panel is already
            // on screen waiting for them.
            async let mailDocs = Firestore.collection("mail")
            async let todoDocs = Firestore.collection("todos")
            async let ruleDocs = Firestore.collection("rules")
            let (mailPage, todoPage, rulePage) = try await (mailDocs, todoDocs, ruleDocs)
            guard !Task.isCancelled else { return }

            let starred = StarredSenders(rulePage)
            let unread = mailPage.compactMap(Mail.init)
                .map {
                    var mail = $0
                    mail.starred = mail.starred || starred.covers(mail)
                    return mail
                }
                // Starred first, whatever the engine scored it: a standing rule about a sender
                // is a judgement you made yourself, and it outranks a guess made by a model at
                // four in the morning.
                .sorted {
                    if $0.starred != $1.starred { return $0.starred }
                    if $0.importance != $1.importance { return $0.importance > $1.importance }
                    return $0.receivedAt > $1.receivedAt
                }

            // Nothing new is good news, and a column of good news is a strip of empty black
            // taking up a sixth of the panel. What you were part-way through is the next most
            // useful thing it can hold — and the heading changes with it, because a mail you
            // have already dealt with once must not be able to pass for one that arrived.
            let fresh = unread.filter { $0.state == "new" }
            mail = fresh.isEmpty ? unread.filter { $0.state == "ongoing" } : fresh
            showingSeen = fresh.isEmpty && !mail.isEmpty
            let all = todoPage.map(Todo.init)
            todos = all.filter(\.open).sorted { $0.createdAt < $1.createdAt }
            file(all.filter { $0.state == Todo.Pile.done })
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
