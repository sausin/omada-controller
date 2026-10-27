#!/bin/bash
#
# omada-network.sh
# ------------------------------------------------------------------------------
# Checks whether this host can reach factory-default Omada devices, and suggests
# the network config to fix it for the network stack this host actually uses.
#
# Why: out of the box, Omada gateways hand out 192.168.0.0/24 (gateway
# 192.168.0.1), and APs/switches without a DHCP lease fall back to 192.168.0.254.
# The controller finds new devices with a broadcast on that L2 segment (UDP 29810),
# so a controller that only has an address in another subnet -- your home LAN,
# say 10.0.0.x -- won't see or adopt them until each one is pointed at it by hand
# (Discovery Utility, DHCP option 138, or the device's inform URL).
#
# The fix is to give the controller host a second address in 192.168.0.0/24,
# either on the same cable (untagged) or on a VLAN interface if your Omada devices
# sit on a tagged management VLAN. No gateway is set on that address, so your
# normal routing/default route is untouched.
#
# Usage:
#   omada-network.sh check                  # exit 0 if this host has a 192.168.0.x address
#   omada-network.sh suggest [options]      # print config for this host's network stack
#   sudo omada-network.sh apply-temp [opts] # add the address/VLAN NOW (lost at reboot; for testing)
#   sudo omada-network.sh remove-temp [opts]# undo apply-temp
#
# Options:
#   --vlan ID        Omada devices are on tagged VLAN ID (else: untagged secondary address)
#   --ip ADDR/PFX    address to add (default 192.168.0.250/24: outside the gateway's
#                    default DHCP pool, not .1 or the .254 fallback)
#   --iface IF       physical interface (default: the one with the default route)
#   --manager M      show config for: networkmanager | netplan | networkd | ifupdown | dhcpcd | generic
#   --base NET/PFX   network to check for (default 192.168.0.0/24)
#
# Network stack detection: netplan (Ubuntu), NetworkManager (Raspberry Pi OS
# bookworm+, Debian/Ubuntu desktop, many Arch installs), systemd-networkd (Arch,
# minimal Debian), ifupdown /etc/network/interfaces (Debian server), dhcpcd
# (Raspberry Pi OS bullseye and older). Nothing here edits your config files.
# ------------------------------------------------------------------------------

set -o pipefail

