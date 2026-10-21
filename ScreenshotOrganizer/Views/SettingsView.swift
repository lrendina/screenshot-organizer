import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CategoryDef.sortIndex) private var categories: [CategoryDef]
    @Query private var records: [ScreenshotRecord]

    @AppStorage(SettingsKey.model) private var model = "jev-latest"
    @AppStorage(SettingsKey.sendImage) private var sendImage = false
    @AppStorage(SettingsKey.imageModel) private var imageModel = "jev-preview"
    @AppStorage(SettingsKey.reviewThreshold) private var threshold = 0.5
    @AppStorage(SettingsKey.engine) private var engine = Engine.local.rawValue
    @AppStorage(SettingsKey.autoSort) private var autoSort = false

    @State private var apiKey = Keychain.get(SettingsKey.apiKey) ?? ""
    @State private var albumStatus: String?
    @State private var showResetConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sort with", selection: $engine) {
                        Text("On-device").tag(Engine.local.rawValue)
                        Text("Jev (your key)").tag(Engine.jev.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(engine == Engine.local.rawValue
                         ? "Apple's MobileCLIP runs on your iPhone. Free, works offline, and nothing leaves the device."
                         : "TypeSafe's Jev with your own API key. Only the text read from each screenshot is sent.")
                }

                if engine == Engine.local.rawValue {
                    LocalModelSection()
                } else {
                    Section {
                        SecureField("API key", text: $apiKey)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: apiKey) { _, value in
                                Keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: SettingsKey.apiKey)
                            }
                        TextField("Text model", text: $model)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Toggle("Also send the image", isOn: $sendImage)
                        if sendImage {
                            TextField("Vision model", text: $imageModel)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    } header: {
                        Text("TypeSafe")
                    } footer: {
                        Text("The key is stored in this device's Keychain. Sending the image needs a key with image access.")
                    }
                }

                Section {
                    Toggle("Auto-sort new screenshots", isOn: $autoSort)
                    VStack(alignment: .leading) {
                        Text("Review below \(Int(threshold * 100))% confidence")
                        Slider(value: $threshold, in: 0.2...0.9, step: 0.05)
                    }
                }

                Section("Categories") {
                    ForEach(categories) { category in
                        NavigationLink {
                            CategoryEditor(category: category)
                        } label: {
                            Label(category.name, systemImage: category.symbol)
                        }
                    }
                    .onDelete(perform: deleteCategories)
                    Button("Add category", action: addCategory)
                }

                Section {
                    Button("Save categories as Photos albums", action: saveAlbums)
                    if let albumStatus {
                        Text(albumStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Re-sort everything", role: .destructive) { showResetConfirm = true }
                        .confirmationDialog(
                            "Clear Jev's categories? Ones you set by hand are kept.",
                            isPresented: $showResetConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("Clear", role: .destructive, action: resetClassifications)
                        }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func addCategory() {
        let key = "custom_\(UUID().uuidString.prefix(8).lowercased())"
        let next = (categories.map(\.sortIndex).max() ?? 0) + 1
        context.insert(CategoryDef(key: key, name: "New category", detail: "Describe what belongs here", symbol: "folder", sortIndex: next))
        try? context.save()
    }

    private func deleteCategories(at offsets: IndexSet) {
        for index in offsets {
            let category = categories[index]
            guard category.key != CategoryDef.otherKey else { continue }
            for record in records where record.category == category.key {
                record.category = nil
                record.userOverride = false
            }
            context.delete(category)
        }
        try? context.save()
    }

    private func resetClassifications() {
        for record in records where !record.userOverride {
            record.category = nil
            record.confidence = nil
            record.probabilitiesData = nil
            record.lastError = nil
        }
        try? context.save()
    }

    private func saveAlbums() {
        var groups: [String: [String]] = [:]
        for category in categories {
            groups[category.name] = records.filter { $0.category == category.key }.map(\.assetID)
        }
        albumStatus = "Saving…"
        Task {
            do {
                try await PhotoLibrary.saveAlbums(groups)
                albumStatus = "Saved \(groups.values.filter { !$0.isEmpty }.count) albums."
            } catch {
                albumStatus = "Couldn't save albums: \(error.localizedDescription)"
            }
        }
    }
}

struct LocalModelSection: View {
    @State private var store = LocalModelStore.shared

    var body: some View {
        Section("On-device model") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MobileCLIP-S0")
                    Text("Apple · research license · \(ByteCountFormatter.string(fromByteCount: LocalModelStore.approximateBytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch store.state {
                case .ready:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                case .downloading, .compiling:
                    ProgressView()
                case .notDownloaded, .failed:
                    EmptyView()
                }
            }
            switch store.state {
            case .notDownloaded:
                Button("Download model") { Task { await store.download() } }
            case let .downloading(fraction):
                ProgressView(value: fraction) {
                    Text("Downloading… \(Int(fraction * 100))%").font(.footnote)
                }
            case .compiling:
                Text("Preparing model…").font(.footnote).foregroundStyle(.secondary)
            case .ready:
                Button("Remove model", role: .destructive) { store.delete() }
            case let .failed(message):
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("Try again") { Task { await store.download() } }
            }
            Link(destination: URL(string: "https://github.com/apple/ml-mobileclip/blob/main/LICENSE_MODELS")!) {
                Text("Apple Machine Learning Research Model is licensed under the Apple Machine Learning Research Model License Agreement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct CategoryEditor: View {
    @Environment(\.modelContext) private var context
    @Bindable var category: CategoryDef

    var body: some View {
        Form {
            TextField("Name", text: $category.name)
            TextField("SF Symbol", text: $category.symbol)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Section {
                TextField("What belongs here", text: $category.detail, axis: .vertical)
                    .lineLimit(3...6)
            } footer: {
                Text("Jev reads this description to decide what goes in the category.")
            }
        }
        .navigationTitle(category.name)
        .onDisappear { try? context.save() }
    }
}
