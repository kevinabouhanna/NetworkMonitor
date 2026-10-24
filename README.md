<p align="center">
  <img src="Resources/README/logo.png" alt="" width="128">
</p>

<h1 align="center">NetworkMonitor</h1>

<p align="center">
  <b>Live network speed in your Mac's menu bar, and which apps used your data.</b>
</p>

<p align="center">
  <a href="https://github.com/kevinabouhanna/NetworkMonitor/releases/latest"><img src="https://img.shields.io/github/v/release/kevinabouhanna/NetworkMonitor?color=51FF70&label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-1d1d1f" alt="macOS 13 or later">
  <a href="https://github.com/kevinabouhanna/NetworkMonitor/actions/workflows/ci.yml"><img src="https://github.com/kevinabouhanna/NetworkMonitor/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT licence">
</p>

<p align="center">
  <a href="https://github.com/kevinabouhanna/NetworkMonitor/releases/latest/download/NetworkMonitor.dmg"><b>Download</b></a> ·
  <a href="https://kevinabouhanna.github.io/NetworkMonitor/">Website</a> ·
  <a href="docs/README.md">Docs</a>
</p>

<p align="center">
  <img src="Resources/README/demo.gif" width="404"
       alt="The real app during a download: the menu bar reads about 1.2 MB/s down, and a click opens a list of apps by data used, led by Google Chrome and iTerm2, with iTerm2's own processes beneath it.">
</p>

## ✨ Features

- ⚡ **Live speed** in the menu bar, download and upload, in MB/s or Mbps, in colours you choose.
- 📊 **Which apps used your data** on this connection, biggest first.
- 🏠 **Internet only.** AirPlay, Time Machine and other home-network traffic don't count.
- 📱 **Hotspot mode** pauses app updates on a mobile hotspot, and resumes them when you leave.
- 🗓️ **Usage History** by day, week, month or year, per app and per network.
- 🚀 **Speed test** on demand, using the one built into macOS.
- 🔋 **Light on battery:** about 1% of one CPU core, less in Low Power Mode.
- 🔒 **Private:** no telemetry, no account, no network access of its own.

## 📦 Install

For macOS 13 or later, on Apple silicon or Intel.

1. [**Download NetworkMonitor.dmg**](https://github.com/kevinabouhanna/NetworkMonitor/releases/latest/download/NetworkMonitor.dmg), open it, and drag NetworkMonitor into **Applications**.
2. Open NetworkMonitor. macOS says it can't check it for malicious software. Click **Done**.
3. Open **System Settings › Privacy & Security**, scroll down to **Security**, click **Open Anyway** next to NetworkMonitor, and confirm with your password.

> [!NOTE]
> **Why the extra step?** NetworkMonitor isn't signed with a paid Apple Developer ID yet, so macOS can't confirm who made it. The code is all here to read, or to [build yourself](docs/development.md).

Look for the ↓ ↑ readout in your menu bar. It starts at login from then on.

### 🔄 Update

The app never goes online by itself, so it can't tell you about new versions. To hear about them, click **Watch › Custom › Releases** at the top of this page.

To update, download the new DMG and drag NetworkMonitor into Applications, choosing **Replace**. Your settings and history are kept. macOS checks each new version afresh, so you'll need **Open Anyway** once more (steps 2 and 3 above).

### 🗑️ Uninstall

Right-click the menu bar readout and choose **Uninstall NetworkMonitor…** (or **Settings › About › Uninstall…**). It puts back every setting it changed, then moves itself to the Trash.

> [!WARNING]
> Don't just drag it to the Trash: the update settings that Hotspot mode changed without a password would stay off. If you already did, drag it back, open it, and uninstall from the menu.

## 🖱️ Using it

- **Click** the readout for this connection's total and the apps behind it.
- **Right-click** it for the speed test, Usage History, Settings and Quit.
- **Settings** has a pane each for General, Speed Test, History, Hotspot and About.

## 📚 Learn more

The [docs](docs/README.md) explain how every feature works, and why:

- **Using it:** [installing](docs/installing.md) · [features](docs/features.md) · [Usage History](docs/usage-history.md) · [speed test](docs/speed-test.md) · [Hotspot mode](docs/hotspot-mode.md) · [accuracy and battery](docs/accuracy-and-battery.md) · [privacy](docs/privacy.md)
- **Working on it:** [architecture](docs/architecture.md) · [building and releasing](docs/development.md) · [decisions](docs/decisions.md) · [roadmap](docs/roadmap.md)

## 🤝 Contributing

Issues and pull requests are welcome. Building needs only Apple's Command Line Tools:

```sh
xcode-select --install
make test   # run the test suite
make app    # build build/NetworkMonitor.app
```

See [docs/development.md](docs/development.md) for the rest.

## 📄 License

[MIT](LICENSE)
