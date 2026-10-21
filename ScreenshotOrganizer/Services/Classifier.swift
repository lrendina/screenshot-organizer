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
    static let autoSort = "auto_sort"
    static let engine = "engine"
}

/// Which model sorts screenshots.
enum Engine: String, CaseIterable, Identifiable {
    /// Apple's open-source MobileCLIP, on-device. Free, offline, private.
    case local
    /// TypeSafe's Jev, with the user's own API key.
    case jev

    var id: String { rawValue }

    static var current: Engine {
        Engine(rawValue: UserDefaults.standard.string(forKey: SettingsKey.engine) ?? "") ?? .local
    }
}

/// Syncs the Photos library into SwiftData, reads each screenshot's text on-device,
/// then classifies it with Jev.
@MainActor
@Observable
final class Classifier {
    enum Phase: Equatable {
        case idle
        case reading // on-device OCR
        case sorting // MobileCLIP or Jev
    }

    var phase: Phase = .idle
    var done = 0
    var total = 0
    var lastError: String?

    var isRunning: Bool { phase != .idle }

    private var task: Task<Void, Never>?
    private static let concurrency = 4

    /// Inserts a record for every screenshot not yet tracked. Records for deleted assets are removed.
    /// Returns the number of new screenshots.
    @discardableResult
    func sync(context: ModelContext) -> Int {
        let assets = PhotoLibrary.fetchScreenshots()
        let existing = (try? context.fetch(FetchDescriptor<ScreenshotRecord>())) ?? []
        let existingIDs = Set(existing.map(\.assetID))
        let liveIDs = Set(assets.map(\.localIdentifier))

        var added = 0
        for asset in assets where !existingIDs.contains(asset.localIdentifier) {
            context.insert(ScreenshotRecord(assetID: asset.localIdentifier, createdAt: asset.creationDate))
            added += 1
        }
        for record in existing where !liveIDs.contains(record.assetID) {
            context.delete(record)
        }
        try? context.save()
        return added
    }

    /// Reads text for every screenshot that hasn't been read yet, then classifies every record
    /// without a category (or only `records`, if given). Text reading needs no API key.
    func run(context: ModelContext, records: [ScreenshotRecord]? = nil) {
        guard !isRunning else { return }
        let all = (try? context.fetch(FetchDescriptor<ScreenshotRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        ))) ?? []
        let targets = records ?? all
        let toRead = targets.filter { $0.ocrText == nil }
        let toSort = records?.filter { !$0.userOverride } ?? all.filter { $0.category == nil && !$0.userOverride }

