import Photos
import UIKit

enum PhotoLibrary {
    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// All screenshots, newest first. Photos tags most screenshots with `.photoScreenshot`, but
    /// images saved or imported from elsewhere often lose the tag, so an image whose pixel size
    /// exactly matches this device's screen also counts.
    @MainActor
    static func fetchScreenshots() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)

        let screen = UIScreen.main.nativeBounds.size
        let screenSizes: Set<[Int]> = [
            [Int(screen.width), Int(screen.height)],
            [Int(screen.height), Int(screen.width)],
        ]
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            if asset.mediaSubtypes.contains(.photoScreenshot)
                || screenSizes.contains([asset.pixelWidth, asset.pixelHeight]) {
                assets.append(asset)
            }
        }
        return assets
    }

    static func asset(for id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// Loads an image no larger than `maxDimension` on its longest side.
    static func image(for asset: PHAsset, maxDimension: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let scale = min(1, maxDimension / CGFloat(max(asset.pixelWidth, asset.pixelHeight)))
        let size = CGSize(width: CGFloat(asset.pixelWidth) * scale, height: CGFloat(asset.pixelHeight) * scale)

        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: size, contentMode: .aspectFit, options: options
            ) { image, info in
                // highQualityFormat calls back once, but guard against a degraded callback anyway.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !resumed, !degraded || image == nil else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    /// Adds each category's screenshots to a Photos album named "Screenshots · <name>".
    static func saveAlbums(_ groups: [String: [String]]) async throws {
        for (albumName, assetIDs) in groups where !assetIDs.isEmpty {
            let title = "Screenshots · \(albumName)"
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
            let existing = existingAlbum(named: title)
            try await PHPhotoLibrary.shared().performChanges {
                let request: PHAssetCollectionChangeRequest?
                if let existing {
                    request = PHAssetCollectionChangeRequest(for: existing)
                } else {
                    request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                }
                request?.addAssets(assets)
            }
        }
    }

    private static func existingAlbum(named title: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", title)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
    }
}
