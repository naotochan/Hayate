import SwiftUI

extension Notification.Name {
    /// Posted from Settings / Help menu to re-show the welcome guide.
    static let showOnboarding = Notification.Name("hayate.showOnboarding")
}

/// Anchors for coach-mark spotlights. Views report their frames via preference.
enum OnboardingAnchor: Hashable {
    case openFolderButton
    case folderList
    case dropArea
}

struct OnboardingAnchorKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [OnboardingAnchor: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [OnboardingAnchor: Anchor<CGRect>],
        nextValue: () -> [OnboardingAnchor: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    func onboardingAnchor(_ id: OnboardingAnchor) -> some View {
        anchorPreference(key: OnboardingAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

/// Coach-mark onboarding that spotlights real controls in the app.
struct OnboardingOverlay: View {
    let bindings: [ActionID: Shortcut]
    /// Measured frames of anchored UI elements, in the overlay's coordinate space.
    let frames: [OnboardingAnchor: CGRect]
    let onDismiss: () -> Void

    @EnvironmentObject private var L: LocalizationStore
    @State private var step = 0

    private let calloutWidth: CGFloat = 320
    private let pad: CGFloat = 6

    private var anchors: [OnboardingAnchor] {
        [.openFolderButton, .folderList, .dropArea]
    }

    var body: some View {
        GeometryReader { geometry in
            let target = targetRect(in: geometry.size)

            ZStack(alignment: .topLeading) {
                spotlightMask(size: geometry.size, target: target)
                    .contentShape(Rectangle())

                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: target.width, height: target.height)
                    .offset(x: target.minX, y: target.minY)
                    .shadow(color: .white.opacity(0.35), radius: 8)

                callout
                    .frame(width: calloutWidth)
                    .offset(calloutOffset(for: target, in: geometry.size))
            }
            .animation(.easeInOut(duration: 0.22), value: step)
        }
    }

    private func spotlightMask(size: CGSize, target: CGRect) -> some View {
        Canvas { context, canvasSize in
            var path = Path(CGRect(origin: .zero, size: canvasSize))
            path.addRoundedRect(in: target, cornerSize: CGSize(width: 10, height: 10))
            context.fill(
                path,
                with: .color(.black.opacity(0.72)),
                style: FillStyle(eoFill: true)
            )
        }
    }

    private var callout: some View {
        let item = steps[step]
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: item.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(step + 1) / \(steps.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
            }

            Text(item.body)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            stepPreview
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )

            HStack(spacing: 10) {
                Button(L.t("Skip", ja: "スキップ"), action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))

                Spacer()

                if step > 0 {
                    Button(L.t("Back", ja: "戻る")) { step -= 1 }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }

                Button(step == steps.count - 1
                       ? L.t("Done", ja: "完了")
                       : L.t("Next", ja: "次へ")) {
                    if step == steps.count - 1 {
                        onDismiss()
                    } else {
                        step += 1
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(Color.white)
                .cornerRadius(6)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: NSColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 0.98)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        )
    }

    // MARK: - Per-step example previews

    /// Small "what it will look like" sample so the guide makes sense even
    /// when the real sidebar / recents are still empty on first launch.
    @ViewBuilder
    private var stepPreview: some View {
        switch step {
        case 0:
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.12))
                    .cornerRadius(6)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                    Text("2026-04-03")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
            }
        case 1:
            VStack(alignment: .leading, spacing: 6) {
                previewSectionLabel("Pinned")
                previewFolderRow(name: "Wedding_Main", path: "/Volumes/SSD/2026", pinned: true)
                previewSectionLabel("Recent")
                    .padding(.top, 2)
                previewFolderRow(name: "2026-04-03", path: "/Volumes/SanDisk/日常/Leica", pinned: false)
            }
        default:
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        Color.white.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )
                    .frame(width: 64, height: 44)
                    .overlay(
                        Image(systemName: "folder.fill.badge.plus")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.6))
                    )
                HStack(spacing: 8) {
                    previewKeyCap(bindings[.toggleFavorite]?.display ?? "K", label: "Keep")
                    previewKeyCap(bindings[.setTriageMaybe]?.display ?? "M", label: "Maybe")
                    previewKeyCap(bindings[.toggleRejected]?.display ?? "O", label: "Out")
                }
            }
        }
    }

    private func previewSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.white.opacity(0.38))
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private func previewFolderRow(name: String, path: String, pinned: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                Text(path)
                    .font(.system(size: 8.5))
                    .foregroundColor(.white.opacity(0.3))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Image(systemName: pinned ? "pin.fill" : "pin")
                .font(.system(size: 9))
                .foregroundColor(pinned ? .accentColor.opacity(0.85) : .white.opacity(0.3))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.05))
        .cornerRadius(5)
    }

    private func previewKeyCap(_ key: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(key)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 26, height: 24)
                .background(Color.white.opacity(0.14))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    private func targetRect(in size: CGSize) -> CGRect {
        let anchor = anchors[min(step, anchors.count - 1)]
        if let frame = frames[anchor], frame.width > 1, frame.height > 1 {
            return frame.insetBy(dx: -pad, dy: -pad)
                .intersection(CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4))
        }
        // Fallback if anchors have not reported yet.
        switch step {
        case 0:
            return CGRect(x: 194, y: 6, width: 36, height: 36)
        case 1:
            return CGRect(x: 8, y: 52, width: 220, height: min(220, size.height - 70))
        default:
            let w = min(430, size.width - 80)
            let h = min(280, max(180, size.height - 180))
            return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        }
    }

    private func calloutOffset(for target: CGRect, in size: CGSize) -> CGSize {
        let preferredX = target.maxX + 14
        let x: CGFloat
        if preferredX + calloutWidth <= size.width - 12 {
            x = preferredX
        } else {
            x = max(12, target.minX - calloutWidth - 14)
        }
        let preferredY = max(12, min(target.minY, size.height - 220))
        return CGSize(width: x, height: preferredY)
    }

    private var steps: [Step] {
        let keep = bindings[.toggleFavorite]?.display ?? "K"
        let maybe = bindings[.setTriageMaybe]?.display ?? "M"
        let out = bindings[.toggleRejected]?.display ?? "O"
        let sidebar = bindings[.toggleSidebar]?.display ?? "⌘B"
        return [
            Step(
                icon: "folder.badge.plus",
                title: L.t("Open a photo folder", ja: "写真フォルダを開く"),
                body: L.t(
                    "Start here to choose a folder. You can also drag a folder directly onto the main area.",
                    ja: "ここからフォルダを選びます。メインエリアにフォルダをドラッグしても開けます。"
                )
            ),
            Step(
                icon: "sidebar.left",
                title: L.t("Switch folders quickly", ja: "フォルダをすばやく切り替え"),
                body: L.t(
                    "Pinned folders stay at the top; recently opened folders appear below. Use \(sidebar) to show or hide this sidebar.",
                    ja: "Pinned は上部に固定され、Recent はその下に並びます。\(sidebar) でサイドバーの表示を切り替えます。"
                )
            ),
            Step(
                icon: "hand.tap",
                title: L.t("Drop, then cull", ja: "ドロップして選別"),
                body: L.t(
                    "Drop a folder in this area. Once photos open, use \(keep) Keep · \(maybe) Maybe · \(out) Out. Press ? anytime for every shortcut.",
                    ja: "このエリアにフォルダをドロップ。写真が開いたら \(keep) Keep · \(maybe) Maybe · \(out) Out。? でいつでも全ショートカットを表示できます。"
                )
            ),
        ]
    }

    private struct Step {
        let icon: String
        let title: String
        let body: String
    }
}
