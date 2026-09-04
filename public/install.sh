#!/usr/bin/env bash
set -euo pipefail

ZURG_REPO="${ZURG_REPO:-debridmediamanager/zurg}"
INSTALL_DIR="${ZURG_INSTALL_DIR:-$HOME/zurg}"
DRY_RUN="${ZURG_INSTALL_DRY_RUN:-0}"
TTY_PATH=/dev/tty
TEMP_DIR=""

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nError: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "This step needs root access and sudo is not installed."
  fi
}

detect_platform() {
  case "$(uname -s)" in
    Linux) OS=linux ;;
    Darwin) OS=darwin ;;
    *) die "This installer supports Linux and macOS. Use install.ps1 on Windows." ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64 ;;
    i386|i486|i586|i686) ARCH=386 ;;
    armv5*) ARCH=arm-5 ;;
    armv6*) ARCH=arm-6 ;;
    armv7*) ARCH=arm-7 ;;
    mips) ARCH=mips ;;
    mipsle) ARCH=mipsle ;;
    mips64) ARCH=mips64 ;;
    mips64le) ARCH=mips64le ;;
    ppc64le) ARCH=ppc64le ;;
    s390x) ARCH=s390x ;;
    *) die "No zurg binary is published for architecture $(uname -m)." ;;
  esac

  if [[ "$OS" == darwin && "$ARCH" != amd64 && "$ARCH" != arm64 ]]; then
    die "zurg publishes macOS binaries only for Intel and Apple silicon."
  fi
}

install_linux_prerequisites() {
  if ! command -v curl >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1 || ! command -v fusermount3 >/dev/null 2>&1; then
    say "Installing curl, tar, unzip and FUSE 3"
    if command -v apt-get >/dev/null 2>&1; then
      run_root apt-get update
      run_root apt-get install -y ca-certificates curl tar unzip fuse3
    elif command -v dnf >/dev/null 2>&1; then
      run_root dnf install -y ca-certificates curl tar unzip fuse3
    elif command -v yum >/dev/null 2>&1; then
      run_root yum install -y ca-certificates curl tar unzip fuse3
    elif command -v pacman >/dev/null 2>&1; then
      run_root pacman -Sy --needed --noconfirm ca-certificates curl tar unzip fuse3
    elif command -v zypper >/dev/null 2>&1; then
      run_root zypper --non-interactive install ca-certificates curl tar unzip fuse3
    elif command -v apk >/dev/null 2>&1; then
      run_root apk add ca-certificates curl tar unzip fuse3
    else
      die "Install curl, tar, unzip and FUSE 3 with your package manager, then rerun this command."
    fi
  fi

  if [[ ! -c /dev/fuse ]] && command -v modprobe >/dev/null 2>&1; then
    run_root modprobe fuse || true
  fi
  [[ -c /dev/fuse ]] || die "/dev/fuse is unavailable. Load the fuse kernel module, then rerun this command."
}

download_portable_gh() {
  local release_json tag version gh_os gh_arch asset archive extracted
  release_json=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest)
  tag=$(printf '%s\n' "$release_json" | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [[ -n "$tag" ]] || die "Could not determine the latest GitHub CLI release."
  version=${tag#v}
  gh_arch=$ARCH
  case "$ARCH" in
    arm-6|arm-7) gh_arch=armv6 ;;
    amd64|arm64|386) ;;
    *) die "Install GitHub CLI first on $OS-$ARCH, then rerun this command." ;;
  esac
  if [[ "$OS" == darwin ]]; then
    gh_os=macOS
    asset="gh_${version}_${gh_os}_${gh_arch}.zip"
    archive="$TEMP_DIR/$asset"
    curl -fL --retry 3 -o "$archive" "https://github.com/cli/cli/releases/download/$tag/$asset"
    unzip -q "$archive" -d "$TEMP_DIR/gh"
  else
    gh_os=linux
    asset="gh_${version}_${gh_os}_${gh_arch}.tar.gz"
    archive="$TEMP_DIR/$asset"
    curl -fL --retry 3 -o "$archive" "https://github.com/cli/cli/releases/download/$tag/$asset"
    mkdir -p "$TEMP_DIR/gh"
    tar -xzf "$archive" -C "$TEMP_DIR/gh"
  fi
  extracted=$(find "$TEMP_DIR/gh" -type f -path '*/bin/gh' -print -quit)
  [[ -n "$extracted" ]] || die "The downloaded GitHub CLI archive did not contain gh."
  chmod +x "$extracted"
  GH_BIN=$extracted
}

ensure_github_access() {
  if command -v gh >/dev/null 2>&1; then
    GH_BIN=$(command -v gh)
  else
    say "Downloading a temporary GitHub CLI"
    download_portable_gh
  fi

  if ! "$GH_BIN" auth status --hostname github.com >/dev/null 2>&1; then
    [[ -r "$TTY_PATH" ]] || die "GitHub sign-in needs a terminal. Download install.sh and run it directly."
    say "Sign in to GitHub with the account that has zurg access"
    "$GH_BIN" auth login --hostname github.com --git-protocol https --web <"$TTY_PATH"
  fi
  "$GH_BIN" api "repos/$ZURG_REPO" >/dev/null 2>&1 || die "This GitHub account cannot access $ZURG_REPO. Check your sponsorship access and try again."
}