        let categories = ((try? context.fetch(FetchDescriptor<CategoryDef>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? [])
            .map { TypeSafeClient.CategoryOption(key: $0.key, name: $0.name, detail: $0.detail) }
        let defaults = UserDefaults.standard
        let sendImage = defaults.bool(forKey: SettingsKey.sendImage)
        let model = sendImage
            ? (defaults.string(forKey: SettingsKey.imageModel) ?? "jev-preview")
            : (defaults.string(forKey: SettingsKey.model) ?? "jev-latest")
        let client = TypeSafeClient(apiKey: Keychain.apiKey)

        lastError = nil
        task = Task {
            if !toRead.isEmpty {
                start(.reading, count: toRead.count)
                await forEach(toRead) { record in
                    await self.readText(record)
                    return false
                }
                try? context.save()
            }

            if !toSort.isEmpty, !Task.isCancelled {
                switch Engine.current {
                case .local:
                    await sortLocally(toSort, categories: categories, context: context)
                case .jev:
                    await sortWithJev(toSort, client: client, categories: categories, model: model, sendImage: sendImage, context: context)
                }
            }
            phase = .idle
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func sortLocally(_ records: [ScreenshotRecord], categories: [TypeSafeClient.CategoryOption], context: ModelContext) async {
        let clip: MobileCLIP
        do {
            clip = try await LocalModelStore.shared.model()
        } catch {
            lastError = error.localizedDescription
            return
        }
        let options = categories.map { MobileCLIP.Category(key: $0.key, name: $0.name, detail: $0.detail) }
        start(.sorting, count: records.count)
        await forEach(records) { record in
            await self.classifyLocally(record, clip: clip, categories: options)
            try? context.save()
            return false
        }
    }

    private func sortWithJev(
        _ records: [ScreenshotRecord],
        client: TypeSafeClient,
        categories: [TypeSafeClient.CategoryOption],
        model: String,
        sendImage: Bool,
        context: ModelContext
    ) async {
        guard client.apiKey?.isEmpty == false else {
            lastError = TypeSafeClient.ClientError.missingKey.localizedDescription
            return
        }
        start(.sorting, count: records.count)
        await forEach(records) { record in
            let error = await self.classify(record, client: client, categories: categories, model: model, sendImage: sendImage)
            try? context.save()
            // A rejected key fails every request the same way; stop instead of flagging the whole library.
            return error?.isAuthFailure == true
        }
    }

    private func classifyLocally(_ record: ScreenshotRecord, clip: MobileCLIP, categories: [MobileCLIP.Category]) async {
        guard let asset = PhotoLibrary.asset(for: record.assetID),
              let cgImage = await PhotoLibrary.image(for: asset, maxDimension: 1024)?.cgImage
        else {
            record.lastError = "Couldn't load the image from Photos."
            return
        }
        let text = record.ocrText
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try clip.classify(cgImage, recognizedText: text, categories: categories,
                                  fallbackKey: CategoryDef.otherKey, textWeight: 0.3)
            }.value
            record.category = result.choice
            record.confidence = result.confidence
            record.probabilitiesData = try? JSONEncoder().encode(result.probabilities)
            record.model = LocalModelStore.modelName
            record.classifiedAt = .now
            record.lastError = nil
        } catch {
            // Keep the previous category; surface the error on the record.
            record.lastError = "On-device model failed: \(error.localizedDescription)"
            lastError = record.lastError
        }
    }

    private func start(_ phase: Phase, count: Int) {
        self.phase = phase
        done = 0
        total = count
    }

    /// Runs `body` over `records` with bounded concurrency. `body` returns true to stop early.
    private func forEach(_ records: [ScreenshotRecord], _ body: @escaping @MainActor (ScreenshotRecord) async -> Bool) async {
        await withTaskGroup(of: Bool.self) { group in
            var iterator = records.makeIterator()
            var inFlight = 0
            func addNext() -> Bool {
                guard !Task.isCancelled, let record = iterator.next() else { return false }
                group.addTask { await body(record) }
                inFlight += 1
                return true
            }
            for _ in 0..<Self.concurrency where !addNext() { break }
            while inFlight > 0, let shouldStop = await group.next() {
                inFlight -= 1
                done += 1
                if shouldStop {
                    group.cancelAll()
                    break
                }
                _ = addNext()
            }
        }
    }

    private func readText(_ record: ScreenshotRecord) async {
        guard let asset = PhotoLibrary.asset(for: record.assetID),
              let image = await PhotoLibrary.image(for: asset, maxDimension: 1600)
        else {
            record.lastError = "Couldn't load the image from Photos."
            return
        }
        do {
            record.ocrText = try await OCR.recognizeText(in: image)
        } catch {
            record.lastError = "Couldn't read text: \(error.localizedDescription)"
        }
    }

    /// Returns the client error, if any. On failure the record keeps its previous category.
    private func classify(
        _ record: ScreenshotRecord,
        client: TypeSafeClient,
        categories: [TypeSafeClient.CategoryOption],
        model: String,
        sendImage: Bool
    ) async -> TypeSafeClient.ClientError? {
        do {
            var jpeg: Data?
            if sendImage, let asset = PhotoLibrary.asset(for: record.assetID),
               let image = await PhotoLibrary.image(for: asset, maxDimension: 768) {
                jpeg = image.jpegData(compressionQuality: 0.7)
            }
            let text = record.ocrText ?? ""

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
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            record.lastError = error.localizedDescription
            lastError = error.localizedDescription
            return error as? TypeSafeClient.ClientError
        }
    }
}
