#!/usr/bin/env sh
# dextr installer (macOS + Linux).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/JayashBhandary/dextr/main/install.sh | sh
#
# Detects platform/arch, downloads the latest GitHub release asset, and installs:
#   macOS -> /Applications/Dextr.app    (requires sudo)
#   Linux -> /opt/dextr  + symlink at /usr/local/bin/dextr  (requires sudo)

set -eu

REPO="JayashBhandary/dextr"
APP_NAME="Dextr"

# ---------- platform detection ----------
OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin)
    PLATFORM="macos"
    case "$ARCH" in
      arm64)  ASSET_SUFFIX="macos-arm64.dmg" ;;
      x86_64) ASSET_SUFFIX="macos-x64.dmg" ;;
      *)      ASSET_SUFFIX="macos-universal.dmg" ;;
    esac
    ;;
  Linux)
    PLATFORM="linux"
    case "$ARCH" in
      x86_64|amd64) ASSET_SUFFIX="linux-x64.tar.gz" ;;
      *)
        echo "Unsupported Linux architecture: $ARCH" >&2
        echo "Only x86_64 Linux builds are published." >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Unsupported OS: $OS" >&2
    echo "Windows users: use install.ps1 instead." >&2
    exit 1
    ;;
esac

echo "==> Detected $PLATFORM / $ARCH -> looking for *${ASSET_SUFFIX}"

# ---------- pick latest release asset ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need curl

API_URL="https://api.github.com/repos/$REPO/releases/latest"

# Auth header if GITHUB_TOKEN is set (avoids rate limits for power users)
AUTH_HEADER=""
if [ -n "${GITHUB_TOKEN:-}" ]; then
  AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
fi

if [ -n "$AUTH_HEADER" ]; then
  RELEASE_JSON=$(curl -fsSL -H "$AUTH_HEADER" "$API_URL")
else
  RELEASE_JSON=$(curl -fsSL "$API_URL")
fi

# Only assets served from this project's own release path are candidates. The
# release JSON lists every asset attached to the release, and matching a bare
# suffix anywhere in a URL would accept one uploaded by somebody else.
RELEASE_PREFIX="https://github.com/$REPO/releases/download/"

asset_urls() {
  printf '%s' "$RELEASE_JSON" \
    | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]+)"$/\1/' \
    | grep -F "$RELEASE_PREFIX"
}

# Anchored to the end of the name, so `evil-macos-arm64.dmg` does not match a
# request for `dextr-<version>-macos-arm64.dmg`.
find_asset() {
  asset_urls | grep -E "/dextr-[^/]*${1}\$" | head -n 1
}

ASSET_URL=$(find_asset "$ASSET_SUFFIX")

# macOS fallback: if no per-arch DMG, try the universal one.
if [ -z "$ASSET_URL" ] && [ "$PLATFORM" = "macos" ]; then
  ASSET_URL=$(find_asset "macos-universal\.dmg")
fi

if [ -z "$ASSET_URL" ]; then
  echo "Could not find a release asset matching *${ASSET_SUFFIX} in $REPO." >&2
  echo "Visit https://github.com/$REPO/releases to inspect available assets." >&2
  exit 1
fi

SUMS_URL=$(asset_urls | grep -E '/SHA256SUMS$' | head -n 1)

if [ -z "$SUMS_URL" ]; then
  echo "This release publishes no SHA256SUMS file, so the download cannot be" >&2
  echo "verified. Refusing to install." >&2
  echo "" >&2
  echo "Releases from v0.1.3 onward publish one. To install an earlier build," >&2
  echo "download it from https://github.com/$REPO/releases and check it by" >&2
  echo "hand." >&2
  exit 1
fi

# ---------- download ----------
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
ASSET_NAME=$(basename "$ASSET_URL")
FILENAME="$WORKDIR/$ASSET_NAME"

echo "==> Downloading $ASSET_URL"
curl -fSL --progress-bar -o "$FILENAME" "$ASSET_URL"