install_macos_fuse() {
  if [[ -d /Library/Filesystems/macfuse.fs ]]; then
    return
  fi

  say "Installing macFUSE"
  if command -v brew >/dev/null 2>&1; then
    brew install --cask macfuse
    return
  fi

  local dmg mount_dir package
  mount_dir="$TEMP_DIR/macfuse"
  mkdir -p "$mount_dir"
  mkdir -p "$TEMP_DIR/macfuse-download"
  "$GH_BIN" release download --repo macfuse/macfuse --pattern '*.dmg' --dir "$TEMP_DIR/macfuse-download" --clobber
  dmg=$(find "$TEMP_DIR/macfuse-download" -maxdepth 1 -type f -name '*.dmg' -print -quit)
  [[ -n "$dmg" ]] || die "Could not download the macFUSE installer."
  hdiutil attach "$dmg" -nobrowse -quiet -mountpoint "$mount_dir"
  package=$(find "$mount_dir" -maxdepth 3 -type f -name '*.pkg' -print -quit)
  if [[ -z "$package" ]]; then
    hdiutil detach "$mount_dir" -quiet || true
    die "The macFUSE image did not contain an installer package. Install macFUSE from macfuse.io and rerun."
  fi
  run_root installer -pkg "$package" -target /
  hdiutil detach "$mount_dir" -quiet || true
}

resolve_zurg_release() {
  ZURG_TAG=$(
    "$GH_BIN" api "repos/$ZURG_REPO/releases?per_page=30" \
      --jq '[.[] | select(.prerelease == true and .draft == false)][0].tag_name'
  )
  [[ -n "$ZURG_TAG" && "$ZURG_TAG" != null ]] || die "No sponsor nightly release was found."
  ZURG_ASSET=$(
    "$GH_BIN" api "repos/$ZURG_REPO/releases/tags/$ZURG_TAG" \
      --jq ".assets[] | select(.name | endswith(\"-$OS-$ARCH.zip\")) | .name" | head -n 1
  )
  [[ -n "$ZURG_ASSET" ]] || die "Release $ZURG_TAG has no $OS-$ARCH binary."
}

install_zurg_binary() {
  mkdir -p "$INSTALL_DIR"
  if [[ -x "$INSTALL_DIR/zurg" ]]; then
    say "Using the existing zurg binary in $INSTALL_DIR"
    return
  fi

  resolve_zurg_release
  say "Downloading zurg $ZURG_TAG for $OS-$ARCH"
  mkdir -p "$TEMP_DIR/zurg"
  "$GH_BIN" release download "$ZURG_TAG" --repo "$ZURG_REPO" --pattern "$ZURG_ASSET" --dir "$TEMP_DIR/zurg" --clobber
  unzip -q "$TEMP_DIR/zurg/$ZURG_ASSET" -d "$TEMP_DIR/zurg/extracted"
  [[ -f "$TEMP_DIR/zurg/extracted/zurg" ]] || die "The zurg archive did not contain the expected binary."
  chmod +x "$TEMP_DIR/zurg/extracted/zurg"
  if ! "$TEMP_DIR/zurg/extracted/zurg" setup --help 2>&1 | grep -q -- '--provider'; then
    die "The newest nightly predates provider selection. Try again after the next nightly release."
  fi
  install -m 0755 "$TEMP_DIR/zurg/extracted/zurg" "$INSTALL_DIR/zurg"
}

main() {
  detect_platform
  say "zurg convenience installer"
  printf 'Platform: %s-%s\nInstall:  %s\n' "$OS" "$ARCH" "$INSTALL_DIR"

  if [[ "$DRY_RUN" == 1 ]]; then
    printf 'Dry run: prerequisites, private release download and zurg setup would run.\n'
    return
  fi

  [[ -r "$TTY_PATH" ]] || die "This installer needs an interactive terminal."
  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zurg-install.XXXXXX")

  if [[ "$OS" == linux ]]; then
    install_linux_prerequisites
  else
    command -v curl >/dev/null 2>&1 || die "curl is required."
    command -v unzip >/dev/null 2>&1 || die "unzip is required."
  fi

  ensure_github_access
  if [[ "$OS" == darwin ]]; then
    install_macos_fuse
  fi
  install_zurg_binary

  if ! "$INSTALL_DIR/zurg" setup --help 2>&1 | grep -q -- '--provider'; then
    die "This zurg build predates provider selection. Use a newer nightly, then rerun this command."
  fi

  say "Running zurg setup"
  (
    cd "$INSTALL_DIR"
    ./zurg setup <"$TTY_PATH"
    ./zurg doctor
  )
  say "zurg is installed in $INSTALL_DIR"
}

main "$@"
