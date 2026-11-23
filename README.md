<div align="center">

<img src="assets/icon.png" alt="SimInstall icon" width="128" height="128">

# SimInstall

**Install iOS Simulator builds in one click.**

A small native macOS app for installing `.app` bundles and EAS / Expo `.tar.gz` builds on any iOS Simulator.

[![Latest release](https://img.shields.io/github/v/release/pera14/siminstall?label=release)](https://github.com/pera14/siminstall/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue?logo=apple)
![Universal](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-lightgrey)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[Download](https://github.com/pera14/siminstall/releases/latest) · [Features](#features) · [Usage](#usage) · [Build from source](#building-from-source)

</div>

<!-- Screenshot: add assets/screenshot.png and uncomment
<p align="center"><img src="assets/screenshot.png" alt="SimInstall main window" width="720"></p>
-->

## Why SimInstall

Xcode 27's Device Hub no longer accepts drag-and-drop installs, so installing a build from CI or EAS now takes a trip to the terminal and `xcrun simctl`. SimInstall puts that back into a native app: it finds your builds, picks a simulator, boots the simulator if needed, installs the build and launches it.

## Features

- **Auto-discovery**: lists simulator builds in `~/Downloads`, newest first. Add any other folders from the folder menu, with <kbd>⌘</kbd><kbd>O</kbd>, or by dropping a folder onto the window.
- **EAS / Expo archives**: `.tar.gz` and `.tgz` builds are extracted automatically.
- **See what's inside**: each build shows its app name, icon, bundle ID and version, so you can tell `application-3b6e….tar.gz` builds apart without extracting them. Archives that hold no simulator app, and device-only builds, are flagged.
- **Simulator picker**: choose any available iOS simulator, with booted devices listed first. Shut-down simulators are booted for you.
- **Several ways to install**: double-click a build, press <kbd>Return</kbd>, drag files onto the window, or drop them on the Dock icon.
- **Launch after install**: optionally opens the app as soon as it is installed.
- **Native and lightweight**: one SwiftUI source file, a universal binary (Apple silicon and Intel), and no third-party dependencies.

## Requirements

- macOS 14 Sonoma or later
- Xcode with at least one iOS Simulator runtime installed (SimInstall uses `xcrun simctl`)

## Installation

1. Download the latest `SimInstall-x.y.z.dmg` from [Releases](https://github.com/pera14/siminstall/releases/latest).
2. Open the DMG and drag **SimInstall** into **Applications**.

> [!NOTE]
> If a release isn't notarized, macOS Gatekeeper blocks the first launch. Right-click the app and choose **Open**, or remove the quarantine flag:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/SimInstall.app
> ```

## Usage

1. Download a simulator build, for example from an EAS build profile that sets `"ios": { "simulator": true }`.
2. Open **SimInstall**. Builds in `~/Downloads` show up automatically. To scan other folders, use the folder button next to the simulator picker. Use the refresh button to rescan.
3. Pick a target simulator.
4. Double-click the build or press <kbd>Return</kbd>. To install a build stored somewhere else, drop it onto the window or the Dock icon.

### Supported inputs

| Input | Notes |
| --- | --- |
| `.app` | iOS Simulator app bundle. macOS apps are ignored. |
| `.tar.gz` / `.tgz` | EAS / Expo simulator archive containing a `.app`. |

### How it works

Under the hood, SimInstall runs the same steps you would run by hand:

1. Extracts archives to a temporary directory and locates the `.app`.
2. Boots the selected simulator if needed (`simctl boot` and `simctl bootstatus`).
3. Installs the app with `simctl install`.
4. If **Launch after install** is enabled, launches the app by its bundle identifier with `simctl launch`.

## Building from source

**Prerequisites:** Xcode Command Line Tools. For the styled DMG window you also need [`create-dmg`](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`). Without it, the script falls back to a plain DMG.

```bash
scripts/build-app.sh 1.0.0   # → build/SimInstall.app (universal, ad-hoc signed)
scripts/make-dmg.sh 1.0.0    # → build/SimInstall-1.0.0.dmg
```

Optional environment variables:

| Variable | Purpose |
| --- | --- |
| `SIGN_IDENTITY` | Code-signing identity. Hardened runtime is enabled when set; otherwise the app is ad-hoc signed. |
| `BUNDLE_ID` | Overrides the bundle identifier (default `io.github.siminstall`). |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | Turn on notarization in `make-dmg.sh`. |

## Releasing

<details>
<summary>Maintainer notes: tagging, signing and notarization</summary>

<br>

Pushing a version tag triggers the [release workflow](.github/workflows/release.yml), which builds the app, packages the DMG and publishes a GitHub release with generated release notes:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

To produce signed and notarized builds, add these repository secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERT_P12` | Developer ID Application certificate (`.p12`), base64-encoded |
| `MACOS_CERT_PASSWORD` | Password for the `.p12` |
| `SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID` | Apple ID email |
| `APPLE_TEAM_ID` | 10-character Team ID |
| `APPLE_APP_PASSWORD` | App-specific password from [appleid.apple.com](https://appleid.apple.com) |

Without these secrets, the workflow still produces an ad-hoc signed DMG. CI installs `create-dmg` automatically.

</details>

## Project structure

```text
Sources/SimInstall.swift      SwiftUI app (single file)
scripts/build-app.sh          Compiles the universal .app bundle
scripts/make-dmg.sh           Packages, and optionally notarizes, the DMG
assets/                       App icon and DMG background artwork
.github/workflows/            Release automation
```

## License

Released under the [MIT License](LICENSE).
