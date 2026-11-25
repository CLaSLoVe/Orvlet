import Darwin
import Foundation

nonisolated enum ModelAccessError: LocalizedError {
    case authorizationRequired, authorizationPending
    var errorDescription: String? {
        "Orvlet couldn’t access its local key storage. Check access to its app data, then retry."
    }
}

/// App-owned data, never a resource in the application bundle or source tree.
/// No Keychain access, provider calls, or credential values in errors/logs.
nonisolated final class LocalCredentials: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private let filename = "credentials-v1.json"
    init(directory: URL) { self.directory = directory }

    func load(_ account: String) throws -> String {
        // Writers publish by atomic rename. An open descriptor sees one complete snapshot,
        // so readers never need the cross-process writer lock.
        try access(exclusive: false) { dir in try read(dir)[account] ?? "" }
    }

    func save(_ value: String, account: String) throws {
        try update { entries in entries[account] = value.isEmpty ? nil : value }
    }

    /// Recovery may fill missing accounts, but must never replace a newer saved key.
    func importMissing(_ recovered: [String: String]) throws {
        try update { entries in
            for (account, value) in recovered where !value.isEmpty && (entries[account] ?? "").isEmpty {
                entries[account] = value
            }
        }
    }

    private func update(_ edit: (inout [String: String]) -> Void) throws {
        try access { dir in
            // A malformed file is never silently replaced, losing other profiles.
            var entries = try read(dir)
            edit(&entries)
            let data = try JSONEncoder().encode(entries)
            guard data.count <= 1_048_576 else { throw ModelAccessError.authorizationRequired }
            let temporary = ".credentials-\(UUID().uuidString).tmp"
            let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ModelAccessError.authorizationRequired }
            defer {
                close(fd)
                unlinkat(dir, temporary, 0)
            }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw ModelAccessError.authorizationRequired }
                    offset += count
                }
            }
            guard fsync(fd) == 0, renameat(dir, temporary, dir, filename) == 0 else {
                throw ModelAccessError.authorizationRequired
            }
            _ = fsync(dir)
        }
    }

    private func access<T>(exclusive: Bool = true, _ body: (Int32) throws -> T) throws -> T {
        if exclusive { lock.lock() }
        defer { if exclusive { lock.unlock() } }
        do {
            // Parent is the application's existing Application Support directory.
            try FileManager.default.createDirectory(
                at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw ModelAccessError.authorizationRequired }
            let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard dir >= 0 else { throw ModelAccessError.authorizationRequired }
            defer { close(dir) }
            var info = stat()
            guard fstat(dir, &info) == 0, info.st_uid == getuid(), fchmod(dir, 0o700) == 0 else {
                throw ModelAccessError.authorizationRequired
            }
            // Only read-modify-write transactions serialize across processes.
            var gate: Int32 = -1
            defer { if gate >= 0 { flock(gate, LOCK_UN); close(gate) } }
            if exclusive {
                gate = openat(dir, ".credentials.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
                guard gate >= 0 else { throw ModelAccessError.authorizationRequired }
                try validateFile(gate)
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while flock(gate, LOCK_EX | LOCK_NB) != 0 {
                    if errno == EINTR { continue }
                    guard errno == EWOULDBLOCK || errno == EAGAIN else { throw ModelAccessError.authorizationRequired }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw ModelAccessError.authorizationPending }
                    usleep(10_000)
                }
            }
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return try body(dir)
        } catch let error as ModelAccessError {
            throw error
        } catch {
            // Foundation errors may contain paths/data; surface only a safe message.
            throw ModelAccessError.authorizationRequired
        }
    }

    private func validateFile(_ fd: Int32, allowReplacedSnapshot: Bool = false) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
            info.st_mode & S_IFMT == S_IFREG,
            info.st_nlink == 1 || (allowReplacedSnapshot && info.st_nlink == 0),
            info.st_size <= 1_048_576, fchmod(fd, 0o600) == 0
        else {
            throw ModelAccessError.authorizationRequired
        }
    }

    private func read(_ dir: Int32) throws -> [String: String] {
        let fd = openat(dir, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return [:] }
        guard fd >= 0 else { throw ModelAccessError.authorizationRequired }
        defer { close(fd) }
        // A writer can replace the directory entry after open(). The old descriptor
        // remains a safe complete snapshot even though its link count becomes zero.
        try validateFile(fd, allowReplacedSnapshot: true)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, data.count + count <= 1_048_576 else { throw ModelAccessError.authorizationRequired }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}

nonisolated enum SecretStore {
    static let store = LocalCredentials(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orvlet/Private", isDirectory: true))
    static func load(_ account: String) async throws -> String {
        try Task.checkCancellation()
        let value = try store.load(account)
        try Task.checkCancellation()
        return value
    }
    static func loadAvailable(_ account: String) async throws -> String { try await load(account) }
    static func save(_ value: String, account: String) throws { try store.save(value, account: account) }
}
