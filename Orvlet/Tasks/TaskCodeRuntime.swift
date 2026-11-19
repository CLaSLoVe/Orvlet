import Darwin
import Foundation
import JavaScriptCore

/// A disposable, CPU-only JavaScript worker. No DOM, filesystem, shell, network,
/// credentials or application objects are exported into the JavaScript context.
enum TaskCodeWorker {
    nonisolated static func main() -> Never {
        var cpu = rlimit(rlim_cur: 4, rlim_max: 4)
        _ = setrlimit(RLIMIT_CPU, &cpu)
        var core = rlimit(rlim_cur: 0, rlim_max: 0)
        _ = setrlimit(RLIMIT_CORE, &core)
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard data.count <= 262144,
                let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let context = JSContext()
            else { throw WorkerError.invalid }
            context.evaluateScript("globalThis.console = Object.freeze({log(){},warn(){},error(){}});")
            let constructor = context.objectForKeyedSubscript("Function")!
            let json = context.objectForKeyedSubscript("JSON")!
            if request["mode"] as? String == "validate" {
                guard let codes = request["codes"] as? [String], codes.count <= 8 else { throw WorkerError.invalid }
                for code in codes {
                    guard code.utf8.count <= 32768 else { throw WorkerError.invalid }
                    _ = constructor.construct(withArguments: ["input", "state", "\"use strict\";\n" + code])
                    if let error = context.exception { throw WorkerError.script(error.toString() ?? "Invalid code") }
                }
                emit(["ok": true, "result": ["validated": true]])
            } else {
                guard let code = request["code"] as? String, code.utf8.count <= 32768 else { throw WorkerError.invalid }
                func value(_ key: String) throws -> JSValue {
                    let data = try JSONSerialization.data(withJSONObject: request[key] ?? [:], options: [.sortedKeys])
                    guard let value = json.invokeMethod("parse", withArguments: [String(decoding: data, as: UTF8.self)])
                    else { throw WorkerError.invalid }
                    return value
                }
                let function = constructor.construct(withArguments: ["input", "state", "\"use strict\";\n" + code])
                if let error = context.exception { throw WorkerError.script(error.toString() ?? "Invalid code") }
                var input = try value("input")
                var contract: JSValue?
                if let fields = request["declaredInputs"] as? [String] {
                    let keys = Set((request["input"] as? [String: Any] ?? [:]).keys)
                    guard keys == Set(fields) else {
                        throw WorkerError.contract("Supply exactly the declared input fields: " + fields.sorted().joined(separator: ", "))
                    }
                    // Keep the violation outside generated code: catching a missing-field error
                    // must not turn a broken input contract into a passing negative check.
                    let wrap = context.evaluateScript("""
                        (function(value) {
                            let violation = null;
                            const fail = message => { violation = message; throw Error(message); };
                            const names = Object.keys(value).sort().join(', ');
                            const input = new Proxy(value, { get(target, key, receiver) {
                                if (key === Symbol.toPrimitive) return () => fail('input is an object of named fields (' + names + '); read input[fieldName], not the whole object as a scalar.');
                                if (typeof key === 'string' && !(key in target) && key !== 'toJSON')
                                    return fail('Undeclared input field "' + key + '". Available fields: ' + names + '. Keep form.inputs, state, checks and handler property names consistent.');
                                return Reflect.get(target, key, receiver);
                            }});
                            return {input, violation: () => violation};
                        })
                        """)
                    contract = wrap?.call(withArguments: [input])
                    input = contract!.forProperty("input")
                }
                let result = try function?.call(withArguments: [input, value("state")])
                let scriptError = context.exception?.toString()
                context.exception = nil
                if let violation = contract?.invokeMethod("violation", withArguments: []), !violation.isNull {
                    throw WorkerError.contract(violation.toString() ?? "Input contract violation")
                }
                if let scriptError { throw WorkerError.script(scriptError) }
                if let error = context.exception { throw WorkerError.script(error.toString() ?? "Code failed") }
                if result?.hasProperty("then") == true {
                    throw WorkerError.script("Return a synchronous JSON result, not a Promise.")
                }
                if let result, !result.isUndefined {
                    let validate = context.evaluateScript(
                        "(function check(v){if(typeof v==='number'&&!Number.isFinite(v))throw Error('The calculation produced a non-finite number. Check the inputs.');if(v&&typeof v==='object')for(const k of Object.keys(v))check(v[k]);})"
                    )
                    _ = validate?.call(withArguments: [result])
                    if let error = context.exception {
                        throw WorkerError.script(error.toString() ?? "Invalid numerical result")
                    }
                }
                guard let result, !result.isUndefined,
                    let encoded = json.invokeMethod("stringify", withArguments: [result])?.toString(),
                    encoded.utf8.count <= 131072,
                    let object = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
                else {
                    throw WorkerError.script("Return a JSON object; use {state:{...}} for interface values.")
                }
                if let error = context.exception {
                    throw WorkerError.script(error.toString() ?? "Result could not be encoded")
                }
                emit(["ok": true, "result": object])
            }
            exit(0)
        } catch {
            let kind: String
            if case WorkerError.script = error { kind = "script" } else if case WorkerError.contract = error { kind = "contract" } else { kind = "request" }
            emit(["ok": false, "error": String(error.localizedDescription.prefix(500)), "kind": kind])
            exit(1)
        }
    }
    nonisolated private static func emit(_ result: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: result) { FileHandle.standardOutput.write(data) }
    }
    private enum WorkerError: LocalizedError {
        case invalid
        case script(String)
        case contract(String)
        nonisolated var errorDescription: String? {
            switch self {
            case .invalid: return "Invalid code request."
            case .script(let value), .contract(let value): return value
            }
        }
    }
}

