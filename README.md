# NetworkMonitor

A macOS menu bar utility showing live network speed and per-app data usage,
bucketed per network and reset at local midnight.

Built against the design in [macOS_Network_Monitor_Spec.md](macOS_Network_Monitor_Spec.md).
Several of that document's technical claims turned out to be wrong when tested on
real hardware; the corrections are recorded below, since each one would have
produced silently incorrect numbers.

```
make test      # 87 tests, no Xcode required
make run       # build the .app and launch it
make install   # install to /Applications
```

Requires macOS 13+. Developed and verified on macOS 26.5.2, Swift 6.3.3, with
Command Line Tools only (no Xcode).

---

## Spec corrections

Each of these was verified on the development machine, not reasoned about.

### 1. `getifaddrs()` byte counters are 32-bit and had already wrapped

The spec called for reading `if_data.ifi_ibytes` via `getifaddrs()`. That field is
`u_int32_t`, so it wraps every 4 GiB. On the development machine:

```
getifaddrs if_data (32-bit):  ibytes = 1,229,071,807
netstat -ibn (64-bit truth):  ibytes = 5,524,039,103
difference                             4,294,967,296   ← exactly 2^32
```

en0 had already rolled over once. Diffing that counter yields a huge negative
delta at each wrap, i.e. a garbage speed spike every 4 GB.

**Fixed** in `InterfaceCounters.swift` by using
`sysctl(CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0)` and reading `if_msghdr2`,
whose `if_data64` payload has 64-bit counters — the same source `netstat` uses.

### 2. `nettop` cumulative totals go *down*, so delta mode is mandatory

The spec described `-d` as "delta mode disabled, use cumulative mode" and
proposed diffing cumulative snapshots. `-d` is in fact *delta mode*, and
cumulative mode is unusable regardless: a process's cumulative total is the sum
over its **currently live sockets**, so it decreases when a socket closes.
Observed on Google Chrome Helper across four consecutive polls:

```
4,529,465 → 4,529,330 → 4,523,833 → 4,518,819
```

Diffing those under-counts every app that opens and closes connections — every
browser, in other words.

**Fixed** in `NettopStream.swift` / `NettopParser.swift`: one long-lived
`nettop -P -x -d -L 0 -s 1` process, whose first sample (cumulative) is discarded
and whose subsequent samples are true per-interval deltas. Verified at exactly
one sample per second.

### 3. Both SSID fallbacks are dead on modern macOS

The spec suggested shelling out to `networksetup` or `system_profiler` to read
the SSID "if you want to avoid the location prompt". While connected to Wi-Fi:

```
$ networksetup -getairportnetwork en0
You are not associated with an AirPort network.     ← withheld, not true
$ system_profiler SPAirPortDataType | grep -i ssid
(redacted)
```

SSID now requires Location authorization, full stop.

**Fixed** in `NetworkIdentity.swift` by not using SSID at all. Network identity
comes from the **default gateway's MAC address**, which needs no permission and
is a strictly better fingerprint:

- it distinguishes two different routers that share an SSID name;
- it is stable across a Wi-Fi roam between access points, where the BSSID changes
  but the gateway does not.

The app therefore never shows a permission prompt.

### 4. Process names are truncated, so they cannot be dictionary keys

The spec proposed `[String: (bytesIn, bytesOut)]` keyed on process name. `nettop`
truncates to the kernel's 15-character `p_comm` limit — "Google Chrome Helper"
arrives as `Google Chrome H`, and several distinct processes share one truncated
name.

**Fixed** in `AppIdentityResolver.swift` by keying on pid, resolving through
`proc_pidpath` to the executable, then folding up to the **outermost** enclosing
`.app`. That last step is what collapses Chrome's dozen helpers into one row.
`proc_pidpath` was verified to work unprivileged on root-owned processes
(`apsd`, `mDNSResponder`, `launchd` all resolve), so no elevation is needed.

### 5. The menu bar title jittered despite monospaced digits

Not a spec error, but a bug found by rendering the title rather than trusting it.
`monospacedDigitSystemFont` fixes the width of *digits only*; letters and spaces
keep proportional advances. The seven realistic rate cases rendered at seven
different widths spanning 97.19–125.67 pt, so the menu bar shifted whenever
traffic crossed a unit boundary (`B/s → KB/s → MB/s`) — which happens constantly.

**Fixed** in `MenuBarTitle.swift` with a fully monospaced font, padding of *both*
the numeric and unit fields, and left alignment (right alignment makes CoreText
discard the trailing pad, reintroducing a one-character shift). All cases now
render at exactly 154.54 pt, asserted by test.

### 6. `nettop` block-buffers stdout, so a pipe delivers nothing

The spec's `Process`/`Pipe` approach silently produces **no data**. nettop only
line-flushes when stdout is a terminal; through a pipe it block-buffers, measured
at zero output over 9 s versus one flush per second through a PTY. The failure is
invisible — the process is running, the parser is correct, no error is raised, and
data eventually arrives in delayed bursts once the 4 KB buffer fills.

