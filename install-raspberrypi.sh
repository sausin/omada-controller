#!/bin/bash
#
# install-raspberrypi.sh
# ------------------------------------------------------------------------------
# Raspberry Pi (Raspberry Pi OS / Raspbian, 64-bit) prerequisite installer and
# launcher for the TP-Link Omada Network Application (Linux tar/gz package).
#
# The stock install.sh assumes Java 17, jsvc, curl and a MongoDB server are
# ALREADY installed on the system -- it only checks for them and exits if any is
# missing. On a fresh Raspberry Pi none of those are present, and MongoDB in
# particular has hard architecture / CPU constraints on the Pi. This wrapper
# installs and verifies each prerequisite the correct way for a Pi, then hands
# off to the stock TP-Link install.sh to do the actual Omada installation.
#
# What it handles that a plain apt install would get wrong:
#   * Refuses to run on a 32-bit OS  -> MongoDB ships no 32-bit ARM packages.
#   * Installs the MongoDB GPG signing key FIRST, then adds the official Debian
#     arm64 repo (component 'main'). On Debian 13 (trixie) it points the repo at
#     the 'bookworm' codename, because MongoDB hasn't published a trixie server
#     component yet -- the bookworm packages run correctly on trixie.
#   * Picks a MongoDB source + version the CPU can actually run:
#       - Pi 5 / Cortex-A76 (ARMv8.2, has LSE 'atomics') -> official apt, MongoDB 8.0
#       - Pi 4 / Pi 3 / Cortex-A72/A53 (ARMv8.0, no LSE) -> UNOFFICIAL modern MongoDB
#         (7.0) from themattman/mongodb-raspberrypi-binaries, which is patched to run
#         on ARMv8.0. Official apt on these boards can only give EOL 4.4 -- available
#         via MONGO_SOURCE=apt. (Official MongoDB 5.0+ aborts with "Illegal
#         instruction" on ARMv8.0 cores.)
#   * Picks the right Java for the OS: openjdk-17 on bullseye/bookworm, openjdk-21
#     on trixie (Omada needs Java 17+, verified after install), and exports
#     JAVA_HOME so install.sh's jsvc check stays quiet.
#   * Installs the runtime libraries the Pi builds need, verified by running mongod:
#     the Pi 5 apt path uses libssl3 (nothing extra). The Pi 4 themattman builds are
#     linked against OpenSSL 1.1 and GCC 11+ libstdc++, so on bookworm/trixie the
#     script auto-installs libssl1.1 (libcrypto.so.1.1) and, if needed, a newer
#     libstdc++ -- looping until mongod actually executes.
#   * Disables the redundant system mongod service (Omada runs its own instance
#     on port 27217 with dbpath data/db, per properties/omada.properties).
#
# SD-card longevity / read-only root:
#   * Before doing anything it checks whether the root filesystem is read-only or
#     overlay-protected, and stops with instructions if so (installing needs a
#     writable root).
#   * It offers to place Omada's writable data (data/, logs/, work/) on a
#     separate disk/partition you choose, and symlinks it back in. That both
#     spares the SD card MongoDB's constant writes AND leaves zero runtime writes
#     under /opt/tplink -- so you can safely re-enable a read-only/overlay root
#     afterwards and Omada keeps working.
#
# Usage:
#   sudo bash install-raspberrypi.sh                     # interactive: asks the questions below
#   sudo bash install-raspberrypi.sh -y                  # non-interactive (needs --data-dir if relocating)
#   sudo bash install-raspberrypi.sh --data-dir /mnt/ssd/omada   # put data on this path (symlinked)
#   sudo bash install-raspberrypi.sh --profile oc200     # size memory to a TP-Link model
#   sudo bash install-raspberrypi.sh --fast-start        # also enable AppCDS faster-boot (Java 19+)
#   sudo bash install-raspberrypi.sh --deps-only         # install/verify prerequisites only
#   sudo bash install-raspberrypi.sh --relocate-only --data-dir /mnt/ssd/omada
#                                                        # move an EXISTING install's data; no (re)install
#   sudo bash install-raspberrypi.sh --optimize-only     # add AppCDS faster-boot to an EXISTING install
#   sudo bash install-raspberrypi.sh --profile-only --profile oc300
#                                                        # (re)size an EXISTING install's memory
#   sudo bash install-raspberrypi.sh --verbose           # stream all output instead of the clean checklist
#
# Output: quiet by default -- a live checklist on the terminal, everything else to
#   a log (/var/log/omada-rpi-install.log, or /tmp if that's not writable). On any
#   failure the last log lines are shown. `--verbose`/-v streams raw output.
#   sudo bash install-raspberrypi.sh init-cluster-mode   # passed through to install.sh
#
# Memory profiles (--profile / interactive prompt): size MongoDB's cache + the JVM
# heap to a TP-Link controller model. The board's RAM sets the CEILING; you may pick
# that model or a SMALLER one, never a bigger one than the RAM backs:
#     nano  (~handful, 1 GB) · oc200 (~130) · oc300 (~700) · oc400 (~1,310, 8 GB)
#     auto = the ceiling (default) · none = stock, no caps
#
# Overrides (environment variables):
#   MONGO_VERSION=x.y     Force a MongoDB version/series instead of auto-detecting
#                         (Pi 5: 8.0/7.0 via apt; Pi 4: 7.0/6.0 via themattman, or 4.4).
#   MONGO_SOURCE=apt|themattman   Force the MongoDB source. On a Pi 4, 'apt' means
#                         official EOL 4.4; 'themattman' means unofficial modern builds.
#   JAVA_PKG=...          Override the JRE package (else auto: openjdk-21 on trixie,
#                         openjdk-17 on bookworm/bullseye).
#   OMADA_DATA_DIR=PATH   Same as --data-dir PATH.
#   OMADA_PROFILE=NAME    Same as --profile NAME.  FORCE_PROFILE=1 lifts the ceiling.
#
# Assumes: Raspberry Pi OS / Raspbian (Debian bullseye, bookworm or trixie), 64-bit (arm64).
# Version-agnostic: works with any Omada Linux tar/gz release (tested against
# v5.x/v6.x). Run from inside the extracted Omada package directory (next to
# the stock install.sh).
# ------------------------------------------------------------------------------

set -o pipefail

