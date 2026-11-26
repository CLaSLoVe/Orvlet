import SwiftUI
import WebKit

struct LocalDataSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var webSize = "…"
    @State private var pendingClear: LocalDataKind?
    @State private var clearing: LocalDataKind?
    @State private var notice = ""
    @State private var reviewingMemory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(reviewingMemory ? "Saved memory" : "Local data")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                Spacer()
                Button(reviewingMemory ? "Done" : "Review memory") {
                    reviewingMemory.toggle()
                }
                .controlSize(.small)
                .accessibilityIdentifier("review-saved-memory")
            }
            if reviewingMemory {
                SavedMemoryList(model: model)
            } else {
                VStack(spacing: 0) {
                    ForEach(LocalDataKind.allCases) { kind in
                        if kind != .interfaces { Divider().opacity(0.35).padding(.leading, 44) }
                        row(kind)
                    }
                }
                if !notice.isEmpty {
                    Text(notice).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(19).frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
        .task { model.resumePendingConversationClear(); await refreshSizes() }
        .confirmationDialog(
            "Clear \(pendingClear?.title.lowercased() ?? "data")?",
            isPresented: Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } }),
            titleVisibility: .visible, presenting: pendingClear
        ) { kind in
            Button(kind == .interfaces ? "Clear & reset" : "Clear", role: .destructive) {
                pendingClear = nil
                clearing = kind
                Task {
                    let cleared = await model.clearLocalData(kind)
                    notice =
                        cleared
                        ? (kind == .interfaces
                            ? "Saved interfaces reset." : "\(kind.title) cleared.")
                        : (model.canClearLocalData ? "Could not finish clearing local data. Try again."
                           : "Wait for the current request to finish, then try again.")
                    await refreshSizes()
                    clearing = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingClear = nil }
        } message: { kind in
            Text(kind.confirmation)
        }
    }

    private func row(_ kind: LocalDataKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol).font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(kind.title).font(.system(size: 12, weight: .medium))
                Text(kind.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(kind == .web ? webSize : LocalDataSize.label(model.storedBytes(for: kind)))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                .fixedSize().accessibilityLabel("\(kind.title) size")
                .accessibilityValue(kind == .web ? webSize : LocalDataSize.label(model.storedBytes(for: kind)))
            Button {
                pendingClear = kind
            } label: {
                if clearing == kind {
                    ProgressView().controlSize(.mini).frame(width: 28, height: 28)
                } else {
                    Image(systemName: "trash").font(.system(size: 12)).frame(width: 28, height: 28).contentShape(
                        Rectangle())
                }
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(clearing != nil || !model.canClearLocalData)
            .help(
                model.canClearLocalData
                    ? "Clear \(kind.title.lowercased())…" : "Available after the current request finishes"
            )
            .accessibilityLabel("Clear \(kind.title.lowercased())")
            .accessibilityIdentifier("clear-data-\(kind.rawValue)")
        }.padding(.vertical, 12)
    }

    private func refreshSizes() async {
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in
            model.browser.webView.configuration.websiteDataStore.fetchDataRecords(
                ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
            ) { continuation.resume(returning: $0) }
        }
        let estimate = await Task.detached(priority: .utility) { LocalDataSize.webCacheBytes() }.value
        guard !Task.isCancelled else { return }
        if let estimate {
            webSize = "≈ " + LocalDataSize.label(estimate)
        } else {
            webSize = records.isEmpty ? "0 B" : "Unavailable"
        }
    }
}

private struct SavedMemoryList: View {
    @ObservedObject var model: AppModel
    @State private var confirming: String?
    @State private var notice = ""

    var body: some View {
        let tasks = model.taskMemoryItems
        let sites = model.siteMemoryItems
        VStack(alignment: .leading, spacing: 14) {
            if tasks.isEmpty && sites.isEmpty {
                Text("No saved memory").font(.callout).foregroundStyle(.secondary)
            }
            group("Task memory", tasks)
            group("Website experience", sites)
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func group(_ title: String, _ items: [MemoryListItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary).padding(.bottom, 5)
                ForEach(items.sorted { $0.updated > $1.updated }) { item in
                    Divider().opacity(0.35)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.system(size: 13, weight: .medium))
                            Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(item.updated.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if confirming == item.id {
                            Button("Cancel") { confirming = nil }
                                .controlSize(.small)
                            Button("Forget", role: .destructive) {
                                let deleted = item.kind == .task
                                    ? model.removeTaskMemoryItem(item.id) : model.removeSiteMemoryItem(item.id)
                                confirming = nil
                                notice = deleted ? "" : "Could not forget this memory."
                            }
                            .controlSize(.small)
                            .accessibilityIdentifier("confirm-forget-\(item.id)")
                        } else {
                            Button {
                                confirming = item.id
                            } label: {
                                Image(systemName: "trash").frame(width: 28, height: 28).contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("Forget this memory")
                                .accessibilityLabel("Forget \(item.title)")
                                .accessibilityIdentifier("forget-\(item.id)")
                        }
                    }.padding(.vertical, 9)
                }
            }
        }
    }
}
