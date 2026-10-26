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
    /// Apple's MobileCLIP, on-device. Free, offline, private.
    case local
    /// TypeSafe's Jev, with the user's own API key.
    case jev

    var id: String { rawValue }

    static var current: Engine {
        Engine(rawValue: UserDefaults.standard.string(forKey: SettingsKey.engine) ?? "") ?? .local
    }
}

/// Syncs the Photos library into SwiftData and sorts unsorted screenshots.
///
/// Each screenshot goes through one pass: load a small image from Photos, read its text with
/// Vision's fast recognizer, and classify it. The heavy work runs off the main thread on every
/// core; the main thread only applies small results and saves in batches. Screenshots that are
/// only in iCloud are skipped in the first pass and downloaded afterwards at low concurrency.
@MainActor
@Observable
final class Classifier {
    enum Phase: Equatable {
        case idle
        case sorting
    }

    var phase: Phase = .idle
    var done = 0
    var total = 0
    var waitingOnICloud = 0
    var lastError: String?
    /// e.g. "Sorted 1,204 screenshots in 9.8 s"
    var lastSummary: String?

    var isRunning: Bool { phase != .idle }

    @ObservationIgnored let index: LibraryIndex
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Longest side of the image each screenshot is sorted from.
    static let sortImagePixels: CGFloat = 768
    private static let networkConcurrency = 4

    init(index: LibraryIndex) {
        self.index = index
    }

    /// Inserts a record for every screenshot not yet tracked. Records for deleted assets are removed.
    /// Returns the number of new screenshots.
    @discardableResult
    func sync(context: ModelContext) -> Int {
        let assets = PhotoLibrary.fetchScreenshots()
        var descriptor = FetchDescriptor<ScreenshotRecord>()
        descriptor.propertiesToFetch = [\.assetID]
        let existing = (try? context.fetch(descriptor)) ?? []
        let existingIDs = Set(existing.map(\.assetID))
        let liveIDs = Set(assets.map(\.localIdentifier))

        var added = 0
        for asset in assets where !existingIDs.contains(asset.localIdentifier) {
            context.insert(ScreenshotRecord(assetID: asset.localIdentifier, createdAt: asset.creationDate))
            added += 1
        }
        var removed = 0
        for record in existing where !liveIDs.contains(record.assetID) {
            context.delete(record)
            removed += 1
        }
        if added > 0 || removed > 0 { try? context.save() }
        index.reload(context: context)
        return added
    }

