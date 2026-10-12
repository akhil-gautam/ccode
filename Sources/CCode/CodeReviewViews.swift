import SwiftUI
import CCodeCore

struct CodeReviewStatusView: View {
    let review: CodeReview
    let canFix: Bool
    let select: (ReviewFinding) -> Void
    let fixAll: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if review.status == .queued || review.status == .running { ProgressView().controlSize(.small) }
                Text(summary).lineLimit(1)
                Spacer(minLength: 4)
                if review.status == .complete, !review.findings.isEmpty {
                    Menu("Findings") {
                        ForEach(review.findings) { finding in
                            Button("P\(finding.priority) · \(finding.path)\(finding.startLine.map { ":\($0)" } ?? "") · \(finding.title)") { select(finding) }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                    Button("Fix all", action: fixAll).disabled(!canFix)
                }
            }
            if let details = review.details { Text(details).foregroundStyle(.secondary).lineLimit(2).help(details) }
        }.font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.muted)
    }
    private var summary: String {
        switch review.status {
        case .queued: "Review queued"
        case .running: "Reviewing changes…"
        case .complete: review.findings.isEmpty ? "No actionable findings" : "\(review.findings.count) review \(review.findings.count == 1 ? "finding" : "findings")"
        case .unstructured: "Review in conversation"
        case .stale: "Review needs refreshing"
        case .interrupted: "Review interrupted"
        case .failed: "Review failed"
        }
    }
}

struct ReviewFindingCard: View {
    let finding: ReviewFinding
    let canFix: Bool
    let fix: () -> Void
    let respond: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("P\(finding.priority)").font(.caption.monospaced()).foregroundStyle(finding.priority <= 1 ? Color.orange : Color.secondary)
                Text(finding.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
            }
            Text(finding.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(location).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Respond", action: respond)
                Button("Fix finding", action: fix).disabled(!canFix)
            }.font(.caption)
        }.font(.system(size: 12)).padding(12).frame(maxWidth: 680, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border))
            .padding(.leading, finding.startLine == nil ? 12 : 90).padding(.trailing, 12).padding(.vertical, 8)
            .accessibilityElement(children: .contain).accessibilityLabel("Review finding: \(finding.title)")
    }
    private var location: String {
        guard let start = finding.startLine, let end = finding.endLine else { return "\(finding.context.source) · entire file" }
        return "\(finding.context.source) · line \(start)\(end == start ? "" : "–\(end)")"
    }
}
