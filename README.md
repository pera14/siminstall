# SimInstall

A small native macOS app for installing iOS Simulator builds (`.app` or EAS / Expo `.tar.gz`) with one click.

Xcode 27's Device Hub no longer accepts drag-and-drop installs. SimInstall brings that workflow back, and does a bit more.

![icon](assets/icon.png)

## Features

- Lists simulator builds from `~/Downloads`, newest first
- Accepts `.app` bundles and EAS `.tar.gz` archives (extracted automatically)
- Picks any iOS simulator, and boots it if needed
- Double-click, press Enter, drag onto the window, or drop on the Dock icon
- Optionally launches the app after installing

## Install

**Homebrew**

```bash
brew install --cask pera14/tap/siminstall
```

**Manual**

Download the latest `SimInstall-x.y.z.dmg` from [Releases](../../releases), open it and drag **SimInstall** to Applications.

Requires macOS 14+ and Xcode (for `xcrun simctl`).

> If the release isn't notarized, macOS will block the first launch. Right-click the app → **Open**, or run:
> `xattr -dr com.apple.quarantine /Applications/SimInstall.app`

## Build from source

```bash
scripts/build-app.sh 1.0.0     # → build/SimInstall.app (universal)
scripts/make-dmg.sh 1.0.0      # → build/SimInstall-1.0.0.dmg
```

## Releasing

Push a tag and GitHub Actions builds the DMG and attaches it to a release:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

For signed and notarized builds, add these repository secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERT_P12` | Developer ID Application certificate, `.p12`, base64-encoded |
| `MACOS_CERT_PASSWORD` | Password of the `.p12` |
| `SIGN_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_ID` | Apple ID email |
| `APPLE_TEAM_ID` | 10-character team ID |
| `APPLE_APP_PASSWORD` | App-specific password from appleid.apple.com |

Without them, the workflow still produces an ad-hoc signed DMG.

To auto-update the Homebrew tap on each release, create a public `pera14/homebrew-tap` repo and add a `TAP_GITHUB_TOKEN` secret (a fine-grained token with Contents: read/write on that repo).

The styled DMG window needs `create-dmg` (`brew install create-dmg`); CI installs it automatically.

## License

MIT
