import Darwin
import Foundation

/// Public GETs are independent of model authentication and browsing sessions.
nonisolated final class PublicDataClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func url(_ raw: String) throws -> URL {
        guard raw.count <= 2000, let url = URL(string: raw), url.scheme == "https",
            let host = url.host?.lowercased(), host.contains("."),
            !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
            host != "localhost", host != "metadata.google.internal",
            url.user == nil, url.password == nil, url.port == nil || url.port == 443,
            !host.contains(":"), host.range(of: "^[0-9.]+$", options: .regularExpression) == nil,
            !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains(where: {
                ["key", "api_key", "apikey", "token", "access_token", "password", "secret", "authorization"].contains(
                    $0.name.lowercased())
            })
        else { throw AppError.message("Use a public HTTPS data API without credentials or private addresses.") }
        return url
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
    static func publicAddress(_ host: String) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw AppError.message("The data source could not be reached.")
        }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            let address = entry.pointee
            var isPublic = false
            if address.ai_family == AF_INET, let raw = address.ai_addr {
                let bytes = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr.s_addr.bigEndian
                }
                let a = bytes >> 24
                let b = (bytes >> 16) & 255
                isPublic =
                    a != 0 && a != 10 && a != 127 && a < 224 && !(a == 169 && b == 254)
                    && !(a == 172 && (16...31).contains(b)) && !(a == 192 && b == 168)
                    && !(a == 100 && (64...127).contains(b)) && !(a == 198 && (18...19).contains(b))
            } else if address.ai_family == AF_INET6, let raw = address.ai_addr {
                let firstByte = raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { value in
                    withUnsafeBytes(of: value.pointee.sin6_addr) { $0[0] }
                }
                isPublic = (0x20...0x3f).contains(firstByte)
            }
            guard isPublic else { throw AppError.message("Data APIs must resolve to public internet addresses.") }
            cursor = address.ai_next
        }
    }
    func fetch(_ raw: String) async throws -> Any {
        let url = try Self.url(raw)
        try await Task.detached { try Self.publicAddress(url.host!) }.value
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
            response.expectedContentLength <= 524288
        else {
            throw AppError.message(
                "The data source is unavailable or returned an oversized response. Try another source.")
        }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < 524288 else {
                throw AppError.message("The data response is too large. Narrow the query.")
            }
            data.append(byte)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data), json is [String: Any] || json is [Any] else {
            throw AppError.message("The source did not return usable JSON. Use its documented API or another source.")
        }
        return json
    }
}
