import SwiftUI

/// Loading / empty-folder brand screen.
/// Sits on the same charcoal as ContentView (no black plate) with a
/// transparent cheetah mark so the first frame feels continuous with culling.
struct HayateBrandScreen: View {
    enum Mode {
        case loading
        case empty(onOpen: () -> Void)
    }

    let mode: Mode
    /// A folder drag is hovering over the window — show the drop affordance.
    var dropTargeted: Bool = false

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

                    Text(isLoading ? "Preparing…"
                         : dropTargeted ? "Release to open this folder"
                         : "Drop a folder or open one to begin")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(dropTargeted ? 0.85 : 0.4))
                }
                .opacity(textOpacity)

                if case .empty(let onOpen) = mode {
                    Button("Open Folder…", action: onOpen)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.white.opacity(0.18))
                        .foregroundColor(.white.opacity(0.9))
                        .opacity(textOpacity)
                        .padding(.top, 2)
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
                        Color.white.opacity(0.5),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                    .padding(20)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .onAppear {
            runIntro()
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
