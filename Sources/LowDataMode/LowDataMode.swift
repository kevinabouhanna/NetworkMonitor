import Foundation

/// Low Data Mode, as the network stack holds it: two flags on an interface.
///
/// System Settings keeps the user's Low Data Mode choice in two different
/// places — per Wi-Fi network in the root-only
/// `com.apple.wifi.known-networks.plist`, per wired service under
/// `/Sets/<set>/Network/Interface/<bsd>/EnableLowDataMode` in
/// `SystemConfiguration/preferences.plist` — but what the stack acts on is the
/// interface's `CONSTRAINED` flag. That flag is what `NWPath.isConstrained`
/// reports and what `allowsConstrainedNetworkAccess = false` is enforced
/// against. `EXPENSIVE` is its sibling: the flag macOS raises on its own for an
/// iPhone hotspot it recognises, and the one `allowsExpensiveNetworkAccess`
/// honours.
///
/// The helper sets the flags directly, with `/sbin/ifconfig <bsd> constrained`
/// and `expensive`, rather than writing either preference file:
///
/// - **One mechanism for every link.** Wi-Fi, a USB-tethered iPhone and an
///   Android phone's RNDIS interface are all `enN` on a Mac, and all take the
///   same flag. The preference route needs one writer per storage location, and
///   the Wi-Fi one is undocumented and owned by another daemon.
/// - **Transient.** Nothing is written to disk. A reboot clears it, and so does
///   unplugging a USB tether. The failure this feature fears most — a setting
///   left behind by an app that is gone — cannot outlive the next restart.
/// - **The user's own choices are untouched.** Their per-network Low Data Mode
///   settings stay exactly where System Settings keeps them.
///
/// Pure Foundation, and a target of its own for the same reason as `HostsFile`:
/// the root helper and the app have to agree exactly on how these flags are read
/// and on the line the helper reports, and the test suite holds both to it.
public enum LowDataMode {

    /// The two flags, as read from one interface.
    public struct Flags: Equatable {
        public var constrained: Bool
        public var expensive: Bool

        public init(constrained: Bool = false, expensive: Bool = false) {
            self.constrained = constrained
            self.expensive = expensive
        }

        /// What a connection held in Low Data Mode looks like.
        public static let both = Flags(constrained: true, expensive: true)
    }

    // MARK: Interfaces

