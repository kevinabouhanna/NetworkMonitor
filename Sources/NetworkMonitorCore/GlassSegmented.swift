import SwiftUI

/// A segmented switch in the app's own look (#436): the choices on a glass
/// track, the chosen one raised in the control's grey, as the popover's
/// chosen button is, rather than filled with the accent colour. One for the
/// popover's period and groupings and for the row under each section's
/// toolbar, so every switch in the app reads the same.
struct GlassSegmented<Value: Hashable>: View {
    enum Size {
        /// The popover's period, and the row under a section's toolbar.
        case regular
        /// What a list is grouped by, under the popover's buttons.
        case small
    }

    let name: String
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var size: Size = .regular

    /// Not `@State`; see `SettingsPaneState`. A property wrapper, not a macro.
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(2)
        .frame(height: height)
        .background { track }
        .fixedSize()
        // VoiceOver reads it as the segmented control it looks like.
        .accessibilityRepresentation {
            Picker(name, selection: $selection) {
                ForEach(options, id: \.self) { option in Text(label(option)).tag(option) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func segment(_ option: Value) -> some View {
        let chosen = option == selection
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { selection = option }
        } label: {
            Text(label(option))
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(chosen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .padding(.horizontal, size == .regular ? 12 : 10)
                .frame(minWidth: minWidth, maxHeight: .infinity)
                .background {
                    if chosen {
                        Capsule()
                            .fill(Color(nsColor: .controlColor))
                            .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var track: some View {
        if #available(macOS 26, *) {
            Capsule().fill(Color.primary.opacity(0.04)).glassEffect(.regular, in: Capsule())
        } else {
            Capsule().fill(Color.primary.opacity(0.07))
        }
    }

    private var height: CGFloat { size == .regular ? 26 : 22 }
    private var fontSize: CGFloat { size == .regular ? 12 : 11 }
    /// Short words get the same width, so the switch reads as one control.
    private var minWidth: CGFloat { size == .regular ? 56 : 48 }
}
