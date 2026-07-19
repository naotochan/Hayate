import SwiftUI
import AppKit

/// File > Export Picks… — organize into Keep / Maybe / Out (default), or
/// copy/move a filtered selection to a chosen folder, plus bulk trash Out.
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
        case maybe
        case out
        case keepOrMaybe
        case minRating(Int)
    }

    @State private var source: Source = .favorites
    @State private var move = true
    @State private var showTrashConfirmation = false

    private func matches(_ entry: CullingSession.PhotoEntry?) -> Bool {
        switch source {
        case .favorites:
            return entry?.isFavorite == true
        case .maybe:
            return CullingSession.TriageState.of(entry) == .maybe
        case .out:
            return CullingSession.TriageState.of(entry) == .out
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

    private var decidedCount: Int {
        session.files.filter {
            CullingSession.TriageState.of(session.entries[$0.lastPathComponent]) != .undecided
        }.count
    }

    private var rejectedIndices: Set<Int> {
        Set(session.files.enumerated().compactMap { index, url in
            session.entries[url.lastPathComponent]?.isRejected == true ? index : nil
        })
    }

    private var exportBusy: Bool {
        session.exportProgress?.finished == false
    }

    /// Default sibling folder name for the current filter (triage only).
    private var siblingFolderName: String? {
        guard cullingProfileTriage else { return nil }
        switch source {
        case .favorites: return "Keep"
        case .maybe: return "Maybe"
        case .out: return "Out"
        case .keepOrMaybe, .minRating: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.t("Export Picks", ja: "選別結果を書き出す"))
                .font(.title2)
                .fontWeight(.semibold)

            Form {
                Section {
                    Picker(L.t("Action", ja: "操作"), selection: $move) {
                        Text(L.t("Copy", ja: "コピー")).tag(false)
                        Text(L.t("Move", ja: "移動")).tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                if cullingProfileTriage {
                    Section {
                        Text(L.t(
                            "Creates Keep / Maybe / Out next to the shoot and places each decided photo. Undecided stay put.",
                            ja: "撮影フォルダの隣に Keep / Maybe / Out を作り、決定済みを振り分けます。未決定はそのままです。"
                        ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        Text(L.t("\(decidedCount) decided photos", ja: "決定済み \(decidedCount) 枚"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button(L.t("Sort into Keep / Maybe / Out", ja: "Keep / Maybe / Out に振り分け")) {
                            session.organizeIntoTriageFolders(move: move)
                        }
                        .disabled(decidedCount == 0 || exportBusy || session.folderURL == nil)
                    } header: {
                        Text(L.t("Quick organize", ja: "かんたん整理"))
                    }
                }

                Section {
                    Picker(L.t("Photos", ja: "写真"), selection: $source) {
                        if cullingProfileTriage {
                            Text("Keep").tag(Source.favorites)
                            Text("Maybe").tag(Source.maybe)
                            Text("Out").tag(Source.out)
                            Text("Keep + Maybe").tag(Source.keepOrMaybe)
                        } else {
                            Text("♥ Favorites").tag(Source.favorites)
                            ForEach(1...5, id: \.self) { n in
                                Text("Rating ≥ \(n)").tag(Source.minRating(n))
                            }
                        }
                    }
                    Text(L.t("\(matchCount) photos match", ja: "\(matchCount) 枚が一致"))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let name = siblingFolderName, session.folderURL != nil {
                        Button(L.t("Export to \(name)", ja: "\(name) へ書き出す")) {
                            exportToSibling(named: name)
                        }
                        .disabled(matchCount == 0 || exportBusy)
                    }

                    Button(L.t("Choose destination…", ja: "保存先を選ぶ…")) {
                        chooseDestinationAndExport()
                    }
                    .disabled(matchCount == 0 || exportBusy)
                } header: {
                    Text(L.t("Custom export", ja: "保存先を指定"))
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
                             ? L.t("\(rejectedIndices.count) Out photos", ja: "Out \(rejectedIndices.count) 枚")
                             : L.t("\(rejectedIndices.count) rejected photos", ja: "Rejected \(rejectedIndices.count) 枚"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(
                            cullingProfileTriage
                                ? L.t("Move Out to Trash…", ja: "Out をゴミ箱へ…")
                                : L.t("Move Rejected to Trash…", ja: "Rejected をゴミ箱へ…"),
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
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            // A previous export may have finished after the sheet was closed.
            if session.exportProgress?.finished == true {
                session.exportProgress = nil
            }
            if cullingProfileTriage {
                source = .favorites
            }
            // Move is the usual “organize after cull” default.
            move = cullingProfileTriage
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
                    ja: "Out \(rejectedIndices.count) 枚をゴミ箱に移しますか？"
                )
                : L.t(
                    "Move \(rejectedIndices.count) rejected photos to Trash?",
                    ja: "Rejected \(rejectedIndices.count) 枚をゴミ箱に移しますか？"
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

    private func exportToSibling(named name: String) {
        guard let root = session.folderURL else { return }
        let dest = root.appendingPathComponent(name, isDirectory: true)
        session.exportPicks(where: matches, to: dest, move: move)
    }

    private func chooseDestinationAndExport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L.t("Export", ja: "書き出す")
        panel.message = L.t("Choose a destination folder", ja: "保存先フォルダを選んでください")
        if let root = session.folderURL {
            panel.directoryURL = root
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.exportPicks(where: matches, to: url, move: move)
    }
}