It also hides during manual testing, because a short `nettop -L 2` exits and libc
flushes at exit. Only a long-lived stream shows it.

**Fixed** in `NettopStream.swift` by allocating a real pseudo-terminal with
`openpty()` and handing nettop the slave. `-L` still forces CSV logging mode
("even if standard output is a terminal"), so the output stays parseable and now
arrives once per second. Guarded by a live integration test, since no unit test
can catch this.

### 7. `nettop` costs ~1.36 cores just by running

Not a spec error — the spec's only note was "performance overhead of process
spawning", which is not where the cost is. Measured with `/usr/bin/time` on a
finite run:

```
real 9.02   user 2.34   sys 9.92     →  136% of one core
```

Almost entirely *system* time. And it is a fixed cost, not per-sample work:

| configuration | CPU |
|---|---|
| `-s 1` | 136% |
| `-s 5` | 136% |
| `-s 10` | 135% |
| `-p <single pid>` | 82% |
| `-c` ("less intensive") | 136% |

Raising the sample interval tenfold changes nothing, and scoping to one process
instead of all 482 changes nothing. There is no flag configuration that makes
nettop cheap, so **the only lever is how long it runs** — which is why per-app
tracking is now a power-aware setting (see below) rather than always-on.

---

## Design decisions

### Per-app tracking is power-aware

Because `nettop` costs a fixed ~1.36 cores, running it 24/7 would be a serious
battery drain. The two features have very different costs:

| | source | cost | availability |
|---|---|---|---|
| Live speed + day total | `sysctl` interface counters | ~3% of a core | **always** |
| Per-app breakdown | `nettop` | ~136% of a core | per setting |

The authoritative day total does **not** depend on nettop. Verified with nettop
fully suspended: a 20 MB download was recorded at 21,762,048 bytes against a
kernel-measured 21,780,483 — 99.9%. So Feature 1 is always exact and always
cheap.

Per-app tracking is selectable from the right-click menu, under
**Track Per-App Usage**:

- **While Plugged In** *(default)* — full-day per-app totals at a desk; on
  battery, nettop runs only while the popover is open.
- **Always** — full-day per-app totals everywhere, at ~1.36 cores continuously.
- **Only While Open** — lowest energy; per-app rows fill in about a second after
  the popover appears.

This is exposed rather than decided silently because it is a genuine
completeness-versus-battery tradeoff.

### Which interfaces count

VPN traffic counts; AirDrop does not.

`InterfaceCounters.isCountable` requires `IFT_ETHER`, rejects `IFF_LOOPBACK`,
and excludes a name list. Two details matter:

- **Tunnels are excluded** (`utun*`, `ipsec*` are `IFT_OTHER`). This is what makes
  VPN traffic count *exactly once*: the plaintext bytes on `utun` are ignored and
  the encrypted bytes are counted as they leave the physical NIC. Summing both
  would double-count every VPN byte.
- **AWDL must be excluded by name.** `awdl0` reports `ifi_type = IFT_ETHER` and
  flags `0x8863` — byte for byte identical to `en0` — so type and flags cannot
  distinguish AirDrop/Continuity/Sidecar traffic from internet traffic. It had
  148 MB of lifetime traffic on the development machine.

Also excluded: `bridge*` (Internet Sharing), `bond*` (aggregation), `vmenet*`
(VM networking) — each would double-count an underlying NIC.

### Two sampling loops

| Source | Interval | Feeds |
|---|---|---|
| `sysctl` interface counters | 0.5 s | live menu bar rate, authoritative day total |
| `nettop` | 1 s | per-app attribution |

Interface counters are authoritative — that is the number to measure a data cap
against. The per-app numbers will **not** sum to exactly the same value, for two
reasons: some kernel traffic belongs to no process, and a few multi-homed system
sockets have their full byte count billed to every interface type they match
(`nettop -t awdl` reports 150 MB of mDNSResponder's 263 MB, yet
`-t wifi -t wired` still reports 259 MB — AWDL bytes are not separable for such
sockets). Those land in the collapsed System group; real apps use per-interface
sockets and are unaffected.

`nettop` runs with `-t external`, which keeps VPN tunnel traffic and drops
localhost chatter from dev servers.

### Per-network buckets, not reset-on-change

The spec wiped all totals on any network change. Instead each network gets its
own bucket, keyed by gateway MAC:

- dropping off a network and rejoining it **preserves** that network's total;
- switching networks shows the new network's own total;
- switching back **restores** the original rather than restarting at zero.

This also means hotspot usage is independently queryable while on another
network — the foundation for the planned "limit app updates on hotspot" feature.
`NWPath.isExpensive` flags Personal Hotspot and cellular, and the popover shows a
`METERED` badge for those.