# --- output / TUI -------------------------------------------------------------
# Quiet by default: noisy work streams to a log; the terminal shows a live
# checklist. `--verbose` streams everything. Non-TTY prints plain static lines.
VERBOSE=0
if [ -t 1 ]; then TTY=1; else TTY=0; fi
if [ "$TTY" = 1 ]; then
    RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[36m'; DIM=$'\e[2m'; BOLD=$'\e[1m'; RST=$'\e[0m'
else
    RED=''; GRN=''; YLW=''; BLU=''; DIM=''; BOLD=''; RST=''
fi
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]*) SPIN='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; OKM='✔'; FAILM='✖'; DOTM='•' ;;
    *)              SPIN='|/-\';         OKM='OK'; FAILM='x'; DOTM='-' ;;
esac

LOG="${OMADA_LOG:-/var/log/omada-rpi-install.log}"
( : >"$LOG" ) 2>/dev/null || LOG="/tmp/omada-rpi-install.log"
( : >"$LOG" ) 2>/dev/null || LOG="/dev/null"

log(){  printf '%s\n' "$*" >>"$LOG" 2>/dev/null || true; }
say(){  printf '%b\n' "$*"; }                                          # intentional terminal line
info(){ if [ "$VERBOSE" = 1 ]; then printf '  %s%s%s %s\n' "$BLU" "$DOTM" "$RST" "$*"; else log "[info] $*"; fi; }
ok(){   if [ "$VERBOSE" = 1 ]; then printf '  %s%s%s %s\n' "$GRN" "$OKM"  "$RST" "$*"; else log "[ok] $*"; fi; }
warn(){ printf '  %s!%s %s\n' "$YLW" "$RST" "$*" >&2; log "[warn] $*"; }
die(){  printf '\n  %s%s%s %s\n' "$RED" "$FAILM" "$RST" "$*" >&2; log "[die] $*"; exit 1; }

STEP=0; STEP_TOTAL=0
_lbl(){ if [ "$STEP_TOTAL" -gt 0 ]; then printf '[%d/%d] %s' "$STEP" "$STEP_TOTAL" "$1"; else printf '%s' "$1"; fi; }
_clr(){ [ "$TTY" = 1 ] && printf '\r\033[K'; }
_okline(){   _clr; printf '  %s%s%s %s\n' "$GRN" "$OKM" "$RST" "$1"; }
_failline(){
    _clr; printf '  %s%s%s %s\n\n' "$RED" "$FAILM" "$RST" "$1" >&2
    printf '  %sInstall failed.%s Last lines of the log:\n' "$RED" "$RST" >&2
    tail -n 20 "$LOG" 2>/dev/null | sed 's/^/      /' >&2
    printf '  Full log: %s\n\n' "$LOG" >&2
    exit 1
}
_spin(){
    local pid="$1" label="$2" start="$3" i=0 n f el; n=${#SPIN}
    while kill -0 "$pid" 2>/dev/null; do
        f="${SPIN:i++%n:1}"; el=$((SECONDS-start))
        printf '\r  %s%s%s %s … %02d:%02d ' "$BLU" "$f" "$RST" "$label" $((el/60)) $((el%60))
        sleep 0.1
    done
}
# run_spin LABEL cmd...  -- long/external step; ALL output to log; spinner on TTY.
run_spin(){
    local label="$1"; shift; STEP=$((STEP+1)); local lbl rc; lbl="$(_lbl "$label")"
    if [ "$VERBOSE" = 1 ]; then say "  ${BLU}${DOTM}${RST} ${lbl} …"; "$@"; rc=$?
        [ $rc -eq 0 ] && _okline "$lbl" || _failline "$lbl"; return 0; fi
    if [ "$TTY" != 1 ]; then printf '  %s %s … ' "$DOTM" "$lbl"; "$@" >>"$LOG" 2>&1; rc=$?
        [ $rc -eq 0 ] && printf 'done\n' || { printf 'FAILED\n'; _failline "$lbl"; }; return 0; fi
    "$@" >>"$LOG" 2>&1 & local pid=$! start=$SECONDS
    _spin "$pid" "$lbl" "$start"; wait "$pid"; rc=$?
    [ $rc -eq 0 ] && _okline "$lbl" || _failline "$lbl"
}
# run_task LABEL func  -- fast func that may set globals; foreground (globals kept);
# stdout -> log (quiet), stderr (warn/die) stays visible.
run_task(){
    local label="$1" fn="$2"; STEP=$((STEP+1)); local lbl; lbl="$(_lbl "$label")"
    if [ "$VERBOSE" = 1 ]; then say "  ${BLU}${DOTM}${RST} ${lbl} …"; "$fn"; _okline "$lbl"; return 0; fi
    if "$fn" >>"$LOG"; then _okline "$lbl"; else _failline "$lbl"; fi
}
render_header(){
    say ""
    say "  ${BOLD}${BLU}Omada Controller${RST}${BOLD} · Raspberry Pi setup${RST}"
    say "  ${DIM}────────────────────────────────────────────${RST}"
}
render_context(){
    printf '  %s%-9s%s %s\n' "$DIM" "Board"   "$RST" "${MODEL:-unknown}"
    printf '  %s%-9s%s %s (%s)\n' "$DIM" "OS"  "$RST" "${PRETTY_NAME:-unknown}" "${OS_CODENAME:-?}"
    printf '  %s%-9s%s %s MB  (ceiling: %s)\n' "$DIM" "Memory" "$RST" "${RAM_MB:-?}" "$(ram_ceiling "${RAM_MB:-0}")"
    if [ "${MONGO_SOURCE:-}" = "themattman" ]; then
        printf '  %s%-9s%s %s  via  themattman %s(unofficial ARMv8.0 build)%s\n' "$DIM" "MongoDB" "$RST" "${MONGO_VERSION:-?}" "$DIM" "$RST"
    else
        printf '  %s%-9s%s %s  via  %s\n' "$DIM" "MongoDB" "$RST" "${MONGO_VERSION:-?}" "${MONGO_SOURCE:-?}"
    fi
}
render_summary(){
    local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"; [ -n "$ip" ] || ip="<pi-ip>"
    say ""
    say "  ${GRN}${OKM} Setup complete${RST}"
    say "  ${DIM}────────────────────────────────────────────${RST}"
    printf '  %s%-9s%s sudo tpeap start|stop|status\n' "$DIM" "Manage" "$RST"
    printf '  %s%-9s%s https://%s:8043\n' "$DIM" "Web UI" "$RST" "$ip"
    printf '  %s%-9s%s %s\n' "$DIM" "Profile" "$RST" "${PROFILE:-stock}"
    [ "${RELOCATE:-0}" = 1 ] && printf '  %s%-9s%s %s\n' "$DIM" "Data" "$RST" "$DATA_DEST"
    printf '  %s%-9s%s %s\n' "$DIM" "Log" "$RST" "$LOG"
    say ""
}

# --- argument parsing ---------------------------------------------------------
DEPS_ONLY=0
RELOCATE_ONLY=0
OPTIMIZE_ONLY=0
PROFILE_ONLY=0
FAST_START="${FAST_START:-0}"
PROFILE_ARG="${OMADA_PROFILE:-}"
NEEDS_RESTART=0
ASSUME_YES=0
DATA_DIR_ARG="${OMADA_DATA_DIR:-}"
INSTALL_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --deps-only)        DEPS_ONLY=1 ;;
        --relocate-only)    RELOCATE_ONLY=1 ;;
        --fast-start)       FAST_START=1 ;;
        --optimize-only)    OPTIMIZE_ONLY=1; FAST_START=1 ;;
        --profile-only)     PROFILE_ONLY=1 ;;
        --profile)          if [ $# -ge 2 ]; then shift; PROFILE_ARG="$1"; else warn "--profile needs a value"; fi ;;
        --profile=*)        PROFILE_ARG="${1#*=}" ;;
        --data-dir)         if [ $# -ge 2 ]; then shift; DATA_DIR_ARG="$1"; else warn "--data-dir needs a path"; fi ;;
        --data-dir=*)       DATA_DIR_ARG="${1#*=}" ;;
        --verbose|-v)       VERBOSE=1 ;;
        --quiet|-q)         VERBOSE=0 ;;
        -y|-Y)              ASSUME_YES=1; INSTALL_ARGS+=("-y") ;;
        init-cluster-mode)  INSTALL_ARGS+=("init-cluster-mode") ;;
        -h|--help)          sed -n '3,87p' "$0" | sed 's/^#\s\{0,1\}//'; exit 0 ;;
        *)                  warn "Unknown argument '$1' ignored." ;;
    esac
    shift
