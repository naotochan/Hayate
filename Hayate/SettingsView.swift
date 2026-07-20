import SwiftUI
import AppKit

/// Preference window — canonical layout for Hayate panel UI.
/// Shared chrome: `HayateChrome` + `HayateTheme`. Guideline: `.cursor/rules/ui-design.mdc`.

// MARK: - Category

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case cache

    var id: String { rawValue }

    func title(_ L: LocalizationStore) -> String {
        switch self {
        case .general: return L.t("General", ja: "一般")
        case .shortcuts: return L.t("Shortcuts", ja: "ショートカット")
        case .cache: return L.t("Cache", ja: "キャッシュ")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .cache: return "internaldrive"
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @EnvironmentObject private var keybindings: KeybindingStore
    @EnvironmentObject private var L: LocalizationStore
    @State private var category: SettingsCategory = .general
    @State private var searchText = ""
    @State private var recordingAction: ActionID?

    @AppStorage("autoAdvance") private var autoAdvance = false
    @AppStorage("navigateUndecidedOnly") private var navigateUndecidedOnly = false
    @AppStorage("writeXMPSidecars") private var writeXMPSidecars = false
    @AppStorage("colorizeKeepOnly") private var colorizeKeepOnly = true
    @AppStorage("cullingProfileTriage") private var cullingProfileTriage = true
    @AppStorage("sceneGapMinutes") private var sceneGapMinutes = 15
    @AppStorage("appAppearance") private var appAppearance: AppAppearance = .system
    @AppStorage("previewCacheSizeLimitGB") private var cacheSizeLimitGB: Int = 10
    @AppStorage("previewCacheLocation") private var cacheLocationPath: String = ""

    @State private var cacheUsageBytes: Int64 = 0
    @State private var cacheFileCount: Int = 0
    @State private var showClearConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            contentPane
        }
        .frame(width: 760, height: 580)
        .background(HayateTheme.canvas)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HayateChrome.SearchField(
                placeholder: L.t("Search Settings", ja: "設定を検索"),
                text: $searchText
            )
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)

            VStack(spacing: 2) {
                ForEach(filteredCategories) { item in
                    HayateChrome.SidebarItem(
                        title: item.title(L),
                        systemImage: item.systemImage,
                        isSelected: category == item
                    ) {
                        category = item
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)
        }
        .frame(width: HayateChrome.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(HayateTheme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(HayateTheme.separator)
                .frame(width: 1)
        }
    }

    private var filteredCategories: [SettingsCategory] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return SettingsCategory.allCases }
        return SettingsCategory.allCases.filter { item in
            item.title(L).lowercased().contains(q)
                || categorySearchBlob(item).lowercased().contains(q)
        }
    }

    private func categorySearchBlob(_ item: SettingsCategory) -> String {
        switch item {
        case .general:
            return [
                "appearance", "language", "culling", "keep", "maybe", "out", "stars",
                "auto-advance", "skip", "xmp", "grid", "welcome", "外観", "言語", "選別",
                "自動", "スキップ", "グリッド", "ようこそ",
            ].joined(separator: " ")
        case .shortcuts:
            return "keyboard shortcuts ショートカット キー"
        case .cache:
            return "preview cache location size キャッシュ プレビュー"
        }
    }

    // MARK: - Content

    private var contentPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HayateChrome.PageTitle(title: category.title(L))
                    .padding(.bottom, 2)

                switch category {
                case .general:
                    generalContent
                case .shortcuts:
                    shortcutsContent
                case .cache:
                    cacheContent
                }
            }
            .padding(.horizontal, HayateChrome.pageHorizontalPadding)
            .padding(.vertical, HayateChrome.pageVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HayateTheme.canvas)
        .onAppear {
            if category == .cache { refreshCacheUsage() }
        }
        .onChange(of: category) { _, newValue in
            if newValue == .cache { refreshCacheUsage() }
        }
        .onChange(of: searchText) { _, _ in
            let matches = filteredCategories
            if !matches.contains(category), let first = matches.first {
                category = first
            }
        }
    }

    // MARK: - General

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: HayateChrome.groupSpacing) {
            HayateChrome.Group(title: L.t("Appearance", ja: "外観")) {
                HayateChrome.Row(
                    title: L.t("Theme", ja: "テーマ"),
                    subtitle: L.t(
                        "Applies immediately to the whole window — sidebar, empty screen, and chrome.",
                        ja: "サイドバー・空画面・枠などウィンドウ全体にすぐ反映されます。"
                    )
                ) {
                    Picker("", selection: $appAppearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.label(L.resolved)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 140)
                }

                HayateChrome.Divider()

                HayateChrome.Row(
                    title: L.t("Language", ja: "言語"),
                    subtitle: L.t(
                        "Applies immediately to menus and on-screen text.",
                        ja: "メニューや画面上の文言にすぐ反映されます。"
                    )
                ) {
                    Picker("", selection: $L.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.pickerLabel).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 160)
                }
            }

            HayateChrome.Group(title: L.t("Culling", ja: "選別")) {
                HayateChrome.Row(
                    title: L.t("Culling profile", ja: "選別プロファイル"),
                    subtitle: cullingProfileTriage
                        ? L.t(
                            "K = Keep, M = Maybe, O = Out. Same key again clears. Stored as favorite / rating 3 / reject so existing files stay compatible.",
                            ja: "K = Keep、M = Maybe、O = Out。同じキーでもう一度押すと解除。favorite / rating 3 / reject として保存し、既存ファイルと互換を保ちます。"
                        )
                        : L.t(
                            "Number keys 1–5 set stars; K favorites; O rejects.",
                            ja: "数字キー1–5で星、K で favorite、O で reject。"
                        )
                ) {
                    Picker("", selection: $cullingProfileTriage) {
                        Text("Keep / Maybe / Out").tag(true)
                        Text(L.t("Stars (1–5)", ja: "星（1–5）")).tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 170)
                }

                HayateChrome.Divider()

                HayateChrome.ToggleRow(
                    title: L.t("Colorize Keep only", ja: "Keep だけカラー表示"),
                    subtitle: L.t(
                        "In the filmstrip and grid, Keep stays full color; other thumbnails go nearly grayscale. The main viewer is always full color. Badges still show state.",
                        ja: "フィルムストリップとグリッドでは Keep だけフルカラー、他はほぼグレースケール。メインビューアは常にフルカラー。バッジは状態を表示します。"
                    ),
                    isOn: $colorizeKeepOnly
                )
            }

            HayateChrome.Group(title: L.t("Navigation", ja: "ナビゲーション")) {
                HayateChrome.ToggleRow(
                    title: L.t("Auto-advance after rating", ja: "評価後に自動で次へ"),
                    subtitle: L.t(
                        "Jump to the next photo after Keep / Maybe / Out (or stars / favorite / reject) in the single-photo view.",
                        ja: "1枚表示で Keep / Maybe / Out（または星 / favorite / reject）のあと、次の写真へ進みます。"
                    ),
                    isOn: $autoAdvance
                )

                HayateChrome.Divider()

                HayateChrome.ToggleRow(
                    title: L.t("Skip decided photos", ja: "決定済みをスキップ"),
                    subtitle: L.t(
                        "J / L and arrow keys jump to the next undecided photo. Already Keep / Maybe / Out (or rated / favorite / reject) are skipped. Use this for a second pass over leftovers.",
                        ja: "J / L と矢印キーで未決定の写真だけへ進みます。Keep / Maybe / Out（または星 / favorite / reject）済みは飛ばします。残りの再周回向けです。"
                    ),
                    isOn: $navigateUndecidedOnly
                )
            }

            HayateChrome.Group(title: L.t("Sidecars", ja: "サイドカー")) {
                HayateChrome.ToggleRow(
                    title: L.t("Write XMP sidecar files", ja: "XMPサイドカーを書き出す"),
                    subtitle: L.t(
                        "Save ratings next to each RAW as a .xmp file that Lightroom and Capture One can read. Rejected photos get rating −1 (Bridge convention), favorites a red label. Sidecars created by other apps are never modified.",
                        ja: "各RAWの横にLightroomやCapture Oneが読める.xmpを保存。却下は評価−1（Bridge慣習）、お気に入りは赤いラベル。他アプリが作ったサイドカーは変更しません。"
                    ),
                    isOn: $writeXMPSidecars
                )
            }

            HayateChrome.Group(title: L.t("Grid", ja: "グリッド")) {
                HayateChrome.Row(
                    title: L.t("Grid scene gap", ja: "グリッドのシーン区切り"),
                    subtitle: L.t(
                        "Draw a thin separator in the grid when consecutive photos are farther apart than this (by EXIF capture time). Photos without EXIF dates never create a break.",
                        ja: "連続する写真の撮影時刻（EXIF）がこの間隔より空いたとき、グリッドに細い区切りを描きます。EXIF日付がない写真では区切りません。"
                    )
                ) {
                    Picker("", selection: $sceneGapMinutes) {
                        Text(L.t("Off", ja: "オフ")).tag(0)
                        Text(L.t("5 minutes", ja: "5分")).tag(5)
                        Text(L.t("10 minutes", ja: "10分")).tag(10)
                        Text(L.t("15 minutes", ja: "15分")).tag(15)
                        Text(L.t("30 minutes", ja: "30分")).tag(30)
                        Text(L.t("60 minutes", ja: "60分")).tag(60)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 120)
                }
            }

            HayateChrome.Group(title: L.t("Help", ja: "ヘルプ")) {
                HayateChrome.Row(
                    title: L.t("Welcome Guide", ja: "ようこそガイド"),
                    subtitle: L.t(
                        "Reopen the 3-step intro (open folder, cull keys, sidebar / shortcuts).",
                        ja: "3ステップの導入（フォルダを開く、選別キー、サイドバー / ショートカット）を再表示します。"
                    )
                ) {
                    Button(L.t("Show…", ja: "表示…")) {
                        NotificationCenter.default.post(name: .showOnboarding, object: nil)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Text(L.t(
                    "Rating keys (0–5), ⎋, ?, and ⌘, are fixed and cannot be rebound. Press ? or / for the on-screen cheat sheet.",
                    ja: "評価キー（0–5）、⎋、?、⌘, は固定で変更できません。? または / で画面上の早見表を表示します。"
                ))
                .font(.system(size: 12))
                .foregroundColor(HayateTheme.fg(0.45))
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)

                Button(L.t("Reset to Defaults", ja: "デフォルトに戻す")) {
                    keybindings.resetToDefaults()
                    recordingAction = nil
                }
                .controlSize(.small)
            }

            ForEach(ActionID.Category.allCases) { cat in
                HayateChrome.Group(title: cat.title(lang: L.resolved)) {
                    let items = actions(in: cat)
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, action in
                        shortcutRow(for: action)
                        if index < items.count - 1 {
                            HayateChrome.Divider()
                        }
                    }
                }
            }
        }
    }

    private func actions(in category: ActionID.Category) -> [ActionID] {
        ActionID.allCases.filter { $0.category == category }
    }

    private func shortcutRow(for action: ActionID) -> some View {
        HayateChrome.Row(title: action.title(lang: L.resolved), subtitle: nil) {
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
                .frame(width: 120, height: 22)
            } else {
                HStack(spacing: 8) {
                    Text(keybindings.bindings[action]?.display ?? "—")
                        .foregroundColor(HayateTheme.fg(0.45))
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
                                .foregroundColor(HayateTheme.fg(0.35))
                        }
                        .buttonStyle(.plain)
                        .help(L.t("Clear binding", ja: "割り当てを解除"))
                    }
                }
            }
        }
    }

    // MARK: - Cache

    private var effectiveCacheRoot: URL {
        if cacheLocationPath.isEmpty {
            return DiskCacheManager.defaultCacheRoot
        }
        return URL(fileURLWithPath: cacheLocationPath, isDirectory: true)
    }

    private var cacheContent: some View {
        VStack(alignment: .leading, spacing: HayateChrome.groupSpacing) {
            HayateChrome.Group(title: L.t("Location & Size", ja: "場所と容量")) {
                HayateChrome.Row(
                    title: L.t("Cache Location", ja: "キャッシュの場所"),
                    subtitle: effectiveCacheRoot.path
                ) {
                    HStack(spacing: 8) {
                        Button(L.t("Change…", ja: "変更…")) {
                            chooseCacheLocation()
                        }
                        .controlSize(.small)
                        if !cacheLocationPath.isEmpty {
                            Button(L.t("Reset", ja: "リセット")) {
                                cacheLocationPath = ""
                            }
                            .controlSize(.small)
                        }
                    }
                }

                HayateChrome.Divider()

                HayateChrome.Row(
                    title: L.t("Maximum Cache Size", ja: "キャッシュ上限"),
                    subtitle: L.t(
                        "Cache location changes take effect on next app launch.",
                        ja: "キャッシュ場所の変更は次回起動時に反映されます。"
                    )
                ) {
                    Picker("", selection: $cacheSizeLimitGB) {
                        Text("1 GB").tag(1)
                        Text("5 GB").tag(5)
                        Text("10 GB").tag(10)
                        Text("20 GB").tag(20)
                        Text("50 GB").tag(50)
                        Text(L.t("Unlimited", ja: "無制限")).tag(0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 120)
                }
            }

            HayateChrome.Group(title: L.t("Usage", ja: "使用量")) {
                HayateChrome.Row(
                    title: L.t("Current Usage", ja: "現在の使用量"),
                    subtitle: L.t(
                        "\(formattedSize(cacheUsageBytes)) — \(cacheFileCount) files",
                        ja: "\(formattedSize(cacheUsageBytes)) — \(cacheFileCount) ファイル"
                    )
                ) {
                    Button(L.t("Clear Cache", ja: "キャッシュをクリア")) {
                        showClearConfirmation = true
                    }
                    .controlSize(.small)
                    .disabled(cacheFileCount == 0)
                }
            }
        }
        .onChange(of: cacheSizeLimitGB) { _, _ in triggerEviction() }
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
