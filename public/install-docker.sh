#!/usr/bin/env bash
set -euo pipefail

ZURG_REPO="${ZURG_REPO:-debridmediamanager/zurg}"
INSTALL_DIR="${ZURG_INSTALL_DIR:-$HOME/zurg}"
MOUNT_PARENT=/zurg_mnt
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

confirm() {
  local answer
  printf '%s [y/N] ' "$1" >"$TTY_PATH"
  IFS= read -r answer <"$TTY_PATH"
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]]
}

detect_arch() {
  [[ "$(uname -s)" == Linux ]] || die "Host-visible Docker mounts require a Linux host. Use the binary installer on macOS or Windows."
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64; GH_ARCH=amd64 ;;
    arm64|aarch64) ARCH=arm64; GH_ARCH=arm64 ;;
    armv7*) ARCH=arm-7; GH_ARCH=armv6 ;;
    *) die "The zurg Docker image supports amd64, arm64 and arm/v7 hosts." ;;
  esac
}

install_host_prerequisites() {
  if command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 && command -v fusermount3 >/dev/null 2>&1 && command -v findmnt >/dev/null 2>&1; then
    return
  fi
  say "Installing host prerequisites"
  if command -v apt-get >/dev/null 2>&1; then
    run_root apt-get update
    run_root apt-get install -y ca-certificates curl tar fuse3 util-linux
  elif command -v dnf >/dev/null 2>&1; then
    run_root dnf install -y ca-certificates curl tar fuse3 util-linux
  elif command -v yum >/dev/null 2>&1; then
    run_root yum install -y ca-certificates curl tar fuse3 util-linux
  elif command -v pacman >/dev/null 2>&1; then
    run_root pacman -Sy --needed --noconfirm ca-certificates curl tar fuse3 util-linux
  elif command -v zypper >/dev/null 2>&1; then
    run_root zypper --non-interactive install ca-certificates curl tar fuse3 util-linux
  else
    die "Install curl, tar, FUSE 3 and util-linux with your package manager, then rerun."
  fi
}

install_docker_engine() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    die "Docker is installed without the Compose plugin. Install docker-compose-plugin, then rerun."
  fi
  confirm "Docker Engine is not installed. Install it with Docker's official convenience script?" || die "Docker Engine and the Compose plugin are required."
  say "Installing Docker Engine"
  curl -fsSL https://get.docker.com -o "$TEMP_DIR/get-docker.sh"
  run_root sh "$TEMP_DIR/get-docker.sh"
}

select_docker_command() {
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  else
    die "Docker is installed but the daemon is unavailable. Start Docker and rerun."
  fi
  "${DOCKER[@]}" compose version >/dev/null 2>&1 || die "The Docker Compose plugin is unavailable."
}

