import SwiftUI
import AppKit

/// File > Export Picks… — copy or move Keep / Out photos into destination/Keep and destination/Out.
struct ExportSheet: View {
    @EnvironmentObject var session: CullingSession
    @EnvironmentObject private var L: LocalizationStore
    @Environment(\.dismiss) private var dismiss

    @State private var destination: URL?
    @State private var move = false

    private var counts: CullingSession.TriageCounts { session.triageCounts }

    private var decidedCount: Int { counts.keep + counts.out }

    private var exportBusy: Bool {
        session.exportProgress?.finished == false
    }

    private var exportFinished: Bool {
        session.exportProgress?.finished == true
    }

    private var executeEnabled: Bool {
        decidedCount > 0 && !exportBusy && !exportFinished && destination != nil
    }

    private var destinationPath: String {
        destination?.path ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HayateChrome.groupSpacing) {
            HayateChrome.PageTitle(title: L.t("Export Picks", ja: "選別結果を書き出す"))

            HayateChrome.Panel(title: L.t("Export", ja: "書き出し")) {
                HayateChrome.Row(
                    title: L.t("Destination", ja: "保存先"),
                    subtitle: destinationPath.isEmpty
                        ? L.t("Choose a folder.", ja: "フォルダを選んでください。")
                        : destinationPath
                ) {
                    Button(L.t("Choose…", ja: "選択…")) {
                        chooseDestination()
                    }
                    .controlSize(.small)
                    .disabled(exportBusy)
                }

                HayateChrome.RowSeparator()

                HayateChrome.Row(
                    title: L.t("Copy or move", ja: "コピーまたは移動"),
                    subtitle: L.t(
                        "Keep \(counts.keep) / Out \(counts.out) will be placed into Keep/ and Out/ under the destination. Undecided photos stay in the shoot.",
                        ja: "Keep \(counts.keep) / Out \(counts.out) を保存先の Keep/ と Out/ に振り分けます。未決定は撮影フォルダに残ります。"
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

            HStack {
                Spacer()
                Button(exportFinished
                       ? L.t("Done", ja: "完了")
                       : L.t("Cancel", ja: "キャンセル")) {
                    if exportBusy {
                        session.cancelExport()
                    }
                    dismiss()
                }
                .keyboardShortcut(exportFinished ? .defaultAction : .cancelAction)

                executeButton
            }
        }
        .padding(.horizontal, HayateChrome.pageHorizontalPadding)
        .padding(.vertical, HayateChrome.pageVerticalPadding)
        .frame(width: 520)
        .background(HayateTheme.settingsCanvas)
        .onAppear {
            if session.exportProgress?.finished == true {
                session.exportProgress = nil
            }
            destination = session.folderURL
        }
        .onDisappear {
            if session.exportProgress?.finished == true {
                session.exportProgress = nil
            }
        }
    }

    private var executeButton: some View {
        let label = L.t("Execute", ja: "実行")
        let run = {
            guard let dest = destination else { return }
            session.organizeIntoTriageFolders(into: dest, move: move)
        }
        return Group {
            if executeEnabled {
                Button(label, action: run).keyboardShortcut(.defaultAction)
            } else {
                Button(label, action: run).disabled(true)
            }
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

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L.t("Choose", ja: "選択")
        panel.message = L.t("Choose a destination folder", ja: "保存先フォルダを選んでください")
        if let dest = destination ?? session.folderURL {
            panel.directoryURL = dest
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
    }
}
