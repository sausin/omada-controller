#!/bin/bash
#
# omada-service.sh
# ------------------------------------------------------------------------------
# Native systemd service for the TP-Link Omada Network Application, plus short
# start / stop / restart / status / logs commands.
#
# TP-Link's install.sh registers a SysV init script (/etc/init.d/tpeap). systemd
# wraps that in a generated unit with no start timeout tuning, no restart-on-
# crash and no knowledge of where the data lives. This script writes a native
# /etc/systemd/system/tpeap.service instead (a native unit shadows the generated
# one of the same name, so the controller can never be started twice), with:
#   * Type=forking + the PID file control.sh uses -> systemd tracks the JVM;
#   * Restart=on-failure                          -> comes back after a crash;
#   * a 20-minute start timeout                   -> first boot after an upgrade
#                                                    migrates the database;
#   * RequiresMountsFor= the real data/logs/work paths -> a relocated data disk is
#                                                    mounted before Omada starts;
#   * Alias=omada.service                         -> `systemctl status omada` works.
# The unit calls /opt/tplink/EAPController/bin/control.sh, so it keeps working
# across upgrades (including the versioned layout of omada-maintenance.sh).
#
# Usage:
#   sudo bash omada-service.sh install     # write + enable the unit, install this
#                                          # script as /usr/local/sbin/omada-service
#   sudo omada-service start|stop|restart  # control the controller
#   sudo omada-service status              # service state + web UI reachability
#   sudo omada-service logs [-n N]         # follow Omada's server.log (Ctrl-C to quit)
#   sudo omada-service enable|disable      # start at boot (or not)
#   sudo omada-service uninstall           # remove the unit (falls back to SysV tpeap)
#
# Prefer these (or systemctl) over `tpeap start|stop`: tpeap talks to the
# process directly, so systemd would not know a stop was intentional.
#
# Overrides (environment): OMADA_INSTALL_BASE (default /opt/tplink/EAPController).
# ------------------------------------------------------------------------------

set -o pipefail

