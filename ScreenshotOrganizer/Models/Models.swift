import Foundation
import SwiftData

/// One screenshot in the user's library. Keyed by `PHAsset.localIdentifier`.
@Model
final class ScreenshotRecord {
    @Attribute(.unique) var assetID: String
    var createdAt: Date?

    /// Category key, nil until a classification succeeds. A failed attempt never clears it.
    var category: String?
    var confidence: Double?
    var probabilitiesData: Data?
    var model: String?
    var classifiedAt: Date?

    /// True when the user picked the category by hand. Never overwritten by the model.
    var userOverride: Bool = false
    var ocrText: String?
    var lastError: String?

    init(assetID: String, createdAt: Date?) {
        self.assetID = assetID
        self.createdAt = createdAt
    }

    var probabilities: [String: Double] {
        guard let probabilitiesData,
              let dict = try? JSONDecoder().decode([String: Double].self, from: probabilitiesData)
        else { return [:] }
        return dict
    }

    func needsReview(threshold: Double) -> Bool {
        if userOverride { return false }
        guard category != nil, let confidence else { return lastError != nil }
        return confidence < threshold
    }
}

/// A user-editable category. `key` is what Jev returns; `detail` tells Jev what belongs in it.
@Model
final class CategoryDef {
    @Attribute(.unique) var key: String
    var name: String
    var detail: String
    var symbol: String
    var sortIndex: Int

    init(key: String, name: String, detail: String, symbol: String, sortIndex: Int) {
        self.key = key
        self.name = name
        self.detail = detail
        self.symbol = symbol
        self.sortIndex = sortIndex
    }

    static let otherKey = "other"

    static let defaults: [(String, String, String, String)] = [
        ("receipts", "Receipts & Orders", "Receipts, order confirmations, invoices, payment or bank transaction screens", "receipt"),
        ("chats", "Conversations", "Text messages, DMs, group chats, emails or comment threads between people", "bubble.left.and.bubble.right"),
        ("social", "Social Posts", "Posts, tweets, stories or profiles from social media apps, not private chats", "person.2"),
        ("shopping", "Shopping", "Product pages, wishlists, prices or items someone is considering buying", "bag"),
        ("recipes", "Food & Recipes", "Recipes, ingredient lists, menus or restaurant pages", "fork.knife"),
        ("travel", "Maps & Travel", "Maps, directions, addresses, boarding passes, bookings or travel itineraries", "map"),
        ("code", "Code & Tech", "Source code, terminal output, error messages, technical docs or settings screens", "chevron.left.forwardslash.chevron.right"),
        ("memes", "Memes & Funny", "Memes, jokes or images shared for humor", "face.smiling"),
        ("notes", "Info & Notes", "Articles, quotes, instructions, schedules or reference information saved to read later", "doc.text"),
        (otherKey, "Other", "Anything that fits none of the other categories", "square.grid.2x2"),
    ]
}
