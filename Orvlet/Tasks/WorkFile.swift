import AppKit
import Foundation
import UniformTypeIdentifiers

/// A host-owned document reference. Scripts return text; they never choose a directory.
struct WorkFile: Codable {
    let directoryID: UUID
    let name: String
    let preview: String
    static let formats = ["txt", "md", "csv", "json"]

    private static func validName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return formats.contains(ext) && !name.hasPrefix(".") && !name.contains("/")
            && !name.contains(":") && !name.contains("\\") && !name.contains(where: { $0.isNewline })
            && name.utf8.count <= 100 && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Orvlet/Documents", isDirectory: true)
            .appendingPathComponent(directoryID.uuidString, isDirectory: true)
    }

    func existingURL() throws -> URL {
        guard Self.validName(name) else { throw AppError.message("Invalid document name.") }
        let url = directory.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AppError.message("The document is no longer available.")
        }
        return url
    }

    func write(_ content: Data) throws {
        guard Self.validName(name) else {
            throw ToolArgumentError(path: "$.filename", issue: "supply a single .txt, .md, .csv or .json filename")
        }
        if (name as NSString).pathExtension.lowercased() == "json" {
            guard (try? JSONSerialization.jsonObject(with: content, options: [.fragmentsAllowed])) != nil else {
                throw ToolArgumentError(path: "$.code", issue: "return a valid JSON document")
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try content.write(to: directory.appendingPathComponent(name), options: .atomic)
            guard try Data(contentsOf: existingURL()) == content else { throw AppError.message("Could not verify the written document.") }
        } catch { discardUnpublished(); throw error }
    }

    func discardUnpublished() { try? FileManager.default.removeItem(at: directory) }
}

extension AppModel {
    func attachWorkFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = WorkFile.formats.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        do { try attachWorkFiles(panel.urls) }
        catch { lastActionError = error.localizedDescription }
    }

    func attachWorkFiles(_ urls: [URL]) throws {
        var attachments: [(String, String)] = []
        for url in urls {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let stream = try FileHandle(forReadingFrom: url)
            defer { try? stream.close() }
            let data = try stream.read(upToCount: 65537) ?? Data()
            let ext = url.pathExtension.lowercased()
            guard WorkFile.formats.contains(ext), data.count <= 65536, let content = String(data: data, encoding: .utf8) else {
                throw AppError.message(userText("请选择不超过 64 KB 的 UTF-8 文本文件。", "Choose a UTF-8 text file of up to 64 KB."))
            }
            let handle = "[file-" + UUID().uuidString.prefix(8) + "." + ext + "]"
            attachments.append((handle, content))
        }
        // Submitted commands own their attachment snapshot. Retain only the current draft here.
        if globalRoutingTask == nil && queuedTaskRequests.isEmpty && pendingRoutingRequests.isEmpty && commandRuns.isEmpty {
            attachedWorkFiles = attachedWorkFiles.filter { command.contains($0.key) }
        }
        for (handle, content) in attachments {
            attachedWorkFiles[handle] = content
            command += " " + handle
        }
    }

    func publishWorkFile(name: String, content: String, id: UUID, ticket: TaskRevisionLedger.Ticket?) throws -> WorkFile {
        let data = Data(content.utf8)
        let file = WorkFile(directoryID: UUID(), name: name, preview: String(content.prefix(600)))
        let english = settings.preferredInterfaceLanguage.caseInsensitiveCompare("English") == .orderedSame
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        let form = TaskForm(inputs: [], outputs: [.init(key: "preview", label: english ? "Preview" : "预览")],
            buttons: [], compactSubject: name, compactKey: "size")
        var markup = try form.markup()
        markup.css += ".calm-form>.calm-result .form-value{display:block;font-size:14px;line-height:1.5;font-weight:400;max-height:180px}"
        let surface = try TaskSurface(title: name, markup: markup, fields: [], actions: [],
            state: ["preview": "", "size": size]).validated()
        if let ticket, !accepts(ticket) { throw CancellationError() }
        try file.write(data)
        do { try commitTaskSurface(surface, id: id, ticket: ticket, workFile: file) }
        catch { file.discardUnpublished(); throw error }
        return file
    }
}
