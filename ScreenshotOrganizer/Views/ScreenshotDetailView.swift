import SwiftData
import SwiftUI

/// Swipe between screenshots, starting at `selection`.
struct ScreenshotPager: View {
    let records: [ScreenshotRecord]
    @State var selection: String

    var body: some View {
        TabView(selection: $selection) {
            ForEach(records) { record in
                ScreenshotDetailView(record: record).tag(record.assetID)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let record = records.first(where: { $0.assetID == selection }) {
                ToolbarItem(placement: .principal) {
                    if let date = record.createdAt {
                        Text(date, format: .dateTime.month().day().year().hour().minute())
                            .font(.subheadline.weight(.semibold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareScreenshotButton(assetID: record.assetID)
                }
            }
        }
    }
}

struct ScreenshotDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(Classifier.self) private var classifier
    @Bindable var record: ScreenshotRecord
    @Query(sort: \CategoryDef.sortIndex) private var categories: [CategoryDef]
    @State private var showFullScreen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button { showFullScreen = true } label: {
                    Thumbnail(assetID: record.assetID, maxDimension: 1400)
                        .aspectRatio(9 / 19.5, contentMode: .fit)
                        .frame(maxHeight: 440)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)

                categoryPicker
                if !record.userOverride, !record.probabilities.isEmpty { probabilities }
                if let error = record.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let text = record.ocrText, !text.isEmpty { recognizedText(text) }
            }
            .padding()
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenImage(assetID: record.assetID)
        }
    }

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Category").font(.headline)
                Spacer()
                if record.userOverride {
                    Label("Set by you", systemImage: "hand.point.up.left.fill")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let confidence = record.confidence {
                    Text("\(record.model == LocalModelStore.modelName ? "On-device" : "Jev") · \(confidence, format: .percent.precision(.fractionLength(0))) sure")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    record.userOverride = false
                    classifier.run(context: context, records: [record])
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(classifier.isRunning)
                .accessibilityLabel("Sort again")
            }
            FlowLayout(spacing: 8) {
                ForEach(categories) { category in
                    let selected = record.category == category.key
                    Button {
                        record.category = category.key
                        record.userOverride = true
                        try? context.save()
                    } label: {
                        Label(category.name, systemImage: category.symbol)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(selected ? .white : .primary)
                            .background(selected ? category.tint : Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: selected)
                }
            }
        }
    }

    private var probabilities: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top guesses").font(.headline)
            ForEach(record.probabilities.sorted { $0.value > $1.value }.prefix(3), id: \.key) { key, value in
                let category = categories.first { $0.key == key }
                HStack {
                    Text(category?.name ?? key).font(.subheadline).frame(width: 130, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule().fill(Color(.tertiarySystemFill))
                            .overlay(alignment: .leading) {
                                Capsule().fill(category?.tint ?? .accentColor)
                                    .frame(width: max(6, proxy.size.width * value))
                            }
                    }
                    .frame(height: 8)
                    Text(value, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    private func recognizedText(_ text: String) -> some View {
        DisclosureGroup {
            Text(text).font(.footnote).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            Label("Text on screen", systemImage: "text.viewfinder").font(.headline)
        }
        .tint(.primary)
    }
}

struct ShareScreenshotButton: View {
    let assetID: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ShareLink(item: Image(uiImage: image), preview: SharePreview("Screenshot", image: Image(uiImage: image)))
            } else {
                Image(systemName: "square.and.arrow.up").foregroundStyle(.tertiary)
            }
        }
        .task(id: assetID) {
            image = nil
            guard let asset = PhotoLibrary.asset(for: assetID) else { return }
            image = await PhotoLibrary.image(for: asset, maxDimension: 3000)
        }
    }
}

struct FullScreenImage: View {
    let assetID: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Thumbnail(assetID: assetID, maxDimension: 3000)
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }
                    .onEnded { _ in withAnimation(.spring) { scale = 1 } })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding()
        }
        .onTapGesture { dismiss() }
    }
}

/// Lays out children left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var y: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            let gap: CGFloat = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
