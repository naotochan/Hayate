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
        VStack(alignment: .leading, spacing: HayateChrome.groupSpacing) {
            HayateChrome.PageTitle(title: L.t("Export Picks", ja: "選別結果を書き出す"))

            HayateChrome.Panel(title: L.t("Action", ja: "操作")) {
                HayateChrome.Row(
                    title: L.t("Copy or move", ja: "コピーまたは移動"),
                    subtitle: L.t(
                        "Applies to quick organize and custom export.",
                        ja: "かんたん整理と保存先指定の両方に適用されます。"
                    )
                ) {
                    Picker("", selection: $move) {
                        Text(L.t("Copy", ja: "コピー")).tag(false)
                        Text(L.t("Move", ja: "移動")).tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }
            }

            if cullingProfileTriage {
                HayateChrome.Panel(title: L.t("Quick organize", ja: "かんたん整理")) {
                    HayateChrome.Row(
                        title: L.t("Keep / Maybe / Out", ja: "Keep / Maybe / Out"),
                        subtitle: L.t(
                            "Creates Keep / Maybe / Out next to the shoot and places each decided photo. Undecided stay put. \(decidedCount) decided photos.",
                            ja: "撮影フォルダの隣に Keep / Maybe / Out を作り、決定済みを振り分けます。未決定はそのままです。決定済み \(decidedCount) 枚。"
                        )
                    ) {
                        Button(L.t("Sort…", ja: "振り分け…")) {
                            session.organizeIntoTriageFolders(move: move)
                        }
                        .controlSize(.small)
                        .disabled(decidedCount == 0 || exportBusy || session.folderURL == nil)
                    }
                }
            }

            HayateChrome.Panel(title: L.t("Custom export", ja: "保存先を指定")) {
                HayateChrome.Row(
                    title: L.t("Photos", ja: "写真"),
                    subtitle: L.t("\(matchCount) photos match", ja: "\(matchCount) 枚が一致")
                ) {
                    Picker("", selection: $source) {
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
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 160)
                }

                HayateChrome.RowSeparator()

                HayateChrome.Row(
                    title: L.t("Destination", ja: "保存先"),
                    subtitle: siblingFolderName.map {
                        L.t("Sibling folder '\($0)' or choose another.", ja: "隣の「\($0)」フォルダ、または別の場所を選択。")
                    } ?? L.t("Choose a folder to export into.", ja: "書き出し先フォルダを選びます。")
                ) {
                    HStack(spacing: 8) {
                        if let name = siblingFolderName, session.folderURL != nil {
                            Button(L.t("Export to \(name)", ja: "\(name) へ")) {
                                exportToSibling(named: name)
                            }
                            .controlSize(.small)
                            .disabled(matchCount == 0 || exportBusy)
                        }
                        Button(L.t("Choose…", ja: "選択…")) {
                            chooseDestinationAndExport()
                        }
                        .controlSize(.small)
                        .disabled(matchCount == 0 || exportBusy)
                    }
                }
            }

            if let progress = session.exportProgress {
                HayateChrome.Panel(title: L.t("Progress", ja: "進捗")) {
                    HayateChrome.Row(
                        title: progressText(progress),
                        subtitle: nil
                    ) {
                        ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                            .frame(width: 120)
                    }
                }
            }

            HayateChrome.Panel(title: L.t("Cleanup", ja: "クリーンアップ")) {
                HayateChrome.Row(
                    title: cullingProfileTriage
                        ? L.t("Out photos", ja: "Out の写真")
                        : L.t("Rejected photos", ja: "Rejected の写真"),
                    subtitle: cullingProfileTriage
                        ? L.t("\(rejectedIndices.count) Out photos", ja: "Out \(rejectedIndices.count) 枚")
                        : L.t("\(rejectedIndices.count) rejected photos", ja: "Rejected \(rejectedIndices.count) 枚")
                ) {
                    Button(
                        cullingProfileTriage
                            ? L.t("Move to Trash…", ja: "ゴミ箱へ…")
                            : L.t("Move to Trash…", ja: "ゴミ箱へ…"),
                        role: .destructive
                    ) {
                        showTrashConfirmation = true
                    }
                    .controlSize(.small)
                    .disabled(rejectedIndices.isEmpty)
                }
            }

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
        .padding(.horizontal, HayateChrome.pageHorizontalPadding)
        .padding(.vertical, HayateChrome.pageVerticalPadding)
        .frame(width: 520)
        .background(HayateTheme.canvas)
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
