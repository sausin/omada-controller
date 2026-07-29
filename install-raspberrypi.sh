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
#   * Uses MongoDB's UBUNTU arm64 repo (there are NO official MongoDB arm64
#     packages under the Debian repo, so a naive "debian bookworm" repo 404s).
#   * Picks a MongoDB version the CPU can actually run:
#       - Pi 5 / Cortex-A76 (ARMv8.2, has LSE 'atomics')  -> MongoDB 7.0 (ubuntu jammy)
#       - Pi 4 / Pi 3 / Cortex-A72/A53 (ARMv8.0, no LSE)  -> MongoDB 4.4 (ubuntu focal)
#         (MongoDB 5.0+ aborts with "Illegal instruction" on ARMv8.0 cores.)
#   * Installs the libssl1.1 that MongoDB 4.4 needs but bookworm dropped.
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
#   sudo bash install-raspberrypi.sh --deps-only         # install/verify prerequisites only
#   sudo bash install-raspberrypi.sh --relocate-only --data-dir /mnt/ssd/omada
#                                                        # move an EXISTING install's data; no (re)install
#   sudo bash install-raspberrypi.sh init-cluster-mode   # passed through to install.sh
#
# Overrides (environment variables):
#   MONGO_VERSION=8.0     Force a MongoDB major version instead of auto-detecting
#                         (8.0 or 7.0 on a Pi 5; 4.4 is the ceiling on a Pi 4).
#   JAVA_PKG=...          Override the JDK/JRE package (default openjdk-17-jre-headless).
#   OMADA_DATA_DIR=PATH   Same as --data-dir PATH.
#
# Assumes: Raspberry Pi OS / Raspbian (Debian bullseye or bookworm), 64-bit (arm64).
# Version-agnostic: works with any Omada Linux tar/gz release (tested against
# v5.x/v6.x). Run from inside the extracted Omada package directory (next to
# the stock install.sh).
# ------------------------------------------------------------------------------

set -o pipefail

# --- pretty output ------------------------------------------------------------
if [ -t 1 ]; then
    RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; RST=$'\e[0m'
else
    RED=''; GRN=''; YLW=''; BLU=''; RST=''
fi
info(){ echo "${BLU}[*]${RST} $*"; }
ok(){   echo "${GRN}[OK]${RST} $*"; }
warn(){ echo "${YLW}[!]${RST} $*" >&2; }
die(){  echo "${RED}[X]${RST} $*" >&2; exit 1; }

# --- argument parsing ---------------------------------------------------------
DEPS_ONLY=0
RELOCATE_ONLY=0
ASSUME_YES=0
DATA_DIR_ARG="${OMADA_DATA_DIR:-}"
INSTALL_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --deps-only)        DEPS_ONLY=1 ;;
        --relocate-only)    RELOCATE_ONLY=1 ;;
        --data-dir)         if [ $# -ge 2 ]; then shift; DATA_DIR_ARG="$1"; else warn "--data-dir needs a path"; fi ;;
        --data-dir=*)       DATA_DIR_ARG="${1#*=}" ;;
        -y|-Y)              ASSUME_YES=1; INSTALL_ARGS+=("-y") ;;
        init-cluster-mode)  INSTALL_ARGS+=("init-cluster-mode") ;;
        -h|--help)          sed -n '3,53p' "$0" | sed 's/^#\s\{0,1\}//'; exit 0 ;;
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

# --- choose MongoDB version ---------------------------------------------------
if [ -n "${MONGO_VERSION:-}" ]; then
    info "MongoDB version       : ${MONGO_VERSION} (pinned via MONGO_VERSION env var)"
elif [ "$CPU_V82" -eq 1 ]; then
    MONGO_VERSION="7.0"
    ok "Selected MongoDB ${MONGO_VERSION} for this CPU."
else
    MONGO_VERSION="4.4"
    warn "This CPU (ARMv8.0, e.g. Pi 4/3) cannot run MongoDB 5.0+ -- it would"
    warn "abort with 'Illegal instruction'. Falling back to MongoDB ${MONGO_VERSION},"
    warn "the last series that runs on this core. Note: 4.4 is end-of-life upstream."
fi

