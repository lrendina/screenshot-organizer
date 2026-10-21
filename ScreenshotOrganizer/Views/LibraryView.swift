import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(Classifier.self) private var classifier
    @Query(sort: \ScreenshotRecord.createdAt, order: .reverse) private var records: [ScreenshotRecord]
    @Query(sort: \CategoryDef.sortIndex) private var categories: [CategoryDef]

    private var unsorted: [ScreenshotRecord] { records.filter { $0.category == nil } }

    var body: some View {
        NavigationStack {
            List {
                Section { statusRow }

                Section("Categories") {
                    ForEach(categories) { category in
                        let items = records.filter { $0.category == category.key }
                        NavigationLink {
                            CategoryScreen(title: category.name, records: items)
                        } label: {
                            CategoryRow(category: category, records: items)
                        }
                    }
                }

                if !unsorted.isEmpty {
                    Section {
                        NavigationLink {
                            CategoryScreen(title: "Unsorted", records: unsorted)
                        } label: {
                            Label("Unsorted (\(unsorted.count))", systemImage: "tray")
                        }
                    }
                }
            }
            .navigationTitle("Screenshots")
            .refreshable { classifier.sync(context: context) }
        }
    }

    @ViewBuilder private var statusRow: some View {
        if classifier.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(classifier.done), total: Double(max(classifier.total, 1)))
                HStack {
                    Text("Sorting \(classifier.done) of \(classifier.total)…")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { classifier.cancel() }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    classifier.run(context: context)
                } label: {
                    Label(
                        unsorted.isEmpty ? "All \(records.count) screenshots sorted" : "Sort \(unsorted.count) screenshots",
                        systemImage: "sparkles"
                    )
                }
                .disabled(unsorted.isEmpty)
                if let error = classifier.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
    }
}

struct CategoryRow: View {
    let category: CategoryDef
    let records: [ScreenshotRecord]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.symbol)
                .frame(width: 28)
                .foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(category.name)
                Text("\(records.count)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(records.prefix(3)) { record in
                    Thumbnail(assetID: record.assetID, maxDimension: 120)
                        .frame(width: 22, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
        }
    }
}

struct CategoryScreen: View {
    let title: String
    let records: [ScreenshotRecord]

    var body: some View {
        ScrollView {
            if records.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: "photo.on.rectangle")
                    .padding(.top, 80)
            } else {
                ScreenshotGrid(records: records)
            }
        }
        .navigationTitle(title)
        .navigationDestination(for: ScreenshotRecord.self) { ScreenshotDetailView(record: $0) }
    }
}
