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
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "com.mr.fleet",
                          "-a", "firebase-api-key", "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            // Said out loud, because the failure is otherwise invisible: no key means no side
            // columns, and a panel with no side columns looks like a panel that never had them.
            NSLog("Fleet: no firebase-api-key in the Keychain — the side columns stay hidden")
            return nil
        }
        return key
    }()

    /// Whether the side columns have any chance of filling — a machine without the key gets no
    /// columns at all rather than two empty ones apologising for themselves.
    static var isConfigured: Bool { apiKey != nil }

    enum Failure: LocalizedError {
        case noKey
        case http(status: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "No Firebase key in the Keychain"
            case .http(let status, let body):
                return "HTTP \(status): \(body.prefix(200))"
            }
        }
    }

    /// One whole collection, small enough that paging and server-side filtering would both be
    /// more machinery than the data deserves: `mail` holds a dozen documents and `todos` a
    /// couple of dozen. Everything is filtered on this side, which also sidesteps needing a
    /// composite index for every ordering the panel might want.
    static func collection(_ name: String, pageSize: Int = 300) async throws -> [Document] {
        var request = URLRequest(url: Firestore.documents
            .appending(path: name)
            .appending(queryItems: [URLQueryItem(name: "pageSize", value: String(pageSize))]))
        request.setValue("Bearer \(try await FirestoreAuth.shared.token())",
                         forHTTPHeaderField: "Authorization")
        return try await send(request, decoding: Page.self).documents
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
           let session = try? await refresh(stored) {
            keep(session)
            return session.id
        }
        let session = try await signUpAnonymously()
        keep(session)
        return session.id
    }

    private func keep(_ session: Session) {
        idToken = session.id
        expiresAt = Date().addingTimeInterval(session.lifetime)
        UserDefaults.standard.set(session.refresh, forKey: Self.refreshKey)
    }

    private func key() throws -> String {
        guard let key = Firestore.apiKey else { throw Firestore.Failure.noKey }
        return key
    }

    private struct SignUpResponse: Decodable {
        let idToken: String
        let refreshToken: String
        let expiresIn: String
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
