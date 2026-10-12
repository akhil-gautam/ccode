import SwiftUI
import AppKit
import CCodeCore

struct ToolDetailPresentation: Equatable, Sendable {
    struct Location: Equatable, Sendable { let path: String; let line: Int? }
    struct Field: Equatable, Sendable { let label: String; let value: String }
    enum Section: Equatable, Sendable {
        case text(title: String, value: String, command: Bool)
        case change(path: String, before: String?, after: String?)
        case content(JSONValue)
        case terminal(String)
    }
    var locations: [Location] = []
    var fields: [Field] = []
    var sections: [Section] = []
    let status: String

    init(tool: JSONValue) {
        status = tool["status"].string
        let name = tool["name"].optionalString ?? tool["_meta"]["claudeCode"]["toolName"].optionalString ?? tool["title"].string
        let input = tool["rawInput"]
        let structured = ["Read", "Write", "Edit", "Grep", "Glob"].contains(name) || ["read", "edit", "search"].contains(tool["kind"].string)
        var remaining = input.object
        for location in tool["locations"].array {
            if let path = location["path"].optionalString, !path.isEmpty {
                let line = location["line"].exactInteger.flatMap { $0 > 0 ? $0 : nil }
                let value = Location(path: path, line: line)
                if !locations.contains(value) { locations.append(value) }
            }
        }
        let path = input["file_path"].optionalString ?? input["path"].optionalString
        if structured, let path, !path.isEmpty {
            if !locations.contains(where: { $0.path == path }) {
                locations.append(Location(path: path, line: name == "Read" ? input["offset"].exactInteger.flatMap { $0 > 0 ? $0 : nil } : nil))
            }
            remaining.removeValue(forKey: "file_path"); remaining.removeValue(forKey: "path")
        }
        if structured {
            let labels = [("pattern", "Pattern"), ("glob", "Glob"), ("type", "File type"), ("output_mode", "Output"),
                          ("offset", "Start line"), ("limit", "Line limit"), ("head_limit", "Result limit"),
                          ("-i", "Case insensitive"), ("-n", "Line numbers"), ("multiline", "Multiline"),
                          ("-A", "Lines after"), ("-B", "Lines before"), ("-C", "Context lines"), ("replace_all", "Replace all")]
            for (key, label) in labels where !input[key].isNull {
                let value: String
                if case .bool(let flag) = input[key] { value = flag ? "Yes" : "No" }
                else { value = ToolPresentation.text(input[key]) }
                fields.append(Field(label: label, value: value)); remaining.removeValue(forKey: key)
            }
        }
        let changes = tool["content"].array.filter { $0["type"] == "diff" && $0["path"].optionalString != nil }
        if name == "Edit" || name == "Write" || tool["kind"] == "edit" {
            if changes.isEmpty, let path {
                let before = input["old_string"].optionalString
                let after = input["new_string"].optionalString ?? input["content"].optionalString ?? input["file_text"].optionalString ?? input["file_content"].optionalString
                if before != nil || after != nil { sections.append(.change(path: path, before: before, after: after)) }
            }
            // The authoritative content change holds these bytes once. Unknown keys stay inspectable.
            if !changes.isEmpty || sections.contains(where: { if case .change = $0 { true } else { false } }) {
                for key in ["old_string", "new_string", "content", "file_text", "file_content"] { remaining.removeValue(forKey: key) }
            }
        }
        if let command = input["command"].optionalString {
            sections.insert(.text(title: "Command", value: command, command: true), at: 0)
            remaining.removeValue(forKey: "command"); remaining.removeValue(forKey: "description")
        }
        let extraInput = remaining.isEmpty ? "" : ToolPresentation.text(.object(remaining))
        if !extraInput.isEmpty { sections.insert(.text(title: "Input", value: extraInput, command: false), at: 0) }
        if !input.isNull, input.object.isEmpty {
            switch input {
            case .object: break // Known fields have native presentation.
            default: sections.insert(.text(title: "Input", value: ToolPresentation.text(input), command: false), at: 0)
            }
        }
        var hasCanonicalResult = false
        for content in tool["content"].array {
            switch content["type"].string {
            case "diff":
                guard let path = content["path"].optionalString else { continue }
                sections.append(.change(path: path, before: content["oldText"].optionalString, after: content["newText"].optionalString))
            case "terminal":
                if let id = content["terminalId"].optionalString { sections.append(.terminal(id)) }
            case "content":
                let block = content["content"]
                if block["type"] == "text" {
                    let value = ToolPresentation.displayText(block["text"].string)
                    if !value.isEmpty, value != extraInput, value != input["command"].optionalString {
                        let section = Section.text(title: "Output", value: value, command: false)
                        if !sections.contains(section) { sections.append(section) }
                        hasCanonicalResult = true
                    }
                } else if !block["type"].isNull {
                    if ["image", "resource_link", "resource"].contains(block["type"].string) { sections.append(.content(block)) }
                    else { sections.append(.text(title: "Content", value: block.pretty, command: false)) }
                    hasCanonicalResult = true
                }
            default: sections.append(.text(title: "Content", value: content.pretty, command: false))
            }
        }
        let raw = ToolPresentation.text(tool["rawOutput"])
        if !hasCanonicalResult, !raw.isEmpty { sections.append(.text(title: "Output", value: ToolPresentation.displayText(raw), command: false)) }
    }
}

