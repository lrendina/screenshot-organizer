import SwiftData
import SwiftUI

/// Screenshots Jev wasn't sure about, plus ones that failed to classify.
struct ReviewView: View {
    @Query(sort: \ScreenshotRecord.createdAt, order: .reverse) private var records: [ScreenshotRecord]
    @AppStorage(SettingsKey.reviewThreshold) private var threshold = 0.5

    private var needsReview: [ScreenshotRecord] { records.filter { $0.needsReview(threshold: threshold) } }

    var body: some View {
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
                    ScreenshotGrid(records: needsReview, scope: .review)
                }
            }
            .navigationTitle("Review")
            .navigationDestination(for: ScreenshotRoute.self) { ScreenshotPager(records: needsReview, selection: $0.assetID) }
        }
    }
}
