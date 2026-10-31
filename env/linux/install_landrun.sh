#!/usr/bin/env bash
# Install landrun (https://github.com/Zouuup/landrun), the Landlock sandbox in which both comparators build
# and check solutions on Linux, and check that this machine enforces it. Linux only; never runs sudo.
#
#   1. landrun into ~/.local/bin (or $LANDRUN_BIN_DIR):
#        - by default, the v0.1.17 release binary for x86_64 or arm64, checked against its sha256 below. It
#          is linked against glibc 2.38 or later (Ubuntu 24.04, Debian 13, Fedora 39, or later releases);
#        - with LANDRUN_FROM_SOURCE=1, built by `go install` (Go 1.24 or later) at commit 811cfff: the code
#          of v0.1.17 with the version string 0.1.18 (the other changes are tests and docs);
#   2. probe 1, Landlock is enforced: landlock is one of the active security modules, and a shell started
#      by `landrun --best-effort` cannot create a file outside the paths it was given. Both comparators run
#      landrun with --best-effort, which on a kernel without Landlock runs the command with no sandbox and
#      no error: this probe is what tells the two cases apart;
#   3. probe 2, the guard of Lean checks: `systemd-run --user` starts a transient unit that may not open
#      UNIX or IP sockets and may only make native system calls (env/check/lean_check.py runs each Lean
#      check in such a unit). SKIP_LEAN_GUARD=1 skips this probe, on a machine that only checks Rocq.
# The script fails if a probe fails. A re-run keeps an installed landrun that is the pinned one and runs
# the probes again.
#
# Requirements: curl, or Go 1.24 or later with LANDRUN_FROM_SOURCE=1; for Lean checks, systemd and a D-Bus
# session bus for your user (on Debian and Ubuntu, the package dbus-user-session).
# Usage: bash env/linux/install_landrun.sh
# Env:   LANDRUN_FROM_SOURCE=1, LANDRUN_BIN_DIR (default ~/.local/bin), SKIP_LEAN_GUARD=1
set -euo pipefail

LANDRUN_VERSION=v0.1.17
LANDRUN_REV=811cfff51ceaf3d9843708aa6d22e9b84ccac8b4
# sha256 of the two assets of the v0.1.17 release (https://github.com/Zouuup/landrun/releases/tag/v0.1.17),
# computed with sha256sum on the downloaded files; they are also the digests that GitHub's release API
# gives for these assets.
SHA256_AMD64=6ada66a06669e8994e174a7271af2db636308e55a0d6ec896cc7d326b46727f6
SHA256_ARM64=365d8c8656c732b14d70e621d972cb733e490621fb5b9c0876376bcf457dbb5d
# what `go version -m` reports for landrun built at $LANDRUN_REV: the module, its pseudo-version, and the
# hash of its source, which is the one sum.golang.org records for that version
LANDRUN_MOD="github.com/zouuup/landrun v0.1.18-0.20260723122309-811cfff51cea h1:0behenUlgmVB9+l8LLPG+Ff+m06yVjA7Rae4yJZCrhM="
# the socket families of the Lean guard (GUARD_PROPERTIES in env/check/sandbox.py)
GUARD_FAMILIES="~AF_UNIX AF_INET AF_INET6 AF_NETLINK AF_PACKET AF_VSOCK"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'install_landrun.sh: %s\n' "$*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
go_mod() { go version -m "$1" 2>/dev/null | awk '$1 == "mod" { print $2, $3, $4 }'; }
glibc_ok() {  # true when the C library is glibc 2.38 or later
  local v maj min
  v=$(getconf GNU_LIBC_VERSION 2>/dev/null) || return 1   # "glibc 2.39"
  case "$v" in "glibc "*) v=${v#glibc } ;; *) return 1 ;; esac
  maj=${v%%.*}; min=${v#*.}; min=${min%%[!0-9]*}
  case "$maj:$min" in *[!0-9:]*|:*|*:) return 1 ;; esac
  [ "$maj" -gt 2 ] || { [ "$maj" -eq 2 ] && [ "$min" -ge 38 ]; }
}

[ "$(uname -s)" = Linux ] ||
  die "Linux only. On macOS rocq-comparator sandboxes with sandbox-exec, and Lean checks run without a sandbox."
[ "$(id -u)" != 0 ] || die "do not run this as root: landrun and the checks are meant for an ordinary user"

BIN_DIR=${LANDRUN_BIN_DIR:-$HOME/.local/bin}
DEST="$BIN_DIR/landrun"
TMP_BIN=""; PROBE_DIR=""
cleanup() {
  if [ -n "$TMP_BIN" ]; then rm -f -- "$TMP_BIN"; fi
  if [ -n "$PROBE_DIR" ]; then rm -rf -- "$PROBE_DIR"; fi
}
trap cleanup EXIT
mkdir -p "$BIN_DIR"

