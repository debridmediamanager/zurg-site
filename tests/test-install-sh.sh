#!/usr/bin/env bash
# Regression tests for the shell installers, public/install.sh and
# public/install-docker.sh.
#
# Each case loads an installer's functions in a subshell, swaps curl for a
# stand-in that serves recorded responses, and runs one function against a
# scratch directory. Nothing here touches the network, GitHub sign-in or root.
#
#   bash tests/test-install-sh.sh
#
# 2026-10-03: GitHub's API now answers in compact JSON, all on one line. The
# installers found the GitHub CLI release tag with a sed that only matched
# "tag_name" at the start of a line, so on any machine without gh both
# installers stopped with "Could not determine the latest GitHub CLI release."
# fixtures/installer/gh-latest-release.json is that response as recorded on zen.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIXTURES="$ROOT/tests/fixtures/installer"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/zurg-installer-test.XXXXXX")
trap 'rm -rf -- "$SCRATCH"' EXIT
failures=0
cases=0

# Every tool on this machine except gh, so "no GitHub CLI installed" can be
# tested on a runner that ships one.
NO_GH_PATH="$SCRATCH/no-gh-path"
mkdir -p "$NO_GH_PATH"
IFS=: read -r -a path_dirs <<<"$PATH"
for dir in "${path_dirs[@]}"; do
  [[ -d "$dir" ]] || continue
  for tool in "$dir"/*; do
    name=${tool##*/}
    if [[ "$name" == gh || -e "$NO_GH_PATH/$name" || ! -x "$tool" || -d "$tool" ]]; then
      continue
    fi
    ln -s "$tool" "$NO_GH_PATH/$name"
  done
done

# The installers end by calling main. Everything above that line is functions
# and settings, which is what the cases need.
loadable() {
  local script=$1 out
  out="$SCRATCH/$(basename "$script").functions"
  grep -vx 'main "$@"' "$script" >"$out"
  printf '%s\n' "$out"
}
INSTALL_SH=$(loadable "$ROOT/public/install.sh")
INSTALL_DOCKER_SH=$(loadable "$ROOT/public/install-docker.sh")

# Writes the archive the installer would download from the GitHub CLI release,
# laid out the same way, with a gh inside that answers like a signed-in CLI.
make_gh_archive() {
  python3 - "$1" <<'PY'
import io, os, sys, tarfile, zipfile
dest = sys.argv[1]
name = os.path.basename(dest)
stem = name[:-len(".tar.gz")] if name.endswith(".tar.gz") else name[:-len(".zip")]
script = b'#!/bin/sh\necho "gh $*" >>"${GH_STUB_LOG:-/dev/null}"\nexit 0\n'
member = stem + "/bin/gh"
if name.endswith(".tar.gz"):
    with tarfile.open(dest, "w:gz") as tar:
        info = tarfile.TarInfo(member)
        info.size = len(script)
        info.mode = 0o755
        tar.addfile(info, io.BytesIO(script))
else:
    with zipfile.ZipFile(dest, "w") as archive:
        info = zipfile.ZipInfo(member)
        info.external_attr = 0o755 << 16
        archive.writestr(info, script)
PY
}

# Body shared by every case: sourced after the installer, it replaces curl.
STUBS="$SCRATCH/stubs.sh"
cat >"$STUBS" <<'STUBS'
curl() {
  local out="" url=""
  while (($#)); do
    case "$1" in
      -o) out=$2; shift 2; continue ;;
      --retry) shift 2; continue ;;
      -*) ;;
      *) url=$1 ;;
    esac
    shift
  done
  printf '%s\n' "$url" >>"$CURL_LOG"
  case "$url" in
    https://api.github.com/repos/cli/cli/releases/latest) cat "$GH_RELEASE_JSON" ;;
    https://github.com/cli/cli/releases/download/*) make_gh_archive "$out" ;;
    *) printf 'unexpected curl %s\n' "$url" >&2; return 22 ;;
  esac
}
STUBS

