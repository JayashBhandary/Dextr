# dextr

Cross-platform database & data-source management tool, built with Flutter.

Desktop only — `dextr` connects directly to databases over TCP sockets and via
native SQLite (FFI), neither of which exist in a browser, so there is no web
build. Mobile (Android/iOS) is not targeted.

## Supported platforms

| Platform | Architectures | Release artifact |
|----------|---------------|------------------|
| macOS    | universal (arm64 + x86_64), plus per-arch | `dextr-<version>-macos-{universal,arm64,x64}.dmg` |
| Windows  | x64 | `dextr-<version>-windows-x64.zip` |
| Linux    | x64 | `dextr-<version>-linux-x64.tar.gz` |

> Windows is x64 only — Flutter has no official Windows arm64 desktop target.

## Install

Pulls the matching artifact from the latest GitHub Release and installs it.

**macOS / Linux** (requires `sudo`):

```bash
curl -fsSL https://raw.githubusercontent.com/JayashBhandary/dextr/main/install.sh | sh
```

**Windows** (PowerShell):

```powershell
irm https://raw.githubusercontent.com/JayashBhandary/dextr/main/install.ps1 | iex
```

| OS | Installs to |
|----|-------------|
| macOS | `/Applications/dextr.app` (quarantine stripped — unsigned build) |
| Linux | `/opt/dextr`, symlink `/usr/local/bin/dextr`, desktop entry + icon |
| Windows | `%LOCALAPPDATA%\Programs\dextr`, Start Menu shortcut |

Set `GITHUB_TOKEN` before running to avoid GitHub API rate limits.

## Build locally

Requires the Flutter SDK (`stable` 3.44.0, Dart `>= 3.12`).

```bash
flutter pub get

flutter build macos --release     # macOS universal
flutter build windows --release   # Windows x64
flutter build linux --release     # Linux x64
```

> No `build_runner` step — the project declares codegen dev-deps but does not
> use any `@freezed` / `@riverpod` / `@JsonSerializable` annotations yet.

## CI: build & release

`.github/workflows/release.yml` builds macOS, Windows, and Linux and publishes a
GitHub Release.

- **Trigger:** `workflow_dispatch` only (Actions tab → Release → *Run workflow*).
- **Version:** read from the `version:` line in `pubspec.yaml`; the release is
  tagged `v<version>` (e.g. `0.1.0+1` → `v0.1.0`).

```bash
gh workflow run release.yml
```

Each job builds and uploads its artifact; the final `release` job attaches them
all to the `v<version>` tag with auto-generated notes.

> **Signing:** macOS artifacts are **unsigned** (ad-hoc codesigned after `lipo`
> thinning). For notarized distribution, add a Developer ID cert via repository
> secrets and the matching signing steps.
