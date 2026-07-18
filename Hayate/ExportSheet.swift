import SwiftUI
import AppKit

/// File > Export Picks… — copy or move a filtered selection of photos to a
/// destination folder, plus a bulk "trash all rejected" action.
struct ExportSheet: View {
    @EnvironmentObject var session: CullingSession
    @EnvironmentObject private var L: LocalizationStore
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
            Text(L.t("Export Picks", ja: "選別結果を書き出す"))
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                Section {
                    Picker(L.t("Photos", ja: "写真"), selection: $source) {
                        if cullingProfileTriage {
                            Text(L.t("Keep", ja: "キープ")).tag(Source.favorites)
                            Text(L.t("Keep + Maybe", ja: "キープ + 保留")).tag(Source.keepOrMaybe)
                        } else {
                            Text(L.t("♥ Favorites", ja: "♥ お気に入り")).tag(Source.favorites)
                            ForEach(1...5, id: \.self) { n in
                                Text(L.t("Rating ≥ \(n)", ja: "評価 ≥ \(n)")).tag(Source.minRating(n))
                            }
                        }
                    }
                    Picker(L.t("Action", ja: "操作"), selection: $move) {
                        Text(L.t("Copy", ja: "コピー")).tag(false)
                        Text(L.t("Move", ja: "移動")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text(L.t("\(matchCount) photos match", ja: "\(matchCount) 枚が一致"))
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
                             ? L.t("\(rejectedIndices.count) Out photos", ja: "アウト \(rejectedIndices.count) 枚")
                             : L.t("\(rejectedIndices.count) rejected photos", ja: "却下 \(rejectedIndices.count) 枚"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(
                            cullingProfileTriage
                                ? L.t("Move Out to Trash…", ja: "アウトをゴミ箱へ…")
                                : L.t("Move Rejected to Trash…", ja: "却下をゴミ箱へ…"),
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
                Button(session.exportProgress?.finished == true
                       ? L.t("Done", ja: "完了")
                       : L.t("Cancel", ja: "キャンセル")) {
                    // Cancelling while an export runs stops it after the
                    // file currently in flight.
                    if session.exportProgress?.finished == false {
                        session.cancelExport()
                    }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(L.t("Export…", ja: "書き出す…")) {
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
                ? L.t(
                    "Move \(rejectedIndices.count) Out photos to Trash?",
                    ja: "アウト \(rejectedIndices.count) 枚をゴミ箱に移しますか？"
                )
                : L.t(
                    "Move \(rejectedIndices.count) rejected photos to Trash?",
                    ja: "却下 \(rejectedIndices.count) 枚をゴミ箱に移しますか？"
                ),
            isPresented: $showTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button(L.t("Move to Trash", ja: "ゴミ箱に移す"), role: .destructive) {
                session.deleteFilesAtIndices(rejectedIndices)
                onBulkDelete()
            }
            Button(L.t("Cancel", ja: "キャンセル"), role: .cancel) {}
        }
    }

    private func progressText(_ progress: CullingSession.ExportProgress) -> String {
        if progress.finished {
            return progress.failed > 0
                ? L.t(
                    "Done — \(progress.completed - progress.failed) exported, \(progress.failed) failed (already exists or unwritable)",
                    ja: "完了 — \(progress.completed - progress.failed) 件書き出し、\(progress.failed) 件失敗（既存または書き込み不可）"
                )
                : L.t("Done — \(progress.completed) exported", ja: "完了 — \(progress.completed) 件書き出し")
        }
        return L.t(
            "Exporting \(progress.completed)/\(progress.total)…",
            ja: "書き出し中 \(progress.completed)/\(progress.total)…"
        )
    }

    private func chooseDestinationAndExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L.t("Export", ja: "書き出す")
        panel.message = L.t("Choose a destination folder", ja: "保存先フォルダを選んでください")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.exportPicks(where: matches, to: url, move: move)
    }
}
