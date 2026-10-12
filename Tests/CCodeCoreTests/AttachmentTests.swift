import XCTest
import AppKit
import PDFKit
import ImageIO
import CCodeCore
@testable import CCode

final class AttachmentTests: XCTestCase {
    func testSnapshotsSurviveSourceRemovalAndPDFUsesSupportedImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-attachments-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(directory: root.appendingPathComponent("data"))
        let text = root.appendingPathComponent("context.txt")
        try "Saved context".write(to: text, atomically: true, encoding: .utf8)
        let attachment = try await storage.importAttachment(text)
        try FileManager.default.removeItem(at: text)
        var transcript = SessionTranscript(); transcript.draftAttachments = [attachment]
        let id = UUID(); try await storage.save(transcript, id: id)
        let restored = try await storage.load(id)
        XCTAssertEqual(restored.draftAttachments, [attachment])
        let blocks = try await storage.attachmentPrompt(attachment, capabilities: [:])
        XCTAssertTrue(blocks[0]["text"].string.contains("Saved context"))
        let json = try Data(contentsOf: root.appendingPathComponent("data/\(id).json"))
        XCTAssertLessThan(json.count, 2000, "History must contain metadata, not attachment payloads")
        let pdf = root.appendingPathComponent("pages.pdf")
        var box = CGRect(x: 0, y: 0, width: 240, height: 120)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
            context.beginPDFPage(nil); context.setFillColor(color); context.fill(box); context.endPDFPage()
        }
        context.closePDF()
        let rotated = try XCTUnwrap(PDFDocument(url: pdf))
        try XCTUnwrap(rotated.page(at: 1)).rotation = 90
        XCTAssertTrue(rotated.write(to: pdf))
        let document = try await storage.importAttachment(pdf)
        let pages = try await storage.attachmentPrompt(document, capabilities: ["image": true])
        XCTAssertEqual(pages.filter { $0["type"].string == "image" }.count, 2)
        XCTAssertTrue(pages[0]["text"].string.contains("2 pages"))
        if let path = ProcessInfo.processInfo.environment["CCODE_ATTACHMENT_WIRE_PATH"] {
            try JSONEncoder().encode(JSONValue.array(pages)).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        for (index, page) in pages.filter({ $0["type"].string == "image" }).enumerated() {
            let data = try XCTUnwrap(Data(base64Encoded: page["data"].string))
            let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
            XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelWidth] as? Int ?? .max, 1600)
            XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelHeight] as? Int ?? .max, 1600)
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, index == 0 ? 1600 : 800)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, index == 0 ? 800 : 1600)
            let pixel = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            pixel.draw(try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil)), in: CGRect(x: 0, y: 0, width: 64, height: 64))
            let rgb = try XCTUnwrap(pixel.data).advanced(by: (32 * 64 + 32) * 4).assumingMemoryBound(to: UInt8.self)
            XCTAssertGreaterThan(rgb[index == 0 ? 0 : 2], 230, "Page order and color must survive rendering")
            XCTAssertLessThan(rgb[index == 0 ? 2 : 0], 25)
        }
        do { _ = try await storage.attachmentPrompt(document, capabilities: [:]); XCTFail("PDF visuals require image support") } catch {}
    }
    func testImageThumbnailsAreBoundedAndFileReadsAreComplete() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4000, pixelsHigh: 2000, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-thumbnail-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("large.png"); try data.write(to: image)
        for source in [AttachmentImage.Source.file(image), .base64(data.base64EncodedString())] {
            let thumbnail = try XCTUnwrap(AttachmentImage.thumbnail(source, pixelLimit: 80))
            XCTAssertEqual(thumbnail.width, 80); XCTAssertEqual(thumbnail.height, 40)
            XCTAssertLessThanOrEqual(thumbnail.bytesPerRow * thumbnail.height, 80 * 80 * 4)
        }
        XCTAssertNil(AttachmentImage.thumbnail(.base64("invalid"), pixelLimit: 80))
        XCTAssertNil(AttachmentImage.thumbnail(.base64(String(repeating: "A", count: PromptAttachment.promptLimit)), pixelLimit: 80))
        let text = root.appendingPathComponent("chunks.txt")
        let contents = String(repeating: "abcΩ\n", count: 40_000)
        try contents.write(to: text, atomically: true, encoding: .utf8)
        let storage = SessionStorage(directory: root.appendingPathComponent("data"))
        let attachment = try await storage.importAttachment(text)
        let blocks = try await storage.attachmentPrompt(attachment, capabilities: [:])
        XCTAssertEqual(blocks[0]["text"].string, "File: chunks.txt\n" + contents)
    }
    func testLimitsAndAudioCapabilityDoNotReadArbitraryPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-attachment-limits-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(directory: root.appendingPathComponent("data"))
        let audio = root.appendingPathComponent("sample.wav")
        try XCTUnwrap(Data(base64Encoded: "UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA=")).write(to: audio)
        let attachment = try await storage.importAttachment(audio)
        do { _ = try await storage.attachmentPrompt(attachment, capabilities: [:]); XCTFail("Unsupported audio must reject") } catch {}
        let blocks = try await storage.attachmentPrompt(attachment, capabilities: ["audio": true])
        XCTAssertEqual(blocks[0]["type"], "audio")
        XCTAssertEqual(Data(base64Encoded: blocks[0]["data"].string), try Data(contentsOf: audio))
        for source in [root, URL(string: "https://example.invalid/file.txt")!] {
            do { _ = try await storage.importAttachment(source); XCTFail("Only selected regular files can be imported") } catch {}
        }
        let huge = root.appendingPathComponent("huge.txt")
        try Data(count: 5 * 1024 * 1024).write(to: huge)
        do { _ = try await storage.importAttachment(huge); XCTFail("Oversized files must reject") } catch {}
        try Data(count: 2 * 1024 * 1024).write(to: huge)
        do { _ = try await storage.importAttachment(huge); XCTFail("Escaped text exceeds the wire budget") } catch {}
        try FileManager.default.removeItem(at: storage.attachmentURL(attachment))
        do { _ = try await storage.attachmentPrompt(attachment, capabilities: ["audio": true]); XCTFail("Missing snapshot must not fall back to the original path") } catch {}
        let legacy = try JSONDecoder().decode(SessionTranscript.self, from: Data("{\"version\":1,\"items\":[],\"plan\":[],\"configOptions\":[],\"modes\":{},\"models\":{},\"commands\":[],\"usage\":{}}".utf8))
        XCTAssertNil(legacy.draftAttachments)
        XCTAssertNil(legacy.remoteUnprompted)
    }
}
