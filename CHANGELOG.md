# Changelog

All notable changes to **Ollama Usage Monitor** are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [1.0.0] — 2026-07-01

### Added
- **Native macOS menu bar app** written in SwiftUI — zero dependencies, zero Electron
- **Cloud usage scraping** — automatically reads session %, weekly %, and reset times from `ollama.com/settings`
- **Per-model request breakdown** — shows how many requests each model consumed in the current session and week
- **Auto cookie sync** — extracts the Ollama session cookie from Google Chrome automatically (no manual copy-paste)
- **Display Mode toggle** — switch between "Remaining" and "Used" views; updates both the menu bar percentage and all modal labels
- **Menu bar percentage** — shows remaining or used % directly next to the icon in the macOS status bar
- **Active model tracking** — detects the currently running model via a local proxy and shows it in the menu bar
- **Online / Offline status** — green "Ollama: Online" header when connected; red "Offline" dot when the daemon is unreachable
- **Custom SVG icon** — uses `icon.svg` as a native macOS template icon (renders white on Dark Mode, black on Light Mode)
- **Settings panel** — in-popover settings drawer with Display Mode picker, menu bar % toggle, and cloud sync controls
- **Local SQLite storage** — all data stored locally at `ollama_metrics.db`; no cloud sync, no telemetry
- **Background Python daemon** (`ollama_monitor.py`) — Flask proxy server + 60-second cloud scraper loop
- **Single-command build** (`./build.sh`) — compiles Swift, kills old instances, and relaunches in one step