done

# --- root ---------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "This script must be run as root. Try: sudo bash $0"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
INSTALL_BASE="/opt/tplink/EAPController"
OMADA_CTL="${INSTALL_BASE}/bin/control.sh"

# --- architecture gate --------------------------------------------------------
ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
MACHINE="$(uname -m)"
info "Userland architecture : ${ARCH}  (kernel: ${MACHINE})"
if [ "$ARCH" != "arm64" ] || [ "$MACHINE" != "aarch64" ]; then
    warn "This is not a 64-bit (arm64/aarch64) system."
    warn "MongoDB provides no packages for 32-bit ARM (armhf), so the Omada"
    warn "Application cannot run here. If your Pi is a 3/4/5, re-flash the"
    warn "64-bit Raspberry Pi OS image and run this script again."
    die  "64-bit Raspberry Pi OS required. Aborting."
fi

# --- OS + board detection -----------------------------------------------------
# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || true
OS_CODENAME="${VERSION_CODENAME:-}"
info "Operating system      : ${PRETTY_NAME:-unknown}  (codename: ${OS_CODENAME:-unknown})"

MODEL="$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || echo unknown)"
info "Board                 : ${MODEL}"

# ARMv8.2-A (Cortex-A76 / Pi 5) exposes LSE atomics as the 'atomics' CPU feature.
# ARMv8.0-A (Cortex-A72 / A53, i.e. Pi 4 and earlier) do not. MongoDB 5.0+ hard-
# requires ARMv8.2-A (per MongoDB production notes), so the 'atomics' flag is a
# reliable gate for which MongoDB series will actually run on this board.
if grep -qiw atomics /proc/cpuinfo 2>/dev/null; then
    CPU_V82=1
    info "CPU capability        : ARMv8.2 (LSE atomics present) -> MongoDB 5.0+ safe"
else
    CPU_V82=0
    info "CPU capability        : ARMv8.0 (no LSE atomics)       -> MongoDB 4.4 only"
fi

RAM_MB="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"; [ -n "$RAM_MB" ] || RAM_MB=0

# --- choose MongoDB source + version ------------------------------------------
# Pi 5 (ARMv8.2): official MongoDB Debian apt repo, modern (8.0).
# Pi 4/3 (ARMv8.0): official apt can only run EOL 4.4. The community project
#   themattman/mongodb-raspberrypi-binaries publishes unofficial *modern* MongoDB
#   builds patched to run on ARMv8.0, so that's the default here -- override with
#   MONGO_SOURCE=apt (official EOL 4.4) if you prefer.
# Env: MONGO_SOURCE=apt|themattman, MONGO_VERSION=<x.y>.
MONGO_SOURCE="${MONGO_SOURCE:-}"
if [ "$CPU_V82" -eq 1 ]; then
    MONGO_SOURCE="${MONGO_SOURCE:-apt}"
    MONGO_VERSION="${MONGO_VERSION:-8.0}"
    info "MongoDB               : ${MONGO_VERSION} via official Debian apt repo"
else
    if [ "${MONGO_SOURCE:-}" = "apt" ] || { [ -n "${MONGO_VERSION:-}" ] && [ "${MONGO_VERSION%%.*}" -lt 5 ] 2>/dev/null; }; then
        MONGO_SOURCE="apt"
        MONGO_VERSION="4.4"
        info "ARMv8.0 CPU + official apt -> MongoDB 4.4 (EOL; needs libssl1.1 on Debian 12/13)."
    else
        MONGO_SOURCE="themattman"
        MONGO_VERSION="${MONGO_VERSION:-7.0}"
        info "ARMv8.0 CPU (Pi 4/3): official 5.0+ won't run; using unofficial themattman ${MONGO_VERSION}.x."
    fi
fi
MONGO_MAJOR="${MONGO_VERSION%%.*}"

# --- helpers ------------------------------------------------------------------
mongo_repo_codename() {
    # MongoDB's official Debian apt repo DOES ship arm64 packages. The catch on
    # Debian 13 (trixie): MongoDB has not published a 'trixie' server component
    # yet (the trixie path only carries mongodb-mongosh), so trixie must point at
    # the 'bookworm' component -- those server packages run fine on trixie.
    #   modern (5.0+): bullseye->bullseye, bookworm->bookworm, trixie->bookworm
    #   legacy (4.4) : lives under 'buster' (and links libssl1.1)
    local v="$1"
    if [ "$v" = "4.4" ]; then
        echo "buster"; return
    fi
    case "$OS_CODENAME" in
        bullseye) echo "bullseye" ;;
        bookworm) echo "bookworm" ;;
        trixie)   echo "bookworm" ;;   # trixie server pkgs not published; bookworm works
        *)        echo "bookworm" ;;   # forward-compatible default
    esac
}

# Both the official MongoDB 4.4 build AND the themattman modern Pi builds are
# linked against OpenSSL 1.1 (libcrypto.so.1.1 / libssl.so.1.1). Bullseye still
# ships libssl1.1; bookworm (12) and trixie (13) dropped it for libssl3 -- so on
# those we install it back. (The official Pi 5 apt path uses libssl3 and never
# calls this.) Auto-discovers the newest libssl1.1 arm64 .deb from the pool.
ensure_libssl11() {
    if dpkg -s libssl1.1 >/dev/null 2>&1; then
        ok "libssl1.1 already present (provides libcrypto.so.1.1 + libssl.so.1.1)."
        return 0
    fi
    info "Installing libssl1.1 (provides libcrypto.so.1.1 + libssl.so.1.1)..."
    if apt-get install -y libssl1.1 >/dev/null 2>&1; then
        ok "Installed libssl1.1 from the configured apt sources."
        return 0
    fi
    # Fallback: newest libssl1.1 arm64 .deb from the Debian security pool.
    local base="http://security.debian.org/debian-security/pool/updates/main/o/openssl"
    local deb
    deb="$(curl -fsSL "${base}/" 2>/dev/null | grep -oE 'libssl1\.1_[^"]+_arm64\.deb' | sort -V | tail -n1)"
    [ -n "$deb" ] || die "Couldn't find a libssl1.1 arm64 package in the Debian pool. Install libssl1.1 (provides libcrypto.so.1.1) manually, then re-run. Browse: ${base}/"
    info "Fetching ${deb} from the Debian security pool..."
    if curl -fSL -o "/tmp/${deb}" "${base}/${deb}"; then
        dpkg -i "/tmp/${deb}" >/dev/null 2>&1 || apt-get -f install -y >/dev/null 2>&1 || true
        rm -f "/tmp/${deb}"
    fi
    dpkg -s libssl1.1 >/dev/null 2>&1 \
        || die "Could not install libssl1.1 automatically (needed for libcrypto.so.1.1). Download a libssl1.1 arm64 .deb and 'dpkg -i' it, then re-run. Browse: ${base}/"
    ok "Installed libssl1.1 from the Debian security pool."
}