if [ -t 1 ]; then
    RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[36m'; DIM=$'\e[2m'; BOLD=$'\e[1m'; RST=$'\e[0m'
else
    RED=''; GRN=''; YLW=''; BLU=''; DIM=''; BOLD=''; RST=''
fi
ok(){   echo "  ${GRN}OK${RST} $*"; }
warn(){ echo "  ${YLW}!${RST} $*"; }
die(){  echo "  ${RED}x${RST} $*" >&2; exit 1; }

usage(){ sed -n '5,/^# -----/p' "$0" | sed '$d; s/^#\s\{0,1\}//'; }

VLAN=""; IP="${OMADA_HELPER_IP:-192.168.0.250/24}"; IFACE=""; MANAGER=""
BASE="${OMADA_BASE_NET:-192.168.0.0/24}"; QUIET=0

# --- address math ----------------------------------------------------------------
ip2int(){ local IFS=.; set -- $1; echo $(( ($1<<24) + ($2<<16) + ($3<<8) + $4 )); }
in_net() {   # in_net IP NET/PFX
    local net="${2%/*}" pfx="${2#*/}" mask
    mask=$(( pfx == 0 ? 0 : (0xFFFFFFFF << (32-pfx)) & 0xFFFFFFFF ))
    [ $(( $(ip2int "$1") & mask )) -eq $(( $(ip2int "$net") & mask )) ]
}
host_addrs(){ ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}'; }   # "IF ADDR/PFX"

# Prints the interface + address already in BASE; exit 1 if none.
find_base_addr() {
    local ifc a
    while read -r ifc a; do
        [ -n "$a" ] && in_net "${a%/*}" "$BASE" && { echo "$ifc $a"; return 0; }
    done < <(host_addrs)
    return 1
}

default_iface(){ ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

# --- network stack detection --------------------------------------------------------
svc_active(){ command -v systemctl >/dev/null 2>&1 && systemctl is-active -q "$1" 2>/dev/null; }
detect_manager() {
    if command -v netplan >/dev/null 2>&1 && ls /etc/netplan/*.yaml >/dev/null 2>&1; then echo netplan
    elif svc_active NetworkManager; then echo networkmanager
    elif svc_active systemd-networkd && networkctl list 2>/dev/null | grep -qw configured; then echo networkd
    elif svc_active dhcpcd; then echo dhcpcd
    elif [ -f /etc/network/interfaces ] && grep -qE '^\s*iface\s+[^l]' /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null; then echo ifupdown
    else
        # Fall back to the distro's usual default.
        . /etc/os-release 2>/dev/null
        case " ${ID:-} ${ID_LIKE:-} " in
            *" ubuntu "*) echo netplan ;;
            *" arch "*)   echo networkd ;;
            *" debian "*|*" raspbian "*) echo ifupdown ;;
            *) echo generic ;;
        esac
    fi
}

# --- suggestions ----------------------------------------------------------------------
# Names used in every snippet.
set_names() {
    IFACE="${IFACE:-$(default_iface)}"; IFACE="${IFACE:-eth0}"
    if [ -n "$VLAN" ]; then DEV="${IFACE}.${VLAN}"; else DEV="$IFACE"; fi
}

hdr(){ echo; echo "  ${BOLD}$*${RST}"; }
code(){ sed 's/^/      /'; }

suggest_networkmanager() {
    local con
    con="$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v d="$IFACE" '$2==d{print $1; exit}')"
    con="${con:-<connection name for ${IFACE}>}"
    hdr "NetworkManager (nmcli) -- persistent"
    if [ -n "$VLAN" ]; then
        code <<EOF
sudo nmcli con add type vlan con-name omada-vlan${VLAN} ifname ${DEV} dev ${IFACE} id ${VLAN} \\
     ipv4.method manual ipv4.addresses ${IP} ipv4.never-default yes ipv6.method disabled
sudo nmcli con up omada-vlan${VLAN}
# undo: sudo nmcli con delete omada-vlan${VLAN}
EOF
    else
        code <<EOF
sudo nmcli con mod "${con}" +ipv4.addresses ${IP}
sudo nmcli con up "${con}"        # re-applies; SSH may blip for a second
# undo: sudo nmcli con mod "${con}" -ipv4.addresses ${IP} && sudo nmcli con up "${con}"
EOF
    fi
}

suggest_netplan() {
    hdr "netplan (Ubuntu) -- persistent: /etc/netplan/60-omada.yaml"
    echo "      ${DIM}netplan merges this with your existing file; ${IFACE} must be defined there.${RST}"
    if [ -n "$VLAN" ]; then
        code <<EOF
network:
  version: 2
  vlans:
    ${DEV}:
      id: ${VLAN}
      link: ${IFACE}
      addresses: [${IP}]
EOF
    else
        code <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      addresses: [${IP}]
EOF
    fi
    code <<EOF

sudo chmod 600 /etc/netplan/60-omada.yaml
sudo netplan try          # rolls back by itself after 120 s unless you confirm
EOF
}

suggest_networkd() {
    local nf
    nf="$(networkctl status "$IFACE" 2>/dev/null | awk -F': ' '/Network File/{print $2; exit}')"
    nf="${nf:-/etc/systemd/network/<file matching ${IFACE}>.network}"
    case "$nf" in /usr/lib/*|/lib/*|/run/*) nf="/etc/systemd/network/${nf##*/}" ;; esac
    hdr "systemd-networkd (Arch, minimal Debian) -- persistent"
    if [ -n "$VLAN" ]; then
        code <<EOF
# /etc/systemd/network/20-omada-vlan${VLAN}.netdev
[NetDev]
Name=${DEV}
Kind=vlan

[VLAN]
Id=${VLAN}

# /etc/systemd/network/20-omada-vlan${VLAN}.network
[Match]
Name=${DEV}

[Network]
Address=${IP}

# ${nf}.d/omada-vlan.conf   (drop-in: attaches the VLAN to ${IFACE})
[Network]
VLAN=${DEV}
EOF
    else
        code <<EOF
# ${nf}.d/omada.conf   (drop-in for the file that manages ${IFACE})
[Network]
Address=${IP}
EOF
    fi
    code <<EOF

sudo networkctl reload    # (older systemd: sudo systemctl restart systemd-networkd)
EOF
}

suggest_ifupdown() {
    hdr "ifupdown (/etc/network/interfaces, Debian) -- persistent"
    if [ -n "$VLAN" ]; then
        code <<EOF
sudo apt install vlan     # 8021q tooling ifupdown uses for ${DEV}

# /etc/network/interfaces.d/omada-vlan${VLAN}
auto ${DEV}
iface ${DEV} inet static
    address ${IP}
    vlan-raw-device ${IFACE}

sudo ifup ${DEV}
EOF
        echo "      ${DIM}Make sure /etc/network/interfaces has: source /etc/network/interfaces.d/*${RST}"
    else
        code <<EOF
# add to the existing "iface ${IFACE} ..." stanza in /etc/network/interfaces
    up   ip addr add ${IP} dev ${IFACE}
    down ip addr del ${IP} dev ${IFACE}

sudo ip addr add ${IP} dev ${IFACE}   # apply now without bouncing the link
EOF
    fi
}

suggest_dhcpcd() {
    hdr "dhcpcd (Raspberry Pi OS bullseye and older) -- persistent"
    if [ -n "$VLAN" ]; then
        echo "      ${DIM}dhcpcd can't create VLANs: create it with ifupdown, then give it the static address.${RST}"
        code <<EOF
sudo apt install vlan

# /etc/network/interfaces.d/omada-vlan${VLAN}
auto ${DEV}
iface ${DEV} inet manual
    vlan-raw-device ${IFACE}

# append to /etc/dhcpcd.conf
interface ${DEV}
static ip_address=${IP}
nogateway

sudo ifup ${DEV} && sudo systemctl restart dhcpcd
EOF
    else
        echo "      ${DIM}dhcpcd can't add a second address next to DHCP; use a small systemd unit:${RST}"
        suggest_generic_body
    fi
}

suggest_generic_body() {
    local up down
    if [ -n "$VLAN" ]; then
        up="ip link add link ${IFACE} name ${DEV} type vlan id ${VLAN} ; ip addr add ${IP} dev ${DEV} ; ip link set ${DEV} up"
        down="ip link del ${DEV}"
    else
        up="ip addr add ${IP} dev ${IFACE}"
        down="ip addr del ${IP} dev ${IFACE}"
    fi
    code <<EOF
# /etc/systemd/system/omada-net.service
[Unit]
Description=Omada management address (${IP}${VLAN:+ on VLAN ${VLAN}})
After=network-online.target
Wants=network-online.target
Before=tpeap.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '${up}'
ExecStop=/bin/sh -c '${down}'

[Install]
WantedBy=multi-user.target

sudo systemctl daemon-reload && sudo systemctl enable --now omada-net.service
EOF
}
suggest_generic(){ hdr "Any distro with systemd -- persistent"; suggest_generic_body; }

cmd_check() {
    local hit
    if hit="$(find_base_addr)"; then
        [ "$QUIET" = 1 ] || ok "This host has ${hit#* } on ${hit%% *} (inside ${BASE}) -- factory-default Omada devices are reachable."
        return 0
    fi
    if [ "$QUIET" = 0 ]; then
        warn "This host has no address in ${BASE} (Omada's factory-default network)."
        host_addrs | while read -r i a; do echo "      ${DIM}${i}  ${a}${RST}"; done
    fi
    return 1
}

cmd_suggest() {
    cmd_check && return 0
    set_names
    local m="${MANAGER:-$(detect_manager)}"
    . /etc/os-release 2>/dev/null
    cat <<EOF

  New (factory-default) Omada devices live on ${BASE} and are discovered by
  broadcast, so the controller won't see them from another subnet. Give this host a
  second address there -- no gateway, so your normal routing is unchanged:

      ${BOLD}${IP}${RST} on ${BOLD}${DEV}${RST}${VLAN:+  (tagged VLAN ${VLAN}; the switch port to this host must carry it tagged)}
      ${DIM}OS: ${PRETTY_NAME:-unknown}   network stack: ${m}${RST}
EOF
    [ -z "$VLAN" ] && echo "      ${DIM}(Omada devices on a tagged management VLAN? re-run with --vlan <ID>)${RST}"

    case "$m" in
        networkmanager) suggest_networkmanager ;;
        netplan)        suggest_netplan ;;
        networkd)       suggest_networkd ;;
        ifupdown)       suggest_ifupdown ;;
        dhcpcd)         suggest_dhcpcd ;;
        *)              suggest_generic ;;
    esac

    hdr "Try it first (until reboot)"
    echo "      sudo $(basename "$0") apply-temp${VLAN:+ --vlan ${VLAN}} --ip ${IP} --iface ${IFACE}"
    echo
    echo "  ${DIM}Pick an address that's free on ${BASE}. Once your devices are adopted and moved"
    echo "  to your own network, the extra address can be removed again.${RST}"
    echo
}