    /// Sorts every record without a category, or only `records` if given.
    func run(context: ModelContext, records: [ScreenshotRecord]? = nil) {
        guard !isRunning else { return }
        let pending: [ScreenshotRecord]
        if let records {
            pending = records.filter { !$0.userOverride }
        } else {
            var descriptor = FetchDescriptor<ScreenshotRecord>(
                predicate: #Predicate { $0.category == nil && !$0.userOverride },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            descriptor.propertiesToFetch = [\.assetID, \.ocrText]
            pending = (try? context.fetch(descriptor)) ?? []
        }
        guard !pending.isEmpty else { return }

        let categories = ((try? context.fetch(FetchDescriptor<CategoryDef>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? [])
            .map { Category(key: $0.key, name: $0.name, detail: $0.detail) }
        let engine = Engine.current

        lastError = nil
        lastSummary = nil
        phase = .sorting
        done = 0
        total = pending.count
        waitingOnICloud = 0

        task = Task {
            let started = Date()
            let byID = Dictionary(pending.map { ($0.assetID, $0) }, uniquingKeysWith: { first, _ in first })
            let assets = ImageCache.shared.assets(pending.map(\.assetID))
            let saver = BatchSaver(context: context, index: index)

            let worker: Worker
            switch engine {
            case .local:
                do {
                    worker = .local(try await LocalModelStore.shared.model())
                } catch {
                    lastError = error.localizedDescription
                    phase = .idle
                    return
                }
            case .jev:
                let client = TypeSafeClient(apiKey: Keychain.apiKey)
                guard client.apiKey?.isEmpty == false else {
                    lastError = TypeSafeClient.ClientError.missingKey.localizedDescription
                    phase = .idle
                    return
                }
                let defaults = UserDefaults.standard
                let sendImage = defaults.bool(forKey: SettingsKey.sendImage)
                let model = sendImage
                    ? (defaults.string(forKey: SettingsKey.imageModel) ?? "jev-preview")
                    : (defaults.string(forKey: SettingsKey.model) ?? "jev-latest")
                worker = .jev(client, model: model, sendImage: sendImage)
            }

            let jobs = pending.compactMap { record in
                assets[record.assetID].map { Job(id: record.assetID, asset: $0, knownText: record.ocrText) }
            }
            let missing = pending.count - jobs.count
            done += missing // deleted from Photos since the last sync

            // Pass 1: images already on the device, at full width.
            let localWidth = engine == .local ? ProcessInfo.processInfo.activeProcessorCount : Self.networkConcurrency
            let inICloud = await process(jobs, worker: worker, categories: categories, allowNetwork: false,
                                         width: localWidth, byID: byID, saver: saver)

            // Pass 2: screenshots that have to come down from iCloud.
            if !inICloud.isEmpty, !Task.isCancelled {
                waitingOnICloud = inICloud.count
                _ = await process(inICloud, worker: worker, categories: categories, allowNetwork: true,
                                  width: Self.networkConcurrency, byID: byID, saver: saver)
            }
            saver.flush()

            let sorted = pending.filter { $0.category != nil }.count
            let seconds = Date().timeIntervalSince(started)
            lastSummary = "Sorted \(sorted.formatted()) screenshot\(sorted == 1 ? "" : "s") in \(seconds.formatted(.number.precision(.fractionLength(1)))) s"
            waitingOnICloud = 0
            phase = .idle
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: Pipeline

    struct Category: Sendable {
        let key: String
        let name: String
        let detail: String
    }

    private struct Job: @unchecked Sendable { // PHAsset is immutable and safe to read across threads
        let id: String
        let asset: PHAsset
        let knownText: String?
    }

    private enum Worker: @unchecked Sendable { // MobileCLIP predictions are thread-safe
        case local(MobileCLIP)
        case jev(TypeSafeClient, model: String, sendImage: Bool)
    }

    private enum Outcome: Sendable {
        case sorted(id: String, choice: String, confidence: Double?, probabilities: [String: Double], model: String, text: String?)
        case failed(id: String, message: String, text: String?, authFailure: Bool)
        case notOnDevice(id: String)
    }

    /// Runs jobs with `width` in flight; applies outcomes on the main actor as they finish.
    /// Returns the jobs whose image wasn't on the device (only when `allowNetwork` is false).
    private func process(
        _ jobs: [Job], worker: Worker, categories: [Category], allowNetwork: Bool, width: Int,
        byID: [String: ScreenshotRecord], saver: BatchSaver
    ) async -> [Job] {
        var deferred: [Job] = []
        let jobsByID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        await withTaskGroup(of: Outcome.self) { group in
            var iterator = jobs.makeIterator()
            func addNext() -> Bool {
                guard !Task.isCancelled, let job = iterator.next() else { return false }
                group.addTask(priority: .userInitiated) {
                    await Self.run(job, worker: worker, categories: categories, allowNetwork: allowNetwork)
                }
                return true
            }
            for _ in 0..<max(width, 1) where !addNext() { break }
            while let outcome = await group.next() {
                switch outcome {
                case let .sorted(id, choice, confidence, probabilities, model, text):
                    if let record = byID[id] {
                        record.category = choice
                        record.confidence = confidence
                        record.probabilitiesData = try? JSONEncoder().encode(probabilities)
                        record.model = model
                        record.classifiedAt = .now
                        record.lastError = nil
                        if record.ocrText == nil, let text { record.ocrText = text }
                    }
                    done += 1
                    if allowNetwork { waitingOnICloud -= 1 }
                case let .failed(id, message, text, authFailure):
                    // Keep the previous category; surface the error on the record.
                    if let record = byID[id] {
                        record.lastError = message
                        if record.ocrText == nil, let text { record.ocrText = text }
                    }
                    lastError = message
                    done += 1
                    if allowNetwork { waitingOnICloud -= 1 }
                    // A rejected key fails every request the same way; stop instead of flagging the whole library.
                    if authFailure { group.cancelAll(); return }
                case let .notOnDevice(id):
                    if let job = jobsByID[id] { deferred.append(job) }
                }
                saver.changed()
                _ = addNext()
            }
        }
        return deferred
    }

    /// One screenshot, off the main actor.
    private nonisolated static func run(_ job: Job, worker: Worker, categories: [Category], allowNetwork: Bool) async -> Outcome {
        guard let cgImage = await PhotoLibrary.image(for: job.asset, maxDimension: sortImagePixels, allowNetwork: allowNetwork)?.cgImage else {
            return allowNetwork
                ? .failed(id: job.id, message: "Couldn't load the image from Photos.", text: nil, authFailure: false)
                : .notOnDevice(id: job.id)
        }
        let text: String
        if let known = job.knownText { text = known } else { text = await OCR.recognizeText(in: cgImage, level: .fast) }

        switch worker {
        case let .local(clip):
            do {
                let options = categories.map { MobileCLIP.Category(key: $0.key, name: $0.name, detail: $0.detail) }
                let result = try clip.classify(cgImage, recognizedText: text, categories: options,
                                               fallbackKey: CategoryDef.otherKey, textWeight: 0.3)
                return .sorted(id: job.id, choice: result.choice, confidence: result.confidence,
                               probabilities: result.probabilities, model: LocalModelStore.modelName, text: text)
            } catch {
                return .failed(id: job.id, message: "On-device model failed: \(error.localizedDescription)", text: text, authFailure: false)
            }

        case let .jev(client, model, sendImage):
            let jpeg = sendImage ? UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7) : nil
            let options = categories.map { TypeSafeClient.CategoryOption(key: $0.key, name: $0.name, detail: $0.detail) }
            do {
                // Retry once, then record the error and keep whatever category the record already had.
                let result: TypeSafeClient.ChoiceResult
                do {
                    result = try await client.classify(ocrText: text, imageJPEG: jpeg, categories: options, model: model)
                } catch let error as TypeSafeClient.ClientError where !error.isRetryable {
                    throw error
                } catch {
                    try await Task.sleep(for: .seconds(1))
                    result = try await client.classify(ocrText: text, imageJPEG: jpeg, categories: options, model: model)
                }
                return .sorted(id: job.id, choice: result.choice, confidence: result.confidence,
                               probabilities: result.probabilities, model: result.model, text: text)
            } catch {
                let clientError = error as? TypeSafeClient.ClientError
                return .failed(id: job.id, message: error.localizedDescription, text: text,
                               authFailure: clientError?.isAuthFailure == true)
            }
        }
    }
}

/// Saves at most once a second (or every 200 changes) and refreshes the library index after,
/// so a long sort doesn't redraw the UI for every screenshot.
@MainActor
private final class BatchSaver {
    private let context: ModelContext
    private let index: LibraryIndex
    private var pending = 0
    private var lastSave = Date()

    init(context: ModelContext, index: LibraryIndex) {
        self.context = context
        self.index = index
    }

    func changed() {
        pending += 1
        if pending >= 200 || Date().timeIntervalSince(lastSave) >= 1 { flush() }
    }

    func flush() {
        guard pending > 0 else { return }
        try? context.save()
        pending = 0
        lastSave = Date()
        index.reload(context: context)
    }
}
