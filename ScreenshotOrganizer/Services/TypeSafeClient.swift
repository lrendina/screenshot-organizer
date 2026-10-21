import Foundation

/// Calls TypeSafe's System One endpoint with a single Choice question.
/// Docs: https://docs.typesafe.ai/api.md
struct TypeSafeClient {
    struct CategoryOption {
        let key: String
        let name: String
        let detail: String
    }

    struct ChoiceResult {
        let choice: String
        let confidence: Double?
        let probabilities: [String: Double]
        let model: String
    }

    enum ClientError: LocalizedError {
        case missingKey
        case http(Int, String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: "Add your TypeSafe API key in Settings."
            case let .http(code, body): "TypeSafe returned \(code): \(body)"
            case let .malformed(why): "Unexpected TypeSafe response: \(why)"
            }
        }
    }

    var apiKey: String?
    var endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    /// - Parameters:
    ///   - ocrText: text recognized on the screenshot.
    ///   - imageJPEG: optional downscaled screenshot. Sent as an image asset, which needs a
    ///     vision model (e.g. `jev-preview`) and the `TypeSafe-Danger-Zone-Images` header.
    func classify(
        ocrText: String,
        imageJPEG: Data?,
        categories: [CategoryOption],
        model: String
    ) async throws -> ChoiceResult {
        guard let apiKey, !apiKey.isEmpty else { throw ClientError.missingKey }

        var state: [String: Any] = [
            "kind": "A screenshot taken on an iPhone",
            "recognized_text": ocrText.isEmpty ? "(no text recognized)" : ocrText,
        ]
        var assets: [String: Any]?
        if let imageJPEG {
            let placeholder = UUID().uuidString
            state["screenshot"] = placeholder
            assets = [placeholder: [
                "type": "image",
                "format": "jpeg",
                "data_base64": imageJPEG.base64EncodedString(),
            ]]
        }

        var criteria: [String: String] = [:]
        for category in categories {
            criteria[category.key] = "\(category.name): \(category.detail)"
        }

        let instructions: [String: Any] = [
            "task": "Which category best describes what this screenshot shows and why someone saved it?",
            "evidence": imageJPEG == nil
                ? "Use `recognized_text`, the on-device OCR of the screenshot. OCR may include status bar text, app chrome and minor errors."
                : "Use the `screenshot` image, with `recognized_text` as its OCR transcript.",
            "tie_break": "Pick the category for the main content, not navigation bars or keyboards.",
        ]

        var body: [String: Any] = [
            "model": model,
            "state": state,
            "questions": [
                "category": [
                    "type": "choice",
                    "instructions": instructions,
                    "criteria": criteria,
                ],
            ],
        ]
        if let assets { body["assets"] = assets }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if imageJPEG != nil {
            request.setValue("true", forHTTPHeaderField: "TypeSafe-Danger-Zone-Images")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw ClientError.http(status, String(data: data, encoding: .utf8)?.prefix(300).description ?? "")
        }
        return try Self.parse(data, validKeys: Set(categories.map(\.key)))
    }

    static func parse(_ data: Data, validKeys: Set<String>) throws -> ChoiceResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any],
              let answer = answers["category"] as? [String: Any],
              let choice = answer["choice"] as? String
        else { throw ClientError.malformed("missing answers.category.choice") }
        guard validKeys.contains(choice) else {
            throw ClientError.malformed("choice '\(choice)' is not a known category")
        }
        let probabilities = (answer["probabilities"] as? [String: Any] ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.doubleValue }
        return ChoiceResult(
            choice: choice,
            confidence: (answer["confidence"] as? NSNumber)?.doubleValue,
            probabilities: probabilities,
            model: root["model"] as? String ?? ""
        )
    }
}
