#!/usr/bin/env bash
set -euo pipefail

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

TOTAL_STEPS=6
step()    { echo -e "\n${BLUE}[$1/$TOTAL_STEPS]${NC} ${CYAN}$2${NC}"; }
success() { echo -e "  ${GREEN}✓ $1${NC}"; }
warn()    { echo -e "  ${YELLOW}⚠ $1${NC}"; }
error()   { echo -e "  ${RED}✗ $1${NC}"; exit 1; }

REPO="LeoManrique/Syncden"
API_URL="https://api.github.com/repos/$REPO/releases/latest"
TMP_DIR="/tmp/syncden-install"

# ── Step 1: Detect platform ──
step 1 "Detecting platform"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)        ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) error "Unsupported architecture: $ARCH" ;;
esac

case "$OS" in
  darwin) PLATFORM="macOS-$ARCH" ;;
  linux)  PLATFORM="linux-$ARCH" ;;
  *)      error "Unsupported OS: $OS (this script supports macOS and Linux)" ;;
esac
success "Platform: $PLATFORM"

# ── Step 2: Stop running app + daemon ──
# The daemon (`syncdend`) is a long-lived process spawned by the GUI, so
# replacing the binaries on disk does NOT update the running code. If it
# keeps running across an upgrade it serves stale logic until killed — and
# things like the OAuth client credentials live in memory, so a fresh login
# against a stale daemon writes the old auth.json schema and the bug fix
# in the new release never takes effect.
step 2 "Stopping running app + daemon"

PROCS=(Syncden syncden syncdend)
RUNNING=()
for p in "${PROCS[@]}"; do
  if pgrep -x "$p" >/dev/null 2>&1; then RUNNING+=("$p"); fi
done

if [ ${#RUNNING[@]} -eq 0 ]; then
  success "No running instances"
else
  for p in "${RUNNING[@]}"; do
    pkill -TERM -x "$p" 2>/dev/null || true
  done

  # Up to 8s for graceful exit; the daemon handles SIGTERM cleanly.
  for _ in $(seq 1 16); do
    STILL=()
    for p in "${RUNNING[@]}"; do
      if pgrep -x "$p" >/dev/null 2>&1; then STILL+=("$p"); fi
    done
    [ ${#STILL[@]} -eq 0 ] && break
    sleep 0.5
  done

  for p in "${RUNNING[@]}"; do
    if pgrep -x "$p" >/dev/null 2>&1; then
      warn "Force-killing $p (graceful stop timed out)"
      pkill -KILL -x "$p" 2>/dev/null || true
    fi
  done
  success "Stopped: ${RUNNING[*]}"
fi

# ── Step 3: Fetch latest release ──
step 3 "Fetching latest release from GitHub"

RELEASE_JSON=$(curl -fsSL -H "Accept: application/vnd.github.v3+json" "$API_URL" 2>/dev/null) \
  || error "Failed to fetch release info from GitHub. Check your internet connection."

TAG=$(echo "$RELEASE_JSON" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[ -z "$TAG" ] && error "Could not parse release tag from GitHub API"

VERSION="${TAG#v}"
success "Latest version: $VERSION (tag: $TAG)"

# ── Step 4: Download artifact ──
step 4 "Downloading artifact"

case "$OS" in
  darwin) ARTIFACT="Syncden-$VERSION-$PLATFORM.zip" ;;
  linux)  ARTIFACT="Syncden-$VERSION-$PLATFORM.tar.gz" ;;
esac

DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*'"$ARTIFACT"'"' | head -1 | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
[ -z "$DOWNLOAD_URL" ] && error "Could not find artifact $ARTIFACT in release $TAG"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

curl -fSL --progress-bar -o "$TMP_DIR/$ARTIFACT" "$DOWNLOAD_URL" \
  || error "Failed to download $ARTIFACT"
success "Downloaded $ARTIFACT"

# ── Step 5: Install ──
step 5 "Installing Syncden"

case "$OS" in
  darwin)
    unzip -qo "$TMP_DIR/$ARTIFACT" -d "$TMP_DIR"
    if [ -d "/Applications/Syncden.app" ]; then
      rm -rf "/Applications/Syncden.app"
      warn "Replaced existing /Applications/Syncden.app"
    fi
    mv "$TMP_DIR/Syncden.app" "/Applications/Syncden.app"
    xattr -cr "/Applications/Syncden.app" 2>/dev/null || true
    success "Installed to /Applications/Syncden.app"
    ;;
  linux)
    tar -xzf "$TMP_DIR/$ARTIFACT" -C "$TMP_DIR"
    # Both binaries land in the same dir so the GUI's LocateDaemonBinary()
    # finds syncdend next to itself.
    sudo install -Dm755 "$TMP_DIR/syncden"  "/usr/local/bin/syncden"
    sudo install -Dm755 "$TMP_DIR/syncdend" "/usr/local/bin/syncdend"
    success "Installed syncden, syncdend to /usr/local/bin/"

    # Desktop entry
    sudo tee "/usr/share/applications/syncden.desktop" > /dev/null <<EOF
[Desktop Entry]
Name=Syncden
Comment=Cross-platform file sync
Exec=syncden
Icon=syncden
Type=Application
Categories=Utility;Network;
StartupNotify=true
EOF
    success "Created desktop entry"
    ;;
esac

# ── Step 6: Cleanup ──
step 6 "Cleaning up"

rm -rf "$TMP_DIR"
success "Temporary files removed"

echo -e "\n${GREEN}═══ Syncden $VERSION installed successfully ═══${NC}"
case "$OS" in
  darwin) echo -e "  ${CYAN}Open Syncden from /Applications or Spotlight${NC}" ;;
  linux)  echo -e "  ${CYAN}Run 'syncden' or find Syncden in your app launcher${NC}" ;;
esac
