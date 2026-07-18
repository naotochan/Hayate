import SwiftUI
import AppKit

/// File > Export Picks… — copy or move a filtered selection of photos to a
/// destination folder, plus a bulk "trash all rejected" action.
struct ExportSheet: View {
    @EnvironmentObject var session: CullingSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cullingProfileTriage") private var cullingProfileTriage = true

    /// Called after the bulk "move rejected to Trash" action so the host
    /// view can reload the displayed photo and clear stale selections.
    var onBulkDelete: () -> Void = {}

    enum Source: Hashable {
        case favorites
        case keepOrMaybe
        case minRating(Int)
    }

    @State private var source: Source = .favorites
    @State private var move = false
    @State private var showTrashConfirmation = false

    private func matches(_ entry: CullingSession.PhotoEntry?) -> Bool {
        switch source {
        case .favorites:
            return entry?.isFavorite == true
        case .keepOrMaybe:
            let state = CullingSession.TriageState.of(entry)
            return state == .keep || state == .maybe
        case .minRating(let n):
            return (entry?.rating ?? 0) >= n
        }
    }

    private var matchCount: Int {
        session.files.filter { matches(session.entries[$0.lastPathComponent]) }.count
    }

    private var rejectedIndices: Set<Int> {
        Set(session.files.enumerated().compactMap { index, url in
            session.entries[url.lastPathComponent]?.isRejected == true ? index : nil
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Picks")
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                Section {
                    Picker("Photos", selection: $source) {
                        if cullingProfileTriage {
                            Text("Keep").tag(Source.favorites)
                            Text("Keep + Maybe").tag(Source.keepOrMaybe)
                        } else {
                            Text("♥ Favorites").tag(Source.favorites)
                            ForEach(1...5, id: \.self) { n in
                                Text("Rating ≥ \(n)").tag(Source.minRating(n))
                            }
                        }
                    }
                    Picker("Action", selection: $move) {
                        Text("Copy").tag(false)
                        Text("Move").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text("\(matchCount) photos match")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let progress = session.exportProgress {
                    Section {
                        ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        Text(progressText(progress))
                            .font(.caption)
                            .foregroundColor(progress.failed > 0 ? .orange : .secondary)
                    }
                }

                Section {
                    HStack {
                        Text(cullingProfileTriage
                             ? "\(rejectedIndices.count) Out photos"
                             : "\(rejectedIndices.count) rejected photos")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(
                            cullingProfileTriage ? "Move Out to Trash…" : "Move Rejected to Trash…",
                            role: .destructive
                        ) {
                            showTrashConfirmation = true
                        }
                        .disabled(rejectedIndices.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(session.exportProgress?.finished == true ? "Done" : "Cancel") {
                    // Cancelling while an export runs stops it after the
                    // file currently in flight.
                    if session.exportProgress?.finished == false {
                        session.cancelExport()
                    }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    chooseDestinationAndExport()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(matchCount == 0 || session.exportProgress?.finished == false)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            // A previous export may have finished after the sheet was closed.
            if session.exportProgress?.finished == true {
                session.exportProgress = nil
            }
        }
        .onDisappear {
            // Clear finished progress so the next export starts clean.
            if session.exportProgress?.finished == true {
                session.exportProgress = nil
            }
        }
        .confirmationDialog(
            cullingProfileTriage
                ? "Move \(rejectedIndices.count) Out photos to Trash?"
                : "Move \(rejectedIndices.count) rejected photos to Trash?",
            isPresented: $showTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                session.deleteFilesAtIndices(rejectedIndices)
                onBulkDelete()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func progressText(_ progress: CullingSession.ExportProgress) -> String {
        if progress.finished {
            return progress.failed > 0
                ? "Done — \(progress.completed - progress.failed) exported, \(progress.failed) failed (already exists or unwritable)"
                : "Done — \(progress.completed) exported"
        }
        return "Exporting \(progress.completed)/\(progress.total)…"
    }

    private func chooseDestinationAndExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a destination folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.exportPicks(where: matches, to: url, move: move)
    }
}
