import Foundation
import Observation
import SwiftData

/// A lightweight, value-type snapshot of one screenshot record for list views.
struct Shot: Identifiable, Hashable {
    let id: String // PHAsset.localIdentifier
    let createdAt: Date?
    let category: String?
    let confidence: Double?
    let userOverride: Bool
    let hasError: Bool

    func needsReview(threshold: Double) -> Bool {
        if userOverride { return false }
        guard category != nil, let confidence else { return hasError }
        return confidence < threshold
    }
}

/// In-memory index of the library that views read instead of querying SwiftData directly.
/// Views get plain values grouped once per reload, so saving one record doesn't make every
/// view re-filter thousands of model objects.
@MainActor
@Observable
final class LibraryIndex {
    private(set) var shots: [Shot] = []
    private(set) var byCategory: [String: [Shot]] = [:]
    private(set) var unsorted: [Shot] = []

    /// assetID → lowercased recognized text, loaded on first search.
    @ObservationIgnored private var searchTexts: [(id: String, text: String)]?
    @ObservationIgnored private var lastReload = Date.distantPast
    @ObservationIgnored private var pendingReload: Task<Void, Never>?

    func reload(context: ModelContext) {
        pendingReload?.cancel()
        pendingReload = nil
        lastReload = .now

        var descriptor = FetchDescriptor<ScreenshotRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.propertiesToFetch = [\.assetID, \.createdAt, \.category, \.confidence, \.userOverride, \.lastError]
        let records = (try? context.fetch(descriptor)) ?? []

        let shots = records.map {
            Shot(id: $0.assetID, createdAt: $0.createdAt, category: $0.category, confidence: $0.confidence,
                 userOverride: $0.userOverride, hasError: $0.lastError != nil)
        }
        var byCategory: [String: [Shot]] = [:]
        var unsorted: [Shot] = []
        for shot in shots {
            if let key = shot.category { byCategory[key, default: []].append(shot) } else { unsorted.append(shot) }
        }
        self.shots = shots
        self.byCategory = byCategory
        self.unsorted = unsorted
        searchTexts = nil
    }

    /// Reloads at most once per `interval`, coalescing calls made in between. Used while sorting.
    func reloadThrottled(context: ModelContext, interval: TimeInterval = 1) {
        let wait = interval - Date().timeIntervalSince(lastReload)
        guard wait > 0 else { return reload(context: context) }
        guard pendingReload == nil else { return }
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.reload(context: context)
        }
    }

    func shots(in scope: Scope, reviewThreshold: Double = 0.5) -> [Shot] {
        switch scope {
        case .all: shots
        case let .category(key): byCategory[key] ?? []
        case .unsorted: unsorted
        case .review: shots.filter { $0.needsReview(threshold: reviewThreshold) }
        case .search: [] // async; see search(_:)
        }
    }

    /// Matches recognized text and category names. Runs the text scan off the main thread.
    func search(_ query: String, categoryKeys: Set<String>, context: ModelContext) async -> [Shot] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        if searchTexts == nil {
            var descriptor = FetchDescriptor<ScreenshotRecord>()
            descriptor.propertiesToFetch = [\.assetID, \.ocrText]
            let records = (try? context.fetch(descriptor)) ?? []
            searchTexts = records.compactMap { record in record.ocrText.map { (record.assetID, $0.lowercased()) } }
        }
        let texts = searchTexts ?? []
        let matchedIDs = await Task.detached(priority: .userInitiated) {
            Set(texts.lazy.filter { $0.text.contains(needle) }.map(\.id))
        }.value
        return shots.filter { matchedIDs.contains($0.id) || ($0.category.map(categoryKeys.contains) ?? false) }
    }
}
