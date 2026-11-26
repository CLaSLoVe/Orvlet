import Foundation
import SQLite3

/// Each task snapshot contains both its facts and its compression cursor. Replacing
/// one row commits both, including when the process exits during a background job.
final class MemoryDatabase {
    private let handle: OpaquePointer?
    var isAvailable: Bool { handle != nil }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var localURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orvlet/Memory/memory-v1.sqlite")
    }

    static var runsChecks: Bool {
        #if DEBUG
            return DebugHarness.selected() != nil || CommandLine.arguments.contains("--background-checks")
        #else
            return false
        #endif
    }

    init(url: URL?) {
        if let url {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                handle = nil
                return
            }
        }
        // macOS exposes the temporary directory through /var -> /private/var.
        // Canonicalize the parent, keeping SQLITE_OPEN_NOFOLLOW on the database itself.
        let path: String
        if let url {
            guard let directory = realpath(url.deletingLastPathComponent().path, nil) else {
                handle = nil
                return
            }
            path = String(cString: directory) + "/" + url.lastPathComponent
            free(directory)
        } else { path = ":memory:" }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
            sqlite3_exec(db, """
                PRAGMA secure_delete=ON;
                CREATE TABLE IF NOT EXISTS records (
                    scope TEXT NOT NULL, key TEXT NOT NULL, value BLOB NOT NULL,
                    PRIMARY KEY (scope, key)
                ) WITHOUT ROWID;
                """, nil, nil, nil) == SQLITE_OK
        else {
            sqlite3_close(db)
            handle = nil
            return
        }
        handle = db
    }

    deinit { sqlite3_close(handle) }

    private func statement(_ sql: String, _ arguments: [String]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard let handle, sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        for (index, argument) in arguments.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(index + 1), argument, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return nil
            }
        }
        return stmt
    }

    func read<T: Decodable>(_ type: T.Type, scope: String, key: String) -> T? {
        guard let stmt = statement("SELECT value FROM records WHERE scope=? AND key=?", [scope, key]) else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
        return try? JSONDecoder().decode(type, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))))
    }

    @discardableResult
    func write<T: Encodable>(_ value: T, scope: String, key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value),
            let stmt = statement("INSERT OR REPLACE INTO records(scope,key,value) VALUES(?,?,?)", [scope, key])
        else { return false }
        defer { sqlite3_finalize(stmt) }
        let bound = data.withUnsafeBytes { sqlite3_bind_blob64(stmt, 3, $0.baseAddress, UInt64($0.count), transient) }
        return bound == SQLITE_OK && sqlite3_step(stmt) == SQLITE_DONE
    }

    @discardableResult
    func remove(scope: String, key: String? = nil) -> Bool {
        let clause = key == nil ? "" : " AND key=?"
        guard let stmt = statement("DELETE FROM records WHERE scope=?" + clause, [scope, key].compactMap { $0 }) else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func transaction(_ changes: () -> Bool) -> Bool {
        guard let handle, sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        if changes(), sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK { return true }
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        return false
    }

    func keys(scope: String) -> [String] {
        guard let stmt = statement("SELECT key FROM records WHERE scope=? ORDER BY key", [scope]) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var keys: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let key = sqlite3_column_text(stmt, 0) { keys.append(String(cString: key)) }
        }
        return keys
    }

    func bytes(scope: String) -> Int {
        guard let stmt = statement("SELECT SUM(length(value)) FROM records WHERE scope=?", [scope]) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }
}
