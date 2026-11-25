#if DEBUG
    import Foundation

    enum LocalCredentialsCheck {
        static func run() async throws -> [String] {
            var checks: [String] = []
            func check(_ condition: Bool, _ text: String) throws {
                guard condition else { throw AppError.message(text) }
                checks.append(text)
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent("Private")
            let file = directory.appendingPathComponent("credentials-v1.json")
            let store = LocalCredentials(directory: directory)
            try check(try store.load("missing") == "", "A new local credential store starts empty")
            try store.save("synthetic-one", account: "profile-one")
            try store.save("synthetic-two", account: "profile-two")
            let reopened = LocalCredentials(directory: directory)
            try check(
                try reopened.load("profile-one") == "synthetic-one" && reopened.load("profile-two") == "synthetic-two",
                "Local keys survive reopening and remain isolated by profile")
            try store.save("replacement", account: "profile-one")
            try store.save("", account: "profile-two")
            try check(
                try reopened.load("profile-one") == "replacement" && reopened.load("profile-two").isEmpty,
                "Updating and removing keys preserves other profiles")
            let dirAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
            try check(
                (dirAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
                    && (fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "Local credential directory and file are owner-only")
            // Hold the writer lock in a different process. Reads must see the last
            // atomic snapshot immediately; a writer must wait and then preserve it.
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            let ready = root.appendingPathComponent("ready")
            child.arguments = ["-e", "open(my $gate, '>>', $ARGV[0]) or die; flock($gate,2) or die; open(my $ready, '>', $ARGV[1]) or die; close($ready); select(undef,undef,undef,0.6);",
                directory.appendingPathComponent(".credentials.lock").path, ready.path]
            try child.run()
            defer { if child.isRunning { child.terminate() } }
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: ready.path) {
                guard child.isRunning, Date() < deadline else { throw AppError.message("Credential lock fixture failed") }
                try await Task.sleep(for: .milliseconds(10))
            }
            let began = Date()
            try check(try reopened.load("profile-one") == "replacement" && Date().timeIntervalSince(began) < 0.2,
                "A separate process holding the writer lock does not block credential reads")
            try reopened.save("synthetic-three", account: "profile-three")
            child.waitUntilExit()
            try check(try store.load("profile-one") == "replacement" && store.load("profile-three") == "synthetic-three",
                "A concurrent credential writer waits for the lock without losing other profiles")
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<12 {
                    group.addTask {
                        let independent = LocalCredentials(directory: directory)
                        try independent.save("synthetic", account: "concurrent-" + String(index))
                        guard try independent.load("profile-one") == "replacement" else { throw ModelAccessError.authorizationRequired }
                    }
                }
                try await group.waitForAll()
            }
            for index in 0..<12 {
                guard try store.load("concurrent-" + String(index)) == "synthetic" else { throw AppError.message("Lost concurrent credential write") }
            }
            checks.append("Independent readers and writers preserve complete snapshots and all profiles")
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for index in 0..<60 { try LocalCredentials(directory: directory).save(String(index), account: "rotating") }
                }
                for _ in 0..<4 {
                    group.addTask {
                        for _ in 0..<100 {
                            guard try LocalCredentials(directory: directory).load("profile-one") == "replacement" else { throw ModelAccessError.authorizationRequired }
                        }
                    }
                }
                try await group.waitForAll()
            }
            checks.append("Readers accept complete opened snapshots while writers atomically replace their directory entries")
            let corrupt = Data("invalid synthetic data".utf8)
            try corrupt.write(to: file)
            var rejected = false
            do { try store.save("new", account: "another") } catch { rejected = true }
            try check(
                rejected && (try Data(contentsOf: file)) == corrupt,
                "A corrupt credential file is reported without overwriting saved data")
            try FileManager.default.removeItem(at: file)
            let outside = root.appendingPathComponent("outside")
            try Data("untouched".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
            rejected = false
            do { try store.save("new", account: "another") } catch { rejected = true }
            try check(
                rejected && (try Data(contentsOf: outside)) == Data("untouched".utf8),
                "Credential writes reject symlinks without modifying their targets")
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: root)
            rejected = false
            do { _ = try store.load("profile-one") } catch { rejected = true }
            try check(rejected, "A redirected credential directory is rejected")
            let cancelled = Task { () throws -> String in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await SecretStore.load("unused")
            }
            cancelled.cancel()
            var stopped = false
            do { _ = try await cancelled.value } catch is CancellationError { stopped = true }
            try check(stopped, "Cancelled credential work stops without accessing real keys")
            return checks
        }

    }
#endif
