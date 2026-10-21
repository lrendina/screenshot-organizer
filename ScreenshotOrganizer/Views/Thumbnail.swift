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
                }
            }
            .clipped()
            .task(id: assetID) {
                guard let asset = PhotoLibrary.asset(for: assetID) else { return }
                image = await PhotoLibrary.image(for: asset, maxDimension: maxDimension)
            }
    }
}

struct ScreenshotGrid: View {
    let records: [ScreenshotRecord]
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(records) { record in
                NavigationLink(value: record) {
                    Thumbnail(assetID: record.assetID)
                        .aspectRatio(9 / 19.5, contentMode: .fit)
                        .overlay(alignment: .bottomTrailing) {
                            if record.lastError != nil {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow).padding(4)
                            }
                        }
                }
            }
        }
    }
}
