import Foundation

/// Recorded provider evidence, not authority to restore files or a new query.
public struct FileCheckpointReference: Codable, Sendable, Equatable {
    public let promptID: UUID
    public let checkpointID: String
    public let remoteID: String
    public let connectionID: String
    private let promptToken: String

    public init?(_ receipt: JSONValue, capability: JSONValue) {
        guard receipt["version"] == 1, Self.validCapability(capability),
              let promptToken = receipt["promptId"].optionalString, let prompt = UUID(uuidString: promptToken),
              let checkpoint = receipt["checkpointId"].optionalString, UUID(uuidString: checkpoint) != nil,
              let remote = receipt["sessionId"].optionalString, UUID(uuidString: remote) != nil,
              let connection = receipt["connectionId"].optionalString,
              connection == capability["connectionId"].string else { return nil }
        self.promptID = prompt; self.promptToken = promptToken
        self.checkpointID = checkpoint; self.remoteID = remote; self.connectionID = connection
    }
    public static func validCapability(_ value: JSONValue) -> Bool {
        value["version"] == 1 && UUID(uuidString: value["connectionId"].string) != nil
            && value["previewMethod"] == "_ccode/checkpoint/preview"
            && value["notificationMethod"] == "_ccode/checkpoint"
    }
    public func matches(capability: JSONValue, remoteID: String?) -> Bool {
        Self.validCapability(capability) && capability["connectionId"].string == connectionID && remoteID == self.remoteID
    }
    public var parameters: JSONValue {
        ["sessionId": .string(remoteID), "connectionId": .string(connectionID),
         "checkpointId": .string(checkpointID), "promptId": .string(promptToken)]
    }
}

public struct FileCheckpointPreview: Sendable, Equatable {
    public let reference: FileCheckpointReference
    public let canRewind: Bool
    public let paths: [String]
    public let insertions: Int
    public let deletions: Int
    public let previewToken: String?
    public let restoreUnavailable: String?
    public var restoreParameters: JSONValue? {
        guard let previewToken, canRewind, !paths.isEmpty else { return nil }
        var value = reference.parameters; value["previewToken"] = .string(previewToken); return value
    }
    public init(_ value: JSONValue, reference: FileCheckpointReference) throws {
        guard value["version"] == 1, value["declaredComplete"] == false,
              reference.parameters.object.allSatisfy({ value[$0.key] == $0.value }),
              case .bool(let canRewind) = value["canRewind"],
              case .array(let files) = value["filesChanged"], files.count <= 1024,
              let added = value["insertions"].exactInteger, added >= 0,
              let removed = value["deletions"].exactInteger, removed >= 0 else {
            throw ACPError.protocolViolation("Invalid file checkpoint preview.")
        }
        let paths = files.compactMap(\.optionalString)
        guard paths.count == files.count,
              paths.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.contains("\0") }),
              paths.reduce(0, { $0 + $1.utf8.count }) <= 256 * 1024 else {
            throw ACPError.protocolViolation("Invalid file checkpoint paths.")
        }
        self.reference = reference; self.canRewind = canRewind; self.paths = paths
        insertions = added; deletions = removed
        if !value["previewToken"].isNull {
            guard let token = value["previewToken"].optionalString, UUID(uuidString: token) != nil else { throw ACPError.protocolViolation("Invalid checkpoint preview token.") }
            previewToken = token
        } else { previewToken = nil }
        guard value["restoreUnavailable"].isNull || (value["restoreUnavailable"].optionalString?.utf8.count ?? Int.max) <= 4096 else {
            throw ACPError.protocolViolation("Invalid checkpoint availability.")
        }
        restoreUnavailable = value["restoreUnavailable"].optionalString
    }
}

public struct FileCheckpointRestoration: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable { case preparing, completed, partial, uncertain, rejected }
    public let id: UUID
    public let reference: FileCheckpointReference
    public let startedAt: Date
    public var status: Status
    public var recoveryDirectory: String?
    public var details: String?
    public var skippedLinks: Int
    public init(reference: FileCheckpointReference) {
        id = UUID(); self.reference = reference; startedAt = Date(); status = .preparing; skippedLinks = 0
    }
    public func finishing(_ value: JSONValue, recoveryRoot: URL) throws -> Self {
        guard value["version"] == 1, value["declaredComplete"] == false,
              reference.parameters.object.allSatisfy({ value[$0.key] == $0.value }),
              let status = Status(rawValue: value["status"].string), [.completed, .partial, .uncertain].contains(status),
              let skipped = value["skippedLinks"].exactInteger, skipped >= 0,
              let path = value["recoveryDirectory"].optionalString, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096,
              value["details"].isNull || (value["details"].optionalString?.utf8.count ?? Int.max) <= 4096 else {
            throw ACPError.protocolViolation("Invalid checkpoint restoration response. Inspect files before continuing.")
        }
        let folder = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard folder.deletingLastPathComponent().path == recoveryRoot.standardizedFileURL.resolvingSymlinksInPath().path,
              folder.lastPathComponent.hasPrefix("restore-"), folder.lastPathComponent.count > 8,
              status != .completed || skipped == 0 else { throw ACPError.protocolViolation("Invalid checkpoint recovery location or result.") }
        var result = self; result.status = status; result.skippedLinks = skipped
        result.recoveryDirectory = folder.path; result.details = value["details"].optionalString
        return result
    }
}

extension SessionTranscript {
    @discardableResult public mutating func recordFileCheckpoint(_ receipt: JSONValue, capability: JSONValue) -> Bool {
        guard let reference = FileCheckpointReference(receipt, capability: capability), remoteID == reference.remoteID else { return false }
        let matches = items.indices.filter { items[$0].id == reference.promptID }
        guard matches.count == 1, let index = matches.first, items[index].kind == "user",
              [.submitting, .acknowledged].contains(items[index].deliveryState), items[index].fileCheckpoint == nil else { return false }
        items[index].fileCheckpoint = reference
        return true
    }
}
