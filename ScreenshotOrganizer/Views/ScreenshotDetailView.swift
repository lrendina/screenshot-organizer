import SwiftData
import SwiftUI

struct ScreenshotDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(Classifier.self) private var classifier
    @Bindable var record: ScreenshotRecord
    @Query(sort: \CategoryDef.sortIndex) private var categories: [CategoryDef]

    var body: some View {
        List {
            Section {
                Thumbnail(assetID: record.assetID, maxDimension: 1400)
                    .aspectRatio(9 / 19.5, contentMode: .fit)
                    .frame(maxHeight: 420)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
            }

            Section("Category") {
                Picker("Category", selection: categoryBinding) {
                    Text("Unsorted").tag(String?.none)
                    ForEach(categories) { Text($0.name).tag(Optional($0.key)) }
                }
                if record.userOverride {
                    Label("Set by you", systemImage: "hand.point.up.left").foregroundStyle(.secondary)
                } else if let confidence = record.confidence {
                    LabeledContent("Jev confidence", value: confidence.formatted(.percent.precision(.fractionLength(0))))
                }
                if let error = record.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Button("Ask Jev again") {
                    record.userOverride = false
                    classifier.run(context: context, records: [record])
                }
                .disabled(classifier.isRunning)
            }

            let probabilities = record.probabilities.sorted { $0.value > $1.value }.prefix(4)
            if !probabilities.isEmpty, !record.userOverride {
                Section("Probabilities") {
                    ForEach(Array(probabilities), id: \.key) { key, value in
                        LabeledContent(name(for: key)) {
                            ProgressView(value: value).frame(width: 120)
                        }
                    }
                }
            }

            if let text = record.ocrText, !text.isEmpty {
                Section("Recognized text") {
                    Text(text).font(.footnote).textSelection(.enabled)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var categoryBinding: Binding<String?> {
        Binding {
            record.category
        } set: { newValue in
            record.category = newValue
            record.userOverride = newValue != nil
            try? context.save()
        }
    }

    private func name(for key: String) -> String {
        categories.first { $0.key == key }?.name ?? key
    }
}