if [ -t 1 ]; then
    RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[36m'; DIM=$'\e[2m'; RST=$'\e[0m'
else
    RED=''; GRN=''; YLW=''; BLU=''; DIM=''; RST=''
fi
info(){ echo "  ${BLU}*${RST} $*"; }
ok(){   echo "  ${GRN}OK${RST} $*"; }
warn(){ echo "  ${YLW}!${RST} $*" >&2; }
die(){  echo "  ${RED}x${RST} $*" >&2; exit 1; }

INSTALL_BASE="${OMADA_INSTALL_BASE:-/opt/tplink/EAPController}"
OMADA_CTL="${INSTALL_BASE}/bin/control.sh"
UNIT_NAME="tpeap.service"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"
UNIT_MARKER="# Managed by omada-service"
SELF_DEST="/usr/local/sbin/omada-service"

usage(){ sed -n '5,/^# -----/p' "$0" | sed '$d; s/^#\s\{0,1\}//'; }

have_systemd(){ [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }
unit_is_ours(){ [ -f "$UNIT_FILE" ] && grep -q "^${UNIT_MARKER}" "$UNIT_FILE"; }

# The PID file control.sh hands to jsvc, e.g. PID_FILE="/var/run/${NAME}.pid".
detect_pid_file() {
    local raw name
    raw="$(sed -n 's/^PID_FILE=//p' "$OMADA_CTL" 2>/dev/null | head -n1 | tr -d '"'"'")"
    [ -n "$raw" ] || return 1
    name="$(sed -n 's/^NAME=//p' "$OMADA_CTL" 2>/dev/null | head -n1 | tr -d '"'"'")"
    raw="${raw//\$\{NAME\}/$name}"; raw="${raw//\$NAME/$name}"
    case "$raw" in *'$'*|'') return 1 ;; esac     # still has unresolved variables
    raw="${raw/#\/var\/run\//\/run\/}"             # /var/run is a symlink to /run
    echo "$raw"
}

omada_http_port() {
    local p
    p="$(sed -n 's/^manage\.https\.port=//p' "${INSTALL_BASE}/properties/omada.properties" 2>/dev/null | head -n1)"
    echo "${p:-8043}"
}

omada_running(){ pgrep -f com.tplink.smb.omada.starter.OmadaLinuxMain >/dev/null 2>&1; }

write_unit() {
    [ -x "$OMADA_CTL" ] || die "Omada is not installed (${OMADA_CTL} missing)."
    local pidfile mounts="" n p
    for n in data logs work; do
        p="$(readlink -f "${INSTALL_BASE}/${n}" 2>/dev/null)"
        [ -n "$p" ] && mounts="${mounts} ${p}"
    done

    local service
    if pidfile="$(detect_pid_file)"; then
        # control.sh waits for the web UI and may give up on a slow first boot even
        # though the JVM is fine; count the start as good while the daemon is alive.
        # ($$ is systemd's escape for a literal $.)
        service="Type=forking
PIDFile=${pidfile}
ExecStart=/bin/sh -c '${OMADA_CTL} start; p=\$\$(cat ${pidfile} 2>/dev/null) && kill -0 \"\$\$p\"'
ExecStop=${OMADA_CTL} stop
Restart=on-failure
RestartSec=30"
    else
        warn "Couldn't read PID_FILE from control.sh; using a oneshot unit (no restart-on-crash)."
        service="Type=oneshot
RemainAfterExit=yes
ExecStart=${OMADA_CTL} start
ExecStop=${OMADA_CTL} stop"
    fi

    cat > "${UNIT_FILE}.tmp" <<EOF
${UNIT_MARKER} (omada-controller helper scripts). Regenerate: sudo omada-service install
[Unit]
Description=TP-Link Omada Network Application
Documentation=https://github.com/sausin/omada-controller
Wants=network-online.target
After=network-online.target local-fs.target
RequiresMountsFor=/opt/tplink${mounts}

[Service]
${service}
TimeoutStartSec=1200
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
Alias=omada.service
EOF
    mv "${UNIT_FILE}.tmp" "$UNIT_FILE"
}

cmd_install() {
    have_systemd || die "systemd is not running on this host; keep using 'tpeap start|stop'."
    if [ -f "$UNIT_FILE" ] && ! unit_is_ours; then
        die "${UNIT_FILE} exists and wasn't written by this script; not overwriting it."
    fi
    local was_running=0; omada_running && was_running=1
    write_unit
    systemctl daemon-reload
    systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || warn "systemctl enable ${UNIT_NAME} reported an issue."
    ok "Installed ${UNIT_FILE} (enabled at boot; alias omada.service)."

    if [ "$(readlink -f "$0")" != "$SELF_DEST" ]; then
        install -m 755 "$0" "$SELF_DEST" && ok "Installed this helper as ${SELF_DEST##*/}."
    fi

    # If Omada is already running outside systemd, hand it over so systemd tracks it.
    if [ "$was_running" = 1 ] && ! systemctl is-active -q "$UNIT_NAME"; then
        info "Omada is running outside systemd; handing it over (no restart)..."
        systemctl start "$UNIT_NAME" || warn "Couldn't attach; run 'sudo omada-service restart' when convenient."
    fi
    echo "      Manage it with: sudo omada-service start|stop|restart|status|logs"
}

cmd_uninstall() {
    unit_is_ours || { info "No omada-service unit installed."; return 0; }
    systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
    # Hand boot-time start back to TP-Link's SysV script if it's still there.
    [ -e /etc/init.d/tpeap ] && systemctl enable tpeap >/dev/null 2>&1 || true
    ok "Removed ${UNIT_FILE}. (The controller keeps running; 'tpeap' manages it again.)"
}

# start/stop/restart: through systemd when our unit is installed, else control.sh.
# A stop also calls control.sh in case Omada was started outside systemd.
svc_stop() {
    if unit_is_ours && have_systemd; then systemctl stop "$UNIT_NAME" || true; fi
    [ -x "$OMADA_CTL" ] && omada_running && "$OMADA_CTL" stop
    return 0
}
svc_start() {
    if unit_is_ours && have_systemd; then
        info "Starting Omada (this can take a few minutes on a Pi)..."
        systemctl start "$UNIT_NAME"
    else
        [ -x "$OMADA_CTL" ] || die "Omada is not installed (${OMADA_CTL} missing)."
        "$OMADA_CTL" start
    fi
}

cmd_status() {
    if unit_is_ours && have_systemd; then
        systemctl --no-pager status "$UNIT_NAME" 2>/dev/null | head -n 5
    else
        info "No systemd unit from this script (run: sudo bash $0 install)."
    fi
    local port code; port="$(omada_http_port)"
    if omada_running; then
        code="$(curl -sk -o /dev/null -m 5 -w '%{http_code}' "https://127.0.0.1:${port}/" 2>/dev/null)"
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            ok "Controller is up: https://$(hostname -I 2>/dev/null | awk '{print $1}'):${port}"
        else
            warn "Controller process is running but the web UI (port ${port}) isn't answering yet."
        fi
    else
        warn "Controller is not running."
        return 3
    fi
}

cmd_logs() {
    local n=50
    [ "${1:-}" = "-n" ] && [ -n "${2:-}" ] && n="$2"
    local f="${INSTALL_BASE}/logs/server.log"
    [ -f "$f" ] || die "No log at ${f}."
    echo "  ${DIM}${f}  (Ctrl-C to stop)${RST}"
    exec tail -n "$n" -F "$f"
}

[ $# -gt 0 ] || { usage; exit 1; }
CMD="$1"; shift
case "$CMD" in -h|--help|help) usage; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0 $CMD"

case "$CMD" in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    start)     svc_start ;;
    stop)      svc_stop; ok "Omada stopped." ;;
    restart)   svc_stop; svc_start ;;
    status)    cmd_status ;;
    logs)      cmd_logs "$@" ;;
    enable)    unit_is_ours || die "Run 'install' first."; systemctl enable "$UNIT_NAME" && ok "Enabled at boot." ;;
    disable)   unit_is_ours || die "Run 'install' first."; systemctl disable "$UNIT_NAME" && ok "Disabled at boot." ;;
    *)         usage; exit 1 ;;
esac
