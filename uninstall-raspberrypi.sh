#!/bin/bash
#
# uninstall-raspberrypi.sh
# ------------------------------------------------------------------------------
# Matching uninstaller for install-raspberrypi.sh (TP-Link Omada Network
# Application on Raspberry Pi OS / Raspbian, 64-bit).
#
# The stock uninstall.sh removes only the Omada application itself (the init.d
# service, the /usr/bin symlinks and /opt/tplink/EAPController). It does NOT
# touch the OS packages the Pi installer added -- Java, jsvc, MongoDB -- nor the
# MongoDB apt repo/keyring. This script runs the stock uninstall first, then
# optionally reverses those package changes.
#
# Package removal is OFF by default and gated behind explicit flags, because
# Java/jsvc/curl/MongoDB may be used by other software on the box -- removing an
# app should not silently rip out system-wide packages.
#
# Usage:
#   sudo bash uninstall-raspberrypi.sh                 # remove Omada app only
#   sudo bash uninstall-raspberrypi.sh -y              # ... without prompts
#   sudo bash uninstall-raspberrypi.sh --remove-mongodb   # also purge MongoDB + its apt repo
#   sudo bash uninstall-raspberrypi.sh --remove-deps      # also purge Java + jsvc
#   sudo bash uninstall-raspberrypi.sh --purge-all        # app + MongoDB + Java + jsvc
#
# Notes:
#   * -y is passed through to the stock uninstall.sh (skips its confirm + the
#     "keep/backup database" prompt; non-interactive keeps a db backup under
#     /opt/tplink/omada_db_backup).
#   * curl, gnupg and ca-certificates are always left installed (too widely
#     used to remove safely).
#   * The system MongoDB data dir /var/lib/mongodb is never auto-deleted.
#   * The systemd unit and helper commands from omada-service.sh /
#     omada-maintenance.sh / omada-network.sh are removed with the app.
#   * Versioned installs (omada-maintenance.sh): /opt/tplink/omada -- releases,
#     the shared data and the database snapshots -- is left in place and reported;
#     delete it yourself once you're sure you don't need the data.
#   * JAVA_PKG=<pkg> overrides which Java package --remove-deps purges
#     (default openjdk-17-jre-headless, matching the installer).
#
# Assumes: Raspberry Pi OS / Raspbian, 64-bit. Run from the Omada package dir
# (or anywhere -- it also finds the copy installed under /opt/tplink).
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
REMOVE_MONGODB=0
REMOVE_DEPS=0
ASSUME_YES=0
for a in "$@"; do
    case "$a" in
        --remove-mongodb) REMOVE_MONGODB=1 ;;
        --remove-deps)    REMOVE_DEPS=1 ;;
        --purge-all)      REMOVE_MONGODB=1; REMOVE_DEPS=1 ;;
        -y|-Y)            ASSUME_YES=1 ;;
        -h|--help)        sed -n '5,/^# -----/p' "$0" | sed '$d; s/^#\s\{0,1\}//'; exit 0 ;;
        *)                warn "Unknown argument '$a' ignored." ;;
    esac
done

# --- root ---------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "This script must be run as root. Try: sudo bash $0"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
INSTALLDIR="/opt/tplink/EAPController"

# --- step 0: remove the systemd unit + helper commands -------------------------
UNIT_FILE="/etc/systemd/system/tpeap.service"
remove_service_and_helpers() {
    if [ -f "$UNIT_FILE" ] && grep -q '^# Managed by omada-service' "$UNIT_FILE"; then
        info "Removing the omada-service systemd unit..."
        systemctl stop tpeap.service >/dev/null 2>&1 || true
        systemctl disable tpeap.service >/dev/null 2>&1 || true
        rm -f "$UNIT_FILE"
        systemctl daemon-reload >/dev/null 2>&1 || true
        ok "Removed ${UNIT_FILE}."
    fi
    local h
    for h in omada-service omada-maintenance omada-network; do
        [ -f "/usr/local/sbin/${h}" ] && rm -f "/usr/local/sbin/${h}" && ok "Removed /usr/local/sbin/${h}"
    done
    return 0
}

