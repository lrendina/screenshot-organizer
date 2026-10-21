import Photos
import SwiftData
import SwiftUI

@main
struct ScreenshotOrganizerApp: App {
    @State private var classifier = Classifier()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(classifier)
        }
        .modelContainer(for: [ScreenshotRecord.self, CategoryDef.self])
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(Classifier.self) private var classifier
    @Environment(\.scenePhase) private var scenePhase
    @State private var access: PHAuthorizationStatusBox = .unknown

    var body: some View {
        Group {
            switch access {
            case .unknown:
                ProgressView()
            case .denied:
                ContentUnavailableView {
                    Label("No access to Photos", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text("Allow photo access in Settings so Shotsort can find your screenshots.")
                } actions: {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            case .granted:
                TabView {
                    LibraryView()
                        .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                    ReviewView()
                        .tabItem { Label("Review", systemImage: "questionmark.circle") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gear") }
                }
            }
        }
        .task {
            seedCategoriesIfNeeded()
            access = await PHAuthorizationStatusBox(PhotoLibrary.requestAccess())
            if access == .granted { syncAndMaybeSort() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, access == .granted { syncAndMaybeSort() }
        }
    }

    private func syncAndMaybeSort() {
        let added = classifier.sync(context: context)
        guard added > 0, UserDefaults.standard.bool(forKey: SettingsKey.autoSort) else { return }
        let canSort = Engine.current == .local ? LocalModelStore.shared.isReady : Keychain.apiKey != nil
        if canSort { classifier.run(context: context) }
    }

    private func seedCategoriesIfNeeded() {
        let count = (try? context.fetchCount(FetchDescriptor<CategoryDef>())) ?? 0
        guard count == 0 else { return }
        for (index, entry) in CategoryDef.defaults.enumerated() {
            context.insert(CategoryDef(key: entry.0, name: entry.1, detail: entry.2, symbol: entry.3, sortIndex: index))
        }
        try? context.save()
    }
}

enum PHAuthorizationStatusBox: Equatable {
    case unknown, granted, denied

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized, .limited: self = .granted
        default: self = .denied
        }
    }
}
