import Foundation
import SQLite3

public final class SnapshotCache {
    public static let freshFor: TimeInterval = 600
    private static let limit = 40
    private let queue = DispatchQueue(label: "CodexPocket.SnapshotCache")
    private let legacyDirectory: URL?
    private var activeNamespace: String
    private let namespaceLock = NSLock()
    public var namespace: String {
        namespaceLock.lock(); defer { namespaceLock.unlock() }
        return activeNamespace
    }
    private var db: OpaquePointer?

    // Legacy JSON has no server identity; importing it is opt-in and bound to one owner.
    public init(directory: URL, namespace: String, legacyDirectory: URL? = nil) {
        self.activeNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
        self.legacyDirectory = legacyDirectory
        open(directory)
        claimLegacyOwner()
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    public func setNamespace(_ namespace: String) {
        queue.sync {
            namespaceLock.lock()
            self.activeNamespace = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
            namespaceLock.unlock()
            claimLegacyOwner()
        }
    }

    public func save(_ id: String, _ payload: Data) {
        queue.sync {
            guard !activeNamespace.isEmpty, valid(payload) else { return }
            _ = transaction {
                write(id, payload, at: Date()) && markImported(id) && trim()
            }
        }
    }

    @discardableResult
    public func save(_ id: String, _ payload: Data, namespace expected: String) -> Bool {
        queue.sync {
            guard activeNamespace == expected, !activeNamespace.isEmpty, valid(payload) else { return false }
            return transaction { write(id, payload, at: Date()) && markImported(id) && trim() }
        }
    }

    public func load(_ id: String) -> Data? {
        queue.sync { snapshot(id)?.payload }
    }

    public func load(_ id: String, namespace expected: String) -> Data? {
        queue.sync {
            guard activeNamespace == expected else { return nil }
            return snapshot(id)?.payload
        }
    }

    public func has(_ id: String) -> Bool {
        queue.sync { snapshot(id) != nil }
    }

    public func modifiedAt(_ id: String) -> Date? {
        queue.sync { snapshot(id)?.modified }
    }

    public func isStale(_ id: String, now: Date = Date()) -> Bool {
        queue.sync {
            guard let date = snapshot(id)?.modified else { return true }
            return now.timeIntervalSince(date) > Self.freshFor
        }
    }

    public func drop(_ id: String) {
        queue.sync {
            guard !activeNamespace.isEmpty else { return }
            _ = transaction {
                execute("DELETE FROM snapshots WHERE namespace=? AND id=?", [activeNamespace, id]) && markImported(id)
            }
        }
    }

    public func clear() {
        queue.sync {
            guard !activeNamespace.isEmpty else { return }
            _ = transaction {
                execute("DELETE FROM snapshots WHERE namespace=?", [activeNamespace]) &&
                putMetadata("legacy-cleared:" + Self.safe(activeNamespace), "1")
            }
        }
    }

    private func valid(_ data: Data) -> Bool {
        guard !data.isEmpty, let json = try? JSONSerialization.jsonObject(with: data) else { return false }
        return json is [String: Any] || json is [Any]
    }

    private struct Snapshot {
        let payload: Data
        let modified: Date
    }

    private func open(_ directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { return }
        let path = directory.appendingPathComponent("snapshots.sqlite3").path
        var connection: OpaquePointer?
        guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let connection = connection { sqlite3_close(connection) }
            return
        }
        db = connection
        sqlite3_busy_timeout(db, 1000)
        guard let version = integer("PRAGMA user_version"), (0...1).contains(version),
              configureSchema() else {
            sqlite3_close(db)
            db = nil
            return
        }
    }

