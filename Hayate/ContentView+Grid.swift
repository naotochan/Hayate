import SwiftUI

/// Grid view: thumbnail overview with filtering and multi-selection.
extension ContentView {

    var filteredFiles: [(index: Int, url: URL)] {
        session.files.enumerated().compactMap { index, url in
            let entry = session.entries[url.lastPathComponent]
            switch gridFilter {
            case .all: return (index, url)
            case .favorites: return entry?.isFavorite == true ? (index, url) : nil
            case .rejected: return entry?.isRejected == true ? (index, url) : nil
            case .rated: return (entry?.rating ?? 0) > 0 ? (index, url) : nil
            case .unrated: return (entry?.rating ?? 0) == 0 ? (index, url) : nil
            }
        }
    }

    var gridView: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 8) {
                ForEach(GridFilter.allCases, id: \.self) { filter in
                    Button {
                        gridFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.system(size: 11, weight: gridFilter == filter ? .bold : .regular))
                            .foregroundColor(gridFilter == filter ? .white : .gray)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(gridFilter == filter ? Color.white.opacity(0.2) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text("\(filteredFiles.count) / \(session.files.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.gray)

                if !selectedIndices.isEmpty {
                    Text("\(selectedIndices.count) selected")
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.5))
                        .cornerRadius(3)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            // Grid
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 6)], spacing: 6) {
                        ForEach(filteredFiles, id: \.index) { item in
                            gridCell(for: item.url, index: item.index)
                                .id(item.index)
                        }
                    }
                    .padding(8)
                }
                .onAppear {
                    proxy.scrollTo(session.currentIndex, anchor: .center)
                }
            }
        }
    }

    private func gridCell(for url: URL, index: Int) -> some View {
        let isCurrent = index == session.currentIndex
        let isSelected = selectedIndices.contains(index)
        let entry = session.entries[url.lastPathComponent]

        return VStack(spacing: 0) {
            ZStack {
                // Thumbnail: use .fit to prevent overflow
                if let nsImage = thumbnails[url] {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(height: 140)
                        .background(Color.black)
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 140)
                        .overlay {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                        .onAppear { loadThumbnail(for: url) }
                }

                // Selection checkmark (top left)
                VStack {
                    HStack {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.accentColor)
                                .padding(4)
                        }
                        Spacer()
                        // Badges (top right)
                        PhotoBadgeView(entry: entry)
                            .padding(4)
                    }
                    Spacer()
                }
            }
            .frame(height: 140)
            .clipped()

            // File name
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 10))
                .foregroundColor(isCurrent ? .white : .gray)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(isCurrent ? Color.white.opacity(0.15) : Color.clear)
        }
        .background(Color.gray.opacity(0.1))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? Color.accentColor : (isCurrent && selectedIndices.isEmpty ? Color.white : Color.clear), lineWidth: 2)
        )
        .opacity(entry?.isRejected == true ? 0.5 : 1.0)
        .onTapGesture(count: 2) {
            // Double-click: open in single photo view
            session.currentIndex = index
            selectedIndices.removeAll()
            showGrid = false
            loadCurrentImage()
        }
        .onTapGesture(count: 1) {
            if NSEvent.modifierFlags.contains(.shift) {
                // Shift+click: range select from last selected
                let anchor = selectedIndices.max() ?? session.currentIndex
                let range = min(anchor, index)...max(anchor, index)
                for i in range { selectedIndices.insert(i) }
            } else if NSEvent.modifierFlags.contains(.command) {
                // Cmd+click: add currentIndex on first multi-select, then toggle
                if selectedIndices.isEmpty {
                    selectedIndices.insert(session.currentIndex)
                }
                if selectedIndices.contains(index) {
                    selectedIndices.remove(index)
                } else {
                    selectedIndices.insert(index)
                }
            } else {
                // Plain click: select single, clear multi-select
                selectedIndices.removeAll()
                session.currentIndex = index
            }
        }
    }
}