# Omada needs Java 17+. The right package differs per OS: bookworm/bullseye ship
# openjdk-17, trixie (Debian 13) ships openjdk-21 (no openjdk-17). Pick the first
# candidate that apt can actually install, honouring a JAVA_PKG override.
pick_java_pkg() {
    if [ -n "${JAVA_PKG:-}" ]; then echo "$JAVA_PKG"; return; fi
    local c cand
    for c in openjdk-21-jre-headless openjdk-17-jre-headless default-jre-headless; do
        cand="$(apt-cache policy "$c" 2>/dev/null | awk '/Candidate:/{print $2}')"
        if [ -n "$cand" ] && [ "$cand" != "(none)" ]; then echo "$c"; return; fi
    done
    echo "default-jre-headless"   # last-resort; OS default JRE (>=17 on supported releases)
}

# --- install base packages ----------------------------------------------------
install_base_packages() {
    info "Updating apt package index..."
    apt-get update -y || die "'apt-get update' failed."

    local java_pkg; java_pkg="$(pick_java_pkg)"
    info "Installing ${java_pkg}, jsvc, curl, gnupg, ca-certificates..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        "$java_pkg" jsvc curl gnupg ca-certificates \
        || die "Failed to install base packages (${java_pkg}, jsvc, curl)."

    command -v java  >/dev/null 2>&1 || die "java not found after install."
    command -v jsvc  >/dev/null 2>&1 || die "jsvc not found after install."
    command -v curl  >/dev/null 2>&1 || die "curl not found after install."

    # Omada (v5.15.20+) requires Java 17 or newer -- verify the installed JRE.
    local jmajor
    jmajor="$(java -version 2>&1 | awk -F'"' '/version/{print $2}' | cut -d. -f1)"
    if [ -n "$jmajor" ] && [ "$jmajor" -lt 17 ] 2>/dev/null; then
        die "Installed Java is version ${jmajor}; Omada requires 17+. Set JAVA_PKG to a 17+ JRE."
    fi
    ok "Java: $(java -version 2>&1 | head -n1)"
    ok "jsvc: $(command -v jsvc)"
    ok "curl: $(command -v curl)"
}

# --- install MongoDB (official Debian apt repo) -------------------------------
install_mongodb_apt() {
    local codename keyring listfile
    codename="$(mongo_repo_codename "$MONGO_VERSION")"
    keyring="/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg"
    listfile="/etc/apt/sources.list.d/mongodb-org-${MONGO_VERSION}.list"
    info "Configuring MongoDB ${MONGO_VERSION} apt repo (debian ${codename}, arm64)..."

    # STEP 1: import the signing key FIRST. Without a trusted key the repo's
    # 'apt-get update' fails with NO_PUBKEY, so this must precede the list file.
    command -v gpg >/dev/null 2>&1 || die "gpg missing; base packages must install first."
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL "https://pgp.mongodb.com/server-${MONGO_VERSION}.asc" \
        | gpg --dearmor --yes -o "$keyring" \
        || die "Failed to fetch/dearmor the MongoDB ${MONGO_VERSION} signing key."
    chmod 0644 "$keyring"
    [ -s "$keyring" ] || die "MongoDB signing key ${keyring} is empty; aborting."
    ok "Imported MongoDB ${MONGO_VERSION} signing key -> ${keyring}"

    # STEP 2: add the Debian repo (component 'main'), signed by that key.
    echo "deb [ signed-by=${keyring} arch=arm64 ] https://repo.mongodb.org/apt/debian ${codename}/mongodb-org/${MONGO_VERSION} main" \
        > "$listfile"
    ok "Added repo -> ${listfile}"

    # STEP 3: legacy 4.4 only needs libssl1.1; modern MongoDB uses libssl3.
    [ "$MONGO_VERSION" = "4.4" ] && ensure_libssl11

    apt-get update -y || die "'apt-get update' failed after adding the MongoDB repo (check the key/codename)."
    DEBIAN_FRONTEND=noninteractive apt-get install -y mongodb-org-server \
        || die "Failed to install mongodb-org-server ${MONGO_VERSION}. If this is a Pi 4/3, the CPU can't run 5.0+; use MONGO_SOURCE=themattman (modern) or MONGO_VERSION=4.4."

    # Confirm the binary actually executes on this CPU. On a Pi 5 (ARMv8.2) it does;
    # an ARMv8.0 board forced onto a 5.0+ package would fail with 'Illegal instruction'
    # here rather than silently later when Omada tries to start mongod.
    mongod --version >/dev/null 2>&1 \
        || die "mongod installed but won't run on this CPU: $(LC_ALL=C mongod --version 2>&1 | head -n1). For an ARMv8.0 board use MONGO_SOURCE=themattman or MONGO_VERSION=4.4."
    ok "Installed: $(mongod --version 2>/dev/null | head -n1)"

    # Omada starts and manages its OWN mongod (properties/omada.properties: port
    # 27217, dbpath ../data/db). The distro mongod.service would run a second,
    # unused instance on 27017 -- disable it to save memory.
    if systemctl list-unit-files 2>/dev/null | grep -q '^mongod\.service'; then
        systemctl disable --now mongod >/dev/null 2>&1 || true
        ok "Disabled the standalone system mongod.service (Omada runs its own)."
    fi
}

# The themattman mongod binary is built with GCC 11+ and needs a matching
# libstdc++ (GLIBCXX_3.4.29+). Bookworm (GCC 12) and trixie ship a new enough
# one already; older releases (bullseye, GCC 10) do not. This fetches themattman's
# prebuilt libstdc++ and points the system libstdc++.so.6 at it. A newer libstdc++
# is backward-compatible, so other software keeps working; the original target is
# recorded so the uninstaller can restore it.
install_themattman_libstdcxx() {
    local api="https://api.github.com/repos/themattman/raspberrypi-binaries/contents/libstdc%2B%2B"
    info "Looking up a prebuilt libstdc++ (GCC 11+) on GitHub..."
    local url
    url="$(curl -fsSL "$api" 2>/dev/null \
        | grep -oE '"download_url":[[:space:]]*"[^"]*libstdc\+\+\.so\.6\.0\.[0-9]+"' \
        | sed -E 's/.*"(https[^"]+)"/\1/' | sort -V | tail -n1)"
    [ -n "$url" ] || die "Couldn't find a prebuilt libstdc++ in themattman/raspberrypi-binaries; install a GCC 11+ libstdc++ manually, then re-run."

    local name="${url##*/}"
    install -d -m 0755 /usr/local/lib64
    info "Downloading ${name} ..."
    curl -fSL -o "/usr/local/lib64/${name}" "$url" || die "Failed to download ${name}."
    chmod 0755 "/usr/local/lib64/${name}"

    local target="/lib/aarch64-linux-gnu/libstdc++.so.6" orig
    orig="$(readlink -f "$target" 2>/dev/null)"
    [ -n "$orig" ] && printf '%s\n' "$orig" > /usr/local/lib64/.omada-libstdcxx-original
    ln -sf "/usr/local/lib64/${name}" "$target"
    ldconfig 2>/dev/null || true
    ok "Installed ${name} and repointed ${target} (original recorded for uninstall)."
}

