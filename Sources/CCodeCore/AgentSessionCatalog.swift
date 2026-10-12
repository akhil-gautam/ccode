import Foundation

public struct AgentSessionSummary: Sendable {
    public let sessionID: String
    public let cwd: String
    public let title: String
    public let updatedAt: Date
    public let additionalDirectories: [String]
}

extension ACPConnection {
    public func sessionCatalog() async throws -> [AgentSessionSummary] {
        var summaries: [AgentSessionSummary] = [], cursor: String?, cursors: Set<String> = []
        let dates = ISO8601DateFormatter(); dates.formatOptions.insert(.withFractionalSeconds)
        let plainDates = ISO8601DateFormatter()
        repeat {
            try Task.checkCancellation()
            let result = try await request("session/list", params: cursor.map { ["cursor": .string($0)] } ?? [:], timeout: .seconds(20))
            guard case .array(let rows) = result["sessions"] else { throw ACPError.protocolViolation("Agent returned an invalid session catalog.") }
            for row in rows {
                let id = row["sessionId"].string, cwd = row["cwd"].string
                if !row["additionalDirectories"].isNull {
                    guard case .array = row["additionalDirectories"] else { throw ACPError.protocolViolation("Invalid additional directories in session catalog.") }
                }
                let roots = row["additionalDirectories"].array.map(\.string)
                guard !id.isEmpty, id.utf8.count <= 1024, cwd.hasPrefix("/"), !cwd.contains("\0"), roots.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else {
                    throw ACPError.protocolViolation("Agent returned invalid session metadata.")
                }
                let title = row["title"].optionalString.flatMap { $0.isEmpty ? nil : $0 } ?? "Claude session"
                let date = dates.date(from: row["updatedAt"].string) ?? plainDates.date(from: row["updatedAt"].string) ?? .distantPast
                summaries.append(AgentSessionSummary(sessionID: id, cwd: cwd, title: String(title.prefix(512)), updatedAt: date, additionalDirectories: roots))
            }
            if !result["nextCursor"].isNull {
                guard case .string = result["nextCursor"] else { throw ACPError.protocolViolation("Invalid session catalog cursor.") }
            }
            cursor = result["nextCursor"].optionalString
            if let cursor {
                guard !cursor.isEmpty, cursors.insert(cursor).inserted, cursors.count <= 2_000 else { throw ACPError.protocolViolation("Agent repeated or exceeded session catalog pagination.") }
            }
            guard summaries.count <= 100_000 else { throw ACPError.protocolViolation("Agent session catalog exceeds 100,000 summaries.") }
        } while cursor != nil
        return summaries
    }
}
