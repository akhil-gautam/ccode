import Foundation
import ImageIO
import UniformTypeIdentifiers

extension SessionStorage {
    public nonisolated static let imageInputLimit = 32 * 1024 * 1024
    /// Clipboard and drag images become immutable assets, just like selected files.
    public func importImage(_ data: Data) throws -> PromptAttachment {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count < Self.imageInputLimit else { throw ACPError.workspace("Pasted or dropped image data must be smaller than 32 MB.") }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source), let mime = UTType(type as String)?.preferredMIMEType else { throw ACPError.workspace("Could not read the pasted or dropped image.") }
        let bytes: Data, format: String
        if ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime), ((data.count + 2) / 3) * 4 + 1024 < PromptAttachment.promptLimit {
            bytes = data; format = mime
        } else {
            // AppKit screenshots often arrive as TIFF. Decode a bounded thumbnail,
            // never a full NSImage bitmap, before converting to an agent image format.
            let thumbnailOptions = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                                    kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { throw ACPError.workspace("Could not convert the pasted or dropped image.") }
            let output = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw ACPError.workspace("Could not encode the image.") }
            CGImageDestinationAddImage(encoder, image, nil)
            guard CGImageDestinationFinalize(encoder) else { throw ACPError.workspace("Could not encode the image.") }
            bytes = output as Data; format = "image/png"
        }
        try Task.checkCancellation()
        let charge = ((bytes.count + 2) / 3) * 4 + 1024
        guard bytes.count < 5 * 1024 * 1024, charge < PromptAttachment.promptLimit else { throw ACPError.workspace("Image exceeds the 6 MB prompt limit.") }
        let suffix = UTType(mimeType: format)?.preferredFilenameExtension ?? "png"
        let attachment = PromptAttachment(id: UUID(), url: URL(fileURLWithPath: "/Attached image." + suffix), mimeType: format, byteCount: bytes.count, promptBytes: charge)
        let target = attachmentURL(attachment)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: target, options: .atomic)
        return attachment
    }
}
