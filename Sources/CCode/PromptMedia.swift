import AppKit
import UniformTypeIdentifiers
import CCodeCore

@MainActor enum AttachmentInput {
    case file(URL)
    case image(Data)
    case provider(NSItemProvider)

    var residentBytes: Int { if case .image(let data) = self { return data.count }; return 0 }
    static let imageTypes = [UTType.png, .jpeg, .gif, .webP, .tiff, .image]
    static func supported(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || imageTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    }
    func snapshot(using storage: SessionStorage) async throws -> Attachment {
        try Task.checkCancellation()
        switch self {
        case .file(let url): return try await storage.importAttachment(url)
        case .image(let bytes): return try await storage.importImage(bytes)
        case .provider(let provider):
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let data = try await Self.load(provider, type: UTType.fileURL.identifier)
                guard data.count < 64 * 1024, let value = String(data: data, encoding: .utf8), let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), url.isFileURL else { throw ACPError.workspace("Drop a local file or image.") }
                return try await storage.importAttachment(url)
            }
            guard let type = Self.imageTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { throw ACPError.workspace("Drop a local file or image.") }
            return try await storage.importImage(Self.load(provider, type: type.identifier))
        }
    }
    private static func load(_ provider: NSItemProvider, type: String) async throws -> Data {
        let load = ProviderImageLoad()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                load.install(continuation)
                load.install(provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    if let error { load.finish(.failure(error)) }
                    else if let data, data.count < SessionStorage.imageInputLimit { load.finish(.success(data)) }
                    else { load.finish(.failure(ACPError.workspace("Dropped image data must be smaller than 32 MB."))) }
                })
            }
        } onCancel: { load.cancel() }
    }
}

@MainActor enum PromptPasteboard {
    static func inputs(from board: NSPasteboard) throws -> [AttachmentInput] {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            guard urls.count <= PromptAttachment.countLimit else { throw ACPError.workspace("The attachment limit is 10 files.") }
            return urls.map(AttachmentInput.file)
        }
        var result: [AttachmentInput] = [], total = 0
        for item in board.pasteboardItems ?? [] {
            guard let type = item.availableType(from: [.png, .tiff]), let data = item.data(forType: type) else { continue }
            total += data.count
            guard !data.isEmpty, total < SessionStorage.imageInputLimit, result.count < PromptAttachment.countLimit else { throw ACPError.workspace("Pasted image data limit is 32 MB / 10 images.") }
            result.append(.image(data))
        }
        return result
    }
}

/// Progress cancellation does not guarantee a provider invokes its completion.
/// Resolve our waiter exactly once even when the provider never returns or returns late.
private final class ProviderImageLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var result: Result<Data, any Error>?
    private var progress: Progress?
    func install(_ continuation: CheckedContinuation<Data, any Error>) {
        lock.lock()
        let result = result
        if result == nil { self.continuation = continuation }
        lock.unlock()
        if let result { continuation.resume(with: result) }
    }
    func install(_ progress: Progress) {
        lock.lock(); let done = result != nil; if !done { self.progress = progress }; lock.unlock()
        if done { progress.cancel() }
    }
    func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation; self.continuation = nil
        let progress = progress; self.progress = nil
        lock.unlock()
        continuation?.resume(with: result)
        if case .failure(let error) = result, error is CancellationError { progress?.cancel() }
    }
    func cancel() { finish(.failure(CancellationError())) }
}