if [ "${LANDRUN_FROM_SOURCE:-0}" = 1 ]; then
  say "landrun $LANDRUN_REV, built from source"
  command -v go >/dev/null || die "LANDRUN_FROM_SOURCE=1 needs Go 1.24 or later (https://go.dev/dl/)"
  if [ -x "$DEST" ] && [ "$(go_mod "$DEST")" = "$LANDRUN_MOD" ]; then
    echo "$DEST: already built from $LANDRUN_REV"
  else
    GOV=$(go env GOVERSION)
    GOMINOR=$(printf '%s\n' "$GOV" | sed -n 's/^go1\.\([0-9][0-9]*\).*/\1/p')
    if [ -z "$GOMINOR" ] || [ "$GOMINOR" -lt 24 ]; then
      die "LANDRUN_FROM_SOURCE=1 needs Go 1.24 or later, and this is ${GOV:-an unknown version}"
    fi
    GOBIN="$BIN_DIR" go install "github.com/zouuup/landrun/cmd/landrun@$LANDRUN_REV"
    GOT=$(go_mod "$DEST")
    [ "$GOT" = "$LANDRUN_MOD" ] || die "$DEST reports the module '$GOT', not '$LANDRUN_MOD'"
    echo "installed $DEST ($LANDRUN_MOD)"
  fi
else
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64; WANT=$SHA256_AMD64 ;;
    aarch64|arm64) ARCH=arm64; WANT=$SHA256_ARM64 ;;
    *) die "no landrun release binary for $(uname -m): run again with LANDRUN_FROM_SOURCE=1 (Go 1.24 or later)" ;;
  esac
  say "landrun $LANDRUN_VERSION, release binary for linux-$ARCH"
  if [ -f "$DEST" ] && [ "$(sha256 "$DEST")" = "$WANT" ]; then
    echo "$DEST: already the $LANDRUN_VERSION binary (sha256 checked)"
  else
    glibc_ok || die "the $LANDRUN_VERSION release binaries need glibc 2.38 or later, and this system has" \
      "$(getconf GNU_LIBC_VERSION 2>/dev/null || echo 'another C library'): run again with LANDRUN_FROM_SOURCE=1 (Go 1.24 or later)"
    command -v curl >/dev/null || die "curl not found"
    TMP_BIN=$(mktemp "$BIN_DIR/.landrun.XXXXXX")
    curl -fsSL --retry 3 -o "$TMP_BIN" \
      "https://github.com/Zouuup/landrun/releases/download/$LANDRUN_VERSION/landrun-linux-$ARCH"
    GOT=$(sha256 "$TMP_BIN")
    [ "$GOT" = "$WANT" ] || die "the sha256 of landrun-linux-$ARCH is $GOT, not $WANT: nothing installed"
    chmod 755 "$TMP_BIN"
    mv -f "$TMP_BIN" "$DEST"; TMP_BIN=""
    echo "installed $DEST (sha256 $WANT)"
  fi
fi
VERSION_LINE=$("$DEST" --version 2>&1) || die "$DEST does not run on this system: $VERSION_LINE"
echo "$VERSION_LINE"

FAILED=""
say "probe 1: Landlock is enforced (kernel $(uname -r))"
if [ -r /sys/kernel/security/lsm ]; then
  LSM=$(cat /sys/kernel/security/lsm)
  case ",$LSM," in
    *,landlock,*) echo "active security modules: $LSM" ;;
    *) echo "FAIL: landlock is not one of the active security modules ($LSM). Enable it at boot: add it to the"
       echo "  kernel parameter lsm=, e.g. lsm=landlock,$LSM, and reboot (the kernel must be built with"
       echo "  CONFIG_SECURITY_LANDLOCK=y, Linux 5.13 or later)."
       FAILED="$FAILED landlock" ;;
  esac
else
  echo "cannot read /sys/kernel/security/lsm: the write test below decides"
fi
PROBE_DIR=$(mktemp -d "$HOME/.landrun-probe.XXXXXX") || die "cannot create a probe directory in $HOME"
mkdir "$PROBE_DIR/granted"
# the control: the sandboxed shell starts and can write where it was allowed to
if OUT=$("$DEST" --best-effort --rox / --rw /dev --rw "$PROBE_DIR/granted" -- \
           sh -c 'echo x > "$1"' sh "$PROBE_DIR/granted/file" 2>&1) && [ -f "$PROBE_DIR/granted/file" ]; then
  # the probe: the same shell, given only / (read and execute) and /dev, tries to create a file in the home
  # directory. Landlock refuses with EACCES, and the shell, which landrun starts with an empty environment
  # (so in the C locale), then reports "Permission denied"
  PROBE_OUT=$("$DEST" --best-effort --rox / --rw /dev -- sh -c 'echo x > "$1"' sh "$PROBE_DIR/PROBE" 2>&1) &&
    PROBE_RC=0 || PROBE_RC=$?
  if [ -e "$PROBE_DIR/PROBE" ]; then
    echo "FAIL: a shell started by landrun --best-effort created a file outside the paths it was given:"
    echo "  this kernel does not enforce Landlock, so landrun runs commands WITHOUT a sandbox here."
    case "$FAILED" in *landlock*) ;; *) FAILED="$FAILED landlock" ;; esac
  elif [ "$PROBE_RC" != 0 ] && printf '%s\n' "$PROBE_OUT" | grep -q 'Permission denied'; then
    echo "OK: the sandboxed shell could write where it was allowed to, and was refused anywhere else"
  else
    echo "FAIL: inconclusive: the write outside the given paths neither happened nor was refused (exit $PROBE_RC):"
    echo "  $PROBE_OUT"
    case "$FAILED" in *landlock*) ;; *) FAILED="$FAILED landlock" ;; esac
  fi
