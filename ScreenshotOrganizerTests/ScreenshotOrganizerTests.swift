import CoreGraphics
import XCTest
@testable import ScreenshotOrganizer

final class TypeSafeParsingTests: XCTestCase {
    private let keys: Set<String> = ["receipts", "other"]

    func testParsesChoiceAnswer() throws {
        let json = #"{"model":"jev-latest","answers":{"category":{"type":"choice","choice":"receipts","confidence":0.7,"probabilities":{"receipts":0.8,"other":0.2}}},"usage":{"input_tokens":1,"output_tokens":1}}"#
        let result = try TypeSafeClient.parse(Data(json.utf8), validKeys: keys)
        XCTAssertEqual(result.choice, "receipts")
        XCTAssertEqual(result.confidence, 0.7)
        XCTAssertEqual(result.probabilities["other"], 0.2)
        XCTAssertEqual(result.model, "jev-latest")
    }

    func testRejectsUnknownCategory() {
        let json = #"{"answers":{"category":{"choice":"bogus"}}}"#
        XCTAssertThrowsError(try TypeSafeClient.parse(Data(json.utf8), validKeys: keys))
    }

    func testRejectsMissingAnswer() {
        XCTAssertThrowsError(try TypeSafeClient.parse(Data(#"{"answers":{}}"#.utf8), validKeys: keys))
        XCTAssertThrowsError(try TypeSafeClient.parse(Data("[]".utf8), validKeys: keys))
    }

    func testRetryAndAuthRules() {
        XCTAssertTrue(TypeSafeClient.ClientError.http(401, "").isAuthFailure)
        XCTAssertTrue(TypeSafeClient.ClientError.missingKey.isAuthFailure)
        XCTAssertFalse(TypeSafeClient.ClientError.http(500, "").isAuthFailure)
        XCTAssertFalse(TypeSafeClient.ClientError.http(422, "").isRetryable)
        XCTAssertTrue(TypeSafeClient.ClientError.http(429, "").isRetryable)
        XCTAssertTrue(TypeSafeClient.ClientError.http(503, "").isRetryable)
    }
}

final class MobileCLIPHelperTests: XCTestCase {
    private func image(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testPortraitScreenshotGetsThreeSquareCrops() {
        let crops = MobileCLIP.squareCrops(of: image(width: 100, height: 217))
        XCTAssertEqual(crops.count, 3)
        XCTAssertTrue(crops.allSatisfy { $0.width == 100 && $0.height == 100 })
    }

    func testSquareImageIsOneCrop() {
        XCTAssertEqual(MobileCLIP.squareCrops(of: image(width: 64, height: 64)).count, 1)
    }

    func testPixelBufferIsModelInputSize() {
        let buffer = MobileCLIP.pixelBuffer(from: image(width: 100, height: 100), size: MobileCLIP.inputSize)
        XCTAssertEqual(buffer.map(CVPixelBufferGetWidth), 256)
    }

    func testTokenizerWrapsAndTruncates() throws {
        let tokenizer = try CLIPTokenizer()
        let short = tokenizer.encode_full(text: "a screenshot of a receipt")
        XCTAssertEqual(short.count, 77)
        XCTAssertEqual(short[0], 49406) // <|startoftext|>
        XCTAssertTrue(short.contains(49407)) // <|endoftext|>
        // Long OCR text must not overflow the 77-token context.
        let long = tokenizer.encode_full(text: String(repeating: "word ", count: 500))
        XCTAssertEqual(long.count, 77)
        XCTAssertEqual(long[76], 49407)
    }
}
