import Foundation

/// The Firestore project behind my-hub — the phone's mail triage and todo list, read here over
/// the REST API.
///
/// No Firebase SDK, for the same reason the Toudou widget does without one (`apps/todo/mac/`
/// over in my-hub, which this is adapted from): the SDK opens a gRPC channel and keeps a local
/// cache, and Fleet wants two GETs when a panel opens and nothing at all the rest of the time.
/// A background agent that exists to save power has no business holding a socket open.
enum Firestore {
    /// Not a secret — an anonymous session can read nothing without the rules allowing it, and
    /// the rules gate on being signed in. The API key is the part that is worth keeping out of
    /// a public repo, so it lives in the Keychain.
    static let projectID = "auto-mail-bot-3b170"

    static var documents: URL {
        URL(string: "https://firestore.googleapis.com/v1/projects/\(projectID)"
            + "/databases/(default)/documents")!
    }

    /// The Firebase Web API key, from the login Keychain:
    ///
    ///     security add-generic-password -s com.mr.fleet -a firebase-api-key -w <key>
    ///
    /// Same reasoning as every other secret this app reads: Fleet runs from a LaunchAgent,
    /// which inherits almost no environment, so an exported variable works under `swift run`
    /// and silently stops working after a login. The environment is still honoured as an
    /// override, because it is the only thing a one-off `swift run` can set.
    static let apiKey: String? = {
        if let env = ProcessInfo.processInfo.environment["FLEET_FIREBASE_API_KEY"],
           !env.isEmpty {
            return env
        }
        guard let key = keychain("firebase-api-key") else {
            // Said out loud, because the failure is otherwise invisible: no key means no side
            // columns, and a panel with no side columns looks like a panel that never had them.
            NSLog("Fleet: no firebase-api-key in the Keychain — the side columns stay hidden")
            return nil
        }
        return key
    }()

    /// The owner account this Mac signs in as, when there is one.
    ///
    /// A Firebase web API key is not a secret — Google ships it in every web and mobile client
    /// and says so — so rules that only ask for *somebody* signed in are rules that let anyone
    /// who has seen the key read everything. The account is what makes them mean "him".
    ///
    /// Nil until the credentials are in the Keychain, and the sign-in falls back to anonymous
    /// then, so this Mac keeps working through the half of the migration where the rules have
    /// not been tightened yet.
    static var owner: (email: String, password: String)? {
        guard let email = keychain("firebase-owner-email"),
              let password = keychain("firebase-owner") else { return nil }
        return (email, password)
    }

