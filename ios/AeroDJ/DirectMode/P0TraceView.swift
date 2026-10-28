#if AERODJ_P0_DIAG
// TEMPORARY P0 diagnostics (remove with #121 / #133). Minimal placeholder; Nova replaces this
// file. Keep the init: `P0TraceView(rows:header:onClear:)`. -Fry
import AeroDJCore
import SwiftUI

struct P0TraceView: View {
    let rows: [P0TraceRow]
    let header: String
    let onClear: () -> Void

    init(rows: [P0TraceRow], header: String, onClear: @escaping () -> Void) {
        self.rows = rows
        self.header = header
        self.onClear = onClear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // The header's first line is the build; the next lines are the last 3 polls.
                Text("\(header)\n\(rows.count)/\(P0EventTrace.capacity) rows")
                    .font(.system(size: 10, design: .monospaced).bold())
                Spacer()
                Button("Clear", action: onClear)
                    .font(.caption)
                    .accessibilityIdentifier("p0trace.clear")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            Text(row.rendered)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .id(row.id)
                        }
                    }
                }
                .onChange(of: rows.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.green)
        .accessibilityIdentifier("p0trace.panel")
    }
}
#endif
