#!/usr/bin/env bash
# prowlarr-stack bootstrap installer.
# Audit with:  curl -fsSL https://raw.githubusercontent.com/media-centarr/prowlarr-stack/main/install.sh | less
#
# Flow: prereq check → resolve latest release → download tarball + SHA256SUMS →
#       verify → validate archive safety → extract → exec ./install.
set -eu

REPO="media-centarr/prowlarr-stack"
API_ROOT="https://api.github.com/repos/$REPO/releases"
DL_ROOT="https://github.com/$REPO/releases/download"
DEFAULT_DIR="$HOME/prowlarr-stack"

DIR=""
VERSION=""
YES=0
FORCE=0
RESTORE_FILE=""

# --- flag parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --dir=*) DIR="${1#--dir=}"; shift ;;
    --dir) DIR="${2:-}"; shift 2 ;;
    --version=*) VERSION="${1#--version=}"; shift ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --yes) YES=1; shift ;;
    --force) FORCE=1; shift ;;
    --restore=*) RESTORE_FILE="${1#--restore=}"; shift ;;
    --restore) RESTORE_FILE="${2:-}"; shift 2 ;;
    -h|--help)
      cat <<HELP
Usage: curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh [OPTIONS]
   or: sh install.sh [OPTIONS]

Options:
  --dir PATH           install directory (skips the prompt below; default: \$HOME/prowlarr-stack)
  --version vX.Y.Z     install a specific release (default: latest)
  --yes                skip all prompts (uses default install dir; for non-interactive runs)
  --force              install even if target dir exists (replaces it)
  --restore PATH       restore from a backup tarball produced by ./backup
                       (skips interactive setup; reproduces the source install)
  -h | --help          this text

Interactive prompt:
  When run interactively (no --dir, no --yes, no --restore, and a controlling
  terminal is available), the bootstrap asks for the install directory after
  resolving the release version. Press Enter to accept the default
  \$HOME/prowlarr-stack, or type any other absolute path. Tilde (~/foo) is
  expanded.

Env vars:
  PROWLARR_STACK_DIR    same as --dir (sets the install dir without a prompt)
HELP
      exit 0
      ;;
    *) echo "error: unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
done

# If --dir wasn't given, fall back to PROWLARR_STACK_DIR env var. If neither
# is set, DIR stays empty here and the interactive prompt below picks it up.
if [ -z "$DIR" ] && [ -n "${PROWLARR_STACK_DIR:-}" ]; then
  DIR="$PROWLARR_STACK_DIR"
fi

# Validate --restore early so we don't bother downloading + extracting if
# the file isn't there. Resolve to an absolute path because we may cd later.
if [ -n "$RESTORE_FILE" ]; then
  if [ ! -f "$RESTORE_FILE" ]; then
    echo "error: --restore file not found: $RESTORE_FILE" >&2
    exit 1
  fi
  if [ ! -r "$RESTORE_FILE" ]; then
    echo "error: --restore file not readable: $RESTORE_FILE" >&2
    exit 1
  fi
  RESTORE_FILE=$(readlink -f "$RESTORE_FILE")
fi

