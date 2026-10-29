import SwiftUI

// The parts Usage History and Connections share (#123, #125), so the two
// windows read the same way and can't drift apart: a control with its name,
// the period's heading, and ‹ Today › for History, which lives in Settings and
// so has no window toolbar of its own.

/// A segmented control with its name beside it: on its own, a segmented
/// control doesn't say what it chooses.
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

    static func count(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value) \(value == 1 ? one : many)"
    }
}

/// ‹ Today ›, as Calendar has it, with ⌘← and ⌘→.
struct PeriodStepper: View {
    let canStepBack: Bool
    let canStepForward: Bool
    let onStep: (Int) -> Void
    let onToday: () -> Void

    var body: some View {
        ControlGroup {
            Button { onStep(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(!canStepBack)
                .help("Previous (⌘←)")
            Button("Today", action: onToday)
                .help("Back to the present")
            Button { onStep(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!canStepForward)
                .help("Next (⌘→)")
        }
        .fixedSize()
    }
}
