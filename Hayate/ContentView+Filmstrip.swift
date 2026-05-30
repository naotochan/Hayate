import SwiftUI

/// Bottom-of-screen filmstrip and status bar for the single-photo view.
extension ContentView {

    var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 2) {
                    ForEach(Array(session.files.enumerated()), id: \.offset) { index, url in
                        thumbnailView(for: url, index: index)
                            .id(index)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(height: 68)
            .background(Color.black.opacity(0.6))
            .onChange(of: session.currentIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onAppear {
                proxy.scrollTo(session.currentIndex, anchor: .center)
            }
        }
    }

    private func thumbnailView(for url: URL, index: Int) -> some View {
        let isCurrent = index == session.currentIndex
        let entry = session.entries[url.lastPathComponent]

        return ZStack(alignment: .bottomTrailing) {
            if let nsImage = thumbnails[url] {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 60)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 80, height: 60)
                    .onAppear { loadThumbnail(for: url) }
            }

            // Rating/favorite/rejected indicator
            if let entry = entry, entry.rating > 0 || entry.isFavorite || entry.isRejected {
                HStack(spacing: 1) {
                    if entry.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 7))
                            .foregroundColor(.red)
                    }
                    if entry.isRejected {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.orange)
                    }
                    if entry.rating > 0 {
                        Text("\(entry.rating)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow)
                    }
                }
                .padding(2)
                .background(Color.black.opacity(0.6))
                .cornerRadius(2)
                .padding(2)
            }
        }
        .border(isCurrent ? Color.white : Color.clear, width: 2)
        .opacity(isCurrent ? 1.0 : 0.6)
        .onTapGesture {
            session.currentIndex = index
        }
    }

    var statusBar: some View {
        HStack {
            if !session.files.isEmpty {
                // Position
                Text("\(session.currentIndex + 1)/\(session.files.count)")
                    .monospacedDigit()

                Spacer()

                // File name
                if let file = session.currentFile {
                    Text(file.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // Rating stars + favorite
                HStack(spacing: 2) {
                    let rating = session.currentEntry?.rating ?? 0
                    let isFav = session.currentEntry?.isFavorite ?? false
                    let isRej = session.currentEntry?.isRejected ?? false
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= rating ? "star.fill" : "star")
                            .foregroundColor(i <= rating ? .yellow : .gray)
                            .font(.system(size: 12))
                    }
                    Image(systemName: isFav ? "heart.fill" : "heart")
                        .foregroundColor(isFav ? .red : .gray)
                        .font(.system(size: 12))
                        .padding(.leading, 4)
                    Image(systemName: isRej ? "xmark.circle.fill" : "xmark.circle")
                        .foregroundColor(isRej ? .orange : .gray)
                        .font(.system(size: 12))
                        .padding(.leading, 2)
                }

                Spacer()

                // Focus peaking indicator
                if focusPeakingEnabled {
                    Text("PEAK")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.red)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.2))
                        .cornerRadius(3)
                }

                // Decode time
                if decodeTimeMs > 0 {
                    Text(String(format: "%.0fms", decodeTimeMs))
                        .foregroundColor(.gray)
                        .font(.system(size: 11, design: .monospaced))
                }

                // Background build progress
                if buildProgress.isBuilding {
                    Text("Building previews: \(buildProgress.completed)/\(buildProgress.total)")
                        .foregroundColor(.gray)
                        .font(.system(size: 11, design: .monospaced))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .foregroundColor(.white)
        .font(.system(size: 13))
    }
}
