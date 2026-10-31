import AppKit
import Combine
import FilterProtocol
import FirewallPolicy
import SwiftUI

/// Ask Me (#129): the filter holds an app's first connections to a company,
/// or to a site on a host's network, and this asks about them in a small
/// panel at the top right, never a modal alert. One question at a time; the
/// rest wait their turn. Unanswered in 30 seconds, the filter lets them go,
/// and the panel says so.
///
/// Since #199 it names the site, from the connection's handshake when the app
/// gave none, and the answer can be narrower: this site or the whole company,
/// and once, until the app quits, or always.
public final class AskController: ObservableObject {

    /// What an answer covers.
    public enum Scope: Equatable {
        /// The site and every name under it, such as `segment.io`.
        case site(String)
        case company(key: String, name: String, isHost: Bool)
        /// An address nobody owns.
        case server(String)

        public var label: String {
            switch self {
            case .site(let site):                  return site
            case .company(_, let name, let isHost): return isHost ? "All of \(name)'s network" : "All of \(name)"
            case .server(let address):             return address
            }
        }
    }

    /// How long an Allow lasts.
    public enum Lifetime: Equatable, CaseIterable {
        case once, untilQuit, always
    }

    public struct Item: Identifiable, Equatable {
        public let question: FlowQuestion
        public let appName: String
        public let bundlePath: String?
        /// Where to, as the question reads it: the site, or failing that the
        /// company or address.
        public let target: String
        /// What else is known: whose it is, the country, the port.
        public let detail: String
        /// Narrowest first.
        public let scopes: [Scope]
        /// An app that can quit, so "until it quits" means something.
        public let canLastUntilQuit: Bool
        public var expired = false

        public var id: String { question.id }
    }

    public enum Choice {
        case block, allow
        /// The app, wherever it connects.
        case allowAnywhere
    }

    @Published public private(set) var items: [Item] = []
    /// The front question's choices, set afresh for each question.
    @Published public var scopeIndex = 0
    @Published public var lifetime: Lifetime = .always

    private let filter: FilterController
    private let firewall: FirewallRules
    private var panel: NSPanel?
    private var subscriptions: Set<AnyCancellable> = []