# --- install MongoDB (unofficial Pi builds for ARMv8.0 / Pi 4) ----------------
# Uses themattman/mongodb-raspberrypi-binaries: modern MongoDB compiled to run on
# the Pi 4's ARMv8.0 CPU (which official 5.0+ refuses). Raw binaries, no apt.
install_mongodb_themattman() {
    local series="${1:-7.0}"
    warn "Installing UNOFFICIAL MongoDB (themattman/mongodb-raspberrypi-binaries)."
    warn "These are best-effort community builds that run modern MongoDB on ARMv8.0;"
    warn "they are NOT supported by MongoDB Inc. Review the project before relying on it."

    local repo="themattman/mongodb-raspberrypi-binaries"
    local api="https://api.github.com/repos/${repo}/releases?per_page=100"
    local esc="${series//./\\.}"
    info "Finding the latest ${series}.x Pi build on GitHub..."
    local url
    url="$(curl -fsSL "$api" 2>/dev/null \
        | grep -oE 'https://[^"]+/mongodb\.ce\.pi4\.r'"${esc}"'\.[0-9]+\.tar\.gz' \
        | head -n1)"
    [ -n "$url" ] || die "No ${series}.x pi4 build found. See https://github.com/${repo}/releases and set MONGO_VERSION to an available series (e.g. 6.0/7.0), or use MONGO_SOURCE=apt for official 4.4."

    local tgz="/tmp/mongodb-pi.$$.tgz" tmpd="/tmp/mongodb-pi.$$.d"
    info "Downloading ${url##*/} ..."
    curl -fSL -o "$tgz" "$url" || die "Download failed: ${url}"
    mkdir -p "$tmpd"
    tar xzf "$tgz" -C "$tmpd" || die "Could not extract ${tgz}."

    install -d -m 0755 /usr/local/bin
    local b f got=0
    for b in mongod mongos mongosh; do
        f="$(find "$tmpd" -type f -name "$b" 2>/dev/null | head -n1)"
        [ -n "$f" ] && { install -m 0755 "$f" "/usr/local/bin/$b"; [ "$b" = mongod ] && got=1; }
    done
    rm -rf "$tgz" "$tmpd"
    [ "$got" -eq 1 ] || die "The downloaded archive had no 'mongod' binary."

    hash -r 2>/dev/null || true
    command -v mongod >/dev/null 2>&1 || die "mongod not on PATH after install (check /usr/local/bin)."

    # Verify it actually runs, applying library shims as the loader reports them.
    # The Pi builds can need BOTH a newer libstdc++ (GLIBCXX_3.4.29+, GCC 11) AND
    # OpenSSL 1.1 (libcrypto.so.1.1) -- and the loader only reports one missing lib
    # at a time, so we loop: fix whatever the current error names, then re-check.
    # Bookworm/trixie ship a new-enough libstdc++, but still need libssl1.1 for the
    # themattman builds. A Pi 5 (official apt path) never gets here.
    local tries=0 err
    while ! mongod --version >/dev/null 2>&1; do
        tries=$((tries + 1))
        [ "$tries" -gt 4 ] && die "mongod still won't run after library fixes: $(LC_ALL=C mongod --version 2>&1 | head -n1). Check: ldd \$(command -v mongod)"
        err="$(LC_ALL=C mongod --version 2>&1 || true)"
        if printf '%s' "$err" | grep -qiE 'GLIBCXX|libstdc\+\+'; then
            warn "mongod needs a newer libstdc++ than this OS ships; applying the libstdc++ fix..."
            install_themattman_libstdcxx
        elif printf '%s' "$err" | grep -qiE 'libcrypto\.so\.1\.1|libssl\.so\.1\.1'; then
            warn "mongod is linked against OpenSSL 1.1 (libcrypto.so.1.1), absent on this OS..."
            ensure_libssl11
        else
            die "Installed mongod won't execute: $(printf '%s' "$err" | head -n1). Check: ldd \$(command -v mongod)"
        fi
    done
    ok "Installed unofficial $(mongod --version 2>/dev/null | head -n1) -> /usr/local/bin/mongod"
    # No apt package/service here, so nothing to disable.
}

# --- install MongoDB (dispatch) -----------------------------------------------
install_mongodb() {
    if command -v mongod >/dev/null 2>&1; then
        local cur
        cur="$(mongod --version 2>/dev/null | grep -oP 'db version v\K[0-9]+\.[0-9]+\.[0-9]+' || echo unknown)"
        ok "mongod already installed (v${cur}); leaving it as-is."
        return 0
    fi
    case "$MONGO_SOURCE" in
        themattman) install_mongodb_themattman "$MONGO_VERSION" ;;
        *)          install_mongodb_apt ;;
    esac
}

# --- read-only root pre-check -------------------------------------------------
is_root_readonly() {
    # 0 = root looks read-only or overlay-backed; 1 = writable
    local fstype opts line
    line="$(awk '$2=="/"{print $3"|"$4; exit}' /proc/mounts 2>/dev/null)"
    fstype="${line%%|*}"; opts="${line#*|}"
    [ "$fstype" = "overlay" ] && return 0
    case ",${opts}," in *,ro,*) return 0 ;; esac
    # active probe: if we can't create a file on /, it's effectively read-only
    ( : > /.omada_rwprobe.$$ ) 2>/dev/null || return 0
    rm -f /.omada_rwprobe.$$ 2>/dev/null
    return 1
}

readonly_instructions() {
    cat >&2 <<'EOF'

  Omada's installation writes packages and files to the ROOT filesystem, so the
  root must be WRITABLE right now. If you use the read-only / overlay filesystem
  feature, disable it first:

    sudo raspi-config
      -> Performance Options -> Overlay File System -> disable -> reboot

  (or, for a temporary remount:  sudo mount -o remount,rw / )

  Then run this installer again. You can re-enable the read-only/overlay root
  AFTER installation -- this installer puts all of Omada's writable data on a
  separate path via symlinks, so a read-only root will not stop Omada running.

EOF
}

readonly_precheck() {
    if is_root_readonly; then
        readonly_instructions
        die "Root filesystem is read-only/overlay. Make it writable, then re-run."
    fi
    if [ "$ASSUME_YES" -eq 0 ]; then
        say ""
        say "  ${BOLD}Root filesystem${RST} ${DIM}— installation writes to it${RST}"
        read -r -p "  Is your root read-only / overlay-protected? (y/N): " ans
        case "${ans^^}" in
            Y|YES) readonly_instructions
                   die "Please make the root filesystem writable, then re-run." ;;
        esac
    fi
    ok "Root filesystem is writable -- proceeding."
}