# Sets CASE_DIR to a fresh scratch directory for the next case.
new_case() {
  cases=$((cases + 1))
  CASE_DIR="$SCRATCH/case$cases"
  mkdir -p "$CASE_DIR/home" "$CASE_DIR/tmp"
  : >"$CASE_DIR/curl.log"
}

pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  shift
  local line
  for line in "$@"; do printf '      | %s\n' "$line"; done
  failures=$((failures + 1))
}

# check NAME OUTPUT CONDITION... : every condition is a command that must succeed.
check() {
  local name=$1 output=$2
  shift 2
  local condition
  for condition in "$@"; do
    if ! eval "$condition"; then
      local lines=() line
      while IFS= read -r line; do lines+=("$line"); done <<<"$output"
      fail "$name" "failed: $condition" "${lines[@]}"
      return
    fi
  done
  pass "$name"
}

# --- the GitHub CLI release tag --------------------------------------------

# download_portable_gh with the recorded response, as install.sh runs it.
portable_gh_case() {
  local script=$1 os=$2 arch=$3 json=$4 dir
  new_case
  dir=$CASE_DIR
  CASE_OUT=$(
    exec 2>&1
    cd "$dir" || exit 1
    export PATH="$NO_GH_PATH" HOME="$dir/home" CURL_LOG="$dir/curl.log" GH_RELEASE_JSON="$json"
    # shellcheck disable=SC1090
    source "$script"
    # shellcheck disable=SC1090
    source "$STUBS"
    OS=$os ARCH=$arch GH_ARCH=$arch TEMP_DIR="$dir/tmp"
    download_portable_gh
    printf 'GH_BIN=%s\n' "$GH_BIN"
    "$GH_BIN" --version >/dev/null && printf 'GH_RUNS=yes\n'
  )
}

COMPACT="$FIXTURES/gh-latest-release.json"
PRETTY="$SCRATCH/gh-latest-release.pretty.json"
python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2], "w"), indent=2)' "$COMPACT" "$PRETTY"

portable_gh_case "$INSTALL_SH" linux amd64 "$COMPACT"
check "install.sh reads the tag from GitHub's compact JSON (Linux)" "$CASE_OUT" \
  '[[ "$CASE_OUT" == *GH_RUNS=yes* ]]' \
  'grep -qx "https://github.com/cli/cli/releases/download/v2.102.0/gh_2.102.0_linux_amd64.tar.gz" "$CASE_DIR/curl.log"'

portable_gh_case "$INSTALL_SH" darwin arm64 "$COMPACT"
check "install.sh reads the tag from GitHub's compact JSON (macOS)" "$CASE_OUT" \
  '[[ "$CASE_OUT" == *GH_RUNS=yes* ]]' \
  'grep -qx "https://github.com/cli/cli/releases/download/v2.102.0/gh_2.102.0_macOS_arm64.zip" "$CASE_DIR/curl.log"'

portable_gh_case "$INSTALL_SH" linux amd64 "$PRETTY"
check "install.sh still reads the tag from indented JSON" "$CASE_OUT" \
  '[[ "$CASE_OUT" == *GH_RUNS=yes* ]]' \
  'grep -qx "https://github.com/cli/cli/releases/download/v2.102.0/gh_2.102.0_linux_amd64.tar.gz" "$CASE_DIR/curl.log"'

portable_gh_case "$INSTALL_DOCKER_SH" linux amd64 "$COMPACT"
check "install-docker.sh reads the tag from GitHub's compact JSON" "$CASE_OUT" \
  '[[ "$CASE_OUT" == *GH_RUNS=yes* ]]' \
  'grep -qx "https://github.com/cli/cli/releases/download/v2.102.0/gh_2.102.0_linux_amd64.tar.gz" "$CASE_DIR/curl.log"'

printf '\n'
if ((failures > 0)); then
  printf '%d of %d failed\n' "$failures" "$cases"
  exit 1
fi
printf 'all %d passed\n' "$cases"