`NWPathMonitor` is debounced by 2 s because it fires several times per logical
event (VPN up/down, AWDL flaps, DNS changes), and the fingerprint is then
compared so non-changes are discarded. Traffic recorded during that 2 s window,
before the network is identified, is folded into the network once known rather
than stranded in a placeholder bucket.

### Reset at local midnight

Anchored to `Calendar.startOfDay`, not "86,400 s since the last reset". A rolling
window drifts a little each day and eventually resets at an arbitrary hour; a
calendar day is predictable and matches how ISPs meter. Because timers do not
fire while the machine sleeps, rollover is also checked on
`NSWorkspace.didWakeNotification` and at launch.

### Robustness details worth knowing

- **Counter resets produce zero, not a spike.** Cycling an interface resets its
  kernel counters; a naive diff would underflow the unsigned subtraction into a
  multi-exabyte value. `InterfaceDeltaTracker` re-baselines instead.
- **New interfaces contribute no backlog.** A VPN coming up brings a lifetime
  counter with it; adopting it as a baseline avoids billing that history.
- **pid reuse is handled.** `AppIdentityResolver.retainOnly` evicts pid→path
  entries for departed processes, so a recycled pid cannot inherit the previous
  process's identity.
- **Monotonic clock.** Rates use `CLOCK_MONOTONIC_RAW`, immune to NTP slew, which
  via `Date()` could yield a negative elapsed time.
- **Row order freezes while the popover is open**, so rows do not slide out from
  under the pointer as totals change.
- **Energy.** The sampler uses a `DispatchSourceTimer` with 100 ms leeway so the
  kernel can coalesce wakeups, and relaxes to 2 s while the display sleeps —
  totals keep accumulating, but nobody is reading the menu bar. Measured at 0.77 s
  CPU over 25 s wall (~3% of a core) with nettop suspended.
- **No orphaned subprocess.** Terminating signals bypass
  `applicationWillTerminate`, which left a `nettop` orphan holding ~1.4 cores
  after the app was killed. `SIGTERM`/`SIGINT`/`SIGHUP` are trapped and routed
  through a normal AppKit quit; verified clean after `kill -TERM`.
- **Atomic persistence.** Totals survive relaunch and reboot; a corrupt store
  starts clean rather than blocking launch.

---

## Layout

```
Sources/NetworkMonitorCore/     testable core, no app lifecycle
  ByteFormat.swift              all byte/rate formatting (1024-based)
  MenuBarTitle.swift            status item title + width invariant
  InterfaceCounters.swift       sysctl NET_RT_IFLIST2, 64-bit, classification
  InterfaceDeltaTracker.swift   baseline/delta logic, rate smoothing
  NettopParser.swift            pure CSV parsing + sample framing
  NettopStream.swift            long-lived nettop subprocess
  AppIdentityResolver.swift     pid → bundle → icon, helper collapsing
  NetworkIdentity.swift         gateway-MAC fingerprint, NWPathMonitor
  UsageStore.swift              per-network buckets, rollover, persistence
  MonitorViewModel.swift        wires it together
  MenuBarPopoverView.swift      SwiftUI popover

Sources/NetworkMonitor/         AppKit shell (status item, popover, menu)
Sources/NetworkMonitorTests/    test suite + harness
Scripts/bundle.sh               assembles and signs the .app
```

State lives at `~/Library/Application Support/NetworkMonitor/usage.json`.

## Distribution

`Scripts/bundle.sh` ad-hoc signs by default, which is enough to run locally
(Gatekeeper asks for a right-click → Open on first launch). The bundle layout and
hardened-runtime flag are already notarization-ready; for distribution:

```sh
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./Scripts/bundle.sh --universal        # arm64 + x86_64
xcrun notarytool submit build/NetworkMonitor.app --wait \
      --apple-id … --team-id … --password …
xcrun stapler staple build/NetworkMonitor.app
```

Spawning `/usr/bin/nettop` needs no hardened-runtime exception — it is a separate
signed process, not injected code. The app cannot be sandboxed (and so cannot go
to the Mac App Store) because it spawns subprocesses.

**Launch at Login** uses `SMAppService.mainApp`, which wants a properly signed
bundle in `/Applications`. It may fail while ad-hoc signed; the app reports the
reason rather than failing silently.

## Known limitations

- Per-app numbers do not sum exactly to the interface total (see *Two sampling
  loops*). The headline figure is the authoritative one.
- In the two low-energy tracking modes, per-app totals cover only the periods
  when nettop was running, so they will read lower than the day total. The day
  total itself is always complete.
- The per-app list has ~1 s latency, since a sample is only emitted when the next
  sample's header arrives. The menu bar rate is unaffected.
- AWDL bytes on multi-homed system sockets cannot be separated out, so the
  System group slightly over-reports on machines that use AirDrop heavily.
- Network identity falls back to the interface name where no default gateway is
  reachable (captive portals before sign-in, IPv6-only networks without ARP).
