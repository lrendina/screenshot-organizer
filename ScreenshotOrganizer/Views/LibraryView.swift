import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(Classifier.self) private var classifier
    @Query(sort: \ScreenshotRecord.createdAt, order: .reverse) private var records: [ScreenshotRecord]
    @Query(sort: \CategoryDef.sortIndex) private var categories: [CategoryDef]
    @State private var search = ""

    private var unsorted: [ScreenshotRecord] { records.filter { $0.category == nil } }
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if search.isEmpty {
                    VStack(alignment: .leading, spacing: 24) {
                        StatusCard(records: records, unsorted: unsorted.count)
                        if !records.isEmpty { recentStrip }
                        categoryGrid
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                } else {
                    searchResults
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Shotsort")
            .searchable(text: $search, prompt: "Search text in screenshots")
            .refreshable { classifier.sync(context: context) }
            .navigationDestination(for: CategoryRoute.self) { route in
                CategoryScreen(title: title(for: route.scope), tint: tint(for: route.scope),
                               records: records(in: route.scope), scope: route.scope)
            }
            .navigationDestination(for: ScreenshotRoute.self) { route in
                ScreenshotPager(records: records(in: route.scope), selection: route.assetID)
            }
        }
    }

    // MARK: Sections

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent").font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(records.prefix(12)) { record in
                        NavigationLink(value: ScreenshotRoute(assetID: record.assetID, scope: .all)) {
                            Thumbnail(assetID: record.assetID, maxDimension: 300)
                                .frame(width: 92, height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(alignment: .bottomLeading) {
                                    if let key = record.category, let category = category(for: key) {
                                        CategoryBadge(category: category).padding(6)
                                    }
                                }
                        }
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private var categoryGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Categories").font(.title3.bold())
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(categories) { category in
                    let items = records.filter { $0.category == category.key }
                    NavigationLink(value: CategoryRoute(scope: .category(category.key))) {
                        CategoryCard(name: category.name, symbol: category.symbol, tint: category.tint, records: items)
                    }
                    .buttonStyle(.plain)
                }
                if !unsorted.isEmpty {
                    NavigationLink(value: CategoryRoute(scope: .unsorted)) {
                        CategoryCard(name: "Unsorted", symbol: "tray", tint: .gray, records: unsorted)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var searchMatches: [ScreenshotRecord] { matches(for: search) }

    private func matches(for search: String) -> [ScreenshotRecord] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let matchingKeys = Set(categories.filter { $0.name.localizedCaseInsensitiveContains(query) }.map(\.key))
        return records.filter { record in
            (record.ocrText?.localizedCaseInsensitiveContains(query) ?? false)
                || record.category.map(matchingKeys.contains) == true
        }
    }

    @ViewBuilder private var searchResults: some View {
        let matches = searchMatches
        if matches.isEmpty {
            ContentUnavailableView.search(text: search).padding(.top, 60)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("^[\(matches.count) screenshot](inflect: true)")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal)
                ScreenshotGrid(records: matches, scope: .search(search))
            }
        }
    }

    // MARK: Helpers

    private func category(for key: String) -> CategoryDef? {
        categories.first { $0.key == key }
    }

    private func records(in scope: Scope) -> [ScreenshotRecord] {
        switch scope {
        case .all, .review: records
        case let .category(key): records.filter { $0.category == key }
        case .unsorted: unsorted
        case let .search(query): matches(for: query)
        }
    }

    private func title(for scope: Scope) -> String {
        switch scope {
        case let .category(key): category(for: key)?.name ?? "Category"
        case .unsorted: "Unsorted"
        default: "Screenshots"
        }
    }

    private func tint(for scope: Scope) -> Color {
        if case let .category(key) = scope { return category(for: key)?.tint ?? .accentColor }
        return .gray
    }
}

// MARK: - Status

