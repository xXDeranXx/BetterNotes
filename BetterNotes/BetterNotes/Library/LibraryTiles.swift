import SwiftUI

extension Color {
    /// "#RRGGBB"; anything else becomes grey.
    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        if digits.count == 6, Scanner(string: digits).scanHexInt64(&value) {
            self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255)
        } else {
            self = .gray
        }
    }
}

/// Width of a tile's picture; the grid uses it as the column width.
let libraryTileWidth: CGFloat = 170
let libraryTileHeight: CGFloat = 220

/// A notebook as the library shows it: the first page in a rounded card with a colored spine,
/// the title and the date below, a star if it is a favorite.
struct NotebookTile: View {
    let notebook: NotebookSummary
    let isFavorite: Bool
    /// `nil` when not selecting; otherwise whether this tile is ticked.
    var isSelected: Bool?
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Color.white
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if notebook.problem != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle).foregroundStyle(.orange)
                }
            }
            .frame(width: libraryTileWidth, height: libraryTileHeight)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color(hex: notebook.coverColor)).frame(width: 8)
            }
            .overlay(alignment: .topTrailing) {
                if isFavorite {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                        .padding(6).background(.black.opacity(0.45), in: Circle()).padding(6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

            VStack(spacing: 2) {
                Text(notebook.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                if let problem = notebook.problem {
                    Text(problem).font(.caption2).foregroundStyle(.red).lineLimit(2).multilineTextAlignment(.center)
                } else {
                    Text("\(notebook.updatedAt.formatted(date: .abbreviated, time: .omitted)) · \(notebook.pageCount) \(notebook.pageCount == 1 ? "page" : "pages")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: libraryTileWidth)
        }
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) { SelectionMark(isSelected: isSelected).padding(6) }
        .task(id: notebook.updatedAt) { image = await CoverStore.shared.image(for: notebook) }
    }
}

/// The round tick in a corner while selecting.
struct SelectionMark: View {
    let isSelected: Bool?

    var body: some View {
        if let isSelected {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(isSelected ? Color.white : Color.secondary, isSelected ? Color.accentColor : Color.white.opacity(0.9))
                .shadow(radius: 1)
        }
    }
}

/// A folder drawn the way people expect one: a back panel with a tab, a lighter front panel,
/// and the chosen symbol on the front, all in the folder's color.
struct FolderIcon: View {
    let style: FolderStyle

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let base = Color(hex: style.color)
            ZStack(alignment: .topLeading) {
                // Back panel and its tab.
                RoundedRectangle(cornerRadius: w * 0.09)
                    .fill(base.mix(with: .black, by: 0.22))
                    .frame(width: w * 0.42, height: h * 0.3)
                RoundedRectangle(cornerRadius: w * 0.07)
                    .fill(base.mix(with: .black, by: 0.22))
                    .frame(width: w, height: h * 0.8)
                    .offset(y: h * 0.14)
                // Front panel.
                RoundedRectangle(cornerRadius: w * 0.07)
                    .fill(LinearGradient(colors: [base.mix(with: .white, by: 0.18), base], startPoint: .top, endPoint: .bottom))
                    .frame(width: w, height: h * 0.68)
                    .offset(y: h * 0.32)
                    .shadow(color: .black.opacity(0.18), radius: w * 0.02, y: -w * 0.005)
                if let symbol = style.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: w * 0.3, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                        .frame(width: w, height: h * 0.68)
                        .offset(y: h * 0.32)
                }
            }
        }
        .aspectRatio(1.25, contentMode: .fit)
    }
}

/// A folder tile: the folder icon, its name, and a highlight while something is dragged over it.
struct FolderTile: View {
    let folder: FolderSummary
    var isDropTargeted = false
    var isSelected: Bool?

    var body: some View {
        VStack(spacing: 10) {
            FolderIcon(style: folder.style)
                .frame(width: libraryTileWidth * 0.86)
                .frame(width: libraryTileWidth, height: libraryTileHeight)
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(isDropTargeted ? 0.25 : 0)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: isDropTargeted ? 3 : 0))
            Text(folder.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                .multilineTextAlignment(.center).frame(width: libraryTileWidth)
        }
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) { SelectionMark(isSelected: isSelected).padding(6) }
    }
}

/// A notebook as one row of the list layout: small cover, title, date and page count.
struct NotebookRow: View {
    let notebook: NotebookSummary
    let isFavorite: Bool
    var isSelected: Bool?
    @State private var image: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            SelectionMark(isSelected: isSelected)
            ZStack {
                Color.white
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else if notebook.problem != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            .frame(width: 44, height: 58)
            .overlay(alignment: .leading) { Rectangle().fill(Color(hex: notebook.coverColor)).frame(width: 4) }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(notebook.title).font(.body.weight(.medium)).lineLimit(1)
                if let problem = notebook.problem {
                    Text(problem).font(.caption).foregroundStyle(.red).lineLimit(1)
                } else {
                    Text("\(notebook.updatedAt.formatted(date: .abbreviated, time: .shortened)) · \(notebook.pageCount) \(notebook.pageCount == 1 ? "page" : "pages")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .contentShape(Rectangle())
        .task(id: notebook.updatedAt) { image = await CoverStore.shared.image(for: notebook) }
    }
}

struct FolderRow: View {
    let folder: FolderSummary
    var isDropTargeted = false
    var isSelected: Bool?

    var body: some View {
        HStack(spacing: 14) {
            SelectionMark(isSelected: isSelected)
            FolderIcon(style: folder.style).frame(width: 52).frame(width: 44, height: 58)
            Text(folder.name).font(.body.weight(.medium)).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color.accentColor.opacity(isDropTargeted ? 0.2 : 0))
        .contentShape(Rectangle())
    }
}
