import AppKit
import Combine
import FilterProtocol
import FirewallPolicy
import SwiftUI

/// Ask Me (#129): the filter holds an app's first connections to a company,
/// and this asks about them in a small panel at the top right, never a modal
/// alert. One question at a time; the rest wait their turn. Unanswered in 30
/// seconds, the filter lets them go, and the panel says so.
public final class AskController: ObservableObject {

    public struct Item: Identifiable, Equatable {
        public let question: FlowQuestion
        public let appName: String
        public let bundlePath: String?
        /// Where to, as the question reads it: the company, or the site.
        public let target: String
        /// What else is known: the site or address, whose network, the country.
        public let detail: String
        public var expired = false

        public var id: String { question.id }
    }

    public enum Choice {
        case block, allowOnce, allow
        /// The app, wherever it connects.
        case allowAnywhere
    }

    @Published public private(set) var items: [Item] = []

    private let filter: FilterController
    private let firewall: FirewallRules
    private var panel: NSPanel?
    private var subscriptions: Set<AnyCancellable> = []

    public init(filter: FilterController, firewall: FirewallRules) {
        self.filter = filter
        self.firewall = firewall
        filter.questions.sink { [weak self] in self?.add($0) }.store(in: &subscriptions)
        filter.expiredQuestions.sink { [weak self] in self?.expire($0) }.store(in: &subscriptions)
    }

    public static func item(for question: FlowQuestion) -> Item {
        let app = AppIdentityResolver.identity(forKey: question.appKey)
        let country = question.country.map { ConnectionsReport.countryName($0) }
        let site = question.hostname ?? question.address
        let target: String
        var detail: [String] = []
        switch (question.companyName, question.companyIsHost) {
        case (let name?, false):
            target = name
            detail.append(site)
        case (let name?, true):
            // A host's name says whose computers, not whose service.
            target = question.hostname ?? "a server on \(name)'s network"
            detail.append(question.hostname == nil ? question.address : "on \(name)'s network")
        case (nil, _):
            target = site
        }
        if let country { detail.append(country) }
        return Item(question: question, appName: app.displayName, bundlePath: app.bundlePath ?? app.parent?.bundlePath,
                    target: target, detail: detail.joined(separator: " · "))
    }

    private func add(_ question: FlowQuestion) {
        guard !items.contains(where: { $0.id == question.id }) else { return }
        items.append(Self.item(for: question))
        show()
    }

    private func expire(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].expired = true
        // Long enough to read that it went ahead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.remove(id) }
    }

    public func answer(_ item: Item, _ choice: Choice) {
        let question = item.question
        // The rule is about what the question was about: the company, or the
        // address when nobody owns it.
        let subject: RuleSubject = question.companyKey == nil ? .server : .company
        let key = question.companyKey ?? question.address
        let title = question.companyIsHost ? "Hosted on \(question.companyName ?? key)"
            : (question.companyName ?? key)
        switch choice {
        case .block:
            firewall.add(FirewallRule(subject: subject, key: key, title: title, action: .block,
                                      appKey: question.appKey, appTitle: item.appName))
            filter.answer(question.id, .block)
        case .allow:
            firewall.add(FirewallRule(subject: subject, key: key, title: title, action: .allow,
                                      appKey: question.appKey, appTitle: item.appName))
            filter.answer(question.id, .allow)
        case .allowAnywhere:
            firewall.add(FirewallRule(subject: .app, key: question.appKey, title: item.appName, action: .allow))
            filter.answer(question.id, .allow)
        case .allowOnce:
            filter.answer(question.id, .allowOnce)
        }
        remove(question.id)
    }

    private func remove(_ id: String) {
        items.removeAll { $0.id == id }
        if items.isEmpty { panel?.orderOut(nil) }
    }

    // MARK: The panel

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard !panel.isVisible else { return }
        place(panel)
        // Never takes the focus from what the person is doing.
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: AskView(controller: self))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.setContentSize(host.view.fittingSize)
        return panel
    }

    /// Top right, under the menu bar, where a notification would be.
    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - 12))
    }
}

struct AskView: View {
    @ObservedObject var controller: AskController

    var body: some View {
        Group {
            if let item = controller.items.first {
                question(item)
            }
        }
        .padding(16)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func question(_ item: AskController.Item) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                icon(item)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(item.appName) wants to connect to \(item.target)")
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if item.expired {
                Text("Allowed, since there was no answer in 30 seconds. NetworkMonitor asks again in an hour.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    Button("Block") { controller.answer(item, .block) }
                    Spacer(minLength: 8)
                    Button("Allow Once") { controller.answer(item, .allowOnce) }
                        .help("Lets it connect, and asks again in an hour")
                    Menu("Always Allow") {
                        Button("Always Allow \(item.appName) Anywhere") { controller.answer(item, .allowAnywhere) }
                    } primaryAction: {
                        controller.answer(item, .allow)
                    }
                    .fixedSize()
                    .help("Always lets \(item.appName) connect to \(item.target)")
                }
                footer(item)
            }
        }
    }

    /// How long until it goes ahead anyway, and what's waiting.
    private func footer(_ item: AskController.Item) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(item.question.deadline.timeIntervalSince(context.date).rounded(.up)))
            let more = controller.items.count - 1
            Text("Allowed in \(seconds) s if you don't answer" + (more > 0 ? " · \(more) more" : ""))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    private func icon(_ item: AskController.Item) -> some View {
        if let path = item.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 36, height: 36)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 22))
                .frame(width: 36, height: 36)
                .foregroundStyle(.secondary)
        }
    }
}
