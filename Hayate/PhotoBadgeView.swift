import SwiftUI

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

    var body: some View {
        if let entry = entry, entry.isFavorite || entry.isRejected || entry.rating > 0 {
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
            .padding(padding)
            .background(Color.black.opacity(0.6))
            .cornerRadius(cornerRadius)
        }
    }
}