cmd_apply_temp() {
    set_names
    ip link show "$IFACE" >/dev/null 2>&1 || die "No interface '${IFACE}' (use --iface)."
    if [ -n "$VLAN" ]; then
        modprobe 8021q 2>/dev/null || true
        ip link show "$DEV" >/dev/null 2>&1 || ip link add link "$IFACE" name "$DEV" type vlan id "$VLAN" \
            || die "Couldn't create ${DEV}."
        ip link set "$DEV" up
    fi
    ip addr add "$IP" dev "$DEV" 2>/dev/null || ip addr show dev "$DEV" | grep -q " ${IP} " \
        || die "Couldn't add ${IP} to ${DEV}."
    ok "Added ${IP} on ${DEV} until reboot. Undo: sudo $(basename "$0") remove-temp${VLAN:+ --vlan ${VLAN}} --ip ${IP} --iface ${IFACE}"
}

cmd_remove_temp() {
    set_names
    if [ -n "$VLAN" ]; then ip link del "$DEV" 2>/dev/null && ok "Removed ${DEV}."
    else ip addr del "$IP" dev "$DEV" 2>/dev/null && ok "Removed ${IP} from ${DEV}."; fi
    return 0
}

[ $# -gt 0 ] || { usage; exit 1; }
CMD="$1"; shift
while [ $# -gt 0 ]; do
    case "$1" in
        --vlan)     shift; VLAN="${1:-}" ;;
        --vlan=*)   VLAN="${1#*=}" ;;
        --ip)       shift; IP="${1:-}" ;;
        --ip=*)     IP="${1#*=}" ;;
        --iface)    shift; IFACE="${1:-}" ;;
        --iface=*)  IFACE="${1#*=}" ;;
        --manager)  shift; MANAGER="${1:-}" ;;
        --manager=*) MANAGER="${1#*=}" ;;
        --base)     shift; BASE="${1:-}" ;;
        --base=*)   BASE="${1#*=}" ;;
        -q|--quiet) QUIET=1 ;;
        -h|--help)  usage; exit 0 ;;
        *)          die "Unknown argument '$1'." ;;
    esac
    shift
done
[ -z "$VLAN" ] || [[ "$VLAN" =~ ^[0-9]+$ && "$VLAN" -ge 1 && "$VLAN" -le 4094 ]] || die "--vlan must be 1-4094."
[[ "$IP" =~ ^[0-9]+(\.[0-9]+){3}/[0-9]+$ ]] || die "--ip must look like 192.168.0.250/24."
[[ "$BASE" =~ ^[0-9]+(\.[0-9]+){3}/[0-9]+$ ]] || die "--base must look like 192.168.0.0/24."
command -v ip >/dev/null 2>&1 || die "The 'ip' command (iproute2) is required."

case "$CMD" in
    check)       cmd_check ;;
    suggest)     cmd_suggest ;;
    apply-temp)  [ "$(id -u)" -eq 0 ] || die "Run as root."; cmd_apply_temp ;;
    remove-temp) [ "$(id -u)" -eq 0 ] || die "Run as root."; cmd_remove_temp ;;
    -h|--help|help) usage ;;
    *)           usage; exit 1 ;;
esac