# --- tiny logger ---
info() { printf '  %s\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

printf '\n\033[1mprowlarr-stack bootstrap\033[0m\n'

# --- prereq check ---
info "checking prerequisites..."
for cmd in curl tar sha256sum docker findmnt; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "$cmd is required but not installed"
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  die "docker compose plugin not installed (try: pacman -S docker-compose or apt install docker-compose-plugin)"
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
  die "sqlite3 not installed (try: pacman -S sqlite or apt install sqlite3)"
fi
if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user --version >/dev/null 2>&1; then
  die "systemctl --user must work (the installer enables a user-scope unit for autostart on reboot)"
fi
ok "docker, compose, sqlite3, curl, tar, sha256sum, findmnt, systemctl --user"

# --- resolve release ---
resolve_release() {
  if [ -n "$VERSION" ]; then
    printf '%s' "$VERSION"
    return 0
  fi
  delay=2
  body=""
  for _ in 1 2 3; do
    if body=$(curl -fsSL --max-time 10 "$API_ROOT/latest" 2>/dev/null); then
      break
    fi
    sleep "$delay"
    delay=$((delay * 2))
  done
  [ -n "$body" ] || die "could not reach GitHub API at $API_ROOT/latest"
  tag=$(printf '%s' "$body" | awk -F'"' '/"tag_name":/ {print $4; exit}')
  [ -n "$tag" ] || die "unexpected GitHub API response (no tag_name)"
  printf '%s' "$tag"
}

info "resolving release..."
TAG=$(resolve_release)
ok "release: $TAG"
printf '\n\033[1m\033[36mInstalling prowlarr-stack %s\033[0m\n\n' "$TAG"

# --- prompt for install dir if not specified ---
# Asked AFTER the version banner (so the user knows what they're about to
# install) and BEFORE the existence check + download (so picking a different
# path doesn't waste a download). Skipped when:
#   - --dir or PROWLARR_STACK_DIR was set (user already chose)
#   - --yes (non-interactive)
#   - --restore (non-interactive)
#   - no controlling terminal (curl-piped without a tty available)
if [ -z "$DIR" ] && [ "$YES" -eq 0 ] && [ -z "$RESTORE_FILE" ] && { [ -t 0 ] || [ -e /dev/tty ]; }; then
  default_dir="$DEFAULT_DIR"
  info "install location"
  info "  this dir holds the stack's config, scripts, and .env (chmod 600)"
  info "  press Enter to accept the default, or type another absolute path"
  printf '  install dir [%s]: ' "$default_dir"
  if [ -t 0 ]; then
    IFS= read -r answer
  else
    IFS= read -r answer < /dev/tty
  fi
  [ -z "$answer" ] && answer="$default_dir"
  # Expand a leading ~ since `read -r` doesn't do it. Backslash-escape the
  # tildes so shellcheck doesn't think we meant them to expand (SC2088).
  case "$answer" in
    \~) answer="$HOME" ;;
    \~/*) answer="$HOME/${answer#\~/}" ;;
  esac
  case "$answer" in
    /*) ;;
    *) die "install dir must be an absolute path (got: $answer)" ;;
  esac
  DIR="$answer"
fi
# Fallback for non-interactive runs where DIR is still unset.
[ -z "$DIR" ] && DIR="$DEFAULT_DIR"

# --- install dir existence check ---
# Done AFTER the prompt so an interactive user can pick a different path
# rather than getting kicked out at "$DIR already exists".
if [ -e "$DIR" ] && [ "$FORCE" -ne 1 ]; then
  die "$DIR already exists. Run '$DIR/update' to upgrade, or pass --force to reinstall, or pick another path."
fi
if [ -e "$DIR" ] && [ "$FORCE" -eq 1 ]; then
  info "removing existing $DIR (--force)"
  rm -rf "$DIR"
fi

TARBALL="prowlarr-stack-${TAG}.tar.gz"
URL_TAR="$DL_ROOT/$TAG/$TARBALL"
URL_SUM="$DL_ROOT/$TAG/SHA256SUMS"

# --- tempdir with cleanup ---
TMPDIR_BS=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_BS"; }
trap cleanup EXIT INT TERM

# --- download ---
info "downloading tarball and SHA256SUMS..."
curl -fsSL --max-time 60 -o "$TMPDIR_BS/$TARBALL" "$URL_TAR" || die "failed to download $URL_TAR"
curl -fsSL --max-time 30 -o "$TMPDIR_BS/SHA256SUMS" "$URL_SUM" || die "failed to download $URL_SUM"
ok "downloaded"

# --- verify ---
info "verifying checksum..."
(cd "$TMPDIR_BS" && sha256sum -c SHA256SUMS >/dev/null) || die "checksum mismatch — refusing to extract"
ok "checksum verified"

# --- validate archive safety ---
info "validating archive contents..."
bad=$(tar tzf "$TMPDIR_BS/$TARBALL" | awk -v p="prowlarr-stack-${TAG}/" '
  /^\// { print "absolute path: "$0; exit }
  /\.\./ { print "parent-ref:    "$0; exit }
  $0 !~ "^"p { print "bad prefix:    "$0; exit }
  { next }
')
[ -z "$bad" ] || die "tarball rejected: $bad"
ok "archive safe"

# --- extract ---
info "extracting to $DIR..."
DIR_PARENT=$(dirname "$DIR")
mkdir -p "$DIR_PARENT"
tar xzf "$TMPDIR_BS/$TARBALL" -C "$DIR_PARENT"
mv "$DIR_PARENT/prowlarr-stack-${TAG}" "$DIR"
ok "extracted"

# --- write .version (belt + suspenders; release.yml also embeds it) ---
printf '%s\n' "$TAG" > "$DIR/.version"

# --- handoff ---
info "handing off to tarball's ./install for interactive configuration..."
cd "$DIR"
if [ -n "$RESTORE_FILE" ]; then
  # Restore mode is non-interactive (./restore --yes), so /dev/tty doesn't matter.
  exec ./install --restore "$RESTORE_FILE"
elif [ "$YES" -eq 1 ]; then
  exec ./install --non-interactive
elif [ ! -t 0 ] && [ -e /dev/tty ]; then
  # Invoked via `curl … | sh`: stdin is the curl pipe (now closed), which
  # would EOF the first interactive prompt and exit. Reattach to the
  # controlling terminal so prompts work.
  exec ./install < /dev/tty
else
  exec ./install
fi
