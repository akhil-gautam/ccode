import Foundation

public struct SideQuestionExchange: Equatable, Sendable {
    public let question: String
    public let response: String
    public init(question: String, response: String) { self.question=question;self.response=response }
}
public struct SideQuestionReply: Sendable {
    public let answer: String?
    public let synthetic: Bool
    public init(_ value: JSONValue, sessionID: String, connectionID: UUID, questionID: UUID) throws {
        guard value["version"] == 1, value["sessionId"] == .string(sessionID),
              value["connectionId"].optionalString.flatMap(UUID.init(uuidString:)) == connectionID,
              value["questionId"].optionalString.flatMap(UUID.init(uuidString:)) == questionID,
              case .bool(let synthetic) = value["synthetic"],
              value["answer"].isNull || Self.validText(value["answer"].optionalString, limit: 24576) else {
            throw ACPError.protocolViolation("Side question response belongs to a different or unsupported request.")
        }
        answer=value["answer"].optionalString;self.synthetic=synthetic
    }
    public static func validText(_ text: String?, limit: Int) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= limit && !text.contains("\0")
    }
}