# --- data location (SD-card longevity / read-only root) -----------------------
RELOCATE=0
DATA_DEST=""
resolve_data_dir() {
    local d="$DATA_DIR_ARG"
    if [ -z "$d" ] && [ "$ASSUME_YES" -eq 0 ] && [ "$RELOCATE_ONLY" -eq 0 ]; then
        say ""
        say "  ${BOLD}Data location${RST} ${DIM}— spare the SD card / enable read-only root${RST}"
        say "  ${DIM}Put the database + logs on a USB SSD or separate partition (symlinked in).${RST}"
        read -r -p "  Path for Omada data, or Enter to keep it on the SD card: " d
    fi

    if [ -z "$d" ]; then
        [ "$RELOCATE_ONLY" -eq 1 ] && die "--relocate-only requires --data-dir PATH (or OMADA_DATA_DIR)."
        RELOCATE=0
        info "Data will stay under ${INSTALL_BASE} (no relocation)."
        return
    fi

    case "$d" in /*) : ;; *) die "Data path must be absolute (got '$d')." ;; esac
    mkdir -p "$d" || die "Could not create data path '$d'."
    [ -w "$d" ] || die "Data path '$d' is not writable."
    DATA_DEST="${d%/}"
    RELOCATE=1

    # Same filesystem as / ? Then it won't survive a read-only root or spare the card.
    local dev_root dev_dest
    dev_root="$(stat -c %d / 2>/dev/null)"
    dev_dest="$(stat -c %d "$DATA_DEST" 2>/dev/null)"
    if [ -n "$dev_root" ] && [ "$dev_root" = "$dev_dest" ]; then
        warn "'${DATA_DEST}' is on the SAME filesystem as / (root)."
        warn "For SD longevity and read-only-root operation it must be a SEPARATE"
        warn "disk/partition, mounted at boot via /etc/fstab (before Omada starts)."
        if [ "$ASSUME_YES" -eq 0 ]; then
            read -r -p "Continue anyway? (y/N): " c
            case "${c^^}" in Y|YES) : ;; *) die "Aborted. Pick a path on a separate writable disk." ;; esac
        fi
    else
        ok "Data location: ${DATA_DEST} (separate from the root filesystem)."
        warn "Make sure ${DATA_DEST}'s mount is in /etc/fstab so it mounts at boot,"
        warn "otherwise the symlinks will dangle and Omada won't start."
    fi
}

relocate_omada_data() {
    [ "$RELOCATE" -eq 1 ] || return 0
    [ -d "$INSTALL_BASE" ] || die "Omada is not installed at ${INSTALL_BASE}; cannot relocate."

    info "Relocating Omada's writable data to ${DATA_DEST} ..."

    # Stop the controller and make sure its embedded mongod is really down first.
    [ -x "$OMADA_CTL" ] && "$OMADA_CTL" stop >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 10); do
        pgrep -f "mongod.*27217" >/dev/null 2>&1 || break
        sleep 1
    done
    pkill -f "mongod.*27217" >/dev/null 2>&1 || true
    sleep 1

    local name src dst
    for name in data logs work; do
        src="${INSTALL_BASE}/${name}"
        dst="${DATA_DEST}/${name}"

        if [ -L "$src" ]; then
            ok "  ${name}/ already a symlink -> $(readlink -f "$src"); leaving as-is."
            continue
        fi

        mkdir -p "$dst"
        if [ -d "$src" ]; then
            if [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
                warn "  ${dst} already has contents; KEEPING it, not overwriting from ${src}."
            else
                cp -a "$src/." "$dst/" 2>/dev/null || true
            fi
            rm -rf "$src"
        fi
        ln -s "$dst" "$src"
        ok "  ${name}/ -> ${dst}"
    done

    # Keep ownership control.sh expects (default OMADA_USER=root).
    local u="${OMADA_USER:-root}"
    chown -R "${u}:$(id -gn "$u" 2>/dev/null || echo root)" "$DATA_DEST" 2>/dev/null || true

    info "Starting Omada on the relocated data ..."
    [ -x "$OMADA_CTL" ] && { "$OMADA_CTL" start || warn "Omada didn't report a clean start; check ${DATA_DEST}/logs."; }
    ok "Relocation complete: Omada now reads/writes under ${DATA_DEST}."
}

# --- startup optimization (AppCDS) --------------------------------------------
# Speeds boot by memory-mapping a pre-parsed class-data archive so the JVM skips
# re-parsing/verifying the ~500 jars each start. Java 19+ self-manages it via
# AutoCreateSharedArchive (creates on first run, reuses after, regenerates if the
# classpath changes on upgrade). NO steady-state penalty -- unlike
# -XX:TieredStopAtLevel=1 -- so it suits a rarely-restarted, long-uptime controller.
# Implemented by appending flags to control.sh's JAVA_OPTS (backed up; idempotent).
optimize_startup_patch() {
    local ctl="${INSTALL_BASE}/bin/control.sh"
    [ -f "$ctl" ] || { warn "control.sh not found; skipping startup optimization."; return 0; }

    local jmajor
    jmajor="$(java -version 2>&1 | awk -F'"' '/version/{print $2}' | cut -d. -f1)"
    if [ -z "$jmajor" ] || [ "$jmajor" -lt 19 ] 2>/dev/null; then
        warn "Startup optimization needs Java 19+ (AppCDS auto-archive); yours is ${jmajor:-unknown}. Skipping."
        return 0
    fi

    if grep -q 'omada-rpi-fast-start' "$ctl"; then
        ok "Startup optimization already present in control.sh."
    else
        [ -f "${ctl}.orig-omada-rpi" ] || cp -a "$ctl" "${ctl}.orig-omada-rpi"
        # Append CDS flags after the first JAVA_OPTS= line (DATA_DIR is defined earlier
        # in control.sh, so the archive lands under data/ -> your SSD if relocated).
        awk '
          { print }
          /^JAVA_OPTS=/ && !patched {
            print "# omada-rpi-fast-start (added by install-raspberrypi.sh): AppCDS class-data sharing"
            print "JAVA_OPTS=\"${JAVA_OPTS} -XX:+AutoCreateSharedArchive -XX:SharedArchiveFile=${DATA_DIR}/omada-app-cds.jsa\""
            patched=1
          }
        ' "$ctl" > "${ctl}.tmp" && mv "${ctl}.tmp" "$ctl" || die "Failed to patch control.sh for AppCDS."
        grep -q 'omada-rpi-fast-start' "$ctl" || die "AppCDS patch didn't apply (no JAVA_OPTS line found?)."
        chmod 755 "$ctl"
        ok "Enabled AppCDS in control.sh (original saved as control.sh.orig-omada-rpi)."
        echo "      Archive builds on the next start; the boot after that is the fast one."
        echo "      Measure: grep -iE 'Started .* in .* seconds' ${INSTALL_BASE}/logs/*.log"
    fi
    NEEDS_RESTART=1
}

# --- memory profiles (size to a TP-Link controller model) ---------------------
# The board's RAM sets the ceiling; the user may pick that model or any SMALLER
# one, never a bigger one than the RAM backs. Each profile caps MongoDB's cache
# and the JVM heap, picks a GC, and sets Omada's adoption limit to match.
# Numbers are sane, margin-included starting points (override via env if needed).
set_profile_params() {
    case "$1" in
      nano)  P_WT="0.25"; P_XMX="512m";  P_XMS="192m";  P_GC=" -XX:+UseSerialGC"; P_MAXDEV=50;   P_LABEL="Nano (~handful of devices; 1 GB board, best-effort)";;
      oc200) P_WT="0.25"; P_XMX="768m";  P_XMS="256m";  P_GC=" -XX:+UseSerialGC"; P_MAXDEV=130;  P_LABEL="OC200 / OC220 (~130 devices)";;
      oc300) P_WT="0.5";  P_XMX="1536m"; P_XMS="512m";  P_GC="";                  P_MAXDEV=700;  P_LABEL="OC300 (~700 devices)";;
      oc400) P_WT="1.0";  P_XMX="3584m"; P_XMS="1024m"; P_GC="";                  P_MAXDEV=1310; P_LABEL="OC400 (~1,310 devices)";;
      *) return 1;;
    esac
    return 0
}
profile_rank() { case "$1" in nano) echo 0;; oc200) echo 1;; oc300) echo 2;; oc400) echo 3;; none) echo 9;; *) echo -1;; esac; }
ram_ceiling() {
    local mb="$1"
    if   [ "$mb" -ge 7000 ]; then echo oc400
    elif [ "$mb" -ge 3600 ]; then echo oc300
    elif [ "$mb" -ge 1800 ]; then echo oc200
    else echo nano
    fi
}

PROFILE=""   # resolved: nano|oc200|oc300|oc400|none
resolve_profile() {
    RAM_MB="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)"; [ -n "$RAM_MB" ] || RAM_MB=0
    local ceil crank; ceil="$(ram_ceiling "$RAM_MB")"; crank="$(profile_rank "$ceil")"
    info "Detected RAM: ${RAM_MB} MB  ->  this board can run up to: ${ceil}"

    local want="${PROFILE_ARG:-}"
    if [ -n "$want" ]; then
        want="$(printf '%s' "$want" | tr 'A-Z' 'a-z')"
        case "$want" in
          auto) PROFILE="$ceil"; return;;
          none) PROFILE="none"; return;;
        esac
        set_profile_params "$want" || die "Unknown profile '$want' (use: nano|oc200|oc300|oc400|auto|none)."
        if [ "$(profile_rank "$want")" -gt "$crank" ]; then
            if [ "${FORCE_PROFILE:-0}" = "1" ]; then
                warn "FORCE_PROFILE: '${want}' is above this board's ceiling (${ceil}) -- expect swapping/OOM."
                PROFILE="$want"
            else
                die "Profile '${want}' needs more RAM than this board has (ceiling: ${ceil}). Choose ${ceil} or lower, or set FORCE_PROFILE=1 to override."
            fi
        else
            PROFILE="$want"
        fi
        return
    fi

    if [ "$ASSUME_YES" -eq 1 ]; then PROFILE="$ceil"; return; fi   # non-interactive default = ceiling

    say ""
    say "  ${BOLD}Controller size${RST} ${DIM}— sets MongoDB cache + JVM heap${RST}"
    say "  ${DIM}Your ${RAM_MB} MB board tops out at ${ceil}; pick it or anything smaller.${RST}"
    local order=(oc400 oc300 oc200 nano) idx=1 p; declare -A MENU
    for p in "${order[@]}"; do
        if [ "$(profile_rank "$p")" -le "$crank" ]; then
            set_profile_params "$p"
            local tag=""; [ "$p" = "$ceil" ] && tag="   ${GRN}← suggested${RST}"
            printf "      %s%d)%s %s%s\n" "$BOLD" "$idx" "$RST" "$P_LABEL" "$tag"
            MENU[$idx]="$p"; idx=$((idx+1))
        fi
    done
    printf "      %s%d)%s Stock ${DIM}(no memory limits)${RST}\n" "$BOLD" "$idx" "$RST"; MENU[$idx]="none"
    local pick; read -r -p "  Choose [Enter = ${ceil}]: " pick
    if   [ -z "$pick" ]; then PROFILE="$ceil"
    elif [ -n "${MENU[$pick]:-}" ]; then PROFILE="${MENU[$pick]}"
    else warn "Unrecognized choice; using suggested ${ceil}."; PROFILE="$ceil"; fi
}

apply_profile() {
    local ctl="${INSTALL_BASE}/bin/control.sh" props="${INSTALL_BASE}/properties/omada.properties"
    [ -f "$ctl" ]   || { warn "control.sh not found; skipping memory profile."; return 0; }
    [ -f "$props" ] || { warn "omada.properties not found; skipping memory profile."; return 0; }

    [ -f "${ctl}.orig-omada-rpi" ]   || cp -a "$ctl" "${ctl}.orig-omada-rpi"
    [ -f "${props}.orig-omada-rpi" ] || cp -a "$props" "${props}.orig-omada-rpi"

    # Reset to a clean baseline every time so re-applying/switching profiles is idempotent:
    #  - control.sh: strip only our profile block (leave any AppCDS block intact)
    #  - omada.properties: restore the pristine copy (it only ever holds our edits)
    sed -i '/# >>> omada-rpi-profile >>>/,/# <<< omada-rpi-profile <<</d' "$ctl"
    cp -a "${props}.orig-omada-rpi" "$props"

    if [ "$PROFILE" = "none" ]; then
        chmod 755 "$ctl"; NEEDS_RESTART=1
        ok "Memory profile: Stock -- reverted MongoDB/JVM caps to TP-Link defaults."
        return 0
    fi
    set_profile_params "$PROFILE" || { warn "Unknown profile '$PROFILE'; skipping."; return 0; }

    # 1) MongoDB WiredTiger cache (append/update on the eap.mongod.args line).
    awk -v c="$P_WT" '
      /^eap\.mongod\.args=/ {
        if ($0 ~ /--wiredTigerCacheSizeGB/) sub(/--wiredTigerCacheSizeGB[ ]+[0-9.]+/, "--wiredTigerCacheSizeGB " c)
        else $0 = $0 " --wiredTigerCacheSizeGB " c
      }
      { print }
    ' "$props" > "${props}.tmp" && mv "${props}.tmp" "$props"

    # 2) Omada adoption cap (soft guardrail matching the chosen model).
    if grep -q '^max\.device=' "$props"; then
        sed -i "s/^max\.device=.*/max.device=${P_MAXDEV}/" "$props"
    else
        printf '\nmax.device=%s\n' "$P_MAXDEV" >> "$props"
    fi

    # 3) JVM heap + GC (append after the first JAVA_OPTS= line, wrapped in markers).
    local jline="JAVA_OPTS=\"\${JAVA_OPTS} -Xms${P_XMS} -Xmx${P_XMX}${P_GC}\""
    awk -v j="$jline" '
      { print }
      /^JAVA_OPTS=/ && !done { print "# >>> omada-rpi-profile >>>"; print j; print "# <<< omada-rpi-profile <<<"; done=1 }
    ' "$ctl" > "${ctl}.tmp" && mv "${ctl}.tmp" "$ctl"
    chmod 755 "$ctl"

    NEEDS_RESTART=1
    ok "Memory profile: ${P_LABEL}"
    echo "      MongoDB cache: ${P_WT} GB   |   JVM: -Xms${P_XMS} -Xmx${P_XMX}${P_GC:+  (SerialGC)}   |   max.device: ${P_MAXDEV}"
}