    public init(filter: FilterController, firewall: FirewallRules, workspace: NSWorkspace = .shared) {
        self.filter = filter
        self.firewall = firewall
        filter.questions.sink { [weak self] in self?.add($0) }.store(in: &subscriptions)
        filter.expiredQuestions.sink { [weak self] in self?.expire($0) }.store(in: &subscriptions)
        // Answers "until it quits" (#199): gone when the app quits, and at
        // launch for apps that quit while NetworkMonitor wasn't running.
        firewall.pruneUntilQuit(running: Set(workspace.runningApplications.compactMap { $0.bundleURL?.path }))
        workspace.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path }
            .sink { [weak firewall] path in firewall?.removeRules(untilQuitOf: path) }
            .store(in: &subscriptions)
    }

    public static func item(for question: FlowQuestion) -> Item {
        let app = AppIdentityResolver.identity(forKey: question.appKey)
        // A program started by an app says whose it is: "node" alone could be
        // anyone's.
        let name = app.parent.map { "\($0.displayName)'s \(app.displayName)" } ?? app.displayName
        return item(for: question, appName: name, bundlePath: app.bundlePath ?? app.parent?.bundlePath)
    }

    /// The wording and the choices, from the question alone.
    public static func item(for question: FlowQuestion, appName: String, bundlePath: String?) -> Item {
        let country = question.country.map { ConnectionsReport.countryName($0) }
        let target: String
        var detail: [String] = []
        switch (question.companyName, question.companyIsHost) {
        case (let name?, false):
            target = question.hostname ?? name
            if question.hostname != nil { detail.append(name) } else { detail.append(question.address) }
        case (let name?, true):
            // A host's name says whose computers, not whose service.
            target = question.hostname ?? "a server on \(name)'s network"
            detail.append(question.hostname == nil ? question.address : "on \(name)'s network")
        case (nil, _):
            target = question.hostname ?? question.address
        }
        if let country { detail.append(country) }
        if let port = question.port { detail.append("port \(port)") }

        var scopes: [Scope] = []
        if let hostname = question.hostname, let site = SiteName.normalized(hostname).map(SiteName.site(of:)) {
            scopes.append(.site(site))
        }
        if let key = question.companyKey, let company = question.companyName, !question.companyIsHost {
            scopes.append(.company(key: key, name: company, isHost: false))
        }
        if scopes.isEmpty {
            if let key = question.companyKey, let company = question.companyName {
                scopes.append(.company(key: key, name: company, isHost: true))
            } else {
                scopes.append(.server(question.address))
            }
        }
        return Item(question: question, appName: appName, bundlePath: bundlePath, target: target,
                    detail: detail.joined(separator: " · "), scopes: scopes,
                    canLastUntilQuit: question.appKey.hasSuffix(".app"))
    }

    /// The rule an answer makes, or nil for Allow Once, which makes none.
    public static func rule(for item: Item, _ choice: Choice, scope: Scope, lifetime: Lifetime) -> FirewallRule? {
        let question = item.question
        switch choice {
        case .allowAnywhere:
            return FirewallRule(subject: .app, key: question.appKey, title: item.appName, action: .allow)
        case .allow where lifetime == .once:
            return nil
        case .block, .allow:
            let action: RuleAction = choice == .block ? .block : .allow
            let untilQuit = choice == .allow && lifetime == .untilQuit && item.canLastUntilQuit
            let (subject, key, title): (RuleSubject, String, String)
            switch scope {
            case .site(let site):
                (subject, key, title) = (.site, site, "*.\(site)")
            case .company(let companyKey, let name, let isHost):
                (subject, key, title) = (.company, companyKey, isHost ? "Hosted on \(name)" : name)
            case .server(let address):
                (subject, key, title) = (.server, address, address)
            }
            return FirewallRule(subject: subject, key: key, title: title, action: action,
                                appKey: question.appKey, appTitle: item.appName, untilQuit: untilQuit)
        }
    }

    private func add(_ question: FlowQuestion) {
        guard !items.contains(where: { $0.id == question.id }) else { return }
        items.append(Self.item(for: question))
        if items.count == 1 { resetChoices() }
        show()
    }

    /// Each question starts narrowest, and allowed for good, as before #199.
    private func resetChoices() {
        scopeIndex = 0
        lifetime = .always
    }

    private func expire(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].expired = true
        // Long enough to read that it went ahead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.remove(id) }
    }

    public func answer(_ item: Item, _ choice: Choice) {
        let scope = item.scopes[min(max(scopeIndex, 0), item.scopes.count - 1)]
        if let rule = Self.rule(for: item, choice, scope: scope, lifetime: lifetime) { firewall.add(rule) }
        let answer: FlowAnswer
        switch choice {
        case .block:                         answer = .block
        case .allow where lifetime == .once: answer = .allowOnce
        case .allow, .allowAnywhere:         answer = .allow
        }
        filter.answer(item.question.id, answer)
        remove(item.question.id)
    }

    private func remove(_ id: String) {
        let wasFront = items.first?.id == id
        items.removeAll { $0.id == id }
        if wasFront { resetChoices() }
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
                choices(item)
                HStack(spacing: 8) {
                    Button("Block") { controller.answer(item, .block) }
                        .help("Blocks it from now on, for \(item.appName)")
                    Spacer(minLength: 8)
                    Menu("Allow") {
                        Button("Always Allow \(item.appName) Anywhere") { controller.answer(item, .allowAnywhere) }
                    } primaryAction: {
                        controller.answer(item, .allow)
                    }
                    .fixedSize()
                    .keyboardShortcut(.defaultAction)
                }
                footer(item)
            }
        }
    }

    /// What the answer covers, and for how long an Allow lasts (#199).
    @ViewBuilder
    private func choices(_ item: AskController.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.scopes.count > 1 {
                HStack(spacing: 8) {
                    Text("For").foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                    Picker("For", selection: $controller.scopeIndex) {
                        ForEach(item.scopes.indices, id: \.self) { Text(item.scopes[$0].label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            HStack(spacing: 8) {
                Text("Allow").foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                Picker("Allow", selection: $controller.lifetime) {
                    Text("Once").tag(AskController.Lifetime.once)
                    if item.canLastUntilQuit {
                        Text("Until It Quits").tag(AskController.Lifetime.untilQuit)
                    }
                    Text("Always").tag(AskController.Lifetime.always)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Once lets it connect and asks again in an hour")
            }
        }
        .font(.system(size: 12))
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
