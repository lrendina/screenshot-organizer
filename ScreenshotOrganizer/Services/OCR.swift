import UIKit
@preconcurrency import Vision

/// On-device text recognition. Screenshots are mostly text, so this is the main signal sent to Jev.
enum OCR {
    static func recognizeText(in image: UIImage, maxCharacters: Int = 4000) async throws -> String {
        guard let cgImage = image.cgImage else { return "" }
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return String(lines.joined(separator: "\n").prefix(maxCharacters))
        }.value
    }
}
