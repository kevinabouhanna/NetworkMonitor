import SwiftUI

/// What a window is narrowed to, said in words (#798): "Showing only Mon,
/// 16 Nov · GitHub · Google Chrome", each with its own ✕, and **Show
/// everything** at the end. In place of the chips, whose ✕ people testing the
/// app didn't see as the way back. The same in Connections, Usage History and
/// Ads and Trackers, as they behave alike (#593). Kevin chose it in the design
/// artifact on #798.
struct FilterBand: View {
    struct Filter: Identifiable {
        let id: String
        let label: String
        let onClear: () -> Void

        /// The toolbar's search, as a filter like the others (#436).
        static func search(_ query: String, onClear: @escaping () -> Void) -> Filter {
            Filter(id: "search", label: L("“%@”", query), onClear: onClear)
        }
    }

    let filters: [Filter]
    let onShowEverything: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L("Showing only"))
                .foregroundStyle(.secondary)
                .fixedSize()
            ForEach(Array(filters.enumerated()), id: \.element.id) { index, filter in
                if index > 0 {
                    Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                HStack(spacing: 3) {
                    Text(filter.label)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(action: filter.onClear) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("Stop showing only %@", filter.label))
                    // What it does, not its symbol (#536).
                    .accessibilityLabel(L("Remove %@", filter.label))
                }
            }
            Spacer(minLength: 8)
            Button(action: onShowEverything) {
                Text(L("Show everything"))
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.8)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(L("Show everything again. Escape lets go of one at a time, from the end; the search stays until it's cleared."))
        }
        .font(.system(size: 12))
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
