import Foundation
import Observation
import Photos
import SwiftData
import UIKit

enum SettingsKey {
    static let apiKey = "typesafe_api_key"
    static let model = "model"
    static let sendImage = "send_image"
    static let imageModel = "image_model"
    static let reviewThreshold = "review_threshold"
}

/// Syncs the Photos library into SwiftData and classifies new screenshots with Jev.
@MainActor
@Observable
final class Classifier {
    var isRunning = false
    var done = 0
    var total = 0
    var lastError: String?

    private var task: Task<Void, Never>?

    /// Inserts a record for every screenshot not yet tracked. Records for deleted assets are removed.
    func sync(context: ModelContext) {
        let assets = PhotoLibrary.fetchScreenshots()
        let existing = (try? context.fetch(FetchDescriptor<ScreenshotRecord>())) ?? []
        let existingIDs = Set(existing.map(\.assetID))
        let liveIDs = Set(assets.map(\.localIdentifier))

        for asset in assets where !existingIDs.contains(asset.localIdentifier) {
            context.insert(ScreenshotRecord(assetID: asset.localIdentifier, createdAt: asset.creationDate))
        }
        for record in existing where !liveIDs.contains(record.assetID) {
            context.delete(record)
        }
        try? context.save()
    }

    /// Classifies every record without a category (or only `records`, if given).
    func run(context: ModelContext, records: [ScreenshotRecord]? = nil) {
        guard !isRunning else { return }
        let pending: [ScreenshotRecord]
        if let records {
            pending = records.filter { !$0.userOverride }
        } else {
            let all = (try? context.fetch(FetchDescriptor<ScreenshotRecord>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            ))) ?? []
            pending = all.filter { $0.category == nil && !$0.userOverride }
        }
        guard !pending.isEmpty else { return }

        let categories = ((try? context.fetch(FetchDescriptor<CategoryDef>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? [])
            .map { TypeSafeClient.CategoryOption(key: $0.key, name: $0.name, detail: $0.detail) }
        let defaults = UserDefaults.standard
        let sendImage = defaults.bool(forKey: SettingsKey.sendImage)
        let model = sendImage
            ? (defaults.string(forKey: SettingsKey.imageModel) ?? "jev-preview")
            : (defaults.string(forKey: SettingsKey.model) ?? "jev-latest")
        let client = TypeSafeClient(apiKey: Keychain.get(SettingsKey.apiKey))

        isRunning = true
        done = 0
        total = pending.count
        lastError = nil

        task = Task {
            for record in pending {
                if Task.isCancelled { break }
                await classify(record, client: client, categories: categories, model: model, sendImage: sendImage)
                done += 1
                try? context.save()
                // A missing or rejected key fails every request the same way; stop instead of flagging the whole library.
                if currentClientError?.isAuthFailure == true { break }
            }
            isRunning = false
        }
    }

    func cancel() {
        task?.cancel()
    }

    private var currentClientError: TypeSafeClient.ClientError?

    private func classify(
        _ record: ScreenshotRecord,
        client: TypeSafeClient,
        categories: [TypeSafeClient.CategoryOption],
        model: String,
        sendImage: Bool
    ) async {
        currentClientError = nil
        guard let asset = PhotoLibrary.asset(for: record.assetID),
              let image = await PhotoLibrary.image(for: asset, maxDimension: 1600)
        else {
            record.lastError = "Couldn't load the image from Photos."
            return
        }

        do {
            let text: String
            if let cached = record.ocrText {
                text = cached
            } else {
                text = try await OCR.recognizeText(in: image)
                record.ocrText = text
            }
            let jpeg = sendImage ? Self.downscaledJPEG(image, maxDimension: 768) : nil

            // Retry once, then record the error and keep whatever category the record already had.
            let result: TypeSafeClient.ChoiceResult
            do {
                result = try await client.classify(ocrText: text, imageJPEG: jpeg, categories: categories, model: model)
            } catch let error as TypeSafeClient.ClientError where !error.isRetryable {
                throw error
            } catch {
                try await Task.sleep(for: .seconds(1))
                result = try await client.classify(ocrText: text, imageJPEG: jpeg, categories: categories, model: model)
            }

            record.category = result.choice
            record.confidence = result.confidence
            record.probabilitiesData = try? JSONEncoder().encode(result.probabilities)
            record.model = result.model
            record.classifiedAt = .now
            record.lastError = nil
        } catch {
            currentClientError = error as? TypeSafeClient.ClientError
            record.lastError = error.localizedDescription
            lastError = error.localizedDescription
        }
    }

    private static func downscaledJPEG(_ image: UIImage, maxDimension: CGFloat) -> Data? {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: 0.7)
    }
}
