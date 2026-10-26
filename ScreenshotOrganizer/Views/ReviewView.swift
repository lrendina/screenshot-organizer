import SwiftUI

/// Screenshots the model wasn't sure about, plus ones that failed to classify.
struct ReviewView: View {
    @Environment(LibraryIndex.self) private var index
    @AppStorage(SettingsKey.reviewThreshold) private var threshold = 0.5

    var body: some View {
        let needsReview = index.shots(in: .review, reviewThreshold: threshold)
        NavigationStack {
            ScrollView {
                if needsReview.isEmpty {
                    ContentUnavailableView(
                        "Nothing to review",
                        systemImage: "checkmark.circle",
                        description: Text("Screenshots sorted with confidence under \(Int(threshold * 100))% show up here.")
                    )
                    .padding(.top, 80)
                } else {
                    ScreenshotGrid(shots: needsReview, scope: .review)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Review")
            .navigationDestination(for: ScreenshotRoute.self) { ScreenshotPager(shots: needsReview, selection: $0.assetID) }
        }
    }
}
