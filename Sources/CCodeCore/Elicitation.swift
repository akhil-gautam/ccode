import Foundation

public enum ElicitationAction: String, Sendable { case accept, decline, cancel }
public enum ElicitationFieldKind: Sendable { case text, boolean, number, integer, choice, multiple }

public struct ElicitationChoice: Sendable, Equatable, Identifiable {
    public let value: JSONValue
    public let title: String
    public let description: String
    public var id: JSONValue { value }
}

public struct ElicitationField: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let description: String
    public let kind: ElicitationFieldKind
    public let required: Bool
    public let choices: [ElicitationChoice]
    public let schema: JSONValue
}

/// ACP's restricted flat schema, not an arbitrary JSON Schema interpreter.
public struct ElicitationRequest: Sendable {
    public enum Mode: String, Sendable { case form, url }
    public let mode: Mode
    public let sessionID: String?
    public let requestID: JSONValue?
    public let toolCallID: String?
    public let message: String
    public let fields: [ElicitationField]
    public let url: URL?
    public let elicitationID: String?

    public init(params: JSONValue) throws {
        guard let mode = Mode(rawValue: params["mode"].string), case .object = params else { throw Self.invalid("Unsupported interaction mode.") }
        self.mode = mode
        let session = params["sessionId"].optionalString
        let request = params["requestId"]
        guard (session != nil) != (!request.isNull), session == nil || !session!.isEmpty,
              request.isNull || request.exactInteger != nil || (request.optionalString != nil && !request.string.isEmpty) else { throw Self.invalid("Interaction has no valid unique owner.") }
        sessionID = session; requestID = request.isNull ? nil : request
        toolCallID = params["toolCallId"].optionalString
        guard let message = params["message"].optionalString, message.utf8.count <= 65536 else { throw Self.invalid("Interaction message is missing or too large.") }
        self.message = message
        if mode == .url {
            guard let target = URL(string: params["url"].string), let host = target.host, !host.isEmpty, target.user == nil, target.password == nil,
                  target.scheme?.lowercased() == "https" || (target.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())),
                  let identity = params["elicitationId"].optionalString, !identity.isEmpty else { throw Self.invalid("The interaction needs a valid HTTPS URL and identity.") }
            url = target; elicitationID = identity; fields = []
            return
        }
        url = nil; elicitationID = nil
        let schema = params["requestedSchema"]
        guard schema["type"].string == "object", case .object(let properties) = schema["properties"], properties.count <= 64,
              schema["required"].isNull || schema["required"].array.allSatisfy({ $0.optionalString != nil && properties[$0.string] != nil }) && { if case .array = schema["required"] { return true }; return false }() else { throw Self.invalid("Unsupported question schema.") }
        let required = Set(schema["required"].array.map(\.string))
        fields = try properties.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
            let value = properties[key]!
            guard case .object = value, !key.isEmpty else { throw Self.invalid("Invalid question field.") }
            let choices: [ElicitationChoice]
            let kind: ElicitationFieldKind
            switch value["type"].string {
            case "string":
                guard value["format"].isNull || ["email", "uri", "date", "date-time"].contains(value["format"].string) else { throw Self.invalid("Unsupported text format.") }
                if !value["pattern"].isNull {
                    guard let pattern = value["pattern"].optionalString, pattern.utf8.count <= 2048,
                          (try? NSRegularExpression(pattern: pattern)) != nil else { throw Self.invalid("Unsupported text pattern.") }
                }
                choices = try Self.choices(value)
                kind = choices.isEmpty ? .text : .choice
            case "boolean": kind = .boolean; choices = []
            case "number": kind = .number; choices = []
            case "integer": kind = .integer; choices = []
            case "array":
                choices = try Self.choices(value["items"])
                guard !choices.isEmpty else { throw Self.invalid("Multiple-choice fields need string options.") }
                kind = .multiple
            default: throw Self.invalid("Unsupported question field type.")
            }
            return ElicitationField(id: key, title: value["title"].optionalString ?? key, description: value["description"].string,
                                    kind: kind, required: required.contains(key), choices: choices, schema: value)
        }
        // Invalid provider defaults must not silently become a user answer.
        for field in fields where !field.schema["default"].isNull { try Self.validate(field.schema["default"], field: field) }
    }

    public var defaultContent: JSONValue {
        .object(fields.reduce(into: [:]) { if !$1.schema["default"].isNull { $0[$1.id] = $1.schema["default"] } })
    }

    public func response(action: ElicitationAction, content: JSONValue = [:]) throws -> JSONValue {
        guard action == .accept, mode == .form else { return ["action": .string(action.rawValue)] }
        guard case .object(let values) = content, Set(values.keys).isSubset(of: Set(fields.map(\.id))) else { throw Self.invalid("The answer contains unknown fields.") }
        for field in fields {
            if let value = values[field.id] { try Self.validate(value, field: field) }
            else if field.required { throw Self.invalid("Please answer \(field.title).") }
        }
        return ["action": "accept", "content": content]
    }

    private static func choices(_ schema: JSONValue) throws -> [ElicitationChoice] {
        let titled = !schema["oneOf"].isNull ? schema["oneOf"] : schema["anyOf"]
        let values = !titled.isNull ? titled : schema["enum"]
        if values.isNull { return [] }
        guard case .array(let options) = values, !options.isEmpty, options.count <= 128 else { throw invalid("Invalid choice list.") }
        var seen = Set<JSONValue>()
        return try options.enumerated().map { index, option in
            let value = titled.isNull ? option : option["const"]
            guard value.optionalString != nil, seen.insert(value).inserted else { throw invalid("Choices must have unique string values.") }
            let names = schema["enumNames"].array
            return ElicitationChoice(value: value, title: titled.isNull ? (index < names.count ? names[index].string : value.string) : (option["title"].optionalString ?? value.string), description: titled.isNull ? "" : option["description"].string)
        }
    }

    private static func validate(_ value: JSONValue, field: ElicitationField) throws {
        let error = invalid("Please enter a valid answer for \(field.title).")
        switch field.kind {
        case .text:
            guard let text = value.optionalString, text.utf8.count <= 65536 else { throw error }
            if !field.schema["minLength"].isNull, text.count < field.schema["minLength"].int { throw error }
            if !field.schema["maxLength"].isNull, text.count > field.schema["maxLength"].int { throw error }
            if let pattern = field.schema["pattern"].optionalString {
                let regex = try NSRegularExpression(pattern: pattern)
                let deadline = ContinuousClock.now + .milliseconds(10)
                var matched = false
                regex.enumerateMatches(in: text, options: .reportProgress, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
                    if ContinuousClock.now >= deadline { stop.pointee = true }
                    else if match != nil { matched = true; stop.pointee = true }
                }
                guard matched else { throw error }
            }
            switch field.schema["format"].string {
            case "email": guard text.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else { throw error }
            case "uri": guard let url = URL(string: text), url.scheme != nil else { throw error }
            case "date":
                let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd"; format.isLenient = false
                guard let date = format.date(from: text), format.string(from: date) == text else { throw error }
            case "date-time":
                let format = ISO8601DateFormatter()
                if format.date(from: text) == nil { format.formatOptions.insert(.withFractionalSeconds); guard format.date(from: text) != nil else { throw error } }
            default: break
            }
        case .boolean: guard case .bool = value else { throw error }
        case .number, .integer:
            guard case .number(let number) = value, number.isFinite, field.kind != .integer || value.exactInteger != nil else { throw error }
            if case .number(let minimum) = field.schema["minimum"], number < minimum { throw error }
            if case .number(let maximum) = field.schema["maximum"], number > maximum { throw error }
        case .choice: guard field.choices.contains(where: { $0.value == value }) else { throw error }
        case .multiple:
            guard case .array(let values) = value, Set(values).count == values.count, values.allSatisfy({ answer in field.choices.contains { $0.value == answer } }) else { throw error }
            if !field.schema["minItems"].isNull, values.count < field.schema["minItems"].int { throw error }
            if !field.schema["maxItems"].isNull, values.count > field.schema["maxItems"].int { throw error }
        }
    }
    private static func invalid(_ message: String) -> ACPError { .remote(-32602, message) }
}