    /// One login-Keychain item, by account name under the `com.mr.fleet` service.
    static func keychain(_ account: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "com.mr.fleet", "-a", account, "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Whether the side columns have any chance of filling — a machine without the key gets no
    /// columns at all rather than two empty ones apologising for themselves.
    static var isConfigured: Bool { apiKey != nil }

    enum Failure: LocalizedError {
        case noKey
        case http(status: Int, body: String)
        case unread
        case budget

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "No Firebase key in the Keychain"
            case .unread:
                return "nothing kept to draw from, and this run does not read Firestore"
            case .budget:
                return "Fleet's share of the day's reads is spent, back at 09:00"
            case .http(429, _):
                return "daily read quota exhausted, resets at 09:00"
            case .http(let status, let body):
                return "HTTP \(status): \(body.prefix(200))"
            }
        }
    }

    /// One whole collection, small enough that paging and server-side filtering would both be
    /// more machinery than the data deserves: `mail` holds a dozen documents and `todos` a
    /// couple of dozen. Everything is filtered on this side, which also sidesteps needing a
    /// composite index for every ordering the panel might want.
    ///
    /// `age` is how old a kept copy of it may be and still stand in for the read: what the
    /// caller would have waited before asking again anyway, so that a restart costs nothing.
    static func collection(_ name: String, pageSize: Int = 300,
                           reusing age: TimeInterval = 0) async throws -> [Document] {
        if let kept = try withoutAsking(name, reusing: age) { return kept }
        var request = URLRequest(url: Firestore.documents
            .appending(path: name)
            .appending(queryItems: [URLQueryItem(name: "pageSize", value: String(pageSize))]))
        request.setValue("Bearer \(try await FirestoreAuth.shared.token())",
                         forHTTPHeaderField: "Authorization")
        let page = try await send(request)
        let documents = try JSONDecoder().decode(Page.self, from: page).documents
        room()
        try? page.write(to: store.appending(path: name + ".json"), options: .atomic)
        // A read is billed a document, and an empty answer one.
        spend(max(1, documents.count))
        return documents
    }

    // MARK: - The day's reads

    /// What Fleet lets itself read in one of Firestore's days, in documents, of the 50k the
    /// project is given. The rest is the phone's: on 2026-10-12 this Mac had spent all of it
    /// before 16:00 — some sixty loads of four whole collections, half of them renders and
    /// benches — and nothing anywhere could read a todo until the day turned.
    static let dailyReads = 35_000

    /// Whether this process asks Firestore at all, or draws from the copies the last read
    /// kept. Turned off by the modes that draw the panel offscreen: a picture does not need
    /// this minute's mail, and thirty of them a day cost what the app itself does.
    static var reads = true

    /// Where the last read of each collection is kept, and the day's count beside them.
    static var store = URL(fileURLWithPath: Hooks.home).appending(path: "hub")

    /// What a read comes to before anything goes near the network: the kept copy, a refusal,
    /// or nil — ask Firestore. An `age` without end is "the kept copy or nothing".
    static func withoutAsking(_ name: String, reusing age: TimeInterval) throws -> [Document]? {
        let asks = reads && age < .infinity
        if let kept = kept(name, within: asks ? age : .infinity) { return kept }
        guard asks else { throw Failure.unread }
        guard spent() < dailyReads else { throw Failure.budget }
        return nil
    }

    /// The last read of a collection, if it is no older than `age`.
    static func kept(_ name: String, within age: TimeInterval = .infinity) -> [Document]? {
        guard let read = keptAt(name), Date().timeIntervalSince(read) <= age,
              let page = try? Data(contentsOf: store.appending(path: name + ".json")) else { return nil }
        return (try? JSONDecoder().decode(Page.self, from: page))?.documents
    }

    /// When that read was made.
    static func keptAt(_ name: String) -> Date? {
        let file = store.appending(path: name + ".json").path
        return (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
    }

    /// Firestore's day, which turns at midnight in California — 09:00 in Paris.
    static func quotaDay(_ now: Date = Date()) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "America/Los_Angeles")
        day.dateFormat = "yyyy-MM-dd"
        return day.string(from: now)
    }

    /// Documents read so far in Firestore's day, by every Fleet process on this Mac.
    static func spent(_ now: Date = Date()) -> Int {
        let parts = (try? String(contentsOf: store.appending(path: "reads"), encoding: .utf8))?
            .split(whereSeparator: \.isWhitespace) ?? []
        return parts.count == 2 && parts[0] == quotaDay(now) ? Int(parts[1]) ?? 0 : 0
    }

    // ponytail: read, add, write. Two processes reading in the same instant lose one of the
    // two counts; a lock, the day more than the app and the Reels job read.
    static func spend(_ documents: Int, _ now: Date = Date()) {
        room()
        try? "\(quotaDay(now)) \(spent(now) + documents)"
            .write(to: store.appending(path: "reads"), atomically: true, encoding: .utf8)
    }

    /// The mail and the todos in the clear: nobody else's to read.
    private static func room() {
        try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// Change some fields of one document, leaving the rest alone.
    ///
    /// The mask is not optional in practice: without it a PATCH *replaces* the document, so
    /// marking a todo done would take its name and its creation date down with it.
    static func patch(_ path: String, fields: [String: Any]) async throws {
        var url = Firestore.documents.appending(path: path)
        url.append(queryItems: fields.keys.map {
            URLQueryItem(name: "updateMask.fieldPaths", value: $0)
        })
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(try await FirestoreAuth.shared.token())",
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])
        _ = try await send(request)
    }

    /// A new document in a collection, with Firestore picking the id — the POST the phone's
    /// widget makes when you type a todo into it. The written document comes back, which is
    /// where the real id is.
    @discardableResult
    static func create(in collection: String, fields: [String: Any]) async throws -> Document {
        var request = URLRequest(url: Firestore.documents.appending(path: collection))
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await FirestoreAuth.shared.token())",
                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])
        return try await send(request, decoding: Document.self)
    }

    /// Gone for good, on every device. The only write here the phone cannot take back.
    static func delete(_ path: String) async throws {
        var request = URLRequest(url: Firestore.documents.appending(path: path))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(try await FirestoreAuth.shared.token())",
                         forHTTPHeaderField: "Authorization")
        _ = try await send(request)
    }

    /// Firestore's wire form for a timestamp. The phone writes a server timestamp, which over
    /// REST would need a commit with a field transform; the clock on this Mac is close enough
    /// for a field that only ever decides whether two weeks have passed.
    static func timestamp(_ date: Date) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["timestampValue": formatter.string(from: date)]
    }

    /// One place where a non-2xx becomes an error. `URLSession` hands back a 403 as a perfectly
    /// good response with the refusal in the body, and decoding that fails further along with a
    /// complaint about a missing key — which says nothing about the permission actually denied.
    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw Failure.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    static func send<T: Decodable>(_ request: URLRequest, decoding: T.Type) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(request))
    }

    // MARK: - Firestore's document shape

    struct Page: Decodable {
        let documents: [Document]

        // Absent, not empty, when the collection has nothing in it.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            documents = try container.decodeIfPresent([Document].self, forKey: .documents) ?? []
        }

        enum CodingKeys: String, CodingKey { case documents }
    }

    /// A document with its fields left in Firestore's typed-value form, unwrapped on demand by
    /// the accessors below — there are four scalar types between the two collections and a
    /// `Codable` model per shape would cost more than it explains.
    struct Document: Decodable {
        let name: String
        let fields: [String: Value]

        struct Value: Decodable {
            let stringValue: String?
            let integerValue: String?
            let doubleValue: Double?
            let timestampValue: String?
            let booleanValue: Bool?
        }

        /// Last path component of the resource name — the document id.
        var id: String { String(name.split(separator: "/").last ?? "") }

        func string(_ key: String) -> String { fields[key]?.stringValue ?? "" }
        func double(_ key: String) -> Double? { fields[key]?.doubleValue }
        func bool(_ key: String) -> Bool { fields[key]?.booleanValue ?? false }
        func int(_ key: String, default fallback: Int = 0) -> Int {
            fields[key]?.integerValue.flatMap(Int.init) ?? fallback
        }

        func date(_ key: String) -> Date? {
            guard let text = fields[key]?.timestampValue else { return nil }
            // Firestore prints fractional seconds only when it has them, and
            // `ISO8601DateFormatter` refuses whichever of the two shapes it was not told to
            // expect — so both are tried rather than assumed.
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
    }
}