# --- step 1: remove the Omada application via the stock uninstaller -----------
uninstall_omada_app() {
    local uninst=""
    if [ -x "${INSTALLDIR}/uninstall.sh" ] || [ -f "${INSTALLDIR}/uninstall.sh" ]; then
        uninst="${INSTALLDIR}/uninstall.sh"
    elif [ -f "${SCRIPT_DIR}/uninstall.sh" ]; then
        uninst="${SCRIPT_DIR}/uninstall.sh"
    fi

    if [ -z "$uninst" ]; then
        warn "Stock uninstall.sh not found (looked in ${INSTALLDIR} and ${SCRIPT_DIR})."
        if [ -d "${INSTALLDIR}" ]; then
            warn "Omada appears installed but its uninstaller is missing; skipping app removal."
            warn "Remove it manually if needed: the init link /etc/init.d/tpeap, the"
            warn "/usr/bin/tpeap[N] + /usr/bin/omadacluster[N] symlinks, and ${INSTALLDIR}."
        else
            info "Omada application not found under ${INSTALLDIR}; nothing to remove."
        fi
        return 0
    fi

    info "Removing the Omada application via ${uninst} ..."
    if [ "$ASSUME_YES" -eq 1 ]; then
        bash "$uninst" -y
    else
        bash "$uninst"
    fi
    ok "Stock Omada uninstall finished."
}

# --- step 2: remove MongoDB server + the apt repo the installer added ---------
remove_mongodb() {
    info "Removing MongoDB server and the apt repo/keyring added by the installer..."
    if dpkg -l 'mongodb-org*' 2>/dev/null | grep -q '^ii'; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y 'mongodb-org-server' 'mongodb-org*' \
            || warn "apt purge of MongoDB reported issues (some packages may have been absent)."
        DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y >/dev/null 2>&1 || true
        ok "Purged MongoDB packages."
    else
        info "No mongodb-org packages are installed."
    fi

    rm -f /etc/apt/sources.list.d/mongodb-org-*.list
    rm -f /usr/share/keyrings/mongodb-server-*.gpg
    ok "Removed MongoDB apt source list(s) and signing keyring(s), if any were present."
    apt-get update -y >/dev/null 2>&1 || true

    # Unofficial themattman binaries (Pi 4 path) live in /usr/local/bin, not apt.
    local removed_local=0 b
    for b in mongod mongos mongosh; do
        if [ -f "/usr/local/bin/$b" ]; then rm -f "/usr/local/bin/$b" && removed_local=1; fi
    done
    [ "$removed_local" -eq 1 ] && ok "Removed unofficial MongoDB binaries from /usr/local/bin."

    # If the installer swapped in a newer libstdc++ (older-OS Pi 4 path), restore it.
    if [ -f /usr/local/lib64/.omada-libstdcxx-original ]; then
        local orig; orig="$(cat /usr/local/lib64/.omada-libstdcxx-original 2>/dev/null)"
        if [ -n "$orig" ] && [ -e "$orig" ]; then
            ln -sf "$orig" /lib/aarch64-linux-gnu/libstdc++.so.6
            ldconfig 2>/dev/null || true
            ok "Restored the original system libstdc++.so.6 -> ${orig}"
        fi
        rm -f /usr/local/lib64/.omada-libstdcxx-original
        rm -f /usr/local/lib64/libstdc++.so.6.0.* 2>/dev/null
    fi

    # libssl1.1 may have been added for MongoDB (4.4 or the themattman Pi 4 builds).
    # It's a shared library other software could now use, so we LEAVE it (like
    # curl/gnupg) rather than risk breaking something -- just flag it.
    if dpkg -s libssl1.1 >/dev/null 2>&1; then
        warn "Left libssl1.1 installed (added for MongoDB; other packages may use it now)."
        warn "Remove it yourself with 'sudo apt-get purge libssl1.1' only if nothing else needs it."
    fi

    if [ -d /var/lib/mongodb ]; then
        warn "Left /var/lib/mongodb in place (the *system* MongoDB data dir)."
        warn "Omada uses its own db under ${INSTALLDIR}/data/db (removed with the app)."
        warn "Delete /var/lib/mongodb manually only if nothing else uses MongoDB."
    fi
}