struct StatusCard: View {
    @Environment(\.modelContext) private var context
    @Environment(Classifier.self) private var classifier
    let records: [ScreenshotRecord]
    let unsorted: Int
    @State private var modelStore = LocalModelStore.shared
    @AppStorage(SettingsKey.engine) private var engine = Engine.local.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if classifier.isRunning {
                HStack {
                    Label(classifier.phase == .reading ? "Reading text" : "Sorting with Jev",
                          systemImage: classifier.phase == .reading ? "text.viewfinder" : "sparkles")
                        .font(.headline)
                    Spacer()
                    Text("\(classifier.done)/\(classifier.total)").monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: Double(classifier.done), total: Double(max(classifier.total, 1)))
                    .tint(.accentColor)
                Button("Stop", role: .cancel) { classifier.cancel() }
                    .font(.subheadline)
            } else if records.isEmpty {
                Label("No screenshots yet", systemImage: "camera.viewfinder").font(.headline)
                Text("Take a screenshot and it'll show up here.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(records.count - unsorted) of \(records.count)")
                            .font(.title2.bold()).monospacedDigit()
                        Text("screenshots sorted").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if unsorted > 0, Engine.current == .local, !modelStore.isReady {
                        ModelDownloadButton(store: modelStore) { classifier.run(context: context) }
                    } else if unsorted > 0 {
                        Button {
                            classifier.run(context: context)
                        } label: {
                            Label("Sort \(unsorted)", systemImage: "sparkles")
                                .font(.headline)
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                    } else {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title)
                            .foregroundStyle(.green)
                    }
                }
                ProgressView(value: Double(records.count - unsorted), total: Double(max(records.count, 1)))
                    .tint(unsorted == 0 ? .green : .accentColor)
            }
            if let error = classifier.lastError, !classifier.isRunning {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Downloads the on-device model, then calls `onReady`.
struct ModelDownloadButton: View {
    let store: LocalModelStore
    let onReady: () -> Void

    var body: some View {
        switch store.state {
        case let .downloading(fraction):
            Gauge(value: fraction) { EmptyView() } currentValueLabel: {
                Text("\(Int(fraction * 100))").font(.caption2.monospacedDigit())
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(.accentColor)
            .scaleEffect(0.8)
        case .compiling:
            ProgressView()
        default:
            Button {
                Task {
                    await store.download()
                    if store.isReady { onReady() }
                }
            } label: {
                Label("Get model",
                      systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }
}

// MARK: - Category card

struct CategoryCard: View {
    let name: String
    let symbol: String
    let tint: Color
    let records: [ScreenshotRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if records.isEmpty {
                    Image(systemName: symbol)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(tint)
                } else {
                    // A small fan of the latest screenshots.
                    ForEach(Array(records.prefix(3).enumerated().reversed()), id: \.element.id) { index, record in
                        Thumbnail(assetID: record.assetID, maxDimension: 240)
                            .frame(width: 58, height: 122)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                            .rotationEffect(.degrees(Double(index - 1) * 9))
                            .offset(x: CGFloat(index - 1) * 30, y: index == 1 ? -4 : 6)
                    }
                    .offset(x: records.count == 1 ? 30 : records.count == 2 ? 15 : 0)
                }
            }
            .frame(height: 148)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint).font(.subheadline.weight(.semibold))
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Text("\(records.count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct CategoryBadge: View {
    let category: CategoryDef

    var body: some View {
        Image(systemName: category.symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(category.tint, in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
    }
}

// MARK: - Category screen

struct CategoryScreen: View {
    let title: String
    let tint: Color
    let records: [ScreenshotRecord]
    let scope: Scope

    var body: some View {
        ScrollView {
            if records.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "photo.on.rectangle")
                    .padding(.top, 80)
            } else {
                ScreenshotGrid(records: records, scope: scope)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .tint(tint)
    }
}

extension CategoryDef {
    var tint: Color {
        switch key {
        case "receipts": .green
        case "chats": .blue
        case "social": .pink
        case "shopping": .orange
        case "recipes": .red
        case "travel": .teal
        case "code": .indigo
        case "memes": .yellow
        case "notes": .brown
        case CategoryDef.otherKey: .gray
        default:
            [Color.purple, .mint, .cyan, .orange, .pink][abs(key.hashValue) % 5]
        }
    }
}
