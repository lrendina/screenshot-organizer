import CoreGraphics
@preconcurrency import Vision

/// On-device text recognition. Feeds search, the on-device model's text signal, and Jev.
enum OCR {
    /// Synchronous; call off the main thread. `.fast` is roughly 20× quicker than `.accurate`
    /// and good enough for classification and keyword search.
    static func recognizeTextSync(in image: CGImage, level: VNRequestTextRecognitionLevel, maxCharacters: Int = 4000) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = level == .accurate
        try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return String(lines.joined(separator: "\n").prefix(maxCharacters))
    }
}

extension OCR {
    /// Vision blocks its calling thread. Running it on Swift's cooperative pool (one thread per
    /// core) can starve the pool, so recognition runs on its own bounded queue instead.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "OCR"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        return queue
    }()

    static func recognizeText(in image: CGImage, level: VNRequestTextRecognitionLevel) async -> String {
        await withCheckedContinuation { continuation in
            queue.addOperation {
                continuation.resume(returning: recognizeTextSync(in: image, level: level))
            }
        }
    }
}