    private func configureSchema() -> Bool {
        transaction {
            execute("""
                CREATE TABLE IF NOT EXISTS snapshots (
                    namespace TEXT NOT NULL, id TEXT NOT NULL,
                    payload BLOB NOT NULL, modified REAL NOT NULL,
                    PRIMARY KEY(namespace, id)
                )
                """) &&
            execute("CREATE INDEX IF NOT EXISTS snapshot_age ON snapshots(modified)") &&
            execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)") &&
            execute("PRAGMA user_version=1")
        }
    }

    private func prepare(_ sql: String, _ values: [String] = []) -> OpaquePointer? {
        guard let db = db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement = statement else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, Int32(value.utf8.count), transient) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return nil
            }
        }
        return statement
    }

    private func execute(_ sql: String, _ values: [String] = []) -> Bool {
        guard let statement = prepare(sql, values) else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func transaction(_ body: () -> Bool) -> Bool {
        guard execute("BEGIN IMMEDIATE") else { return false }
        if body(), execute("COMMIT") { return true }
        _ = execute("ROLLBACK")
        return false
    }

    private func integer(_ sql: String) -> Int? {
        guard let statement = prepare(sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func metadata(_ key: String) -> String? {
        guard let statement = prepare("SELECT value FROM metadata WHERE key=?", [key]) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_text(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    private func putMetadata(_ key: String, _ value: String) -> Bool {
        execute("INSERT OR REPLACE INTO metadata(key, value) VALUES(?, ?)", [key, value])
    }

    private func claimLegacyOwner() {
        guard legacyDirectory != nil, !activeNamespace.isEmpty else { return }
        _ = execute("INSERT OR IGNORE INTO metadata(key, value) VALUES('legacy-owner', ?)", [activeNamespace])
    }

    private func migrationKey(_ id: String) -> String {
        "legacy:" + Self.safe(activeNamespace) + ":" + Self.safe(id)
    }

    private func markImported(_ id: String) -> Bool {
        guard let legacyDirectory = legacyDirectory,
              metadata("legacy-owner") == activeNamespace,
              FileManager.default.fileExists(atPath: legacyDirectory.appendingPathComponent(Self.safe(id) + ".json").path) else { return true }
        return putMetadata(migrationKey(id), "1")
    }

    private func read(_ id: String) -> Snapshot? {
        guard let statement = prepare("SELECT payload, modified FROM snapshots WHERE namespace=? AND id=?", [activeNamespace, id]) else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        let data: Data
        if count > 0, let bytes = sqlite3_column_blob(statement, 0) {
            data = Data(bytes: bytes, count: count)
        } else { data = Data() }
        return Snapshot(payload: data, modified: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)))
    }

    private func write(_ id: String, _ payload: Data, at date: Date) -> Bool {
        guard let statement = prepare("INSERT OR REPLACE INTO snapshots(namespace, id, payload, modified) VALUES(?, ?, ?, ?)", [activeNamespace, id]) else { return false }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bound = payload.withUnsafeBytes {
            sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(payload.count), transient)
        }
        return bound == SQLITE_OK && sqlite3_bind_double(statement, 4, date.timeIntervalSince1970) == SQLITE_OK && sqlite3_step(statement) == SQLITE_DONE
    }

    private func trim() -> Bool {
        execute("DELETE FROM snapshots WHERE rowid NOT IN (SELECT rowid FROM snapshots ORDER BY modified DESC, rowid DESC LIMIT \(Self.limit))")
    }

    private func snapshot(_ id: String) -> Snapshot? {
        guard !activeNamespace.isEmpty else { return nil }
        if let cached = read(id) {
            if valid(cached.payload), cached.modified.timeIntervalSince1970.isFinite { return cached }
            _ = transaction {
                execute("DELETE FROM snapshots WHERE namespace=? AND id=?", [activeNamespace, id]) && markImported(id)
            }
            return nil
        }
        migrate(id)
        guard let cached = read(id), valid(cached.payload),
              cached.modified.timeIntervalSince1970.isFinite else { return nil }
        return cached
    }

    private func migrate(_ id: String) {
        guard let legacyDirectory = legacyDirectory,
              metadata("legacy-owner") == activeNamespace,
              metadata("legacy-cleared:" + Self.safe(activeNamespace)) == nil,
              metadata(migrationKey(id)) == nil else { return }
        let file = legacyDirectory.appendingPathComponent(Self.safe(id) + ".json")
        guard let data = try? Data(contentsOf: file),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let date = attributes[.modificationDate] as? Date else { return }
        _ = transaction {
            // Recheck after taking the write lock so another instance's save/clear wins.
            guard read(id) == nil,
                  metadata("legacy-owner") == activeNamespace,
                  metadata("legacy-cleared:" + Self.safe(activeNamespace)) == nil,
                  metadata(migrationKey(id)) == nil else { return true }
            guard valid(data) else { return markImported(id) }
            return write(id, data, at: date) && markImported(id) && trim()
        }
    }

    public static func safe(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
