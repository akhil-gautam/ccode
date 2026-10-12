import Foundation

public enum SettingState: String, Codable, Sendable { case queued, applying, failed, uncertain }

public struct PendingSetting: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let key: String
    public let value: JSONValue
    public let legacy: Bool
    public let name: String
    public let valueName: String
    public let model: Bool
    public let executable: String
    public let arguments: [String]
    public let remoteID: String?
    public var state: SettingState = .queued
    public var error: String?
    public init(key: String, value: JSONValue, legacy: Bool, name: String, valueName: String, model: Bool, executable: String, arguments: [String], remoteID: String?) {
        id = UUID(); self.key = key; self.value = value; self.legacy = legacy
        self.name = name; self.valueName = valueName; self.model = model
        self.executable = executable; self.arguments = arguments; self.remoteID = remoteID
    }
}
