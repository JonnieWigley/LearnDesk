import Combine
import Foundation

struct SyncError: LocalizedError {
    let message: String
    var status = 0
    var errorDescription: String? { message }
}

/// Keeps this Mac in step with a Supabase table that the phone app also uses.
///
/// Each idea, journal entry, question and to-do is one row. A sync downloads every
/// row, keeps whichever copy of each item changed most recently, then uploads the
/// items this Mac has newer.
@MainActor
final class SyncEngine: ObservableObject {
    enum Status: Equatable {
        case off
        case idle(Date?)
        case syncing
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var signedIn = false

    private let store: Store
    private var busy = false
    private var again = false
    private var pending: Task<Void, Never>?
    private var accessToken: String?
    private var expiresAt = Date.distantPast

    init(store: Store) {
        self.store = store
        signedIn = Keychain.read(account: Keychain.syncTokenAccount) != nil && !baseURL.isEmpty
        status = signedIn ? .idle(nil) : .off
    }

    var statusText: String {
        switch status {
        case .off: return "Sync is off"
        case .idle(nil): return "Signed in"
        case .idle(let date?):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Synced at \(formatter.string(from: date))"
        case .syncing: return "Syncing…"
        case .failed(let message): return "Sync failed: \(message)"
        }
    }

    private var baseURL: String { UserDefaults.standard.string(forKey: Prefs.supabaseURL) ?? "" }
    private var anonKey: String { UserDefaults.standard.string(forKey: Prefs.supabaseKey) ?? "" }

    // MARK: Signing in

    func signIn(url: String, key: String, email: String, password: String) async throws {
        var cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleanURL.hasSuffix("/") { cleanURL.removeLast() }
        guard cleanURL.hasPrefix("https://"), cleanURL.hasSuffix(".supabase.co") else {
            throw SyncError(message: "The project URL should look like https://abcdefgh.supabase.co")
        }
        let defaults = UserDefaults.standard
        defaults.set(cleanURL, forKey: Prefs.supabaseURL)
        defaults.set(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Prefs.supabaseKey)
        defaults.set(email.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Prefs.supabaseEmail)

        let body = try JSONSerialization.data(withJSONObject: [
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
        ])
        let reply = try await send("/auth/v1/token?grant_type=password", method: "POST", body: body)
        try storeSession(reply)
        signedIn = true
        status = .idle(nil)
        await syncNow()
    }

    func signOut() {
        Keychain.write("", account: Keychain.syncTokenAccount)
        accessToken = nil
        expiresAt = .distantPast
        signedIn = false
        status = .off
    }

    private struct Session: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double?
    }

    private func storeSession(_ reply: Data) throws {
        guard let session = try? JSONDecoder().decode(Session.self, from: reply) else {
            throw SyncError(message: "Unexpected sign-in response.")
        }
        accessToken = session.access_token
        expiresAt = Date().addingTimeInterval(session.expires_in ?? 3600)
        Keychain.write(session.refresh_token, account: Keychain.syncTokenAccount)
    }