# Restart Omada once to apply pending control.sh / omada.properties changes.
restart_omada() {
    [ "$NEEDS_RESTART" -eq 1 ] || return 0
    [ -x "$OMADA_CTL" ] || return 0
    if [ -n "$(pgrep -f com.tplink.smb.omada.starter.OmadaLinuxMain 2>/dev/null)" ]; then
        info "Restarting Omada once to apply the changes..."
        "$OMADA_CTL" restart >/dev/null 2>&1 || warn "Restart reported an issue; check ${INSTALL_BASE}/logs/."
    else
        "$OMADA_CTL" start >/dev/null 2>&1 || true
    fi
}

# --- run ----------------------------------------------------------------------
render_header
[ "$TTY" = 1 ] || say "  ${DIM}(non-interactive output; full log: ${LOG})${RST}"

# --optimize-only: apply the AppCDS startup optimization to an existing install.
if [ "$OPTIMIZE_ONLY" -eq 1 ] && [ "$PROFILE_ONLY" -eq 0 ]; then
    [ -d "$INSTALL_BASE" ] || die "Omada is not installed at ${INSTALL_BASE}; nothing to optimize."
    STEP_TOTAL=2
    run_task "Enabling AppCDS fast start" optimize_startup_patch
    run_spin "Restarting controller" restart_omada
    render_summary; exit 0
