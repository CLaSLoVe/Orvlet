import Foundation
import Network

@MainActor
final class LocalBridge {
    // Temporarily unavailable until external tabs can be isolated per task.
    static let browserPairingEnabled = false
    unowned let model: AppModel
    let port: UInt16 = 19243
    private(set) var token = ""
    var listener: NWListener?
    var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    var commands: [[String: Any]] = []
    var lastBrowserPing = Date.distantPast
    var heartbeat: Timer?
    var discoveryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orvlet/bridge.json")
    }
    init(model: AppModel) { self.model = model }
    func start() {
        guard listener == nil else { return }
        token = UUID().uuidString + UUID().uuidString
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let server = try NWListener(using: params)
            listener = server
            server.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            server.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.model.bridgeStatus = "127.0.0.1:\(self.port)"
                        do {
                            try FileManager.default.createDirectory(
                                at: self.discoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
                            let data = try JSONSerialization.data(withJSONObject: [
                                "port": self.port, "token": self.token,
                            ])
                            try data.write(to: self.discoveryURL, options: .atomic)
                            try FileManager.default.setAttributes(
                                [.posixPermissions: 0o600], ofItemAtPath: self.discoveryURL.path)
                        } catch { self.model.bridgeStatus = "Could not save connection file." }
                    case .failed:
                        self.model.bridgeStatus = "Port unavailable or permission denied."
                        self.listener = nil
                    default: break
                    }
                }
            }
            server.start(queue: .main)
            heartbeat = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if Date().timeIntervalSince(self.lastBrowserPing) > 8 {
                        self.model.browserConnected = false
                        self.model.externalBrowser = false
                    }
                }
            }
        } catch { model.bridgeStatus = "Could not start local service." }
    }
    func stop() {
        listener?.cancel()
        listener = nil
        heartbeat?.invalidate()
        heartbeat = nil
        model.browserConnected = false
        model.externalBrowser = false
        model.bridgeStatus = "Off"
        try? FileManager.default.removeItem(at: discoveryURL)
        let waiting = pending
        pending.removeAll()
        commands.removeAll()
        for (_, continuation) in waiting {
            continuation.resume(throwing: AppError.message("Local connections are off."))
        }
    }
    func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { connection.cancel() }
    }
    func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard buffer.count < 3_000_000 else {
                    self.reply(connection, 413, ["error": "Request too large"])
                    return
                }
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)),
                    let header = String(data: buffer[..<range.lowerBound], encoding: .utf8)
                {
                    let lines = header.components(separatedBy: "\r\n")
                    let first = lines[0].components(separatedBy: " ")
                    guard first.count >= 2 else {
                        connection.cancel()
                        return
                    }
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        let parts = line.split(separator: ":", maxSplits: 1)
                        if parts.count == 2 {
                            headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
                        }
                    }
                    guard headers["authorization"] == "Bearer \(self.token)" else {
                        self.reply(connection, 401, ["error": "Pairing required"])
                        return
                    }
                    if let origin = headers["origin"], !origin.hasPrefix("chrome-extension://"),
                        !origin.hasPrefix("moz-extension://")
                    {
                        self.reply(connection, 403, ["error": "Origin not allowed"])
                        return
                    }
                    let length = Int(headers["content-length"] ?? "0") ?? 0
                    guard length >= 0 && length < 3_000_000 else {
                        connection.cancel()
                        return
                    }
                    let body = buffer[range.upperBound...]
                    if body.count >= length {
                        let input =
                            (try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))) as? [String: Any]
                            ?? [:]
                        do { self.reply(connection, 200, try await self.route(first[1], input)) } catch {
                            self.reply(connection, 200, ["error": error.localizedDescription])
                        }
                        return
                    }
                }
                if done || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }
            }
        }
    }
    func route(_ path: String, _ input: [String: Any]) async throws -> [String: Any] {
        guard model.settings.allowAgents else { throw AppError.message("Local connections are off.") }
        if path.hasPrefix("/browser/"), !Self.browserPairingEnabled {
            throw AppError.message("Browser integration is currently unavailable.")
        }
        if path == "/browser/poll" {
            lastBrowserPing = Date()
            model.browserConnected = true
            let batch = commands
            commands.removeAll()
            return ["commands": batch]
        }
        if path == "/browser/state" {
            lastBrowserPing = Date()
            model.browserConnected = true
            if model.externalBrowser { model.browser.updateState(input) }
            return ["ok": true]
        }
        if path == "/browser/result" {
            if let id = input["id"] as? String, let continuation = pending.removeValue(forKey: id) {
                if let error = input["error"] as? String {
                    continuation.resume(throwing: AppError.message(error))
                } else {
                    continuation.resume(returning: input["result"] as? [String: Any] ?? [:])
                }
            }
            return ["ok": true]
        }
        guard path == "/rpc", let name = input["tool"] as? String else { throw AppError.message("Unknown endpoint.") }
        guard
            !["calendar_create", "calendar_clarify", "timer_start", "run_code", "present_ui", "reuse_saved_ui"]
                .contains(name)
        else {
            throw AppError.message("Task execution must be requested through Orvlet's input window or task controls.")
        }
        if name == "state" {
            return [
                "collapsed": model.collapsed, "components": model.surface.components.map { $0.kind.rawValue },
                "playing": model.isPlaying, "title": model.trackTitle, "url": model.webURL, "pinned": model.pinned,
                "browserConnected": model.browserConnected,
            ]
        }
        // Each authenticated RPC is a distinct command, not another round of the app's active request.
        return try await model.agent.execute(name, input["arguments"] as? [String: Any] ?? [:], requestScoped: false)
    }
    func reply(_ connection: NWConnection, _ status: Int, _ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        let header =
            "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var output = Data(header.utf8)
        output.append(data)
        connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
    }
    func externalAction(_ input: [String: Any]) async throws -> [String: Any] {
        guard Self.browserPairingEnabled else {
            throw AppError.message("Browser integration is currently unavailable.")
        }
        guard model.browserConnected else { throw AppError.message("Connect the browser extension first.") }
        try Task.checkCancellation()
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                commands.append(["id": id, "input": input])
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                    guard let self, let waiting = self.pending.removeValue(forKey: id) else { return }
                    self.commands.removeAll { $0["id"] as? String == id }
                    waiting.resume(
                        throwing: AppError.message("Browser timed out. Check that the connected tab is open."))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.commands.removeAll { $0["id"] as? String == id }
                self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }
}
