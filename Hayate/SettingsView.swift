import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var keybindings: KeybindingStore
    @EnvironmentObject private var L: LocalizationStore
    @State private var recordingAction: ActionID?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(L.t("General", ja: "一般"), systemImage: "gearshape") }
            shortcutsTab
                .tabItem { Label(L.t("Shortcuts", ja: "ショートカット"), systemImage: "keyboard") }
            cacheTab
                .tabItem { Label(L.t("Cache", ja: "キャッシュ"), systemImage: "internaldrive") }
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - General tab

    @AppStorage("autoAdvance") private var autoAdvance = false
    @AppStorage("writeXMPSidecars") private var writeXMPSidecars = false
    @AppStorage("cullModeDraft") private var cullModeDraft = false
    @AppStorage("colorizeKeepOnly") private var colorizeKeepOnly = true
    @AppStorage("cullingProfileTriage") private var cullingProfileTriage = true
    @AppStorage("sceneGapMinutes") private var sceneGapMinutes = 15
    @AppStorage("appAppearance") private var appAppearance: AppAppearance = .system

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.t("General", ja: "一般"))
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.horizontal)
                .padding(.top)

            Form {
                Section {
                    Picker(L.t("Appearance", ja: "外観"), selection: $appAppearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.label(L.resolved)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(L.t(
                        "Applies immediately to the whole window — sidebar, empty screen, and chrome.",
                        ja: "サイドバー・空画面・枠などウィンドウ全体にすぐ反映されます。"
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Section {
                    Picker(L.t("Language", ja: "言語"), selection: $L.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.pickerLabel).tag(lang)
                        }
                    }
                    Text(L.t(
                        "Applies immediately to menus and on-screen text.",
                        ja: "メニューや画面上の文言にすぐ反映されます。"
                    ))
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Section {
                    Toggle(L.t("Draft cull mode", ja: "下書き選別モード"), isOn: $cullModeDraft)
                    Text(L.t(
                        "Navigate using embedded JPEG (and disk cache) only. Full RAW decode runs when you enable focus peaking (F) or zoom in. Fastest path for large shoots.",
                        ja: "埋め込みJPEG（とディスクキャッシュ）だけでナビゲートします。フォーカスピーキング（F）やズーム時だけフルRAWをデコード。大量撮影向きの最速パスです。"
                    ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Picker(L.t("Culling profile", ja: "選別プロファイル"), selection: $cullingProfileTriage) {
                        Text("Keep / Maybe / Out").tag(true)
                        Text(L.t("Stars (1–5)", ja: "星（1–5）")).tag(false)
                    }
                    Text(cullingProfileTriage
                         ? L.t(
                            "K = Keep, M = Maybe, O = Out. Same key again clears. Stored as favorite / rating 3 / reject so existing files stay compatible.",
                            ja: "K = Keep、M = Maybe、O = Out。同じキーでもう一度押すと解除。favorite / rating 3 / reject として保存し、既存ファイルと互換を保ちます。"
                         )
                         : L.t(
                            "Number keys 1–5 set stars; K favorites; O rejects.",
                            ja: "数字キー1–5で星、K で favorite、O で reject。"
                         ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle(L.t("Colorize Keep only", ja: "Keep だけカラー表示"), isOn: $colorizeKeepOnly)
                    Text(L.t(
                        "In the filmstrip and grid, Keep stays full color; other thumbnails go nearly grayscale. The main viewer is always full color. Badges still show state.",
                        ja: "フィルムストリップとグリッドでは Keep だけフルカラー、他はほぼグレースケール。メインビューアは常にフルカラー。バッジは状態を表示します。"
                    ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle(L.t("Auto-advance after rating", ja: "評価後に自動で次へ"), isOn: $autoAdvance)
                    Text(L.t(
                        "Jump to the next photo after Keep / Maybe / Out (or stars / favorite / reject) in the single-photo view.",
                        ja: "1枚表示で Keep / Maybe / Out（または星 / favorite / reject）のあと、次の写真へ進みます。"
                    ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle(L.t("Write XMP sidecar files", ja: "XMPサイドカーを書き出す"), isOn: $writeXMPSidecars)
                    Text(L.t(
                        "Save ratings next to each RAW as a .xmp file that Lightroom and Capture One can read. Rejected photos get rating −1 (Bridge convention), favorites a red label. Sidecars created by other apps are never modified.",
                        ja: "各RAWの横にLightroomやCapture Oneが読める.xmpを保存。却下は評価−1（Bridge慣習）、お気に入りは赤いラベル。他アプリが作ったサイドカーは変更しません。"
                    ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Picker(L.t("Grid scene gap", ja: "グリッドのシーン区切り"), selection: $sceneGapMinutes) {
                        Text(L.t("Off", ja: "オフ")).tag(0)
                        Text(L.t("5 minutes", ja: "5分")).tag(5)
                        Text(L.t("10 minutes", ja: "10分")).tag(10)
                        Text(L.t("15 minutes", ja: "15分")).tag(15)
                        Text(L.t("30 minutes", ja: "30分")).tag(30)
                        Text(L.t("60 minutes", ja: "60分")).tag(60)
                    }
                    Text(L.t(
                        "Draw a thin separator in the grid when consecutive photos are farther apart than this (by EXIF capture time). Photos without EXIF dates never create a break.",
                        ja: "連続する写真の撮影時刻（EXIF）がこの間隔より空いたとき、グリッドに細い区切りを描きます。EXIF日付がない写真では区切りません。"
                    ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button(L.t("Show Welcome Guide…", ja: "ようこそガイドを表示…")) {
                        NotificationCenter.default.post(name: .showOnboarding, object: nil)
                    }
                    Text(L.t(
                        "Reopen the 3-step intro (open folder, cull keys, sidebar / shortcuts).",
                        ja: "3ステップの導入（フォルダを開く、選別キー、サイドバー / ショートカット）を再表示します。"
                    ))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            Spacer()
        }
    }

    // MARK: - Cache tab

    @AppStorage("previewCacheSizeLimitGB") private var cacheSizeLimitGB: Int = 10
    @AppStorage("previewCacheLocation") private var cacheLocationPath: String = ""
    @State private var cacheUsageBytes: Int64 = 0
    @State private var cacheFileCount: Int = 0
    @State private var showClearConfirmation = false

    private var effectiveCacheRoot: URL {
        if cacheLocationPath.isEmpty {
            return DiskCacheManager.defaultCacheRoot
        }
        return URL(fileURLWithPath: cacheLocationPath, isDirectory: true)
    }

    private var cacheTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.t("Preview Cache", ja: "プレビューキャッシュ"))
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.horizontal)
                .padding(.top)

            Form {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.t("Cache Location", ja: "キャッシュの場所"))
                                .fontWeight(.medium)
                            Text(effectiveCacheRoot.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(L.t("Change…", ja: "変更…")) {
                            chooseCacheLocation()
                        }
                        if !cacheLocationPath.isEmpty {
                            Button(L.t("Reset", ja: "リセット")) {
                                cacheLocationPath = ""
                            }
                            .controlSize(.small)
                        }
                    }

                    Picker(L.t("Maximum Cache Size", ja: "キャッシュ上限"), selection: $cacheSizeLimitGB) {
                        Text("1 GB").tag(1)
                        Text("5 GB").tag(5)
                        Text("10 GB").tag(10)
                        Text("20 GB").tag(20)
                        Text("50 GB").tag(50)
                        Text(L.t("Unlimited", ja: "無制限")).tag(0)
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.t("Current Usage", ja: "現在の使用量"))
                                .fontWeight(.medium)
                            Text(L.t(
                                "\(formattedSize(cacheUsageBytes)) — \(cacheFileCount) files",
                                ja: "\(formattedSize(cacheUsageBytes)) — \(cacheFileCount) ファイル"
                            ))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(L.t("Clear Cache", ja: "キャッシュをクリア")) {
                            showClearConfirmation = true
                        }
                        .disabled(cacheFileCount == 0)
                    }
                }
            }
            .formStyle(.grouped)

            Text(L.t(
                "Cache location changes take effect on next app launch.",
                ja: "キャッシュ場所の変更は次回起動時に反映されます。"
            ))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            Spacer()
        }
        .onAppear { refreshCacheUsage() }
        .onChange(of: cacheSizeLimitGB) { _ in triggerEviction() }
        .alert(L.t("Clear Preview Cache?", ja: "プレビューキャッシュをクリアしますか？"), isPresented: $showClearConfirmation) {
            Button(L.t("Clear", ja: "クリア"), role: .destructive) { clearCache() }
            Button(L.t("Cancel", ja: "キャンセル"), role: .cancel) {}
        } message: {
            Text(L.t(
                "This will delete all \(cacheFileCount) cached preview files (\(formattedSize(cacheUsageBytes))). Previews will be regenerated as you browse.",
                ja: "キャッシュ済みプレビュー \(cacheFileCount) 件（\(formattedSize(cacheUsageBytes))）をすべて削除します。閲覧に応じて再生成されます。"
            ))
        }
    }

    private func chooseCacheLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L.t("Select", ja: "選択")
        panel.message = L.t(
            "Choose a folder to store preview cache files",
            ja: "プレビューキャッシュを保存するフォルダを選んでください"
        )
        if panel.runModal() == .OK, let url = panel.url {
            cacheLocationPath = url.path
        }
    }

    private func refreshCacheUsage() {
        Task {
            let cache = DiskCacheManager(cacheRoot: effectiveCacheRoot)
            let size = await cache.totalSize()
            let count = await cache.entryCount()
            await MainActor.run {
                cacheUsageBytes = size
                cacheFileCount = count
            }
        }
    }

    private func clearCache() {
        Task {
            let cache = DiskCacheManager(cacheRoot: effectiveCacheRoot)
            await cache.clear()
            await MainActor.run {
                cacheUsageBytes = 0
                cacheFileCount = 0
            }
        }
    }

    private func triggerEviction() {
        guard cacheSizeLimitGB > 0 else { return }
        let limit = Int64(cacheSizeLimitGB) * 1_073_741_824
        Task {
            let cache = DiskCacheManager(cacheRoot: effectiveCacheRoot)
            await cache.evict(maxBytes: limit)
            refreshCacheUsage()
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Shortcuts tab

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.t("Keyboard Shortcuts", ja: "キーボードショートカット"))
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(L.t("Reset to Defaults", ja: "デフォルトに戻す")) {
                    keybindings.resetToDefaults()
                    recordingAction = nil
                }
            }
            .padding(.horizontal)
            .padding(.top)

            Text(L.t(
                "Rating keys (0–5), ⎋, ?, and ⌘, are fixed and cannot be rebound. Press ? or / for the on-screen cheat sheet.",
                ja: "評価キー（0–5）、⎋、?、⌘, は固定で変更できません。? または / で画面上の早見表を表示します。"
            ))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            List {
                ForEach(ActionID.Category.allCases) { category in
                    Section(category.title) {
                        ForEach(actions(in: category)) { action in
                            row(for: action)
                        }
                    }
                }
            }
        }
    }

    private func actions(in category: ActionID.Category) -> [ActionID] {
        ActionID.allCases.filter { $0.category == category }
    }

    private func row(for action: ActionID) -> some View {
        HStack {
            Text(action.title)
            Spacer()
            if recordingAction == action {
                ShortcutRecorder(
                    prompt: L.t("Press a key…", ja: "キーを押してください…"),
                    onCapture: { shortcut in
                        keybindings.bind(shortcut, to: action)
                        recordingAction = nil
                    },
                    onCancel: {
                        recordingAction = nil
                    }
                )
            } else {
                Text(keybindings.bindings[action]?.display ?? "—")
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .monospaced))
                Button(L.t("Record", ja: "記録")) {
                    recordingAction = action
                }
                .controlSize(.small)
                if keybindings.bindings[action] != nil {
                    Button {
                        keybindings.clear(action)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L.t("Clear binding", ja: "割り当てを解除"))
                }
            }
        }
    }
}

/// One-shot recorder: pops up a capture field that consumes the next keyDown
/// and hands the result back via `onCapture`.
private struct ShortcutRecorder: NSViewRepresentable {
    let prompt: String
    let onCapture: (Shortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.prompt = prompt
        view.onCapture = onCapture
        view.onCancel = onCancel
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.prompt = prompt
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        nsView.needsDisplay = true
    }

    final class RecorderView: NSView {
        var prompt: String = "Press a key…"
        var onCapture: ((Shortcut) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            bounds.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.controlAccentColor,
            ]
            let text = prompt
            let size = (text as NSString).size(withAttributes: attrs)
            let origin = NSPoint(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2
            )
            (text as NSString).draw(at: origin, withAttributes: attrs)
        }

        override var intrinsicContentSize: NSSize {
            NSSize(width: 120, height: 22)
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // escape — cancel
                onCancel?()
                return
            }
            guard let shortcut = Shortcut(event: event) else {
                onCancel?()
                return
            }
            onCapture?(shortcut)
        }
    }
}
