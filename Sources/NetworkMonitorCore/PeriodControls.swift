import SwiftUI

// The parts Usage History and Connections share (#123, #125), so the two
// windows read the same way and can't drift apart: a control with its name,
// the period's heading, and ‹ Today › for History, which lives in Settings and
// so has no window toolbar of its own.

/// A segmented control with its name beside it: on its own, a segmented
/// control doesn't say what it chooses.
/// Where the row under a section's toolbar sits, the same in Usage History,
/// Connections and Ads and Trackers, so it doesn't move as you go from one
/// to the next (#436).
enum ScopeMetrics {
    static let inset: CGFloat = 20
    static let top: CGFloat = 12
    static let height: CGFloat = 24
    /// Between the row and what's under it.
    static let below: CGFloat = 14
}

struct LabelledControl<Control: View>: View {
    let label: String
    @ViewBuilder let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            control
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
        }
    }
}

/// When, then how much: the period's name leads, its main figure follows, and
/// the rest is one quieter line rather than more headings of the same weight.
struct PeriodHeading: View {
    let title: String
    /// The figure that matters most, such as "9.8 MB".
    let figure: String
    /// What it is, such as "used".
    let caption: String
    var details: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(figure)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(caption).foregroundStyle(.secondary)
                if !details.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(details.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.system(size: 13))
        }
    }
}
