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
  <a href="docs/README.md">Docs</a> ·
  <a href="https://github.com/kevinabouhanna/NetworkMonitor/wiki">Wiki</a>
</p>

<p align="center">
  <img src="Resources/README/demo.gif" width="404"
       alt="The real app during a download: the menu bar reads about 1.2 MB/s down, and a click opens a list of apps by data used, led by Google Chrome and iTerm2, with iTerm2's own processes beneath it.">
</p>

## ✨ Features

- ⚡ **Live speed** in the menu bar, download and upload, in MB/s or Mbps, in colours you choose.
- 📊 **Which apps used your data** on this connection, biggest first.
- 🌐 **Connections:** which companies, countries and servers each app talks to, on a list and a world map, without looking anything up online. Block any of them, or have it ask.
- 🛡️ **Block ads, trackers and malware** in every app, Chrome included, with one switch.
- 🏠 **Internet only.** AirPlay, Time Machine and other home-network traffic don't count.
- 📱 **Hotspot mode** pauses app updates on a mobile hotspot, and resumes them when you leave.
- 🗓️ **Usage History** by day, week, month or year, per app and per network.
- 🚀 **Speed test** on demand, using the one built into macOS.
- 🔋 **Light on battery:** about 1% of one CPU core, less in Low Power Mode.
- 🔒 **Private:** no telemetry, no account. Its own network access is a monthly download of country and network data, a weekly one of the ad and malware lists while they're on, and a daily update check, all from GitHub, and all can be switched off.

## 📦 Install

For macOS 13 or later, on Apple silicon or Intel.

1. [**Download NetworkMonitor.dmg**](https://github.com/kevinabouhanna/NetworkMonitor/releases/latest/download/NetworkMonitor.dmg), open it, and drag NetworkMonitor into **Applications**.
2. Open NetworkMonitor from Applications.

It's signed with an Apple Developer ID and notarized by Apple, so macOS opens it without a warning. The code is all here to read, or to [build yourself](docs/development.md).

Look for the ↓ ↑ readout in your menu bar. It starts at login from then on.

### 🔄 Update

From 1.15 on, NetworkMonitor offers each new version itself, once a day or when you choose **Check for Updates…** in its menu, and installs it when you say so.

Before that, download the new DMG and drag NetworkMonitor into Applications, choosing **Replace**. Your settings and history are kept. Updating from 1.13 or earlier, macOS asks for Location once more, because the app is now signed with a Developer ID.

### 🗑️ Uninstall

Right-click the menu bar readout and choose **Uninstall NetworkMonitor…** (or **Settings › About › Uninstall…**). It puts back every setting it changed, then moves itself to the Trash.

> [!WARNING]
> Don't just drag it to the Trash: the update settings that Hotspot mode changed without its helper would stay off. If you already did, drag it back, open it, and uninstall from the menu.

## 🖱️ Using it

- **Click** the readout for this connection's total and the apps behind it. The 🌐 there opens Connections.
- **Right-click** it for the speed test, Block Everything, Connections, Usage History, Settings, Check for Updates, Uninstall and Quit.
- **Settings** has a pane each for General, Speed Test, History, Connections, Hotspot and About.

## 📚 Learn more

The [docs](docs/README.md) explain how every feature works, and why. They're also on the [wiki](https://github.com/kevinabouhanna/NetworkMonitor/wiki).

- **Using it:** [installing](docs/installing.md) · [features](docs/features.md) · [Connections](docs/connections.md) · [Usage History](docs/usage-history.md) · [speed test](docs/speed-test.md) · [Hotspot mode](docs/hotspot-mode.md) · [accuracy and battery](docs/accuracy-and-battery.md) · [privacy](docs/privacy.md)
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
