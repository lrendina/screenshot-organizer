import SwiftData
import SwiftUI

struct Thumbnail: View {
    let assetID: String
    /// Longest side of the requested image, in pixels.
    var maxDimension: CGFloat = 360
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: assetID) {
                for await loaded in ImageCache.shared.thumbnails(for: assetID, maxPixels: maxDimension) {
                    image = loaded
                }
            }
    }
}

/// Which list a screenshot was opened from, so the pager can swipe through the same list.
enum Scope: Hashable {
    case all
    case category(String)
    case unsorted
    case search(String)
    case review
}

struct ScreenshotRoute: Hashable {
    let assetID: String
    let scope: Scope
}

/// Pushes a category's grid.
struct CategoryRoute: Hashable {
    let scope: Scope
}

struct ScreenshotGrid: View {
    let shots: [Shot]
    let scope: Scope
    @Query(sort: \CategoryDef.sortIndex) private var categories: [CategoryDef]
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 8)]

    var body: some View {
        let lookup = Dictionary(categories.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(shots) { shot in
                NavigationLink(value: ScreenshotRoute(assetID: shot.id, scope: scope)) {
                    Thumbnail(assetID: shot.id)
                        .aspectRatio(9 / 19.5, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .bottomLeading) {
                            if let key = shot.category, let category = lookup[key] {
                                CategoryBadge(category: category).padding(6)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if shot.hasError {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .symbolRenderingMode(.multicolor)
                                    .padding(6)
                            }
                        }
                }
            }
        }
        .padding(.horizontal)
    }
}