MONGO_MAJOR="${MONGO_VERSION%%.*}"
if [ "$CPU_V82" -eq 0 ] && [ "${MONGO_MAJOR:-0}" -ge 5 ] 2>/dev/null; then
    warn "You pinned MongoDB ${MONGO_VERSION}, but this CPU lacks ARMv8.2/LSE."
    warn "mongod will almost certainly crash with 'Illegal instruction'."
    warn "Set MONGO_VERSION=4.4 for this board unless you know otherwise."
fi

# --- helpers ------------------------------------------------------------------
mongo_repo_suite() {
    # MongoDB does NOT publish arm64 packages under its Debian repo, so we use
    # the Ubuntu arm64 repo (installs cleanly on Debian-based Raspberry Pi OS,
    # since the OpenSSL ABI lines up):
    #   4.4  -> ubuntu focal  (last series that runs on ARMv8.0; links libssl1.1)
    #   5.0+ -> ubuntu jammy  (ARMv8.2 required; links libssl3, present on bookworm)
    case "$1" in
        4.4) echo "focal" ;;
        *)   echo "jammy" ;;
    esac
}

ensure_libssl11() {
    # MongoDB 4.4 (focal build) links libssl1.1. Bullseye still ships it, but
    # bookworm dropped it in favour of libssl3 -- so on bookworm we add it back.
    if dpkg -s libssl1.1 >/dev/null 2>&1; then
        ok "libssl1.1 already present."
        return 0
    fi
    info "MongoDB 4.4 needs libssl1.1 (absent on ${OS_CODENAME:-this OS}); installing it..."
    if apt-get install -y libssl1.1 >/dev/null 2>&1; then
        ok "Installed libssl1.1 from the configured apt sources."
        return 0
    fi
    # Fallback: Debian buster security pool. The point release (deb10uN) rotates
    # over time; if this exact file 404s, grab the current libssl1.1 arm64 .deb
    # from http://security.debian.org/debian-security/pool/updates/main/o/openssl/
    local deb="libssl1.1_1.1.1n-0+deb10u6_arm64.deb"
    local url="http://security.debian.org/debian-security/pool/updates/main/o/openssl/${deb}"
    info "Fetching ${deb} from the Debian buster security archive..."
    if curl -fsSL -o "/tmp/${deb}" "$url" && dpkg -i "/tmp/${deb}" >/dev/null 2>&1; then
        rm -f "/tmp/${deb}"
        ok "Installed libssl1.1 from the Debian buster archive."
        return 0
    fi
    rm -f "/tmp/${deb}"
    die "Could not install libssl1.1 automatically; MongoDB 4.4 will not start without it.
      Download a libssl1.1 arm64 .deb (openssl 1.1.1x) and 'dpkg -i' it, then re-run.
      Browse: http://security.debian.org/debian-security/pool/updates/main/o/openssl/"
}

# --- install base packages ----------------------------------------------------
install_base_packages() {
    info "Updating apt package index..."
    apt-get update -y || die "'apt-get update' failed."

    local java_pkg="${JAVA_PKG:-openjdk-17-jre-headless}"
    info "Installing ${java_pkg}, jsvc, curl, gnupg, ca-certificates..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        "$java_pkg" jsvc curl gnupg ca-certificates \
        || die "Failed to install base packages (${java_pkg}, jsvc, curl)."

    command -v java  >/dev/null 2>&1 || die "java not found after install."
    command -v jsvc  >/dev/null 2>&1 || die "jsvc not found after install."
    command -v curl  >/dev/null 2>&1 || die "curl not found after install."
    ok "Java: $(java -version 2>&1 | head -n1)"
    ok "jsvc: $(command -v jsvc)"
    ok "curl: $(command -v curl)"
}

