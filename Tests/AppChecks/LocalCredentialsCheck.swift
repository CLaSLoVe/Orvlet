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
