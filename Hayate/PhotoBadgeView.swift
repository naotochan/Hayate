import SwiftUI

/// Saturation for filmstrip / grid thumbnails when "Colorize Keep only" is on.
/// Keep (favorite) stays full color; everything else fades toward grayscale so
/// keeps pop out of the strip. Badges remain for non-color cues.
enum CullThumbnailStyle {
    static func saturation(for entry: CullingSession.PhotoEntry?, enabled: Bool) -> Double {
        guard enabled else { return 1.0 }
        switch CullingSession.TriageState.of(entry) {
        case .keep: return 1.0
        case .maybe: return 0.45
        case .out: return 0.08
        case .undecided: return 0.12
        }
    }
}

/// Shared favorite / rejected / rating badge cluster overlaid on photo
/// thumbnails (grid cells, compare slots, filmstrip). Renders nothing when
/// the entry has no state to show.
struct PhotoBadgeView: View {
    let entry: CullingSession.PhotoEntry?
    var iconSize: CGFloat = 10
    var starSize: CGFloat = 7
    var spacing: CGFloat = 3
    var padding: CGFloat = 4
    var cornerRadius: CGFloat = 4
    /// Filmstrip style: numeric rating and a plain bold xmark instead of icons.
    var compact = false
    /// Keep / Maybe / Out glyphs instead of stars.
    var triageStyle = false

    var body: some View {
        if triageStyle {
            triageBody
        } else {
            starsBody
        }
    }

    @ViewBuilder
    private var triageBody: some View {
        switch CullingSession.TriageState.of(entry) {
        case .undecided:
            EmptyView()
        case .keep:
            badge {
                Image(systemName: "heart.fill")
                    .font(.system(size: iconSize))
                    .foregroundColor(.red)
            }
        case .maybe:
            badge {
                Text("M")
                    .font(.system(size: starSize, weight: .bold, design: .monospaced))
                    .foregroundColor(.yellow)
            }
        case .out:
            badge {
                Image(systemName: compact ? "xmark" : "xmark.circle.fill")
                    .font(.system(size: iconSize, weight: compact ? .bold : .regular))
                    .foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private var starsBody: some View {
        if let entry = entry, entry.isFavorite || entry.isRejected || entry.rating > 0 {
            badge {
                HStack(spacing: spacing) {
                    if entry.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: iconSize))
                            .foregroundColor(.red)
                    }
                    if entry.isRejected {
                        Image(systemName: compact ? "xmark" : "xmark.circle.fill")
                            .font(.system(size: iconSize, weight: compact ? .bold : .regular))
                            .foregroundColor(.orange)
                    }
                    if entry.rating > 0 {
                        if compact {
                            Text("\(entry.rating)")
                                .font(.system(size: starSize, weight: .bold, design: .monospaced))
                                .foregroundColor(.yellow)
                        } else {
                            HStack(spacing: 1) {
                                ForEach(1...entry.rating, id: \.self) { _ in
                                    Image(systemName: "star.fill")
                                        .font(.system(size: starSize))
                                        .foregroundColor(.yellow)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func badge<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(padding)
            .background(Color.black.opacity(0.6))
            .cornerRadius(cornerRadius)
    }
}