fi

# --profile-only: (re)apply a memory profile to an existing install; no (re)install.
if [ "$PROFILE_ONLY" -eq 1 ]; then
    [ -d "$INSTALL_BASE" ] || die "Omada is not installed at ${INSTALL_BASE}; nothing to size."
    resolve_profile
    STEP_TOTAL=$(( 2 + FAST_START ))
    run_task "Applying ${PROFILE} memory profile" apply_profile
    [ "$FAST_START" -eq 1 ] && run_task "Enabling AppCDS fast start" optimize_startup_patch
    run_spin "Restarting controller" restart_omada
    render_summary; exit 0
fi

# --relocate-only: retrofit an existing install; skip deps + (re)install.
if [ "$RELOCATE_ONLY" -eq 1 ]; then
    readonly_precheck
    resolve_data_dir
    STEP_TOTAL=$(( 2 + FAST_START ))
    run_spin "Relocating data to ${DATA_DEST}" relocate_omada_data
    [ "$FAST_START" -eq 1 ] && run_task "Enabling AppCDS fast start" optimize_startup_patch
    run_spin "Restarting controller" restart_omada
    render_summary
    say "  ${DIM}Data moved; you may now enable a read-only/overlay root (ensure ${DATA_DEST} is in /etc/fstab).${RST}\n"
    exit 0
fi

# Full install: show context, gather all answers, then run the work quietly.
render_context
readonly_precheck
resolve_data_dir
resolve_profile

# Run install.sh non-interactively. IMPORTANT: TP-Link's install.sh accepts ONLY
# no argument (interactive) or "init-cluster-mode" -- ANY other argument, including
# "-y", makes it print help and exit WITHOUT installing. So we do NOT pass -y; we
# run it with no argument and answer its y/n prompts by feeding `yes` on stdin.
STOCK_ARG=""
if [ "${#INSTALL_ARGS[@]}" -gt 0 ]; then
    for a in "${INSTALL_ARGS[@]}"; do [ "$a" = "init-cluster-mode" ] && STOCK_ARG="init-cluster-mode"; done
fi
run_stock_installer(){
    cd "${SCRIPT_DIR}" || return 1
    local rc
    set +o pipefail                       # `yes` gets SIGPIPE at the end; don't let it fail the pipe
    if [ -n "$STOCK_ARG" ]; then yes | bash ./install.sh "$STOCK_ARG"; else yes | bash ./install.sh; fi
    rc=$?
    set -o pipefail
    return "$rc"
}

if [ "$DEPS_ONLY" -eq 1 ]; then
    STEP_TOTAL=2; say ""
    run_spin "Installing prerequisites (Java, jsvc, curl)" install_base_packages
    run_spin "Installing MongoDB ${MONGO_VERSION}" install_mongodb
    say "\n  ${GRN}${OKM} Prerequisites ready.${RST}  Install Omada with: sudo bash \"${SCRIPT_DIR}/install.sh\""
    say "  ${DIM}Log: ${LOG}${RST}\n"
    exit 0
fi

[ -f "${SCRIPT_DIR}/install.sh" ] || die \
    "install.sh not found in ${SCRIPT_DIR}. Run this script from inside the extracted Omada package directory."

# JAVA_HOME so install.sh's jsvc check stays quiet (see notes at that step).
command -v java >/dev/null 2>&1 && export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"

STEP_TOTAL=3
[ "$RELOCATE" = 1 ]   && STEP_TOTAL=$((STEP_TOTAL+1))
STEP_TOTAL=$((STEP_TOTAL+1))                         # memory profile
[ "$FAST_START" = 1 ] && STEP_TOTAL=$((STEP_TOTAL+1))
STEP_TOTAL=$((STEP_TOTAL+1))                         # restart

say ""
run_spin "Installing prerequisites (Java, jsvc, curl)"          install_base_packages
run_spin "Installing MongoDB ${MONGO_VERSION}"                  install_mongodb
run_spin "Installing Omada controller (first boot ~1-3 min)"    run_stock_installer
# Hard guard: install.sh can exit 0 without installing (e.g. it printed help). Verify
# the controller actually landed before we try to profile/optimize/restart it.
[ -x "$OMADA_CTL" ] || die "Omada did not install (${OMADA_CTL} missing). Check ${LOG} for install.sh output near the end."
[ "$RELOCATE" = 1 ]   && run_spin "Relocating data to ${DATA_DEST}"   relocate_omada_data
run_task "Applying ${PROFILE} memory profile"                   apply_profile
[ "$FAST_START" = 1 ] && run_task "Enabling AppCDS fast start"  optimize_startup_patch
run_spin "Restarting controller (applies settings)"             restart_omada

render_summary
if [ "$RELOCATE" = 1 ]; then
    say "  ${DIM}Data is on a separate disk — you can now enable a read-only/overlay root."
    say "  Ensure ${DATA_DEST} is in /etc/fstab so it mounts before Omada starts.${RST}\n"
fi
