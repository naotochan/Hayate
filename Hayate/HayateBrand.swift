import SwiftUI

/// Loading / empty-folder brand screen.
/// Sits on the same adaptive canvas as ContentView so light/dark stay continuous.
struct HayateBrandScreen: View {
    enum Mode {
        case loading
        case empty(onOpen: () -> Void, recentFolders: [URL], onOpenRecent: (URL) -> Void)
    }

    let mode: Mode
    /// A folder drag is hovering over the window — show the drop affordance.
    var dropTargeted: Bool = false

    @EnvironmentObject private var L: LocalizationStore

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
        // Transparent — parent ContentView already paints the adaptive canvas.
        ZStack {
            VStack(spacing: 24) {
                Image("HayateMark")
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 168, height: 112)
                    .foregroundColor(HayateTheme.fg(0.88))
                    .opacity(markOpacity)
                    .scaleEffect(markScale * (inhale ? 0.97 : 1.0))

                VStack(spacing: 8) {
                    Text("Hayate")
                        .font(.system(size: 32, weight: .semibold))
                        .tracking(1.2)
                        .foregroundColor(HayateTheme.fg(0.92))

                    Text(isLoading
                         ? "Preparing…"
                         : dropTargeted
                         ? "Release to open this folder"
                         : "Drop a folder or open one to begin")
                        .font(.system(size: 13))
                        .foregroundColor(HayateTheme.fg(dropTargeted ? 0.85 : 0.4))
                }
                .opacity(textOpacity)

                if case .empty(let onOpen, let recent, let onOpenRecent) = mode {
                    Button("Open Folder…", action: onOpen)
                        .buttonStyle(.borderedProminent)
                        .tint(HayateTheme.wash(0.18))
                        .foregroundColor(HayateTheme.fg(0.9))
                        .opacity(textOpacity)
                        .padding(.top, 2)

                    if !recent.isEmpty {
                        recentFoldersList(recent, onOpen: onOpenRecent)
                            .opacity(textOpacity)
                            .padding(.top, 8)
                    }
                } else if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(textOpacity * 0.7)
                }
            }
            // Drop-target frame: dashed border while a folder hovers.
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        HayateTheme.fg(0.5),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                    .padding(20)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onboardingAnchor(.dropArea)
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .onAppear {
            runIntro()
        }
    }

    private func recentFoldersList(_ folders: [URL], onOpen: @escaping (URL) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Folders")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(HayateTheme.fg(0.4))
                .textCase(.uppercase)
                .tracking(0.5)
                .frame(maxWidth: 360, alignment: .leading)

            ForEach(folders.prefix(6), id: \.path) { url in
                let available = FileManager.default.isReadableFile(atPath: url.path)
                Button {
                    guard available else { return }
                    onOpen(url)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 13))
                            .foregroundColor(available ? HayateTheme.fg(0.7) : HayateTheme.fg(0.25))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(available ? HayateTheme.fg(0.9) : HayateTheme.fg(0.35))
                                .lineLimit(1)
                            Text(url.deletingLastPathComponent().path)
                                .font(.system(size: 10))
                                .foregroundColor(HayateTheme.fg(available ? 0.35 : 0.2))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if !available {
                            Text("Unavailable")
                                .font(.system(size: 10))
                                .foregroundColor(HayateTheme.fg(0.3))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 360, alignment: .leading)
                    .background(HayateTheme.wash(available ? 0.06 : 0.03))
                    .cornerRadius(6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!available)
                .help(available
                      ? url.path
                      : L.t("This folder is not currently reachable", ja: "このフォルダには現在アクセスできません"))
            }
        }
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