else
  echo "FAIL: landrun could not run a shell that writes to a directory it was given: $OUT"
  case "$FAILED" in *landlock*) ;; *) FAILED="$FAILED landlock" ;; esac
fi

if [ "${SKIP_LEAN_GUARD:-0}" = 1 ]; then
  say "probe 2 skipped (SKIP_LEAN_GUARD=1): Lean checks will not run on this machine"
else
  say "probe 2: systemd-run --user starts the transient unit of Lean checks"
  USER_NAME=$(id -un)
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"   # the default env/check/lean_check.py uses
  if ! command -v systemd-run >/dev/null; then
    echo "FAIL: systemd-run not found: on Linux each Lean check runs in a transient systemd user unit"
    FAILED="$FAILED guard"
  elif OUT=$(systemd-run --user --quiet --wait --pipe -p "RestrictAddressFamilies=$GUARD_FAMILIES" \
               -p SystemCallArchitectures=native /bin/true 2>&1 </dev/null); then
    echo "OK: systemd-run --user accepts RestrictAddressFamilies=$GUARD_FAMILIES and SystemCallArchitectures=native"
    LINGER=$(loginctl show-user "$USER_NAME" -p Linger 2>/dev/null | sed -n 's/^Linger=//p' || true)
    if [ "$LINGER" = no ]; then
      echo "NOTE: lingering is off for $USER_NAME, so your systemd user manager runs only while you are logged in,"
      echo "  and Lean checks started without a login session (cron, some ssh commands) fail. To allow them, an"
      echo "  administrator runs once: sudo loginctl enable-linger $USER_NAME"
    fi
  else
    if [ -S "$XDG_RUNTIME_DIR/bus" ]; then BUS="present"; else BUS="missing"; fi
    echo "FAIL: systemd-run --user could not start the unit: $OUT"
    echo "  Your systemd user manager must be running, with its D-Bus session bus, and reachable through XDG_RUNTIME_DIR:"
    echo "  - an administrator runs once: sudo loginctl enable-linger $USER_NAME   (starts it at boot, without a login)"
    echo "  - in your shell: export XDG_RUNTIME_DIR=/run/user/$(id -u)   (it is unset after sudo -i or su)"
    echo "  - the bus is $XDG_RUNTIME_DIR/bus ($BUS here). On Debian and Ubuntu it comes from the package"
    echo "    dbus-user-session, missing from some minimal systems: an administrator installs it once"
    echo "    (sudo apt-get install dbus-user-session), then reboot (or, if lingering is off, log out and in again)"
    FAILED="$FAILED guard"
  fi
fi

say "landrun on PATH"
ON_PATH=$(command -v landrun || true)
if [ -z "$ON_PATH" ]; then
  echo "NOTE: $BIN_DIR is not on PATH, and both comparators find landrun through PATH. Add it, e.g. with this"
  echo "  line near the top of ~/.bashrc (before any line that returns early in non-interactive shells):"
  echo "  export PATH=\"${BIN_DIR/#"$HOME"/\$HOME}:\$PATH\""
elif [ "$(readlink -f "$ON_PATH")" = "$(readlink -f "$DEST")" ]; then
  echo "$ON_PATH"
else
  echo "WARNING: $ON_PATH comes before $DEST on PATH, so the comparators run that one:"
  echo "  $("$ON_PATH" --version 2>&1 | head -1)"
fi

[ -z "$FAILED" ] || die "failed:$FAILED (see above). landrun stays installed in $DEST; run this script again after the fix."
if [ "${SKIP_LEAN_GUARD:-0}" = 1 ]; then
  MSG="landrun is installed and Landlock is enforced (the Lean guard was not probed)"
else
  MSG="landrun is installed, Landlock is enforced, and systemd-run --user accepts the guard of Lean checks"
fi
[ -n "$ON_PATH" ] || MSG="$MSG; now add $BIN_DIR to PATH (see the note above)"
echo "Done: $MSG."
