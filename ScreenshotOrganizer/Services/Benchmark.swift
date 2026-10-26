// Available in all builds; runs only with the -benchmark launch argument.
import Foundation
import Photos
import UIKit
@preconcurrency import Vision

/// Read-only timing of each sorting stage on real screenshots. Launch with `-benchmark <count>`:
/// `xcrun devicectl device process launch --console --device <udid> <bundle id> -benchmark 200`
enum Benchmark {
    static var requestedCount: Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-benchmark"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    @MainActor static func run(count: Int) async {
        log("benchmark: \(count) screenshots, \(ProcessInfo.processInfo.activeProcessorCount) cores")
        var t = Date()
        let all = PhotoLibrary.fetchScreenshots()
        let assets = Array(all.prefix(count))
        log("fetch asset list: \(all.count) screenshots in \(ms(since: t)) ms")

        // Photos image loads, local only, at two sizes.
        var images: [UIImage] = []
        for size in [512.0, 768.0] {
            t = Date()
            var loaded: [UIImage] = []
            for asset in assets {
                if let image = await PhotoLibrary.image(for: asset, maxDimension: size, allowNetwork: false) { loaded.append(image) }
            }
            log("load \(Int(size))px local-only: \(per(t, assets.count)) ms/shot, \(assets.count - loaded.count) not on device (iCloud)")
            if size == 768 { images = loaded }
        }
        guard !images.isEmpty else { return log("no local images") }
        let cgImages = images.compactMap(\.cgImage)

        // Text recognition, serial.
        let sample = Array(cgImages.prefix(50))
        var texts: [String] = []
        for level in [VNRequestTextRecognitionLevel.fast, .accurate] {
            t = Date()
            texts = sample.map { recognize($0, level: level) }
            log("ocr \(level == .fast ? "fast" : "accurate") @768px serial: \(per(t, sample.count)) ms/shot, avg \(texts.map(\.count).reduce(0, +) / max(texts.count, 1)) chars")
        }

        // Model stages.
        guard let clip = try? await LocalModelStore.shared.model() else { return log("model not downloaded") }
        _ = try? clip.embed(image: cgImages[0])
        t = Date()
        for image in cgImages { _ = try? clip.embed(image: image) }
        log("image embed serial: \(per(t, cgImages.count)) ms/shot")
        t = Date()
        for text in texts { _ = try? clip.embed(prompts: [text], cache: false) }
        log("text embed serial: \(per(t, texts.count)) ms/shot")

        // End-to-end, parallel across cores, local images only. (Vision must not run inline on the cooperative pool: it deadlocks.)
        let width = ProcessInfo.processInfo.activeProcessorCount
        for mode in ["image only", "image+ocr(queue)", "image+ocr(queue)+text embed"] {
            t = Date()
            var finished = 0
            await withTaskGroup(of: Void.self) { group in
                var iterator = assets.makeIterator()
                func next() -> Bool {
                    guard let asset = iterator.next() else { return false }
                    group.addTask {
                        guard let cg = await PhotoLibrary.image(for: asset, maxDimension: 768, allowNetwork: false)?.cgImage else { return }
                        switch mode {
                        case "image only":
                            _ = try? clip.embed(image: cg)
                        case "image+ocr(queue)":
                            _ = try? clip.embed(image: cg)
                            _ = await OCR.recognizeText(in: cg, level: .fast)
                        case "image+ocr(queue)+text embed":
                            _ = try? clip.embed(image: cg)
                            let text = await OCR.recognizeText(in: cg, level: .fast)
                            _ = try? clip.embed(prompts: [text], cache: false)
                        default:
                            _ = recognize(cg, level: .fast)
                        }
                    }
                    return true
                }
                for _ in 0..<width where !next() { break }
                while await group.next() != nil {
                    finished += 1
                    if finished % 50 == 0 { log("  \(mode): \(finished)") }
                    _ = next()
                }
            }
            let total = Date().timeIntervalSince(t)
            log("end-to-end parallel(\(width)) \(mode): \(Int(total * 1000)) ms total → 1000 shots ≈ \(String(format: "%.1f", total / Double(assets.count) * 1000)) s")
        }
        log("benchmark done")
    }

    static func recognize(_ image: CGImage, level: VNRequestTextRecognitionLevel) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = level == .accurate
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func ms(since t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
    private static func per(_ t: Date, _ n: Int) -> String { String(format: "%.1f", Date().timeIntervalSince(t) * 1000 / Double(max(n, 1))) }
    private static func log(_ s: String) { print("[bench] \(s)"); fflush(stdout) }
}