# --- install MongoDB ----------------------------------------------------------
install_mongodb() {
    if command -v mongod >/dev/null 2>&1; then
        local cur
        cur="$(mongod --version 2>/dev/null | grep -oP 'db version v\K[0-9]+\.[0-9]+\.[0-9]+' || echo unknown)"
        ok "mongod already installed (v${cur}); leaving it as-is."
        return 0
    fi

    local suite; suite="$(mongo_repo_suite "$MONGO_VERSION")"
    info "Configuring MongoDB ${MONGO_VERSION} apt repo (ubuntu ${suite}, arm64)..."

    install -d -m 0755 /usr/share/keyrings
    curl -fsSL "https://pgp.mongodb.com/server-${MONGO_VERSION}.asc" \
        | gpg --dearmor -o "/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg" \
        || die "Failed to fetch/dearmor the MongoDB ${MONGO_VERSION} signing key."
    chmod 0644 "/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg"

    # Ubuntu repo uses the 'multiverse' component (Debian repo would use 'main').
    echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg arch=arm64 ] https://repo.mongodb.org/apt/ubuntu ${suite}/mongodb-org/${MONGO_VERSION} multiverse" \
        > "/etc/apt/sources.list.d/mongodb-org-${MONGO_VERSION}.list"

    [ "$MONGO_VERSION" = "4.4" ] && ensure_libssl11

    apt-get update -y || die "'apt-get update' failed after adding the MongoDB repo."
    DEBIAN_FRONTEND=noninteractive apt-get install -y mongodb-org-server \
        || die "Failed to install mongodb-org-server ${MONGO_VERSION}."
    ok "Installed: $(mongod --version 2>/dev/null | head -n1)"

    # Omada starts and manages its own mongod (see properties/omada.properties:
    # port 27217, dbpath ../data/db). The distro's mongod.service would run a
    # second, unused instance on 27017 -- disable it to save memory.
    if systemctl list-unit-files 2>/dev/null | grep -q '^mongod\.service'; then
        systemctl disable --now mongod >/dev/null 2>&1 || true
        ok "Disabled the standalone system mongod.service (Omada runs its own)."
    fi
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
        echo
        warn "Installing writes system packages and files to the root filesystem."
        read -r -p "Is your root filesystem currently READ-ONLY or overlay-protected? (y/N): " ans
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
        echo
        info "SD cards wear out under MongoDB's constant writes. You can place Omada's"
        info "writable data (database, logs, work) on another disk or partition -- e.g."
        info "a USB SSD or a dedicated writable partition -- and this installer will"
        info "symlink it in. This is also what lets a read-only root keep working."
        read -r -p "Path to store Omada's data on, or press Enter to keep it under ${INSTALL_BASE}: " d
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

# --- run ----------------------------------------------------------------------
echo
info "=== Omada Network Application - Raspberry Pi installer ==="

# --relocate-only: retrofit an existing install; skip deps + (re)install.
if [ "$RELOCATE_ONLY" -eq 1 ]; then
    readonly_precheck
    resolve_data_dir
    relocate_omada_data
    echo
    ok "Done. Omada's data now lives under ${DATA_DEST}; only symlinks remain under ${INSTALL_BASE}."
    echo "    You can now re-enable a read-only/overlay root if you wish."
    exit 0
fi

# Ask the up-front questions before any long-running work.
readonly_precheck
resolve_data_dir

echo
install_base_packages
install_mongodb

echo
ok "All prerequisites satisfied:"
echo "      * $(java -version 2>&1 | head -n1)"
echo "      * jsvc  : $(command -v jsvc)"
echo "      * curl  : $(command -v curl)"
echo "      * mongo : $(mongod --version 2>/dev/null | head -n1)"
echo

if [ "$DEPS_ONLY" -eq 1 ]; then
    ok "Prerequisite setup complete (--deps-only)."
    echo "    To install Omada now, run:  sudo bash \"${SCRIPT_DIR}/install.sh\""
    exit 0
fi

[ -f "${SCRIPT_DIR}/install.sh" ] || die \
    "install.sh not found in ${SCRIPT_DIR}. Run this script from inside the extracted Omada package directory."

info "Handing off to the stock Omada installer (install.sh)..."
echo
( cd "${SCRIPT_DIR}" && bash ./install.sh "${INSTALL_ARGS[@]}" ) || die "Stock install.sh failed."

# Move data/logs/work onto the chosen disk AFTER install created them, then
# restart Omada on the new path. Leaves only symlinks under /opt/tplink.
if [ "$RELOCATE" -eq 1 ]; then
    echo
    relocate_omada_data
fi

echo
ok "Done. Manage the service with:  sudo tpeap start|stop|status"
if [ "$RELOCATE" -eq 1 ]; then
    echo "    Omada's writable data (data/, logs/, work/) now lives under: ${DATA_DEST}"
    echo "    Only symlinks remain under ${INSTALL_BASE}, so you can now re-enable a"
    echo "    read-only / overlay root (raspi-config -> Performance Options)."
    echo "    Confirm ${DATA_DEST} is mounted at boot via /etc/fstab before doing so."
fi
