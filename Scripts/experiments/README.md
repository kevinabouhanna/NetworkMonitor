# Background URLSession ownership probe

Run on macOS from the repository root with Python 3.9 or newer, the Xcode
Command Line Tools, and an account that can read the system unified log:

```sh
python3 Scripts/experiments/nsurlsessiond-probe.py
```

The probe builds one Swift executable, packages it in two temporary app
bundles with distinct bundle identifiers, and downloads 32 KiB and 64 KiB
from a single HTTP server bound to
`127.0.0.1`. Both transfers pause so `nettop` can take a socket snapshot
while they are active. The probe releases both transfers, verifies their full
payload sizes, then looks up each socket's owner in the local unified log.

Success shows one `nsurlsessiond` PID, two distinct owners, and equal byte
totals before and after assigning the measured snapshot to those owners.
The numbers describe the partial snapshot and include transport overhead.
The log supplies the owner only. The probe fails if it cannot match a socket
to its expected owner using the daemon PID, interface and socket ports.

The temporary bundles are signed ad hoc. The probe uses loopback only and
requires no packet capture, system update, or NetworkMonitor installation.
It checks the close summaries emitted by the current macOS build. Their
format, visibility and coverage may vary by release. A production matcher
would also need to distinguish reused sockets over time and preserve each
sample's original network and history interval.