    private func validToken() async throws -> String {
        if let token = accessToken, expiresAt.timeIntervalSinceNow > 60 {
            return token
        }
        guard let refresh = Keychain.read(account: Keychain.syncTokenAccount) else {
            signOut()
            throw SyncError(message: "Signed out. Sign in again in Settings.")
        }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["refresh_token": refresh])
            let reply = try await send("/auth/v1/token?grant_type=refresh_token", method: "POST", body: body)
            try storeSession(reply)
        } catch let error as SyncError where (400..<500).contains(error.status) {
            signOut()
            throw SyncError(message: "Signed out. Sign in again in Settings.")
        }
        guard let token = accessToken else {
            throw SyncError(message: "Couldn't refresh the sign-in.")
        }
        return token
    }

    // MARK: Syncing

    /// Sync shortly after a local change, batching quick successive edits.
    func schedule() {
        guard signedIn else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard signedIn else { return }
        if busy {
            again = true
            return
        }
        busy = true
        status = .syncing
        defer {
            busy = false
            if again {
                again = false
                schedule()
            }
        }

        do {
            let token = try await validToken()
            let remote = try await fetchAll(token: token)

            // Take what the other device changed more recently.
            var merged = store.data
            let mine = Self.index(merged)
            var changed = false
            for row in remote {
                if let local = mine[row.id], local.modified >= row.modified { continue }
                if Self.apply(row, to: &merged) { changed = true }
            }
            if changed {
                merged.ideas.sort { $0.created > $1.created }
                merged.entries.sort { $0.created > $1.created }
                merged.todos.sort { $0.created > $1.created }
                store.applySynced(merged)
            }

            // Send what this Mac changed more recently.
            let theirs = Dictionary(remote.map { ($0.id, $0.modified) }, uniquingKeysWith: { max($0, $1) })
            let outgoing = try Self.rows(from: store.data).filter { row in
                guard let id = row["id"] as? String, let uuid = UUID(uuidString: id),
                      let modified = row["modified"] as? Int64
                else { return false }
                guard let remoteModified = theirs[uuid] else { return true }
                return modified > remoteModified
            }
            var start = 0
            while start < outgoing.count {
                let chunk = Array(outgoing[start..<min(start + 500, outgoing.count)])
                let body = try JSONSerialization.data(withJSONObject: chunk)
                _ = try await send("/rest/v1/items?on_conflict=id", method: "POST", body: body, token: token,
                                   prefer: "resolution=merge-duplicates,return=minimal")
                start += 500
            }
            status = .idle(Date())
        } catch {
            status = signedIn ? .failed(error.localizedDescription) : .off
        }
    }

    // MARK: Rows

    private struct Row: Decodable {
        enum Payload {
            case idea(Idea), entry(JournalEntry), card(Card), todo(TodoItem)
            case deleted
            case unknown
        }

        let id: UUID
        let kind: String
        let modified: Int64
        let payload: Payload

        enum CodingKeys: String, CodingKey {
            case id, kind, modified, deleted, data
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            kind = try container.decode(String.self, forKey: .kind)
            modified = try container.decode(Int64.self, forKey: .modified)
            if try container.decode(Bool.self, forKey: .deleted) {
                payload = .deleted
                return
            }
            // A row this version can't read is left alone rather than failing the whole sync.
            switch kind {
            case "idea": payload = (try? container.decode(Idea.self, forKey: .data)).map(Payload.idea) ?? .unknown
            case "entry": payload = (try? container.decode(JournalEntry.self, forKey: .data)).map(Payload.entry) ?? .unknown
            case "card": payload = (try? container.decode(Card.self, forKey: .data)).map(Payload.card) ?? .unknown
            case "todo": payload = (try? container.decode(TodoItem.self, forKey: .data)).map(Payload.todo) ?? .unknown
            default: payload = .unknown
            }
        }
    }

    private func fetchAll(token: String) async throws -> [Row] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var rows: [Row] = []
        var offset = 0
        while true {
            let reply = try await send(
                "/rest/v1/items?select=id,kind,data,modified,deleted&order=id.asc&limit=1000&offset=\(offset)",
                token: token
            )
            guard let page = try? decoder.decode([Row].self, from: reply) else {
                throw SyncError(message: "Unexpected data from Supabase. Was the items table created?")
            }
            rows.append(contentsOf: page)
            if page.count < 1000 { return rows }
            offset += 1000
        }
    }

    private static func index(_ data: AppData) -> [UUID: (modified: Int64, deleted: Bool)] {
        var index: [UUID: (modified: Int64, deleted: Bool)] = [:]
        for item in data.ideas { index[item.id] = (item.modified ?? 0, false) }
        for item in data.entries { index[item.id] = (item.modified ?? 0, false) }
        for item in data.cards { index[item.id] = (item.modified ?? 0, false) }
        for item in data.todos { index[item.id] = (item.modified ?? 0, false) }
        for stone in data.tombstones { index[stone.id] = (stone.modified, true) }
        return index
    }

    /// Returns false for rows that were skipped.
    private static func apply(_ row: Row, to data: inout AppData) -> Bool {
        if case .unknown = row.payload { return false }
        data.ideas.removeAll { $0.id == row.id }
        data.entries.removeAll { $0.id == row.id }
        data.cards.removeAll { $0.id == row.id }
        data.todos.removeAll { $0.id == row.id }
        data.tombstones.removeAll { $0.id == row.id }

        switch row.payload {
        case .idea(var item):
            item.id = row.id
            item.modified = row.modified
            data.ideas.append(item)
        case .entry(var item):
            item.id = row.id
            item.modified = row.modified
            data.entries.append(item)
        case .card(var item):
            item.id = row.id
            item.modified = row.modified
            data.cards.append(item)
        case .todo(var item):
            item.id = row.id
            item.modified = row.modified
            data.todos.append(item)
        case .deleted:
            data.tombstones.append(Tombstone(id: row.id, kind: row.kind, modified: row.modified))
        case .unknown:
            return false
        }
        return true
    }

    private static func rows(from data: AppData) throws -> [[String: Any]] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        func encode<T: Syncable>(_ items: [T], kind: String) throws -> [[String: Any]] {
            try items.map { item -> [String: Any] in
                let object = try JSONSerialization.jsonObject(with: encoder.encode(item))
                return [
                    "id": item.id.uuidString.lowercased(),
                    "kind": kind,
                    "data": object as Any,
                    "modified": item.modified ?? 0,
                    "deleted": false,
                ]
            }
        }

        var rows: [[String: Any]] = []
        rows += try encode(data.ideas, kind: "idea")
        rows += try encode(data.entries, kind: "entry")
        rows += try encode(data.cards, kind: "card")
        rows += try encode(data.todos, kind: "todo")
        rows += data.tombstones.map { stone -> [String: Any] in
            [
                "id": stone.id.uuidString.lowercased(),
                "kind": stone.kind,
                "data": [String: Any](),
                "modified": stone.modified,
                "deleted": true,
            ]
        }
        return rows
    }

    // MARK: Transport

    private func send(_ path: String, method: String = "GET", body: Data? = nil,
                      token: String? = nil, prefer: String? = nil) async throws -> Data {
        guard !baseURL.isEmpty, let url = URL(string: baseURL + path) else {
            throw SyncError(message: "Sync isn't set up.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SyncError(message: "Couldn't reach Supabase: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var detail = "HTTP \(status)"
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for key in ["msg", "message", "error_description", "error"] {
                    if let text = object[key] as? String {
                        detail = text
                        break
                    }
                }
            }
            throw SyncError(message: detail, status: status)
        }
        return data
    }
}
