import SwiftUI
import CCodeCore

struct ChangeStatisticsLabel: View {
    let values: [FileChangeStatistics]
    var body: some View {
        HStack(spacing: 6) {
            if values.contains(where: { !$0.isBinary }) {
                Text("+\(values.compactMap(\.additions).reduce(0, +))").foregroundStyle(.green)
                Text("−\(values.compactMap(\.deletions).reduce(0, +))").foregroundStyle(.red)
            }
            let binary = values.filter(\.isBinary).count
            if binary > 0 { Text(values.count == 1 ? "Binary" : "\(binary) binary").foregroundStyle(.secondary) }
        }.font(.caption.monospacedDigit()).fixedSize()
    }
}
