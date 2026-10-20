import SwiftUI
import UIKit

struct DiagnosticsLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText = "Loading diagnostics…"
    @State private var exportURL: URL?
    @State private var errorMessage: String?
    @State private var isClearConfirmationPresented = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                    Button {
                        UIPasteboard.general.string = logText
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await reload() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await refreshExport() }
                    } label: {
                        Label("Prepare export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)

                    if let exportURL {
                        ShareLink(item: exportURL, preview: SharePreview("Primuse Music Haptics diagnostics")) {
                            Label("Share", systemImage: "square.and.arrow.up.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Text("Files can also open Documents/Diagnostics. Entries omit recording titles, artists, file names, and full ISRC values.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }

                ScrollView([.vertical, .horizontal]) {
                    Text(logText.isEmpty ? "No diagnostic events have been recorded." : logText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding()
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear") { isClearConfirmationPresented = true }
                }
            }
            .confirmationDialog("Clear all diagnostic logs?", isPresented: $isClearConfirmationPresented, titleVisibility: .visible) {
                Button("Clear Logs", role: .destructive) {
                    Task { await clearLogs() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only removes files from the prototype’s Documents/Diagnostics folder.")
            }
            .task { await reload() }
        }
    }

    private func reload() async {
        logText = await DiagnosticsLogStore.shared.readAllText()
        await refreshExport()
    }

    private func refreshExport() async {
        do {
            exportURL = try await DiagnosticsLogStore.shared.exportURL()
            errorMessage = nil
        } catch {
            errorMessage = "The diagnostics export could not be prepared."
        }
    }

    private func clearLogs() async {
        do {
            try await DiagnosticsLogStore.shared.clear()
            logText = ""
            exportURL = nil
            errorMessage = nil
        } catch {
            errorMessage = "The diagnostics logs could not be cleared."
        }
    }
}