enum TaskCodeError: LocalizedError {
    case script(String)
    var errorDescription: String? {
        switch self {
        case .script(let message): return message
        }
    }
}

/// Only pure calculation is exposed to data and scheduling services.
@MainActor
protocol TaskCodeExecuting: AnyObject {
    func run(code: String, input: [String: Any], state: [String: String]) async throws -> [String: Any]
    func run(code: String, input: [String: Any], state: [String: String], declaredInputs: [String]) async throws -> [String: Any]
}

extension TaskCodeExecuting {
    func run(code: String, input: [String: Any], state: [String: String], declaredInputs: [String]) async throws -> [String: Any] {
        try await run(code: code, input: input, state: state)
    }
}

@MainActor
final class TaskCodeRuntime: TaskCodeExecuting {
    var timeout: TimeInterval = 3
    private(set) var runningCount = 0
    func run(code: String, input: [String: Any] = [:], state: [String: String] = [:]) async throws -> [String: Any] {
        try await worker(["mode": "execute", "code": code, "input": input, "state": state])
    }
    func run(code: String, input: [String: Any], state: [String: String], declaredInputs: [String]) async throws -> [String: Any] {
        try await worker(["mode": "execute", "code": code, "input": input, "state": state, "declaredInputs": declaredInputs])
    }
    func validate(_ codes: [String]) async throws {
        guard !codes.isEmpty else { return }
        _ = try await worker(["mode": "validate", "codes": codes])
    }
    private func worker(_ payload: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        while runningCount >= 4 { try await Task.sleep(for: .milliseconds(30)) }
        guard let executable = Bundle.main.executableURL else {
            throw AppError.message("Code execution is busy. Try again shortly.")
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard data.count <= 262144 else { throw AppError.message("Keep task inputs under 256 KB.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "orvlet-code-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.json")
        let output = root.appendingPathComponent("output.json")
        try data.write(to: input, options: .atomic)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let stdin = try FileHandle(forReadingFrom: input)
        let stdout = try FileHandle(forWritingTo: output)
        defer {
            try? stdin.close()
            try? stdout.close()
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--task-code-worker"]
        process.environment = ["LANG": "en_US.UTF-8", "JSC_useJIT": "false"]
        process.currentDirectoryURL = root
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        runningCount += 1
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            runningCount -= 1
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while process.isRunning {
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline {
                throw AppError.message("This calculation took too long and was stopped. Simplify it and try again.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        let resultData = try Data(contentsOf: output)
        guard resultData.count <= 140000,
            let envelope = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        else {
            throw AppError.message("The calculation stopped without returning a result.")
        }
        guard process.terminationStatus == 0, envelope["ok"] as? Bool == true,
            let result = envelope["result"] as? [String: Any]
        else {
            if process.terminationStatus == 1, envelope["kind"] as? String == "script",
                let message = envelope["error"] as? String
            {
                throw TaskCodeError.script(message)
            }
            throw AppError.message(envelope["error"] as? String ?? "The calculation failed.")
        }
        return result
    }
}
