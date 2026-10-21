// Scores MobileCLIP on the labeled screenshots in DevFixtures/shots using the app's own classifier code.
// Run via Tools/eval-local-model.sh.
import Foundation
import ImageIO
import CoreML
import Vision

setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
let (modelsDir, shotsDir, resourcesDir) = (args[1], args[2], args[3])
let textWeight = args.count > 4 ? Float(args[4])! : 0.3

/// Expected category per fixture, by file name.
let expected: [String: String] = [
    "boarding": "travel", "chat": "chats", "code": "code", "map": "travel", "meme": "memes",
    "receipt": "receipts", "recipe": "recipes", "recipe2": "recipes", "shop": "shopping",
    "shop2": "shopping", "terminal": "code", "wiki": "notes",
]

// Mirrors CategoryDef.defaults (key, name, detail).
let categories: [MobileCLIP.Category] = [
    ("receipts", "Receipts & Orders", "Receipts, order confirmations, invoices, payment or bank transaction screens"),
    ("chats", "Conversations", "Text messages, DMs, group chats, emails or comment threads between people"),
    ("social", "Social Posts", "Posts, tweets, stories or profiles from social media apps, not private chats"),
    ("shopping", "Shopping", "Product pages, wishlists, prices or items someone is considering buying"),
    ("recipes", "Food & Recipes", "Recipes, ingredient lists, menus or restaurant pages"),
    ("travel", "Maps & Travel", "Maps, directions, addresses, boarding passes, bookings or travel itineraries"),
    ("code", "Code & Tech", "Source code, terminal output, error messages, technical docs or settings screens"),
    ("memes", "Memes & Funny", "Memes, jokes or images shared for humor"),
    ("notes", "Info & Notes", "Articles, quotes, instructions, schedules or reference information saved to read later"),
    ("other", "Other", "Anything that fits none of the other categories"),
].map { MobileCLIP.Category(key: $0.0, name: $0.1, detail: $0.2) }

func recognizeText(_ image: CGImage) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    // Vision's Neural Engine path can deadlock in a command-line tool; the CPU is fast enough here.
    if let cpu = try? request.supportedComputeStageDevices[.main]?.first(where: { if case .cpu = $0 { true } else { false } }) {
        request.setComputeDevice(cpu, for: .main)
    }
    try? VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

let tokenizer = try CLIPTokenizer(mergesURL: URL(fileURLWithPath: "\(resourcesDir)/clip-merges.txt"),
                                  vocabURL: URL(fileURLWithPath: "\(resourcesDir)/clip-vocab.json"))
let clip = try MobileCLIP(imageModelURL: URL(fileURLWithPath: "\(modelsDir)/mobileclip_s0_image.mlmodelc"),
                          textModelURL: URL(fileURLWithPath: "\(modelsDir)/mobileclip_s0_text.mlmodelc"),
                          tokenizer: tokenizer)

var correct = 0, total = 0
for file in try FileManager.default.contentsOfDirectory(atPath: shotsDir).sorted() where file.hasSuffix(".png") {
    let name = String(file.dropLast(4))
    guard let label = expected[name],
          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: "\(shotsDir)/\(file)") as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
    let result = try clip.classify(image, recognizedText: textWeight > 0 ? recognizeText(image) : nil,
                                   categories: categories, fallbackKey: "other", textWeight: textWeight)
    total += 1
    let ok = result.choice == label
    if ok { correct += 1 }
    print("\(ok ? "✓" : "✗") \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) expected \(label.padding(toLength: 9, withPad: " ", startingAt: 0)) got \(result.choice) (\(String(format: "%.2f", result.confidence)))")
}
print("\(correct)/\(total) correct, text weight \(textWeight)")
