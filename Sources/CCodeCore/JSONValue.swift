import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let b = try? value.decode(Bool.self) { self = .bool(b) }
        else if let n = try? value.decode(Double.self) { self = .number(n) }
        else if let s = try? value.decode(String.self) { self = .string(s) }
        else if let a = try? value.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let o): try value.encode(o)
        case .array(let a): try value.encode(a)
        case .string(let s): try value.encode(s)
        case .number(let n): try value.encode(n)
        case .bool(let b): try value.encode(b)
        case .null: try value.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue {
        get { object[key] ?? .null }
        set { var o = object; o[key] = newValue; self = .object(o) }
    }
    public var object: [String: JSONValue] { if case .object(let o) = self { o } else { [:] } }
    public var array: [JSONValue] { if case .array(let a) = self { a } else { [] } }
    public var string: String { if case .string(let s) = self { s } else { "" } }
    public var optionalString: String? { if case .string(let s) = self { s } else { nil } }
    public var int: Int { if case .number(let n) = self, n.isFinite, n >= Double(Int.min), n < Double(Int.max) { Int(n) } else { 0 } }
    public var exactInteger: Int? {
        guard case .number(let n) = self, n.isFinite, n.rounded(.towardZero) == n, abs(n) <= 9_007_199_254_740_991 else { return nil }
        return Int(n)
    }
    public var bool: Bool { if case .bool(let b) = self { b } else { false } }
    public var isNull: Bool { self == .null }
    public var pretty: String { String(data: (try? JSONEncoder.pretty.encode(self)) ?? Data(), encoding: .utf8) ?? "" }
    public func merging(_ other: JSONValue) -> JSONValue { .object(object.merging(other.object) { _, new in new }) }
}

extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, new in new })) }
}
extension JSONValue: ExpressibleByArrayLiteral { public init(arrayLiteral elements: JSONValue...) { self = .array(elements) } }
extension JSONValue: ExpressibleByStringLiteral { public init(stringLiteral value: String) { self = .string(value) } }
extension JSONValue: ExpressibleByIntegerLiteral { public init(integerLiteral value: Int) { self = .number(Double(value)) } }
extension JSONValue: ExpressibleByBooleanLiteral { public init(booleanLiteral value: Bool) { self = .bool(value) } }
extension JSONValue: ExpressibleByNilLiteral { public init(nilLiteral: ()) { self = .null } }

public enum ACPError: Error, LocalizedError, Sendable {
    case disconnected(String), protocolViolation(String), remote(Int, String), remoteFailure(Int, String, JSONValue), methodNotFound(String), timeout(String), workspace(String)
    public var rpcCode: Int? {
        switch self { case .remote(let code, _), .remoteFailure(let code, _, _): code; default: nil }
    }
    public var rpcData: JSONValue {
        if case .remoteFailure(_, _, let data) = self { data } else { .null }
    }
    public var rpcMessage: String? {
        switch self { case .remote(_, let text), .remoteFailure(_, let text, _): text; default: nil }
    }
    public var errorDescription: String? {
        switch self {
        case .disconnected(let s), .protocolViolation(let s), .workspace(let s): s
        case .remote(let code, let s), .remoteFailure(let code, let s, _): "\(s) (ACP \(code))"
        case .methodNotFound(let s): "Unsupported client method: \(s)"
        case .timeout(let s): "Agent did not answer \(s) in time."
        }
    }
}

public struct LineFramer: Sendable {
    private var buffer = Data()
    private let maximumBytes: Int
    public init(maximumBytes: Int = 8 * 1024 * 1024) { self.maximumBytes = maximumBytes }
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var cursor = buffer.startIndex
        var lines: [Data] = []
        while let end = buffer[cursor...].firstIndex(of: 10) {
            guard end - cursor <= maximumBytes else { throw ACPError.protocolViolation("ACP frame exceeds \(maximumBytes) bytes.") }
            var line = Data(buffer[cursor..<end])
            if line.last == 13 { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
            cursor = end + 1
        }
        buffer.removeSubrange(buffer.startIndex..<cursor)
        guard buffer.count <= maximumBytes else { throw ACPError.protocolViolation("ACP frame exceeds \(maximumBytes) bytes.") }
        return lines
    }
    public var hasPartialFrame: Bool { !buffer.isEmpty }
}
