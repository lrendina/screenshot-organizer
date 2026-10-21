import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// Zero-shot screenshot classification with Apple's open-source MobileCLIP-S0, entirely on-device.
///
/// The image encoder embeds several square crops of the screenshot (a tall screenshot doesn't fit
/// one square); the text encoder embeds a few prompts per category. The category whose averaged text
/// embedding is closest to the averaged image embedding wins, and a softmax over the cosine
/// similarities gives probabilities comparable in shape to Jev's.
final class MobileCLIP: @unchecked Sendable {
    struct Category {
        let key: String
        let name: String
        let detail: String
    }

    struct Result {
        let choice: String
        let confidence: Double
        let probabilities: [String: Double]
    }

    static let inputSize = 256
    /// CLIP's learned logit scale.
    static let logitScale: Float = 100

    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: CLIPTokenizer
    private var textCache: [String: [Float]] = [:]
    private let lock = NSLock()

    init(imageModelURL: URL, textModelURL: URL, tokenizer: CLIPTokenizer) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        imageModel = try MLModel(contentsOf: imageModelURL, configuration: config)
        textModel = try MLModel(contentsOf: textModelURL, configuration: config)
        self.tokenizer = tokenizer
    }

    // MARK: Classification

    /// CLIP has no good embedding for "none of these", so the fallback category (if present) isn't
    /// scored. It wins when no other category gets at least `fallbackBelow` probability.
    ///
    /// When `recognizedText` is given, its embedding is blended in with weight `textWeight`, since the
    /// words on screen often say more than the layout does.
    func classify(
        _ image: CGImage,
        recognizedText: String? = nil,
        categories: [Category],
        fallbackKey: String? = nil,
        fallbackBelow: Double = 0.3,
        textWeight: Float = 0.5
    ) throws -> Result {
        var queryEmbedding = try embed(image: image)
        if let recognizedText, !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let textEmbedding = try embed(prompts: [recognizedText], cache: false)
            queryEmbedding = normalized(zip(queryEmbedding, textEmbedding).map { (1 - textWeight) * $0 + textWeight * $1 })
        }
        var scores: [(String, Float)] = []
        for category in categories where category.key != fallbackKey {
            let categoryEmbedding = try embed(prompts: Self.prompts(for: category))
            scores.append((category.key, dot(queryEmbedding, categoryEmbedding) * Self.logitScale))
        }

        let maxScore = scores.map(\.1).max() ?? 0
        let exps = scores.map { ($0.0, exp(Double($0.1 - maxScore))) }
        let sum = exps.reduce(0) { $0 + $1.1 }
        let probabilities = Dictionary(uniqueKeysWithValues: exps.map { ($0.0, $0.1 / sum) })
        let best = probabilities.max { $0.value < $1.value }!
        if let fallbackKey, categories.contains(where: { $0.key == fallbackKey }), best.value < fallbackBelow {
            return Result(choice: fallbackKey, confidence: 1 - best.value, probabilities: probabilities)
        }
        return Result(choice: best.key, confidence: best.value, probabilities: probabilities)
    }

    static func prompts(for category: Category) -> [String] {
        [
            "a screenshot of \(category.name.lowercased())",
            "a phone screenshot showing \(category.detail.lowercased())",
        ]
    }

    // MARK: Embeddings

    /// Average of unit-normalized embeddings of square crops down the screenshot.
    func embed(image: CGImage) throws -> [Float] {
        var sum = [Float](repeating: 0, count: 512)
        let crops = Self.squareCrops(of: image)
        for crop in crops {
            guard let buffer = Self.pixelBuffer(from: crop, size: Self.inputSize) else { continue }
            let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
            let output = try imageModel.prediction(from: input)
            let embedding = normalized(Self.floats(output.featureValue(for: "final_emb_1")?.multiArrayValue))
            for i in sum.indices { sum[i] += embedding[i] }
        }
        return normalized(sum)
    }

    func embed(prompts: [String], cache: Bool = true) throws -> [Float] {
        let cacheKey = prompts.joined(separator: "\u{1}")
        if cache {
            lock.lock()
            let cached = textCache[cacheKey]
            lock.unlock()
            if let cached { return cached }
        }

        var sum = [Float](repeating: 0, count: 512)
        for prompt in prompts {
            let tokens = tokenizer.encode_full(text: prompt)
            let array = try MLMultiArray(shape: [1, NSNumber(value: tokenizer.contextLength)], dataType: .int32)
            for (i, token) in tokens.enumerated() { array[i] = NSNumber(value: token) }
            let input = try MLDictionaryFeatureProvider(dictionary: ["text": MLFeatureValue(multiArray: array)])
            let output = try textModel.prediction(from: input)
            let embedding = normalized(Self.floats(output.featureValue(for: "final_emb_1")?.multiArrayValue))
            for i in sum.indices { sum[i] += embedding[i] }
        }
        let result = normalized(sum)
        if cache {
            lock.lock()
            textCache[cacheKey] = result
            lock.unlock()
        }
        return result
    }

    // MARK: Image helpers

    /// Top, middle and bottom squares for a portrait screenshot (left/middle/right for landscape).
    static func squareCrops(of image: CGImage) -> [CGImage] {
        let w = image.width, h = image.height
        let side = min(w, h)
        guard max(w, h) > side else { return [image] }
        let span = max(w, h) - side
        return [0, span / 2, span].compactMap { offset in
            let rect = w < h
                ? CGRect(x: 0, y: offset, width: side, height: side)
                : CGRect(x: offset, y: 0, width: side, height: side)
            return image.cropping(to: rect)
        }
    }

    static func pixelBuffer(from image: CGImage, size: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return buffer
    }

    private static func floats(_ array: MLMultiArray?) -> [Float] {
        guard let array else { return [Float](repeating: 0, count: 512) }
        return (0..<array.count).map { array[$0].floatValue }
    }
}

private func dot(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
}

private func normalized(_ v: [Float]) -> [Float] {
    let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
    return norm > 0 ? v.map { $0 / norm } : v
}
