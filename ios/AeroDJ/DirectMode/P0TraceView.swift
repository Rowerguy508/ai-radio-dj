#if AERODJ_P0_DIAG
// TEMPORARY P0 diagnostics (remove with #121 / #133). Internal p0_diag builds only.
// Built to be screenshotted: pinned header (build + last 3 polls), then the rows newest first.
// It shows only `header` and `row.rendered`, which Core has already sanitized
// (t, event, index/count, bools and reason codes). It adds no other text. -Nova
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

    private var newestFirst: [P0TraceRow] { rows.reversed() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(header)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(rows.count)/\(P0EventTrace.capacity) rows · newest first")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
                Button("Clear", action: onClear)
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("p0trace.clear")
            }
            Divider().overlay(Color.white.opacity(0.3))
            if rows.isEmpty {
                Text("No events yet")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(newestFirst.enumerated()), id: \.element.id) { offset, row in
                                Text(row.rendered)
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 1)
                                    .padding(.horizontal, 2)
                                    .background(offset.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.06))
                                    .id(row.id)
                            }
                        }
                    }
                    .onChange(of: rows.last?.id) { _, newest in
                        if let newest { proxy.scrollTo(newest, anchor: .top) }
                    }
                }
            }
        }
        .padding(8)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("p0trace.panel")
    }
}
#endif
