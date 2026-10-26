import Photos
import UIKit

/// Shared Photos access for thumbnails: one caching image manager and a PHAsset lookup table,
/// so scrolling never runs a Photos fetch per cell.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    let manager = PHCachingImageManager()
    private var assets: [String: PHAsset] = [:]

    func asset(_ id: String) -> PHAsset? {
        if let asset = assets[id] { return asset }
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        assets[id] = asset
        return asset
    }

    /// Looks up many assets with one Photos fetch.
    func assets(_ ids: [String]) -> [String: PHAsset] {
        let missing = ids.filter { assets[$0] == nil }
        if !missing.isEmpty {
            PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil).enumerateObjects { asset, _, _ in
                self.assets[asset.localIdentifier] = asset
            }
        }
        var result: [String: PHAsset] = [:]
        for id in ids { if let asset = assets[id] { result[id] = asset } }
        return result
    }

    /// Streams a quick low-res image, then the sharp one. Cancels the request when the stream ends.
    func thumbnails(for id: String, maxPixels: CGFloat) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            guard let asset = asset(id) else { return continuation.finish() }
            let scale = min(1, maxPixels / CGFloat(max(asset.pixelWidth, asset.pixelHeight, 1)))
            let size = CGSize(width: CGFloat(asset.pixelWidth) * scale, height: CGFloat(asset.pixelHeight) * scale)
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            let requestID = manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
                if let image { continuation.yield(image) }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { continuation.finish() }
            }
            let manager = self.manager
            continuation.onTermination = { _ in manager.cancelImageRequest(requestID) }
        }
    }
}