    /// Whether a BSD name is one this feature may act on.
    ///
    /// `enN` only. Wi-Fi, Ethernet and USB tethering all appear under that
    /// prefix on a Mac; tunnels (`utun`), AWDL (`awdl`), bridges and loopback do
    /// not, and constraining any of those would either do nothing or constrain
    /// something the user is not paying for. This is also the helper's input
    /// validation: a name that fails it never reaches `ifconfig`.
    public static func isPhysicalInterface(_ name: String) -> Bool {
        guard name.hasPrefix("en") else { return false }
        let digits = name.dropFirst(2)
        return (1...3).contains(digits.count)
            && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The physical interface carrying traffic, from `scutil --nwi`.
    ///
    /// Its last line lists the interfaces in the order macOS prefers them —
    /// `Network interfaces: utun4 en0` — and the first physical one is the link
    /// the bytes actually cross. A VPN's tunnel is skipped for the same reason
    /// `NetworkIdentityWatcher` skips it: it is not the network you are *on*.
    public static func primaryInterface(fromNWI output: String) -> String? {
        let prefix = "Network interfaces:"
        for line in output.split(separator: "\n") where line.hasPrefix(prefix) {
            return line.dropFirst(prefix.count)
                .split(separator: " ")
                .map(String.init)
                .first(where: isPhysicalInterface)
        }
        return nil
    }

    /// The two flags, from `ifconfig -v <bsd>`.
    ///
    /// `EXPENSIVE` is printed among the `eflags` and `CONSTRAINED` among the
    /// `xflags`, as comma-separated names between angle brackets — on this
    /// machine's `en0`, unconstrained, `xflags=4000000<INBAND_WAKE_PKT>`. Both
    /// names are in `/sbin/ifconfig`'s own flag tables, beside
    /// `ULTRA_CONSTRAINED` and `LOWPOWER`.
    ///
    /// Names are matched whole, because `ULTRA_CONSTRAINED` is a different flag
    /// and a substring test would read it as this one.
    ///
    /// Nil when the output describes no interface at all — `ifconfig` on a
    /// tether that has just been unplugged — so "the interface is gone" is never
    /// mistaken for "the interface has no flags set".
    public static func flags(fromIfconfig output: String) -> Flags? {
        var describesInterface = false
        var names = Set<Substring>()
        for line in output.split(separator: "\n") {
            if let first = line.first, first != "\t", first != " ",
               line.contains(": flags=") {
                describesInterface = true
                continue
            }
            let trimmed = line.drop { $0 == "\t" || $0 == " " }
            guard trimmed.hasPrefix("eflags=") || trimmed.hasPrefix("xflags="),
                  let open = trimmed.firstIndex(of: "<"),
                  let close = trimmed.lastIndex(of: ">"),
                  open < close
            else { continue }
            names.formUnion(trimmed[trimmed.index(after: open)..<close].split(separator: ","))
        }
        guard describesInterface else { return nil }
        return Flags(constrained: names.contains("CONSTRAINED"),
                     expensive: names.contains("EXPENSIVE"))
    }

    /// Whether System Settings has this wired interface in Low Data Mode, in
    /// the location set currently in force.
    ///
    /// Read from `SystemConfiguration/preferences.plist`, where the setting is
    /// `/Sets/<set>/Network/Interface/<bsd>/EnableLowDataMode = 1`. Only the
    /// *current* set counts: on the development machine the flag for `en5`
    /// (iPhone USB) sits in the "Automatic" set while "Home" is the one in use,
    /// and reading it from there would claim a preference that is not in force.
    public static func isConfigured(interface: String,
                                    inPreferences plist: [String: Any]) -> Bool {
        guard let current = plist["CurrentSet"] as? String,
              current.hasPrefix("/Sets/"),
              let sets = plist["Sets"] as? [String: Any],
              let set = sets[String(current.dropFirst("/Sets/".count))] as? [String: Any],
              let network = set["Network"] as? [String: Any],
              let interfaces = network["Interface"] as? [String: Any],
              let entry = interfaces[interface] as? [String: Any],
              let value = entry["EnableLowDataMode"] as? NSNumber
        else { return false }
        return value.boolValue
    }

    // MARK: What the helper holds

    /// Which interface the helper constrained, and which of the two flags it
    /// raised itself.
    ///
    /// A flag that was already up when the helper arrived is not its own and is
    /// never lowered by it. macOS raises `EXPENSIVE` on a recognised iPhone
    /// hotspot unprompted, and a user may have put a network in Low Data Mode
    /// deliberately; taking either down on the way out would undo a decision
    /// that was not ours.
    public struct Hold: Codable, Equatable {
        public var interface: String
        public var setConstrained: Bool
        public var setExpensive: Bool

        public init(interface: String, setConstrained: Bool, setExpensive: Bool) {
            self.interface = interface
            self.setConstrained = setConstrained
            self.setExpensive = setExpensive
        }

        /// The flags this hold owns, for taking them back out of what the
        /// app's own heuristic sees.
        public var owned: Flags {
            Flags(constrained: setConstrained, expensive: setExpensive)
        }
    }

    /// What `constrain` and `unconstrain` print, and `status` embeds: a single
    /// line the app can parse without trusting anything else on stdout.
    ///
    ///     holding en0 constrained expensive
    ///     holding en5 constrained
    ///     holding nothing
    public enum Report: Equatable {
        case holding(Hold)
        case nothing

        static let keyword = "holding"

        public var line: String {
            switch self {
            case .nothing:
                return "\(Self.keyword) nothing"
            case .holding(let hold):
                var words = [Self.keyword, hold.interface]
                if hold.setConstrained { words.append("constrained") }
                if hold.setExpensive { words.append("expensive") }
                return words.joined(separator: " ")
            }
        }

        /// The last report line in `output`, or nil if there is none or it is
        /// malformed. Strict on purpose: a line that names an interface which
        /// fails `isPhysicalInterface`, or an unknown flag, is rejected rather
        /// than half-understood.
        public init?(output: String) {
            guard let line = output.split(separator: "\n")
                .last(where: { $0.hasPrefix(Self.keyword + " ") })
            else { return nil }
            let words = line.split(separator: " ").map(String.init)
            guard words.count >= 2 else { return nil }
            if words.count == 2, words[1] == "nothing" {
                self = .nothing
                return
            }
            guard isPhysicalInterface(words[1]) else { return nil }
            let flags = Set(words.dropFirst(2))
            guard !flags.isEmpty,
                  flags.isSubset(of: ["constrained", "expensive"]),
                  flags.count == words.count - 2
            else { return nil }
            self = .holding(Hold(interface: words[1],
                                 setConstrained: flags.contains("constrained"),
                                 setExpensive: flags.contains("expensive")))
        }
    }
}
