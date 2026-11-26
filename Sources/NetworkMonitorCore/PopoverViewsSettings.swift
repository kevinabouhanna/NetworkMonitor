import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › General › Popover (#802): a tick to show or hide each of the
/// popover's views, and the order of the four buttons, by dragging a row or
/// with its ↑ and ↓, which the keyboard and VoiceOver reach. Live stays on
/// top; the last view shown can't be hidden.
struct PopoverViewsList: View {
    @ObservedObject var layout: PopoverLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(layout.rows.enumerated()), id: \.element) { index, section in
                if index > 0 { Divider() }
                row(section)
            }
            HStack {
                Spacer()
                Button(L("Show All, in the Original Order")) { layout.restore() }
                    .disabled(layout.isDefault)
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func row(_ section: PopoverSection) -> some View {
        let shown = layout.isShown(section)
        let content = HStack(spacing: 8) {
            Toggle(section.title, isOn: Binding(get: { layout.isShown(section) },
                                                set: { layout.setShown(section, $0) }))
                .toggleStyle(.checkbox)
                // The last view shown stays: the popover would open on nothing.
                .disabled(shown && !layout.canHide(section))
                .help(layout.whyShown(section) ?? L("Show %@ in the popover", section.title))
            if section == layout.opening {
                Text(L("Opens here"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if section == .live {
                Text(L("Always on top"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                moveButton(section, by: -1, symbol: "chevron.up", label: L("Move %@ up", section.title))
                moveButton(section, by: 1, symbol: "chevron.down", label: L("Move %@ down", section.title))
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .help(L("Drag to move"))
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        if section == .live {
            content
        } else {
            content
                .onDrag { NSItemProvider(object: section.rawValue as NSString) }
                .onDrop(of: [UTType.plainText], delegate: PopoverViewDrop(target: section, layout: layout))
        }
    }

    private func moveButton(_ section: PopoverSection, by offset: Int, symbol: String, label: String) -> some View {
        Button {
            withAnimation(Motion.content) { layout.move(section, by: offset) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!layout.canMove(section, by: offset))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A row dropped on another takes its place among the four.
private struct PopoverViewDrop: DropDelegate {
    let target: PopoverSection
    let layout: PopoverLayout

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { item, _ in
            guard let raw = item as? String, let section = PopoverSection(rawValue: raw) else { return }
            DispatchQueue.main.async {
                guard let index = layout.order.firstIndex(of: target) else { return }
                withAnimation(Motion.content) { layout.move(section, to: index) }
            }
        }
        return true
    }
}
