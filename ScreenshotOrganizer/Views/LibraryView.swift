import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(Classifier.self) private var classifier
    @Environment(LibraryIndex.self) private var index
    @Query(sort: \CategoryDef.sortIndex) private var categories: [CategoryDef]
    @State private var search = ""
    @State private var searchResults: [Shot] = []
    @State private var searching = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if search.isEmpty {
                    VStack(alignment: .leading, spacing: 24) {
                        StatusCard(total: index.shots.count, unsorted: index.unsorted.count)
                        if !index.shots.isEmpty { recentStrip }
                        categoryGrid
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                } else {
                    searchResultsView
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Shotsort")
            .searchable(text: $search, prompt: "Search text in screenshots")
            .task(id: search) { await runSearch() }
            .refreshable {
                classifier.sync(context: context)
                index.reload(context: context)
            }
            .navigationDestination(for: CategoryRoute.self) { route in
                CategoryScreen(title: title(for: route.scope), tint: tint(for: route.scope),
                               shots: index.shots(in: route.scope), scope: route.scope)
            }
            .navigationDestination(for: ScreenshotRoute.self) { route in
                ScreenshotPager(shots: shots(in: route.scope), selection: route.assetID)
            }
        }
    }

    // MARK: Sections

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent").font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(index.shots.prefix(12)) { shot in
                        NavigationLink(value: ScreenshotRoute(assetID: shot.id, scope: .all)) {
                            Thumbnail(assetID: shot.id, maxDimension: 600)
                                .frame(width: 92, height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(alignment: .bottomLeading) {
                                    if let key = shot.category, let category = category(for: key) {
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
                    NavigationLink(value: CategoryRoute(scope: .category(category.key))) {
                        CategoryCard(name: category.name, symbol: category.symbol, tint: category.tint,
                                     shots: index.byCategory[category.key] ?? [])
                    }
                    .buttonStyle(.plain)
                }
                if !index.unsorted.isEmpty {
                    NavigationLink(value: CategoryRoute(scope: .unsorted)) {
                        CategoryCard(name: "Unsorted", symbol: "tray", tint: .gray, shots: index.unsorted)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var searchResultsView: some View {
        if searchResults.isEmpty, !searching {
            ContentUnavailableView.search(text: search).padding(.top, 60)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("^[\(searchResults.count) screenshot](inflect: true)")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal)
                ScreenshotGrid(shots: searchResults, scope: .search(search))
            }
        }
    }

    // MARK: Helpers

    private func runSearch() async {
        guard !search.isEmpty else { return searchResults = [] }
        searching = true
        // Debounce typing.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let keys = Set(categories.filter { $0.name.localizedCaseInsensitiveContains(search) }.map(\.key))
        let results = await index.search(search, categoryKeys: keys, context: context)
        guard !Task.isCancelled else { return }
        searchResults = results
        searching = false
    }

    private func category(for key: String) -> CategoryDef? {
        categories.first { $0.key == key }
    }

    private func shots(in scope: Scope) -> [Shot] {
        if case .search = scope { return searchResults }
        return index.shots(in: scope)
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
    let total: Int
    let unsorted: Int
    @State private var modelStore = LocalModelStore.shared
    @AppStorage(SettingsKey.engine) private var engine = Engine.local.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if classifier.isRunning {
                HStack {
                    Label(Engine.current == .local ? "Sorting on-device" : "Sorting with Jev", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    Text("\(classifier.done)/\(classifier.total)").monospacedDigit().foregroundStyle(.secondary)
                }
                ProgressView(value: Double(classifier.done), total: Double(max(classifier.total, 1)))
                    .tint(.accentColor)
                HStack {
                    Button("Stop", role: .cancel) { classifier.cancel() }
                    Spacer()
                    if classifier.waitingOnICloud > 0 {
                        Label("\(classifier.waitingOnICloud) in iCloud", systemImage: "icloud.and.arrow.down")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            } else if total == 0 {
                Label("No screenshots yet", systemImage: "camera.viewfinder").font(.headline)
                Text("Take a screenshot and it'll show up here.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(total - unsorted) of \(total)")
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
                ProgressView(value: Double(total - unsorted), total: Double(max(total, 1)))
                    .tint(unsorted == 0 ? .green : .accentColor)
            }
            if let message = classifier.lastSummary, !classifier.isRunning {
                Text(message).font(.footnote).foregroundStyle(.secondary)
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
                Label("Get model", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }
}

// MARK: - Category card

struct CategoryCard: View, Equatable {
    let name: String
    let symbol: String
    let tint: Color
    let shots: [Shot]

    static func == (a: CategoryCard, b: CategoryCard) -> Bool {
        a.name == b.name && a.symbol == b.symbol && a.tint == b.tint
            && a.shots.count == b.shots.count && a.shots.prefix(3).map(\.id) == b.shots.prefix(3).map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if shots.isEmpty {
                    Image(systemName: symbol)
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(tint)
                } else {
                    // A small fan of the latest screenshots.
                    ZStack {
                        ForEach(Array(shots.prefix(3).enumerated().reversed()), id: \.element.id) { index, shot in
                            Thumbnail(assetID: shot.id, maxDimension: 360)
                                .frame(width: 58, height: 122)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                                .rotationEffect(.degrees(Double(index - 1) * 9))
                                .offset(x: CGFloat(index - 1) * 30, y: index == 1 ? -4 : 6)
                        }
                    }
                    .offset(x: shots.count == 1 ? 30 : shots.count == 2 ? 15 : 0)
                    // Rasterize the rotated, shadowed fan once instead of compositing it every frame.
                    .drawingGroup()
                }
            }
            .frame(height: 148)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint).font(.subheadline.weight(.semibold))
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Text("\(shots.count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
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
    let shots: [Shot]
    let scope: Scope

    var body: some View {
        ScrollView {
            if shots.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "photo.on.rectangle")
                    .padding(.top, 80)
            } else {
                ScreenshotGrid(shots: shots, scope: scope)
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
            // Stable across launches (String.hashValue is randomly seeded per process).
            [Color.purple, .mint, .cyan, .orange, .pink][key.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 5]
        }
    }
}
