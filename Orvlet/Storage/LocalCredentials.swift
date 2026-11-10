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
        try access { dir in try read(dir)[account] ?? "" }
    }

    func save(_ value: String, account: String) throws {
        try access { dir in
            // A malformed file is never silently replaced, losing other profiles.
            var entries = try read(dir)
            entries[account] = value.isEmpty ? nil : value
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

    private func access<T>(_ body: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
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
            // Serialize independent app instances as well as threads.
            let gate = openat(dir, ".credentials.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard gate >= 0 else { throw ModelAccessError.authorizationRequired }
            defer { close(gate) }
            try validateFile(gate)
            guard flock(gate, LOCK_EX | LOCK_NB) == 0 else { throw ModelAccessError.authorizationPending }
            defer { flock(gate, LOCK_UN) }
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return try body(dir)
        } catch {
            // Foundation errors may contain paths/data; surface only a safe message.
            throw ModelAccessError.authorizationRequired
        }
    }

    private func validateFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
            info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
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
        try validateFile(fd)
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
    private static let store = LocalCredentials(
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
