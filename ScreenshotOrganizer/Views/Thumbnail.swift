import SwiftData
import SwiftUI

struct Thumbnail: View {
    let assetID: String
    var maxDimension: CGFloat = 300
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: assetID) {
                guard let asset = PhotoLibrary.asset(for: assetID) else { return }
                let loaded = await PhotoLibrary.image(for: asset, maxDimension: maxDimension)
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
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
    let records: [ScreenshotRecord]
    let scope: Scope
    @Query(sort: \CategoryDef.sortIndex) private var categories: [CategoryDef]
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(records) { record in
                NavigationLink(value: ScreenshotRoute(assetID: record.assetID, scope: scope)) {
                    Thumbnail(assetID: record.assetID)
                        .aspectRatio(9 / 19.5, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .bottomLeading) {
                            if let key = record.category, let category = categories.first(where: { $0.key == key }) {
                                CategoryBadge(category: category).padding(6)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if record.lastError != nil {
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

