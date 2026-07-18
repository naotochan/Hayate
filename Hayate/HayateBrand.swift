import SwiftUI

/// Loading / empty-folder brand screen.
/// Sits on the same charcoal as ContentView (no black plate) with a
/// transparent cheetah mark so the first frame feels continuous with culling.
struct HayateBrandScreen: View {
    enum Mode {
        case loading
        case empty(onOpen: () -> Void, recentFolders: [URL], onOpenRecent: (URL) -> Void)
    }

    let mode: Mode

    /// Subsequent launches shorten the intro.
    @AppStorage("hayateLaunchCount") private var launchCount = 0
    @State private var markOpacity: Double = 0
    @State private var markScale: CGFloat = 0.96
    @State private var textOpacity: Double = 0
    @State private var inhale: Bool = false

    private var isLoading: Bool {
        if case .loading = mode { return true }
        return false
    }

    private var drawDuration: Double {
        launchCount == 0 ? 0.7 : 0.3
    }

    var body: some View {
        // Transparent — parent ContentView already paints the app charcoal.
        ZStack {
            VStack(spacing: 24) {
                Image("HayateMark")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 168, height: 112)
                    .opacity(markOpacity)
                    .scaleEffect(markScale * (inhale ? 0.97 : 1.0))

                VStack(spacing: 8) {
                    Text("Hayate")
                        .font(.system(size: 32, weight: .semibold))
                        .tracking(1.2)
                        .foregroundColor(.white.opacity(0.92))

                    Text(isLoading ? "Preparing…" : "Drop a folder or open one to begin")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.4))
                }
                .opacity(textOpacity)

                if case .empty(let onOpen, let recentFolders, let onOpenRecent) = mode {
                    Button("Open Folder…", action: onOpen)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.white.opacity(0.18))
                        .foregroundColor(.white.opacity(0.9))
                        .opacity(textOpacity)
                        .padding(.top, 2)

                    if !recentFolders.isEmpty {
                        recentFoldersList(recentFolders, onOpen: onOpenRecent)
                            .opacity(textOpacity)
                            .padding(.top, 8)
                    }
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(textOpacity * 0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            runIntro()
        }
    }

    @ViewBuilder
    private func recentFoldersList(_ folders: [URL], onOpen: @escaping (URL) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.35))
                .textCase(.uppercase)
                .tracking(0.8)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(folders.prefix(8), id: \.self) { url in
                    Button {
                        onOpen(url)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.35))
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                                    .lineLimit(1)

                                Text(Self.displayPath(for: url))
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.3))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: 320)
    }

    /// Home-abbreviated parent path for secondary display.
    static func displayPath(for url: URL) -> String {
        let parent = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        if parent == home { return "~" }
        if parent.hasPrefix(home + "/") {
            return "~" + parent.dropFirst(home.count)
        }
        return parent
    }

    private func runIntro() {
        withAnimation(.easeOut(duration: drawDuration)) {
            markOpacity = 1
            markScale = 1
        }
        withAnimation(.easeOut(duration: 0.3).delay(drawDuration * 0.4)) {
            textOpacity = 1
        }
        if isLoading {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(drawDuration)) {
                inhale = true
            }
        }
        if isLoading {
            DispatchQueue.main.async {
                if launchCount < 1000 { launchCount += 1 }
            }
        }
    }
}