extension ToolPresentation {
    // Only unwrap an enclosing code fence, never Markdown surrounding a result.
    static func displayText(_ source: String) -> String {
        let value = source.hasSuffix("\n") ? source.dropLast() : source[...]
        guard let first = value.first, first == "`" || first == "~", let openingEnd = value.firstIndex(of: "\n"),
              let closingStart = value.lastIndex(of: "\n"), closingStart > openingEnd else { return source }
        let marker = value[..<openingEnd].prefix { $0 == first }
        guard marker.count >= 3, value[value.index(after: closingStart)...] == marker else { return source }
        return String(value[value.index(after: openingEnd)..<closingStart])
    }
}

struct ToolDetailsContent: View {
    let details: ToolDetailPresentation
    var chat: ChatSession? = nil
    var store: AppStore? = nil
    @State private var page = 0
    @State private var locationPage = 0
    private let pageSize = 12
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(details.locations.dropFirst(locationPage * pageSize).prefix(pageSize).enumerated()), id: \.offset) { _, location in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    if let chat, let store {
                        WorkspaceReferenceButton(reference: location.path, line: location.line, chat: chat, store: store) {
                            Text(location.path + (location.line.map { ":\($0)" } ?? "")).font(.system(size: 12, design: .monospaced)).lineLimit(3).multilineTextAlignment(.leading)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(location.path + (location.line.map { ":\($0)" } ?? "")).font(.system(size: 12, design: .monospaced))
                            .lineLimit(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(location.path, forType: .string) } label: {
                        Image(systemName: "doc.on.doc").frame(width: 40, height: 40)
                    }.buttonStyle(.plain).help("Copy file path").accessibilityLabel("Copy file path")
                }
            }
            paging(count: details.locations.count, page: $locationPage, noun: "Locations")
            ForEach(Array(details.fields.enumerated()), id: \.offset) { _, field in
                HStack(alignment: .top, spacing: 12) {
                    Text(field.label).font(.caption).foregroundStyle(.secondary)
                    Text(field.value).font(.system(size: 12, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(Array(details.sections.dropFirst(page * pageSize).prefix(pageSize).enumerated()), id: \.offset) { _, section in
                sectionView(section)
            }
            paging(count: details.sections.count, page: $page, noun: "Details")
            if details.locations.isEmpty, details.fields.isEmpty, details.sections.isEmpty {
                Text(["completed", "failed"].contains(details.status) ? "No additional details." : "Waiting for tool details…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: details) { _, _ in page = 0; locationPage = 0 }
    }
    @ViewBuilder private func sectionView(_ section: ToolDetailPresentation.Section) -> some View {
        switch section {
        case .text(let title, let value, let command):
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                ToolLog(text: value, command: command)
            }
        case .change(let path, let before, let after):
            VStack(alignment: .leading, spacing: 8) {
                Text(path).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
                if let before {
                    Text("Before").font(.caption).foregroundStyle(.secondary)
                    ToolLog(text: before, command: false).padding(8).background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
                if let after {
                    Text("After").font(.caption).foregroundStyle(.secondary)
                    ToolLog(text: after.isEmpty ? "(empty)" : after, command: false).padding(8).background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                } else { Text("Waiting for change contents…").font(.caption).foregroundStyle(.secondary) }
            }
        case .content(let block): ContentBlock(block: block)
        case .terminal(let id): Label("Terminal \(id)", systemImage: "terminal").font(.caption).lineLimit(2)
        }
    }
    @ViewBuilder private func paging(count: Int, page: Binding<Int>, noun: String) -> some View {
        if count > pageSize {
            HStack {
                Button("Previous") { page.wrappedValue -= 1 }.disabled(page.wrappedValue == 0)
                Text("\(noun) \(page.wrappedValue * pageSize + 1)–\(min(count, (page.wrappedValue + 1) * pageSize)) of \(count)").monospacedDigit().foregroundStyle(.secondary)
                Button("Next") { page.wrappedValue += 1 }.disabled((page.wrappedValue + 1) * pageSize >= count)
            }.font(.caption)
        }
    }
}
