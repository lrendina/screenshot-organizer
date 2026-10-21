import CoreML
import Foundation
import Observation

/// Downloads Apple's MobileCLIP-S0 Core ML encoders from Hugging Face (apple/coreml-mobileclip),
/// compiles them on-device, and keeps the compiled models in Application Support.
@MainActor
@Observable
final class LocalModelStore {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case compiling
        case ready
        case failed(String)
    }

    static let shared = LocalModelStore()
    static let modelName = "mobileclip-s0"
    static let approximateBytes: Int64 = 107_700_000

    private(set) var state: State = .notDownloaded
    private var loaded: MobileCLIP?

    private static let remoteBase = URL(string: "https://huggingface.co/apple/coreml-mobileclip/resolve/main")!
    private static let packages = ["mobileclip_s0_image", "mobileclip_s0_text"]
    private static let packageFiles: [(path: String, bytes: Int64)] = [
        ("Manifest.json", 1_000),
        ("Data/com.apple.CoreML/model.mlmodel", 200_000),
        ("Data/com.apple.CoreML/weights/weight.bin", 0), // sized per package below
    ]
    private static let weightBytes: [String: Int64] = [
        "mobileclip_s0_image": 22_717_696,
        "mobileclip_s0_text": 84_871_616,
    ]

    private var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)
    }

    private func compiledURL(_ package: String) -> URL {
        directory.appending(path: "\(package).mlmodelc", directoryHint: .isDirectory)
    }

    init() {
        if Self.packages.allSatisfy({ FileManager.default.fileExists(atPath: compiledURL($0).path) }) {
            state = .ready
        }
    }

    var isReady: Bool { state == .ready }

    /// The loaded model. Loading takes a moment the first time, so call this off the hot path.
    func model() async throws -> MobileCLIP {
        if let loaded { return loaded }
        guard isReady else { throw LocalModelError.notDownloaded }
        let image = compiledURL(Self.packages[0]), text = compiledURL(Self.packages[1])
        let model = try await Task.detached(priority: .userInitiated) {
            try MobileCLIP(imageModelURL: image, textModelURL: text, tokenizer: CLIPTokenizer())
        }.value
        loaded = model
        return model
    }

    func download() async {
        switch state {
        case .downloading, .compiling, .ready: return
        default: break
        }
        state = .downloading(0)
        let staging = FileManager.default.temporaryDirectory.appending(path: "mobileclip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var received: Int64 = 0
            for package in Self.packages {
                for file in Self.packageFiles {
                    let expected = file.bytes > 0 ? file.bytes : Self.weightBytes[package] ?? 0
                    let remote = Self.remoteBase.appending(path: "\(package).mlpackage/\(file.path)")
                    let local = staging.appending(path: "\(package).mlpackage/\(file.path)")
                    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let base = received
                    try await Self.download(remote, to: local) { bytes in
                        Task { @MainActor in
                            self.state = .downloading(min(1, Double(base + bytes) / Double(Self.approximateBytes)))
                        }
                    }
                    received += expected
                }
            }

            state = .compiling
            for package in Self.packages {
                let source = staging.appending(path: "\(package).mlpackage")
                let compiled = try await MLModel.compileModel(at: source)
                let destination = compiledURL(package)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: compiled, to: destination)
            }
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func delete() {
        loaded = nil
        for package in Self.packages {
            try? FileManager.default.removeItem(at: compiledURL(package))
        }
        state = .notDownloaded
    }

    private static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let delegate = ProgressDelegate(onBytes: progress)
        let (temp, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LocalModelError.http((response as? HTTPURLResponse)?.statusCode ?? -1, url.lastPathComponent)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }
}

enum LocalModelError: LocalizedError {
    case notDownloaded
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notDownloaded: "Download the on-device model in Settings first."
        case let .http(code, file): "Model download failed (\(code)) for \(file)."
        }
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onBytes: @Sendable (Int64) -> Void
    init(onBytes: @escaping @Sendable (Int64) -> Void) { self.onBytes = onBytes }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onBytes(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