# ---------- verify ----------
# Before anything is unpacked, mounted, or run as root. An installer that skips
# this is a remote code execution primitive for whoever can influence a release
# artifact, and this one installs into /Applications and /opt with sudo.
echo "==> Verifying checksum"
curl -fsSL -o "$WORKDIR/SHA256SUMS" "$SUMS_URL"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL=$(sha256sum "$FILENAME" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL=$(shasum -a 256 "$FILENAME" | awk '{print $1}')
else
  echo "Neither sha256sum nor shasum is available, so the download cannot be" >&2
  echo "verified. Refusing to install." >&2
  exit 1
fi

# Matched on the exact file name, not a substring: two assets can share a
# prefix, and picking the wrong line would verify the wrong artifact.
EXPECTED=$(awk -v name="$ASSET_NAME" '$2 == name || $2 == "*" name {print $1}' \
  "$WORKDIR/SHA256SUMS" | head -n 1)

if [ -z "$EXPECTED" ]; then
  echo "SHA256SUMS does not list $ASSET_NAME. Refusing to install." >&2
  exit 1
fi

if [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "Checksum mismatch for $ASSET_NAME — refusing to install." >&2
  echo "  expected: $EXPECTED" >&2
  echo "  actual:   $ACTUAL" >&2
  echo "" >&2
  echo "The download does not match what the release says it published. This" >&2
  echo "is either a corrupted transfer or a tampered artifact; do not install" >&2
  echo "it either way." >&2
  exit 1
fi

echo "    OK  $ACTUAL"

# ---------- install ----------
case "$PLATFORM" in
  macos)
    echo "==> Mounting DMG"
    MOUNT_OUTPUT=$(hdiutil attach "$FILENAME" -nobrowse -readonly -plist)
    MOUNT_DIR=$(printf '%s' "$MOUNT_OUTPUT" \
      | grep -A1 '<key>mount-point</key>' \
      | grep '<string>' \
      | head -n 1 \
      | sed -E 's/.*<string>(.*)<\/string>.*/\1/')

    if [ -z "$MOUNT_DIR" ] || [ ! -d "$MOUNT_DIR/$APP_NAME.app" ]; then
      echo "Failed to locate $APP_NAME.app inside the mounted DMG." >&2
      exit 1
    fi

    echo "==> Installing to /Applications/$APP_NAME.app (sudo required)"
    sudo rm -rf "/Applications/$APP_NAME.app"
    sudo cp -R "$MOUNT_DIR/$APP_NAME.app" /Applications/

    # Quarantine is deliberately left in place. Stripping it used to happen here
    # so the app would launch without a prompt, which meant this script removed
    # Gatekeeper's check on a binary it had just downloaded — the last thing
    # standing between a tampered release and execution. The build is not yet
    # signed with a Developer ID or notarized, so macOS will ask once; that
    # prompt is the user's decision to make, not this script's to make for them.

    hdiutil detach "$MOUNT_DIR" -quiet || true

    echo ""
    echo "Installed: /Applications/$APP_NAME.app"
    echo ""
    echo "This build is not signed with an Apple Developer ID, so the first"
    echo "launch will be refused. To allow it:"
    echo ""
    echo "  1. Open /Applications and right-click Dextr.app -> Open"
    echo "  2. Confirm at the prompt"
    echo ""
    echo "Or, from System Settings -> Privacy & Security, choose \"Open Anyway\""
    echo "after the first refusal. You only have to do this once."
    ;;

  linux)
    INSTALL_DIR="/opt/dextr"
    BIN_LINK="/usr/local/bin/dextr"
    # Named after the GTK application ID (see linux/CMakeLists.txt) so the
    # shell can match a running window's WM_CLASS / app_id to this entry.
    APP_ID="com.dextr.dextr"
    DESKTOP_FILE="/usr/share/applications/$APP_ID.desktop"
    ICON_DIR="/usr/share/icons/hicolor/512x512/apps"
    ICON_FILE="$ICON_DIR/$APP_ID.png"
    PIXMAP_FILE="/usr/share/pixmaps/$APP_ID.png"

    # Unpacked as the invoking user, into a directory under our own temp dir,
    # before anything privileged happens. Extracting an archive as root gives a
    # tar bug or a crafted member the run of the filesystem; this way the worst
    # case is confined to a directory the trap deletes.
    STAGE="$WORKDIR/bundle"
    mkdir -p "$STAGE"
    echo "==> Unpacking"
    tar -xzf "$FILENAME" -C "$STAGE"

    # `cp -R` copies a symlink rather than following it, so extraction cannot
    # write outside the staging directory. What it can do is leave a link inside
    # /opt/dextr pointing at an absolute path the application later follows, so
    # those are rejected — a release bundle has no reason to contain one.
    # `|| true` because the loop's status is the last grep's, and "no absolute
    # symlinks found" is the good outcome, not a failure to report.
    ESCAPING=$(find "$STAGE" -type l -print | while read -r link; do
      readlink "$link" | grep -q '^/' && echo "$link"
    done || true)
    if [ -n "$ESCAPING" ]; then
      echo "This archive contains symlinks to absolute paths:" >&2
      echo "$ESCAPING" >&2
      echo "Refusing to install." >&2
      exit 1
    fi

    echo "==> Installing to $INSTALL_DIR (sudo required)"
    sudo rm -rf "$INSTALL_DIR"
    sudo mkdir -p "$INSTALL_DIR"
    sudo cp -R "$STAGE/." "$INSTALL_DIR/"

    # Find the executable inside the bundle and symlink it
    EXEC_PATH=""
    for candidate in "$INSTALL_DIR/dextr" "$INSTALL_DIR/Dextr"; do
      if [ -x "$candidate" ]; then
        EXEC_PATH="$candidate"
        break
      fi
    done

    if [ -n "$EXEC_PATH" ]; then
      sudo ln -sf "$EXEC_PATH" "$BIN_LINK"
    else
      echo "Could not auto-detect the executable; skipping CLI symlink." >&2
    fi

    # Drop entries and icons from releases that used the old "dextr" names,
    # otherwise the launcher shows two entries and may keep the stale icon.
    sudo rm -f /usr/share/applications/dextr.desktop \
               "$ICON_DIR/dextr.png" \
               /usr/share/pixmaps/dextr.png

    # Install desktop entry so it shows up in app launchers
    SRC_DESKTOP=""
    for candidate in "$INSTALL_DIR/$APP_ID.desktop" "$INSTALL_DIR/dextr.desktop"; do
      if [ -f "$candidate" ]; then
        SRC_DESKTOP="$candidate"
        break
      fi
    done

    if [ -n "$SRC_DESKTOP" ] && [ -n "$EXEC_PATH" ]; then
      echo "==> Registering desktop entry at $DESKTOP_FILE"
      sudo mkdir -p "$(dirname "$DESKTOP_FILE")"
      sudo sh -c "sed -e 's|@EXEC@|$EXEC_PATH|g' -e 's|^Icon=dextr\$|Icon=$APP_ID|' -e 's|^StartupWMClass=dextr\$|StartupWMClass=$APP_ID|' '$SRC_DESKTOP' > '$DESKTOP_FILE'"
      sudo chmod 644 "$DESKTOP_FILE"
    fi

    # Install icon into the hicolor theme + /usr/share/pixmaps fallback
    if [ -f "$INSTALL_DIR/dextr.png" ]; then
      echo "==> Installing app icon"
      sudo mkdir -p "$ICON_DIR"
      sudo cp "$INSTALL_DIR/dextr.png" "$ICON_FILE"
      sudo chmod 644 "$ICON_FILE"
      sudo mkdir -p "$(dirname "$PIXMAP_FILE")"
      sudo cp "$INSTALL_DIR/dextr.png" "$PIXMAP_FILE"
      sudo chmod 644 "$PIXMAP_FILE"

      # The source is a single 1024px PNG. Panels and the switcher ask for much
      # smaller sizes, so pre-scale when a resizer is around; without one the
      # 512x512 copy above still resolves, just scaled at draw time.
      RESIZE=""
      for tool in magick convert; do
        if command -v "$tool" >/dev/null 2>&1; then
          RESIZE="$tool"
          break
        fi
      done
      if [ -n "$RESIZE" ]; then
        for size in 16 24 32 48 64 128 256; do
          SIZE_DIR="/usr/share/icons/hicolor/${size}x${size}/apps"
          sudo mkdir -p "$SIZE_DIR"
          sudo "$RESIZE" "$INSTALL_DIR/dextr.png" -resize "${size}x${size}" \
            "$SIZE_DIR/$APP_ID.png" 2>/dev/null || true
          sudo rm -f "$SIZE_DIR/dextr.png"
        done
      fi
    fi

    # Refresh desktop + icon caches so the entry appears without re-login
    if command -v update-desktop-database >/dev/null 2>&1; then
      sudo update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
      sudo gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
    fi

    echo ""
    echo "Installed: $INSTALL_DIR"
    if [ -n "$EXEC_PATH" ]; then
      echo "Launch:    dextr    (symlinked from $BIN_LINK), or from your app launcher"
    fi
    ;;
esac

echo "Done."