/// Anonymous sign-in, by hand.
///
/// The project's rules gate every collection on `request.auth != null` and nothing more, so an
/// anonymous session is the whole key — the same one the phone signs in with silently on
/// launch.
///
/// The refresh token is kept, and that is the point of this actor: signing up again on every
/// panel would work, and would quietly grow a list of hundreds of one-shot anonymous users in
/// the project's Auth tab. One user, refreshed.
actor FirestoreAuth {
    static let shared = FirestoreAuth()

    private var idToken: String?
    private var expiresAt = Date.distantPast

    private static let refreshKey = "firestore.refreshToken"
    private static let ownerKey = "firestore.refreshTokenIsOwner"

    private struct Session {
        let id: String
        let refresh: String
        let lifetime: TimeInterval
    }

    func token() async throws -> String {
        // A minute of margin: a token that expires between this check and the request that uses
        // it is a 401 on a panel that then draws an error.
        if let token = idToken, expiresAt.timeIntervalSinceNow > 60 { return token }

        if let stored = UserDefaults.standard.string(forKey: Self.refreshKey),
           storedIsOwner == (Firestore.owner != nil),
           let session = try? await refresh(stored) {
            keep(session)
            return session.id
        }
        // The owner account if this Mac has its credentials, an anonymous one otherwise. The
        // fallback is what lets the migration happen in two steps: every client can be moved
        // to the account while the rules still accept anybody, and the rules tightened after.
        let session: Session
        if let owner = Firestore.owner {
            session = try await signIn(owner)
        } else {
            session = try await signUpAnonymously()
        }
        keep(session)
        return session.id
    }

    private func keep(_ session: Session) {
        idToken = session.id
        expiresAt = Date().addingTimeInterval(session.lifetime)
        UserDefaults.standard.set(session.refresh, forKey: Self.refreshKey)
        UserDefaults.standard.set(Firestore.owner != nil, forKey: Self.ownerKey)
    }

    /// Whether the token we are holding belongs to the owner account or to an anonymous one.
    /// Kept because the two are indistinguishable from the refresh token alone, and a Mac that
    /// has just been given credentials must stop resuming the anonymous session it had.
    private var storedIsOwner: Bool { UserDefaults.standard.bool(forKey: Self.ownerKey) }

    private func key() throws -> String {
        guard let key = Firestore.apiKey else { throw Firestore.Failure.noKey }
        return key
    }

    private struct SignUpResponse: Decodable {
        let idToken: String
        let refreshToken: String
        let expiresIn: String
    }

    /// Signing in as the one account the rules name. Same endpoint shape as the anonymous
    /// sign-up, one verb along.
    private func signIn(_ owner: (email: String, password: String)) async throws -> Session {
        var request = URLRequest(url: URL(string:
            "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key="
            + (try key()))!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": owner.email, "password": owner.password, "returnSecureToken": true,
        ])
        let body = try await Firestore.send(request, decoding: SignUpResponse.self)
        return Session(id: body.idToken,
                       refresh: body.refreshToken,
                       lifetime: TimeInterval(body.expiresIn) ?? 3600)
    }

    private func signUpAnonymously() async throws -> Session {
        var request = URLRequest(url: URL(string:
            "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(try key())")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["returnSecureToken": true])
        let body = try await Firestore.send(request, decoding: SignUpResponse.self)
        return Session(id: body.idToken,
                       refresh: body.refreshToken,
                       lifetime: TimeInterval(body.expiresIn) ?? 3600)
    }

    private struct RefreshResponse: Decodable {
        let id_token: String
        let refresh_token: String
        let expires_in: String
    }

    private func refresh(_ refreshToken: String) async throws -> Session {
        var request = URLRequest(url: URL(string:
            "https://securetoken.googleapis.com/v1/token?key=\(try key())")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=refresh_token&refresh_token=\(refreshToken)"
            .data(using: .utf8)
        let body = try await Firestore.send(request, decoding: RefreshResponse.self)
        return Session(id: body.id_token,
                       refresh: body.refresh_token,
                       lifetime: TimeInterval(body.expires_in) ?? 3600)
    }
}
