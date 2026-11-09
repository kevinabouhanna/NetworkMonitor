import Combine
import Darwin
import FilterProtocol
import Foundation
import NetworkExtension
import os

/// Encrypt lookups (#291), the app's side: the DNS proxy's configuration,
/// which the system extension that carries the content filter carries too,
/// switched on and off from Settings › Connections; and a check, each time
/// it's switched on or the app starts with it on, that names still resolve.
/// If they don't, it switches itself off again and says why.
public final class EncryptedLookups: ObservableObject {

    public enum State: Equatable {
        case off
        /// Saving the configuration, which macOS asks about the first time.
        case starting
        /// Switched on, and being checked.
        case checking
        case on
        /// Why it isn't on, in the person's terms.
        case failed(String)
    }

    @Published public private(set) var state: State = .off
    /// The resolver, by `EncryptedDNS.Resolver` id. Sent to the extension in
    /// the policy.
    @Published public var resolverID: String {
        didSet { defaults.set(resolverID, forKey: Self.resolverKey) }
    }

    public static let resolverKey = "lookupResolver"
    static let log = Logger(subsystem: "com.kevinabouhanna.NetworkMonitor", category: "lookups")

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        resolverID = EncryptedDNS.resolver(defaults.string(forKey: Self.resolverKey)).id
    }

    public var resolver: EncryptedDNS.Resolver { EncryptedDNS.resolver(resolverID) }

    public var isOn: Bool { state == .on || state == .checking || state == .starting }

    /// At launch: whether it was left on, and if so, that names resolve.
    public func resume() {
        guard FilterController.isBundled else { return }
        let manager = NEDNSProxyManager.shared()
        manager.loadFromPreferences { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, manager.isEnabled else { return }
                self.state = .checking
                self.check()
            }
        }
    }

    public func setOn(_ on: Bool) {
        on ? turnOn() : turnOff(reason: nil)
    }

    private func turnOn() {
        guard FilterController.isBundled else { return }
        state = .starting
        let manager = NEDNSProxyManager.shared()
        manager.loadFromPreferences { [weak self] _ in
            let proxy = NEDNSProxyProviderProtocol()
            proxy.providerBundleIdentifier = FilterIdentity.extensionIdentifier
            proxy.serverAddress = "DNS over HTTPS"
            manager.providerProtocol = proxy
            manager.localizedDescription = "NetworkMonitor"
            manager.isEnabled = true
            manager.saveToPreferences { error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        Self.log.error("switching encrypted lookups on failed: \(error.localizedDescription, privacy: .public)")
                        self.state = Self.isRefusal(error) ? .off : .failed(Self.describe(error))
                        return
                    }
                    Self.log.notice("encrypted lookups on, to \(self.resolver.title, privacy: .public)")
                    self.state = .checking
                    self.check()
                }
            }
        }
    }

    private func turnOff(reason: String?) {
        let manager = NEDNSProxyManager.shared()
        manager.loadFromPreferences { [weak self] _ in
            manager.isEnabled = false
            manager.saveToPreferences { error in
                DispatchQueue.main.async {
                    if let error {
                        Self.log.error("switching encrypted lookups off failed: \(error.localizedDescription, privacy: .public)")
                    }
                    self?.state = reason.map(State.failed) ?? .off
                }
            }
        }
    }

    // MARK: Checking names still resolve

    /// A few tries over 15 seconds: a name looked up, and either an answer or
    /// "no such name" counts. If none comes while the router answers, the
    /// lookups are broken by this, and it's switched off again.
    private func check(attempt: Int = 1) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let resolves = Self.namesResolve()
            DispatchQueue.main.async {
                guard let self, self.state == .checking else { return }
                if resolves {
                    Self.log.notice("names resolve with encrypted lookups on")
                    self.state = .on
                } else if attempt < 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.check(attempt: attempt + 1) }
                } else {
                    UpdateGuard.routerAnswers { router in
                        DispatchQueue.main.async {
                            guard self.state == .checking else { return }
                            if router == true {
                                Self.log.error("names stopped resolving with encrypted lookups on; switching them off")
                                self.turnOff(reason: L("Names stopped resolving with it on, so it's off again."))
                            } else {
                                // No network to tell by: leave it, and look again later.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.check(attempt: 1) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// A name that exists nowhere, so no cache has it: "no such name" is an
    /// answer, which only working lookups give.
    static func namesResolve(timeout: TimeInterval = 6) -> Bool {
        let name = "nm-check-\(UUID().uuidString.prefix(8).lowercased()).apple.com"
        let done = DispatchSemaphore(value: 0)
        var result: Int32 = EAI_AGAIN
        let lock = NSLock()
        DispatchQueue.global().async {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var info: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(name, "443", &hints, &info)
            if let info { freeaddrinfo(info) }
            lock.lock()
            result = status
            lock.unlock()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return false }
        lock.lock()
        defer { lock.unlock() }
        return result == 0 || result == EAI_NONAME
    }

    // MARK: Errors

    private static func isRefusal(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NEDNSProxyErrorDomain && error.code == NEDNSProxyManagerError.configurationDisabled.rawValue
            || error.domain == "NEConfigurationErrorDomain" && error.code == 10
    }

    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        if error.domain == NEDNSProxyErrorDomain, error.code == NEDNSProxyManagerError.configurationCannotBeRemoved.rawValue {
            return L("Another app's DNS settings are in charge. Switch them off to use this.")
        }
        return error.localizedDescription
    }
}