# --- step 3: remove the Java/jsvc runtime deps the installer added ------------
remove_deps() {
    # The installer may have picked openjdk-17 (bookworm/bullseye) or openjdk-21
    # (trixie), or a JAVA_PKG override. Purge whichever headless JREs are present.
    local candidates=()
    [ -n "${JAVA_PKG:-}" ] && candidates+=("$JAVA_PKG")
    candidates+=("openjdk-21-jre-headless" "openjdk-17-jre-headless" "default-jre-headless")

    local java_pkgs=()
    local p
    for p in "${candidates[@]}"; do
        dpkg -l "$p" 2>/dev/null | grep -q '^ii' && java_pkgs+=("$p")
    done

    warn "Purging jsvc${java_pkgs:+ and: ${java_pkgs[*]}}. (curl, gnupg, ca-certificates are kept.)"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y jsvc "${java_pkgs[@]}" \
        || warn "apt purge of jsvc/JRE reported issues (may be in use or already absent)."
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y >/dev/null 2>&1 || true
    ok "Removed jsvc and the installed JRE where present."
}

# --- run ----------------------------------------------------------------------
echo
info "=== Omada Network Application - Raspberry Pi uninstaller ==="
echo

# Capture any relocated (symlinked) data targets BEFORE removal, so we can tell
# the user their external data survives. rm -rf on the install dir only removes
# the symlinks, never the data they point to on the separate disk.
RELOCATED_TARGETS=()
for _n in data logs work; do
    _p="${INSTALLDIR}/${_n}"
    [ -L "$_p" ] && RELOCATED_TARGETS+=("${_n}/ -> $(readlink -f "$_p" 2>/dev/null)")
done

VERSIONED_ROOT=""
[ -L "$INSTALLDIR" ] && [ -d /opt/tplink/omada/releases ] && VERSIONED_ROOT="/opt/tplink/omada"

remove_service_and_helpers
uninstall_omada_app
# Stock uninstall removes the EAPController symlink; make sure nothing dangles.
[ -n "$VERSIONED_ROOT" ] && [ -L "$INSTALLDIR" ] && rm -f "$INSTALLDIR"

if [ "$REMOVE_MONGODB" -eq 1 ]; then
    echo
    remove_mongodb
fi

if [ "$REMOVE_DEPS" -eq 1 ]; then
    echo
    remove_deps
fi

echo
ok "Uninstall complete."
if [ "$REMOVE_MONGODB" -eq 0 ] || [ "$REMOVE_DEPS" -eq 0 ]; then
    echo "    Left installed on this system:"
    [ "$REMOVE_MONGODB" -eq 0 ] && command -v mongod >/dev/null 2>&1 && \
        echo "      * MongoDB ($(command -v mongod))   -- re-run with --remove-mongodb to purge"
    [ "$REMOVE_DEPS" -eq 0 ] && command -v java >/dev/null 2>&1 && \
        echo "      * Java    ($(command -v java))       -- re-run with --remove-deps to purge"
    [ "$REMOVE_DEPS" -eq 0 ] && command -v jsvc >/dev/null 2>&1 && \
        echo "      * jsvc    ($(command -v jsvc))       -- re-run with --remove-deps to purge"
fi
if [ -f "${INSTALLDIR}/../omada_db_backup/omada.db.tar.gz" ] 2>/dev/null; then
    echo "    A database backup was kept at: /opt/tplink/omada_db_backup/omada.db.tar.gz"
fi
if [ "${#RELOCATED_TARGETS[@]}" -gt 0 ]; then
    echo "    Your data had been relocated to a separate disk and was NOT deleted:"
    for _t in "${RELOCATED_TARGETS[@]}"; do echo "      * ${_t}"; done
    echo "    Remove those paths manually if you no longer need the data."
fi
if [ -n "$VERSIONED_ROOT" ] && [ -d "$VERSIONED_ROOT" ]; then
    echo "    Versioned releases, shared data and database snapshots were kept in:"
    echo "      * ${VERSIONED_ROOT}   ($(du -sh "$VERSIONED_ROOT" 2>/dev/null | cut -f1))"
    echo "    Remove it with 'sudo rm -rf ${VERSIONED_ROOT}' once you no longer need the data."
fi