# Purgeable

A tiny, native macOS menu bar utility that tracks disk and RAM usage and clears safe, regenerable caches with one click — no Electron, no bundled runtime, just Objective-C++ and Cocoa.

|  |  |
|---|---|
| Binary size | ~115 KB |
| RAM while running | ~33 MB |
| Dependencies | None (system frameworks only) |

## Why

Most "Mac cleaner" apps are either Electron-based (100-300 MB RAM just to show a menu) or paid/subscription products (CleanMyMac, etc.) that do far more than you asked for. Purgeable does one thing — show you what's safe to clear and let you clear it — using nothing but native AppKit.

## Features

- **Disk usage bar** — color-coded (green/orange/red), shows used/free/total for your data volume
- **RAM usage bar** — same style, refreshes live every 2 seconds while the popup is open
- **Low disk space alert** — the menu bar icon turns red and you get a system notification when free space drops under 15 GB
- **Six safe-to-clear locations**, sorted largest-first, each with its own **Clear** button or one **Clear All**:
  - App & System Caches (`~/Library/Caches`)
  - Xcode DerivedData
  - iOS Simulator Caches
  - npm Cache (`~/.npm`)
  - Trash
  - Chrome Browser Cache — *only* the safe subfolders (GPU/shader caches, Service Worker cache) across every Chrome profile, never history/cookies/passwords/bookmarks
- **Biggest Items** — a read-only list of the largest folders in `Desktop`, `Downloads`, `Documents`, and common dev folders, each with a **Show** button that reveals it in Finder. These are real project/user data, so they're surfaced for manual review rather than deleted automatically.

## What "safe" means here

Every one-click location is a cache or trash folder that the owning app or tool fully regenerates on its own — clearing it never touches your files, settings, logins, or history. Nothing in the "Biggest Items" list is ever deleted automatically; it's there so new disk hogs don't sneak up on you.

## Build & install

Requires Xcode Command Line Tools (`xcode-select --install`) — no Xcode project needed.

```bash
git clone https://github.com/sahad752/purgeable.git
cd purgeable
./build.sh
```

`build.sh` compiles the app, installs it to `/Applications/Purgeable.app`, ad-hoc code-signs it, and (re)launches it. To have it start automatically every login, add it via **System Settings → General → Login Items**.

## Project layout

| File | Purpose |
|---|---|
| `main.mm` | UI — status bar item, popover, all view/layout code |
| `scanner.hpp` | Core logic — directory sizing, safe clearing, disk/RAM stats (pure C++, no Cocoa) |
| `Info.plist` | App bundle metadata |
| `build.sh` | One-command build + install |
| `generate_icon.mm` | Standalone tool that generated `AppIcon.icns` |

## Requirements

macOS 11.0 (Big Sur) or later.

## License

MIT — see [LICENSE](LICENSE).