download_portable_gh() {
  local release_json tag version asset archive extracted
  release_json=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest)
  tag=$(printf '%s\n' "$release_json" | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  [[ -n "$tag" ]] || die "Could not determine the latest GitHub CLI release."
  version=${tag#v}
  asset="gh_${version}_linux_${GH_ARCH}.tar.gz"
  archive="$TEMP_DIR/$asset"
  curl -fL --retry 3 -o "$archive" "https://github.com/cli/cli/releases/download/$tag/$asset"
  mkdir -p "$TEMP_DIR/gh"
  tar -xzf "$archive" -C "$TEMP_DIR/gh"
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
    say "Sign in to GitHub with the account that has zurg access"
    "$GH_BIN" auth login --hostname github.com --git-protocol https --web <"$TTY_PATH"
  fi
  "$GH_BIN" api "repos/$ZURG_REPO" >/dev/null 2>&1 || die "This GitHub account cannot access $ZURG_REPO."
}

login_registry() {
  local login pat
  login=$("$GH_BIN" api user --jq .login)
  if "$GH_BIN" auth token | "${DOCKER[@]}" login ghcr.io --username "$login" --password-stdin >/dev/null 2>&1; then
    return
  fi
  printf 'GitHub PAT with read:packages (input hidden): ' >"$TTY_PATH"
  IFS= read -r -s pat <"$TTY_PATH"
  printf '\n' >"$TTY_PATH"
  [[ -n "$pat" ]] || die "A package token is required to pull the sponsor image."
  printf '%s' "$pat" | "${DOCKER[@]}" login ghcr.io --username "$login" --password-stdin
  unset pat
}

latest_nightly_tag() {
  "$GH_BIN" api "repos/$ZURG_REPO/releases?per_page=30" \
    --jq '[.[] | select(.prerelease == true and .draft == false)][0].tag_name'
}

prepare_mount_propagation() {
  say "Preparing persistent FUSE mount propagation"
  if [[ ! -c /dev/fuse ]] && command -v modprobe >/dev/null 2>&1; then
    run_root modprobe fuse || true
  fi
  [[ -c /dev/fuse ]] || die "/dev/fuse is unavailable. Load the fuse kernel module, then rerun."
  run_root mkdir -p "$MOUNT_PARENT"
  if ! mountpoint -q "$MOUNT_PARENT"; then
    run_root mount --bind "$MOUNT_PARENT" "$MOUNT_PARENT"
  fi
  run_root mount --make-rshared "$MOUNT_PARENT"

  if command -v systemctl >/dev/null 2>&1 && [[ "$MOUNT_PARENT" == /zurg_mnt ]]; then
    cat >"$TEMP_DIR/zurg-mount-propagation.service" <<'UNIT'
[Unit]
Description=Prepare shared mount propagation for zurg
Before=docker.service

[Service]
Type=oneshot
ExecStart=/bin/mkdir -p /zurg_mnt
ExecStart=/bin/sh -c 'mountpoint -q /zurg_mnt || mount --bind /zurg_mnt /zurg_mnt'
ExecStart=/bin/mount --make-rshared /zurg_mnt
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    run_root install -m 0644 "$TEMP_DIR/zurg-mount-propagation.service" /etc/systemd/system/zurg-mount-propagation.service
    run_root systemctl daemon-reload
    run_root systemctl enable zurg-mount-propagation.service >/dev/null
  fi
}

write_compose_project() {
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"
  if [[ ! -f docker-compose.yml && ! -f compose.yml && ! -f compose.yaml ]]; then
    cat >docker-compose.yml <<'YAML'
services:
  zurg:
    image: ghcr.io/debridmediamanager/zurg:${ZURG_TAG}
    container_name: zurg
    restart: unless-stopped
    devices:
      - /dev/fuse
    cap_add:
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    ports:
      - 9999:9999
    volumes:
      - ./:/config
      - /zurg_mnt:/zurg_mnt:rshared
YAML
  fi
  if [[ ! -f .env ]] || ! grep -q '^ZURG_TAG=' .env; then
    printf 'ZURG_TAG=%s\n' "$ZURG_TAG" >>.env
  else
    ZURG_TAG=$(sed -n 's/^ZURG_TAG=//p' .env | tail -n 1)
  fi
  "${DOCKER[@]}" compose config --services | grep -qx zurg || die "The existing Compose project has no service named zurg."
}

main() {
  detect_arch
  say "zurg Docker convenience installer"
  printf 'Platform: linux-%s\nInstall:  %s\nMount:    %s/zurg\n' "$ARCH" "$INSTALL_DIR" "$MOUNT_PARENT"
  if [[ "$DRY_RUN" == 1 ]]; then
    printf 'Dry run: Docker, FUSE propagation, sponsor image and zurg setup would be configured.\n'
    return
  fi
  [[ -r "$TTY_PATH" ]] || die "This installer needs an interactive terminal."
  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zurg-docker-install.XXXXXX")

  install_host_prerequisites
  install_docker_engine
  select_docker_command
  ensure_github_access
  login_registry
  ZURG_TAG=$(latest_nightly_tag)
  [[ -n "$ZURG_TAG" && "$ZURG_TAG" != null ]] || die "No sponsor nightly image was found."

  say "Checking zurg $ZURG_TAG"
  "${DOCKER[@]}" pull "ghcr.io/debridmediamanager/zurg:$ZURG_TAG" >/dev/null
  if ! "${DOCKER[@]}" run --rm "ghcr.io/debridmediamanager/zurg:$ZURG_TAG" setup --help 2>&1 | grep -q -- '--provider'; then
    die "The newest image predates provider selection. Try again after the next nightly release."
  fi

  prepare_mount_propagation
  write_compose_project

  say "Pulling zurg $ZURG_TAG"
  "${DOCKER[@]}" compose pull zurg
  if ! "${DOCKER[@]}" compose run --rm zurg setup --help 2>&1 | grep -q -- '--provider'; then
    die "The Compose service uses a zurg image that predates provider selection. Update its image and rerun."
  fi

  say "Running zurg setup"
  "${DOCKER[@]}" compose run --rm zurg setup --no-service --skip-downloads --mount-path "$MOUNT_PARENT/zurg" <"$TTY_PATH"
  "${DOCKER[@]}" compose up -d zurg

  say "Waiting for zurg"
  for _ in $(seq 1 60); do
    if curl -fsS http://127.0.0.1:9999/http/version.txt >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  curl -fsS http://127.0.0.1:9999/http/version.txt >/dev/null || die "zurg did not become ready. Check docker compose logs zurg."
  "${DOCKER[@]}" compose exec zurg /app/zurg doctor --working-dir /config
  say "zurg is running. Dashboard: http://127.0.0.1:9999/config/"
}

main "$@"
