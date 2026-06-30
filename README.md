# Ollama Usage Monitor

> A native macOS menu bar app that tracks your **Ollama Cloud** usage limits in real-time — session %, weekly %, per-model request breakdowns, and live connection status.

![macOS](https://img.shields.io/badge/macOS-13%2B-blue?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift)
![Python](https://img.shields.io/badge/Python-3.10%2B-blue?logo=python)
![License](https://img.shields.io/badge/License-MIT-green)

---

## ✨ Features

- **Live Cloud Usage** — Session and weekly usage scraped directly from your Ollama account
- **Per-Model Breakdown** — See exactly how many requests each model consumed this session and week
- **Menu Bar Percentage** — Instantly see remaining or used % right in your macOS menu bar
- **Active Model Tracking** — Menu bar updates to show the currently running model during API calls
- **Display Mode** — Switch between "Remaining" and "Used" views globally — updates both menu bar and modal labels
- **Auto Cookie Sync** — Automatically extracts your Ollama session from Google Chrome (no manual login needed)
- **Online / Offline Status** — Green indicator when connected and syncing; shows "Offline" with a red dot when the daemon is not reachable
- **Custom SVG Icon** — Uses your own `icon.svg` as a native macOS template icon (adapts to light/dark mode)

---

## 📸 Preview

| Menu Bar | Dropdown Modal |
|---|---|
| `30%` next to the Ollama icon in menu bar | Session + Weekly progress bars with per-model request list |

---

## 🚀 Quick Start

### Prerequisites

- macOS 13 or later
- Xcode Command Line Tools: `xcode-select --install`
- Python 3.10+
- Google Chrome (for auto cookie sync)
- An active [Ollama Cloud](https://ollama.com) account

### Installation

```bash
git clone https://github.com/kendrick-gs/ollama-usage-monitor.git
cd ollama-usage-monitor
./build.sh
```

That's it. The app will compile, launch, and appear in your menu bar instantly.

---

## ⚙️ How It Works

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  macOS Menu Bar                          │
│  [Ollama Icon] [30%]  ←── SwiftUI Status Bar App        │
└──────────────────────────────┬──────────────────────────┘
                               │ reads from
                               ▼
                    ┌──────────────────────┐
                    │   SQLite Database     │
                    │   (ollama_metrics.db) │
                    └──────────┬───────────┘
                               │ written by
                               ▼
                    ┌──────────────────────┐
                    │  Python Daemon        │
                    │  (ollama_monitor.py)  │
                    │                       │
                    │  • Scrapes ollama.com │
                    │  • Proxies API calls  │
                    │  • Tracks active model│
                    └──────────────────────┘
```

### Python Daemon (`ollama_monitor.py`)
- Runs as a background process launched by the Swift app
- Scrapes `https://ollama.com/settings` every 60 seconds using your Chrome session cookie
- Parses session %, weekly %, reset times, and per-model request counts from the HTML
- Stores all data in a local SQLite database
- Hosts a local proxy at `http://localhost:8080/ollama/` to intercept API calls and track the currently active model

### Swift App (`OllamaMenuBar.swift`)
- Native macOS status bar application (zero Electron, zero web views)
- Reads from the SQLite database every 1.5 seconds
- Updates the menu bar title and icon in real-time
- Renders a SwiftUI popover with progress bars, model lists, and settings

---

## 🔌 Proxy Setup (Optional)

To track which model is actively being used, route your Ollama client through the built-in proxy:

| Setting | Value |
|---|---|
| **Ollama Endpoint** | `http://localhost:8080/ollama` |
| **Direct Ollama** | `http://localhost:11434` |

In VSCode / Cursor / Continue settings:

```json
{
  "ollama.url": "http://localhost:8080/ollama"
}
```

This is **optional** — cloud usage scraping works independently of the proxy.

---

## 🍎 Menu Bar Status

| State | Display |
|---|---|
| Connected + idle | `30%` (remaining) or `70%` (used) next to icon |
| Active API call | `● ds-acade` (model name) |
| Disconnected | `Offline` |

---

## ⚙️ Settings Panel

Open the dropdown and click **Settings**:

| Setting | Description |
|---|---|
| **Display Mode** | Switch between "Remaining" and "Used" — affects both modal labels and menu bar |
| **Show % in Menu Bar** | Toggle whether the percentage appears next to the icon in the menu bar |
| **Auto-Detect from Chrome** | Automatically syncs your Ollama session cookie from Chrome |
| **Status indicator** | Shows "Connected" or "Not Connected" for your cloud sync |

---

## 📦 Project Structure

```
ollama-usage-monitor/
├── OllamaMenuBar.swift     # Native Swift macOS status bar app
├── ollama_monitor.py       # Python background daemon (scraper + proxy)
├── build.sh                # Single-command build & launch script
├── icon.svg                # Custom menu bar icon (SVG template)
├── CHANGELOG.md            # Version history
└── README.md               # This file
```

---

## 🛡️ Privacy

- **No data is sent anywhere.** All scraping is done locally using your own Chrome cookie.
- The daemon only connects to `ollama.com` (to read your own usage dashboard) and `localhost:11434` (your local Ollama instance).
- The SQLite database is stored locally at `ollama_metrics.db`.

---

## 🗓️ Changelog

See [CHANGELOG.md](CHANGELOG.md) for full version history.

---

## 🤝 Contributing

Pull requests are welcome. For major changes, please open an issue first.

1. Fork the repository
2. Create your feature branch: `git checkout -b feature/my-feature`
3. Commit your changes: `git commit -m 'Add my feature'`
4. Push to the branch: `git push origin feature/my-feature`
5. Open a pull request

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.
