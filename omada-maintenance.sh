#!/bin/bash
#
# omada-maintenance.sh
# ------------------------------------------------------------------------------
# Versioned updates and rollback for the TP-Link Omada Network Application.
#
# Every Omada version gets its own directory, the data lives in one shared place,
# and /opt/tplink/EAPController becomes a symlink to the active version:
#
#   /opt/tplink/
#     EAPController -> omada/current          (TP-Link's path; tpeap, init.d keep working)
#     omada/
#       current  -> releases/6.0.0.24          (switched atomically)
#       previous -> releases/5.15.24.18        (one command to go back)
#       releases/<version>/                    (bin lib properties ...; data logs work -> ../../shared)
#       shared/{data,logs,work}                (or symlinks to a relocated data disk)
#       snapshots/<time>__<from>__<to>/        (database copy taken at each switch)
#
# Updating has two phases:
#   1. PREPARE (controller keeps running): get the package (your file, a URL, or the
#      newest one on TP-Link's site), check it, unpack it into releases/<version>,
#      link it to the shared data and carry over your settings (memory profile,
#      AppCDS, changed ports in omada.properties).
#   2. SWITCH (the only downtime): stop -> snapshot the database -> flip `current`
#      -> start -> wait until the web UI answers. Downtime is one controller stop
#      plus one start (a few minutes on a Pi). APs, switches and gateways keep
#      forwarding traffic the whole time; only management/portal pauses. True zero
#      downtime isn't possible: Omada runs one MongoDB on its data and the new
#      version migrates it on first start.
#
# Rollback flips `current` back AND restores the database snapshot taken when you
# left that version (the new version's migrated database can't be read by the old
# one). Changes made in the UI since the switch are lost; the abandoned database is
# kept under snapshots/ in case you need it.
#
# Usage:
#   sudo omada-maintenance status                       # versions, snapshots, health
#   sudo omada-maintenance check                        # newest version on TP-Link's site
#   sudo omada-maintenance update --file Omada_..._linux_x64.tar.gz
#   sudo omada-maintenance update --url https://static.tp-link.com/.../...tar.gz [--sha256 HASH]
#   sudo omada-maintenance update --latest              # find + download the newest release
#        options: -y (no prompts)  --prepare-only (stage now, switch later)
#                 --no-snapshot  --auto-rollback (roll back if the new version won't come up)
#                 --name NAME (release dir name if the version can't be detected)  --force
#   sudo omada-maintenance switch <version>             # activate a prepared release
#   sudo omada-maintenance rollback [<version>]         # back to `previous` (or <version>)
#        options: --keep-data (don't restore the snapshot)  -y
#   sudo omada-maintenance adopt                        # convert a classic install to this layout
#   sudo omada-maintenance prune [--keep N]             # delete old releases/snapshots
#
# The first `update` adopts a classic install automatically (during the switch, so
# no extra restart). Works with installs made by install-raspberrypi.sh or by
# TP-Link's own install.sh, on any Linux.
#
# Overrides (environment):
#   OMADA_ROOT=/opt/tplink/omada   OMADA_SNAPSHOT_DIR=PATH   OMADA_KEEP=3 (releases + snapshots kept)
#   OMADA_HEALTH_TIMEOUT=900 (seconds to wait for the web UI after a switch)
#   OMADA_DOWNLOAD_PAGE=URL (where --latest/check look for the Linux package)
# ------------------------------------------------------------------------------

set -o pipefail

if [ -t 1 ]; then
    RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[36m'; DIM=$'\e[2m'; BOLD=$'\e[1m'; RST=$'\e[0m'
else
    RED=''; GRN=''; YLW=''; BLU=''; DIM=''; BOLD=''; RST=''
fi
info(){ echo "  ${BLU}*${RST} $*"; }
ok(){   echo "  ${GRN}OK${RST} $*"; }
warn(){ echo "  ${YLW}!${RST} $*" >&2; }
die(){  echo "  ${RED}x${RST} $*" >&2; exit 1; }

INSTALL_LINK="${OMADA_INSTALL_BASE:-/opt/tplink/EAPController}"
OMADA_ROOT="${OMADA_ROOT:-/opt/tplink/omada}"
RELEASES="${OMADA_ROOT}/releases"
SHARED="${OMADA_ROOT}/shared"
CURRENT="${OMADA_ROOT}/current"
PREVIOUS="${OMADA_ROOT}/previous"
DOWNLOADS="${OMADA_ROOT}/downloads"
KEEP="${OMADA_KEEP:-3}"
HEALTH_TIMEOUT="${OMADA_HEALTH_TIMEOUT:-900}"
DOWNLOAD_PAGE="${OMADA_DOWNLOAD_PAGE:-https://www.tp-link.com/us/support/download/omada-software-controller/}"
UNIT_FILE="/etc/systemd/system/tpeap.service"
META=".omada-release"
DIRS="data logs work"

usage(){ sed -n '5,/^# -----/p' "$0" | sed '$d; s/^#\s\{0,1\}//'; }

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    local a; read -r -p "  $1 (y/N): " a
    case "${a^^}" in Y|YES) return 0 ;; *) return 1 ;; esac
}

# --- layout helpers -------------------------------------------------------------
is_managed(){ [ -L "$INSTALL_LINK" ] && [ -L "$CURRENT" ]; }
current_name(){ is_managed && basename "$(readlink -f "$CURRENT")"; }
previous_name(){ [ -L "$PREVIOUS" ] && [ -d "$(readlink -f "$PREVIOUS")" ] && basename "$(readlink -f "$PREVIOUS")"; }
# Tree of the running version: the current release, or the classic install dir.
active_tree(){ if is_managed; then readlink -f "$CURRENT"; else echo "$INSTALL_LINK"; fi; }

# Atomically point symlink $2 at $1 (rename(2) over the old link).
swap_link() {
    ln -sfn "$1" "$2.tmp.$$" && mv -Tf "$2.tmp.$$" "$2"
}

# Where database snapshots go: beside the real data dir, so a copy can use reflinks
# and moving a database aside is a same-disk rename.
snapshot_dir() {
    if [ -n "${OMADA_SNAPSHOT_DIR:-}" ]; then echo "$OMADA_SNAPSHOT_DIR"; return; fi
    local d; d="$(readlink -f "$(active_tree)/data" 2>/dev/null)"
    if [ -n "$d" ] && [ "$d" != "${SHARED}/data" ] && [ "$d" != "${INSTALL_LINK}/data" ]; then
        echo "$(dirname "$d")/omada-snapshots"          # relocated data disk
    else
        echo "${OMADA_ROOT}/snapshots"
    fi
}

# --- version detection ------------------------------------------------------------
# From a package/file name: Omada_Network_Application_v6.0.0.24_linux_x64 -> 6.0.0.24
version_from_name(){ printf '%s\n' "$1" | grep -oE '[vV][0-9]+(\.[0-9]+)+' | head -n1 | cut -c2-; }

# From an installed tree: our metadata, else the most common version among omada jars.
version_from_tree() {
    local t="$1" v
    if [ -f "${t}/${META}" ]; then v="$(sed -n 's/^VERSION=//p' "${t}/${META}" | head -n1)"; [ -n "$v" ] && { echo "$v"; return; }; fi
    ls "${t}/lib" 2>/dev/null | grep -i '^omada' \
        | sed -nE 's/.*-([0-9]+(\.[0-9]+){2,})(-[A-Za-z0-9]+)?\.jar$/\1/p' \
        | sort | uniq -c | sort -rn | awk 'NR==1{print $2}'
}

# --- controller start/stop (systemd-aware) ------------------------------------------
unit_is_ours(){ [ -f "$UNIT_FILE" ] && grep -q '^# Managed by omada-service' "$UNIT_FILE" && command -v systemctl >/dev/null 2>&1; }
omada_running(){ pgrep -f com.tplink.smb.omada.starter.OmadaLinuxMain >/dev/null 2>&1; }

omada_stop() {
    unit_is_ours && systemctl stop tpeap.service >/dev/null 2>&1
    [ -x "${INSTALL_LINK}/bin/control.sh" ] && omada_running && "${INSTALL_LINK}/bin/control.sh" stop >/dev/null 2>&1
    local i
    for i in $(seq 1 30); do
        omada_running || pgrep -f 'mongod.*27217' >/dev/null 2>&1 || return 0
        sleep 1
    done
    pkill -f 'mongod.*27217' >/dev/null 2>&1; sleep 1
    omada_running && die "Omada didn't stop; aborting before touching anything."
    return 0
}

omada_start() {
    if unit_is_ours; then
        # Regenerate the unit (its RequiresMountsFor follows the data paths).
        command -v omada-service >/dev/null 2>&1 && omada-service install >/dev/null 2>&1
        systemctl start tpeap.service >/dev/null 2>&1 || true
    else
        "${INSTALL_LINK}/bin/control.sh" start >/dev/null 2>&1 || true
    fi
}

# Wait until the web UI answers (any HTTP status) or the JVM dies.
wait_healthy() {
    local props="${INSTALL_LINK}/properties/omada.properties" https http code start=$SECONDS
    https="$(sed -n 's/^manage\.https\.port=//p' "$props" 2>/dev/null | head -n1)"; https="${https:-8043}"
    http="$(sed -n 's/^manage\.http\.port=//p' "$props" 2>/dev/null | head -n1)"; http="${http:-8088}"
    info "Waiting for the web UI (up to $(( (HEALTH_TIMEOUT+59)/60 )) min; a database migration takes a while)..."
    while [ $((SECONDS-start)) -lt "$HEALTH_TIMEOUT" ]; do
        code="$(curl -sk -o /dev/null -m 5 -w '%{http_code}' "https://127.0.0.1:${https}/" 2>/dev/null)"
        [ -z "$code" ] || [ "$code" = "000" ] && \
            code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:${http}/" 2>/dev/null)"
        if [ -n "$code" ] && [ "$code" != "000" ]; then return 0; fi
        if [ $((SECONDS-start)) -gt 60 ] && ! omada_running; then
            warn "The controller process exited."; return 1
        fi
        sleep 5
    done
    return 1
}

# --- package acquisition -------------------------------------------------------------
# Newest Linux tar.gz linked from TP-Link's download page (best effort: page layout
# can change; use --url/--file if this finds nothing).
find_latest_url() {
    curl -fsSL -m 60 -A 'Mozilla/5.0 (omada-maintenance)' "$DOWNLOAD_PAGE" 2>/dev/null \
        | grep -oE '(https?:)?//static\.tp-link\.com/[^"'\'' <>]+_[Ll]inux_x64[^"'\'' <>]*\.tar\.gz' \
        | sed -E 's#^(https?:)?//#https://#' | sort -u \
        | while read -r u; do printf '%s %s\n' "$(version_from_name "${u##*/}")" "$u"; done \
        | sort -V | tail -n1 | cut -d' ' -f2
}

download() {
    local url="$1" out
    case "$url" in https://*) : ;; *) die "Only https:// URLs are accepted (got '$url')." ;; esac
    mkdir -p "$DOWNLOADS"
    out="${DOWNLOADS}/$(basename "${url%%\?*}")"
    case "$out" in *.tar.gz|*.tgz) : ;; *) out="${out}.tar.gz" ;; esac
    if [ -s "$out" ] && tar -tzf "$out" >/dev/null 2>&1; then
        info "Using previously downloaded ${out}" >&2
    else
        info "Downloading ${url} ..." >&2
        curl -fSL --retry 3 -o "${out}.part" "$url" >&2 || { rm -f "${out}.part"; die "Download failed."; }
        mv "${out}.part" "$out"
    fi
    echo "$out"
}

# --- carrying settings into a new release --------------------------------------------
# prop_get FILE KEY / prop_set FILE KEY VALUE  (values passed via ENVIRON: no escaping issues)
prop_get(){ K="$2" awk 'BEGIN{k=ENVIRON["K"]"="} index($0,k)==1{print substr($0,length(k)+1); exit}' "$1" 2>/dev/null; }
prop_set() {
    K="$2" V="$3" awk 'BEGIN{k=ENVIRON["K"]"="; v=ENVIRON["V"]}
        index($0,k)==1 && !done {print k v; done=1; next} {print}
        END{if(!done) print k v}' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
prop_keys(){ grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | grep '=' | cut -d= -f1; }

carry_settings() {
    local old="$1" new="$2"
    local octl="${old}/bin/control.sh" nctl="${new}/bin/control.sh"
    local oprops="${old}/properties/omada.properties" nprops="${new}/properties/omada.properties"

    # Pristine copies, the same convention install-raspberrypi.sh uses for re-applying.
    [ -f "$nctl" ]   && cp -a "$nctl"   "${nctl}.orig-omada-rpi"
    [ -f "$nprops" ] && cp -a "$nprops" "${nprops}.orig-omada-rpi"

    # 1) control.sh: the memory-profile block and the AppCDS lines, inserted after the
    #    first JAVA_OPTS= line exactly like the installer does.
    if [ -f "$octl" ] && [ -f "$nctl" ]; then
        local blk; blk="$(mktemp)"
        awk '/# >>> omada-rpi-profile >>>/{p=1} p{print} /# <<< omada-rpi-profile <<</{p=0}
             /omada-rpi-fast-start/{print; getline; print}' "$octl" > "$blk"
        if [ -s "$blk" ]; then
            if grep -q '^JAVA_OPTS=' "$nctl"; then
                awk -v f="$blk" '{print} /^JAVA_OPTS=/ && !d {while((getline l < f)>0) print l; d=1}' \
                    "$nctl" > "${nctl}.tmp" && mv "${nctl}.tmp" "$nctl" && chmod 755 "$nctl"
                ok "Carried memory profile / AppCDS settings into control.sh"
            else
                warn "New control.sh has no JAVA_OPTS line; re-apply your profile with install-raspberrypi.sh --profile-only."
            fi
        fi
        rm -f "$blk"
    fi

    # 2) omada.properties: what you (or the installer) changed. Against the old
    #    pristine copy when there is one; otherwise just the port settings.
    [ -f "$oprops" ] && [ -f "$nprops" ] || return 0
    local base="${oprops}.orig-omada-rpi" k ov bv nv wt carried="" skipped=""
    for k in $(prop_keys "$oprops"); do
        ov="$(prop_get "$oprops" "$k")"; nv="$(prop_get "$nprops" "$k")"
        [ "$ov" = "$nv" ] && continue
        if [ -f "$base" ]; then
            bv="$(prop_get "$base" "$k")"
            [ "$ov" = "$bv" ] && continue                  # unchanged there; take the new default
        elif [[ "$k" != *port* ]]; then
            skipped="${skipped} ${k}"; continue
        fi
        if [ "$k" = "eap.mongod.args" ]; then
            # Only our cache size: the rest of the line belongs to the new version.
            wt="$(printf '%s' "$ov" | grep -oE -- '--wiredTigerCacheSizeGB[ ]+[0-9.]+' | awk '{print $2}')"
            [ -n "$wt" ] || continue
            nv="$(printf '%s' "$nv" | sed -E 's/ ?--wiredTigerCacheSizeGB[ ]+[0-9.]+//')"
            prop_set "$nprops" "$k" "${nv} --wiredTigerCacheSizeGB ${wt}"
        else
            prop_set "$nprops" "$k" "$ov"
        fi
        carried="${carried} ${k}"
    done
    [ -n "$carried" ] && ok "Carried omada.properties settings:${carried}"
    [ -n "$skipped" ] && warn "omada.properties differs from the new defaults for:${skipped} -- kept the NEW values; review ${nprops} if you had customised them."
    return 0
}

# --- prepare ------------------------------------------------------------------------
# prepare_release PKG_DIR NAME SOURCE  -> releases/NAME (controller untouched)
prepare_release() {
    local pkg="$1" name="$2" src="$3" dest="${RELEASES}/$2" tmp n
    tmp="${RELEASES}/.${name}.preparing"
    rm -rf "$tmp"; mkdir -p "$RELEASES"
    info "Copying the package into ${dest} ..."
    cp -a "${pkg}/." "$tmp/" || die "Copy failed (disk full?)."
    for n in $DIRS; do
        # Keep what the package ships in data/ etc. so new top-level entries can be
        # merged into the shared dirs at switch time.
        [ -e "${tmp}/${n}" ] && mv "${tmp}/${n}" "${tmp}/.omada-pkg-${n}"
        ln -s "${SHARED}/${n}" "${tmp}/${n}"
    done
    carry_settings "$(active_tree)" "$tmp"
    {
        printf 'VERSION=%s\n' "$name"
        printf 'SOURCE=%s\n' "$src"
        printf 'PREPARED=%s\n' "$(date -Is)"
    } > "${tmp}/${META}"
    rm -rf "$dest"; mv "$tmp" "$dest"
    ok "Prepared release ${name} (controller still running the old version)."
}

# --- adopt (needs the controller stopped) --------------------------------------------
adopt_layout() {
    is_managed && return 0
    [ -L "$INSTALL_LINK" ] && die "${INSTALL_LINK} is a symlink but ${CURRENT} is missing; fix the layout by hand."
    [ -d "$INSTALL_LINK" ] || die "Omada is not installed at ${INSTALL_LINK}."
    local v name n src
    v="$(version_from_tree "$INSTALL_LINK")"
    name="${v:-installed-$(date +%Y%m%d)}"
    [ -e "${RELEASES}/${name}" ] && name="${name}-adopted-$(date +%Y%m%d%H%M%S)"
    info "Adopting the existing install as release ${name} ..."
    mkdir -p "$RELEASES" "$SHARED"
    for n in $DIRS; do
        src="${INSTALL_LINK}/${n}"
        [ -e "${SHARED}/${n}" ] && die "${SHARED}/${n} already exists; refusing to mix data."
        if [ -L "$src" ]; then
            ln -s "$(readlink -f "$src")" "${SHARED}/${n}"   # relocated: data stays on its disk
            rm -f "$src"
        elif [ -d "$src" ]; then
            mv "$src" "${SHARED}/${n}"
        else
            mkdir -p "${SHARED}/${n}"
        fi
        ok "  ${n}/ -> ${SHARED}/${n}"
    done
    mv "$INSTALL_LINK" "${RELEASES}/${name}"
    for n in $DIRS; do ln -s "${SHARED}/${n}" "${RELEASES}/${name}/${n}"; done
    printf 'VERSION=%s\nSOURCE=adopted\nPREPARED=%s\n' "$v" "$(date -Is)" > "${RELEASES}/${name}/${META}"
    swap_link "releases/${name}" "$CURRENT"
    ln -sfn "$CURRENT" "$INSTALL_LINK"
    ok "  ${INSTALL_LINK} -> ${CURRENT} -> releases/${name}"
}

# --- switch ---------------------------------------------------------------------------
# Copy the database while the controller is stopped (reflink = instant on btrfs/XFS).
take_snapshot() {
    local from="$1" to="$2" data snapd dir need avail
    data="$(readlink -f "${SHARED}/data")"
    snapd="$(snapshot_dir)"; mkdir -p "$snapd" || die "Can't create ${snapd}."
    need="$(du -sk "$data" 2>/dev/null | awk '{print $1}')"
    avail="$(df -Pk "$snapd" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -n "$need" ] && [ -n "$avail" ] && [ "$avail" -lt "$need" ]; then
        omada_start
        die "Not enough space in ${snapd} for a database snapshot (${need} KB needed, ${avail} KB free). Run 'prune', set OMADA_SNAPSHOT_DIR, or pass --no-snapshot. The old version was restarted."
    fi
    dir="${snapd}/$(date +%Y%m%d-%H%M%S)__${from}__${to}"
    info "Snapshotting the database -> ${dir} ..."
    mkdir -p "$dir"
    cp -a --reflink=auto "${data}/." "${dir}/" || { rm -rf "$dir"; omada_start; die "Snapshot failed; the old version was restarted."; }
    ok "Snapshot: ${dir}"
}

merge_pkg_entries() {
    local rel="$1" n e dst
    for n in $DIRS; do
        [ -d "${rel}/.omada-pkg-${n}" ] || continue
        dst="$(readlink -f "${SHARED}/${n}")"; mkdir -p "$dst"
        for e in "${rel}/.omada-pkg-${n}"/* "${rel}/.omada-pkg-${n}"/.[!.]*; do
            [ -e "$e" ] || continue
            [ -e "${dst}/${e##*/}" ] || cp -a "$e" "${dst}/"
        done
    done
}

# do_switch TARGET SNAPSHOT(0|1)
do_switch() {
    local target="$1" snap="$2" from t0=$SECONDS
    [ -d "${RELEASES}/${target}" ] || die "No prepared release '${target}' in ${RELEASES}."
    is_managed && [ "$(current_name)" = "$target" ] && die "${target} is already the active release."
    info "Stopping the controller ..."
    omada_stop
    adopt_layout
    from="$(current_name)"
    [ "$snap" = 1 ] && take_snapshot "$from" "$target"
    merge_pkg_entries "${RELEASES}/${target}"
    local u="${OMADA_USER:-root}"
    chown -R "${u}:$(id -gn "$u" 2>/dev/null || echo root)" "$(readlink -f "${SHARED}/data")/" 2>/dev/null || true
    swap_link "releases/${from}" "$PREVIOUS"
    swap_link "releases/${target}" "$CURRENT"
    ok "Switched: ${from} -> ${BOLD}${target}${RST}"
    info "Starting ${target} ..."
    omada_start
    if wait_healthy; then
        ok "${target} is up. Controller downtime: $(( (SECONDS-t0)/60 ))m $(( (SECONDS-t0)%60 ))s"
        return 0
    fi
    warn "${target} didn't come up within $(( (HEALTH_TIMEOUT+59)/60 )) min (see ${INSTALL_LINK}/logs/server.log)."
    return 1
}

# --- commands ---------------------------------------------------------------------------
cmd_status() {
    local cur prev r v src mark
    if ! is_managed; then
        if [ -d "$INSTALL_LINK" ]; then
            info "Classic install at ${INSTALL_LINK} (version $(version_from_tree "$INSTALL_LINK" || echo '?'))."
            info "It's converted to the versioned layout on the first 'update' (or run 'adopt')."
        else
            warn "Omada is not installed at ${INSTALL_LINK}."
        fi
    else
        cur="$(current_name)"; prev="$(previous_name)"
        echo "  ${BOLD}Releases${RST} ${DIM}(${RELEASES})${RST}"
        for r in $(ls -1 "$RELEASES" 2>/dev/null | sort -V); do
            [ -d "${RELEASES}/${r}" ] || continue
            src="$(sed -n 's/^SOURCE=//p' "${RELEASES}/${r}/${META}" 2>/dev/null)"
            mark="  "; [ "$r" = "$cur" ] && mark="${GRN}* ${RST}"; [ "$r" = "$prev" ] && mark="${DIM}< ${RST}"
            printf '    %s%-24s %s%s%s\n' "$mark" "$r" "$DIM" "${src##*/}" "$RST"
        done
        echo "    ${DIM}* current   < previous (rollback target)${RST}"
        echo "  ${BOLD}Snapshots${RST} ${DIM}($(snapshot_dir))${RST}"
        ls -1d "$(snapshot_dir)"/*__* 2>/dev/null | while read -r r; do
            printf '    %-52s %s\n' "${r##*/}" "$(du -sh "$r" 2>/dev/null | cut -f1)"
        done
    fi
    if omada_running; then ok "Controller is running."; else warn "Controller is not running."; fi
}

cmd_check() {
    local url cur latest
    url="$(find_latest_url)"
    [ -n "$url" ] || die "Couldn't find a Linux package on ${DOWNLOAD_PAGE} (page layout may have changed)."
    latest="$(version_from_name "${url##*/}")"
    cur="$(version_from_tree "$(active_tree)")"
    echo "  Installed : ${cur:-unknown}"
    echo "  Latest    : ${latest}   ${DIM}${url}${RST}"
    if [ -n "$cur" ] && [ "$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | tail -n1)" = "$cur" ]; then
        ok "Up to date."
    else
        info "Update with: sudo omada-maintenance update --latest"
    fi
}

cmd_update() {
    [ -n "$FILE$URL$LATEST" ] || die "Say where the package comes from: --file PATH, --url URL or --latest."
    [ -x "${INSTALL_LINK}/bin/control.sh" ] || die "Omada is not installed at ${INSTALL_LINK}; install it first (install-raspberrypi.sh or TP-Link's install.sh)."

    # 1) Get the package.
    if [ "$LATEST" = 1 ]; then
        URL="$(find_latest_url)"
        [ -n "$URL" ] || die "Couldn't find a Linux package on ${DOWNLOAD_PAGE}; download it yourself and use --file."
        info "Newest package on TP-Link's site: ${URL##*/}"
    fi
    if [ -n "$URL" ]; then FILE="$(download "$URL")" || exit 1; fi
    [ -f "$FILE" ] || die "No such file: ${FILE}"
    if [ -n "$SHA256" ]; then
        echo "${SHA256}  ${FILE}" | sha256sum -c --status || die "SHA-256 mismatch for ${FILE}."
        ok "SHA-256 verified."
    fi
    tar -tzf "$FILE" >/dev/null 2>&1 || die "${FILE} isn't a readable .tar.gz."

    # 2) Unpack into a scratch dir on the same disk and find the package root.
    mkdir -p "$OMADA_ROOT"
    local pkg name cur
    STAGE="$(mktemp -d "${OMADA_ROOT}/.staging.XXXXXX")" || die "Can't create a staging dir in ${OMADA_ROOT}."
    trap 'rm -rf "$STAGE"' EXIT
    tar -xzf "$FILE" -C "$STAGE" --no-same-owner || die "Extracting ${FILE} failed."
    pkg="$(find "$STAGE" -maxdepth 3 -type f -path '*/bin/control.sh' 2>/dev/null | head -n1)"
    pkg="${pkg%/bin/control.sh}"
    [ -n "$pkg" ] && [ -f "${pkg}/install.sh" ] && [ -d "${pkg}/lib" ] \
        || die "${FILE##*/} doesn't look like an Omada Linux package (no bin/control.sh + lib/ + install.sh)."

    name="${NAME:-$(version_from_name "${pkg##*/}")}"
    [ -n "$name" ] || name="$(version_from_name "${FILE##*/}")"
    [ -n "$name" ] || name="$(version_from_tree "$pkg")"
    [ -n "$name" ] || die "Couldn't tell the version from '${FILE##*/}'; pass --name <version>."
    case "$name" in */*|.*) die "Bad release name '${name}'." ;; esac

    cur="$(version_from_tree "$(active_tree)")"
    if is_managed && [ "$(current_name)" = "$name" ]; then
        ok "${name} is already the active release. Nothing to do."; return 0
    fi
    if [ -n "$cur" ] && [ "$cur" != "$name" ] && [ "$(printf '%s\n%s\n' "$cur" "$name" | sort -V | tail -n1)" = "$cur" ]; then
        warn "${name} is OLDER than the running ${cur}. TP-Link doesn't support downgrades"
        warn "(the database has been migrated). To go back, use: omada-maintenance rollback"
        [ "$FORCE" = 1 ] || die "Refusing to downgrade without --force."
    fi
    echo
    echo "  ${BOLD}Update${RST}  ${cur:-installed} -> ${BOLD}${name}${RST}"
    echo

    # 3) Prepare while the old version keeps running.
    if [ -d "${RELEASES}/${name}" ] && [ "$FORCE" = 0 ]; then
        ok "Release ${name} is already prepared; reusing it (--force to rebuild)."
    else
        prepare_release "$pkg" "$name" "${FILE##*/}"
    fi
    rm -rf "$STAGE"; trap - EXIT

    if [ "$PREPARE_ONLY" = 1 ]; then
        echo
        ok "Prepared. Switch when convenient: sudo omada-maintenance switch ${name}"
        return 0
    fi

    # 4) Switch (the only downtime).
    echo
    echo "  Ready to switch. The controller will be down for one stop + start"
    echo "  ${DIM}(devices keep forwarding traffic; only management/portal pauses).${RST}"
    confirm "Switch to ${name} now?" || { ok "Not switched. Later: sudo omada-maintenance switch ${name}"; return 0; }
    finish_switch "$name"
}

finish_switch() {
    local target="$1"
    [ "$NO_SNAPSHOT" = 1 ] && warn "--no-snapshot: rolling back will NOT restore the old database."
    if do_switch "$target" $((1-NO_SNAPSHOT)); then
        prune_quiet
        echo
        echo "  If something is wrong: ${BOLD}sudo omada-maintenance rollback${RST}"
        return 0
    fi
    if [ "$AUTO_ROLLBACK" = 1 ]; then
        warn "--auto-rollback: going back to $(previous_name)."
        local failed="$target" back; back="$(previous_name)"
        ASSUME_YES=1; KEEP_DATA=0; cmd_rollback ""
        die "Update to ${failed} failed; rolled back to ${back}. Its database snapshot was restored."
    else
        die "Check the log; to go back: sudo omada-maintenance rollback"
    fi
}

cmd_switch() {
    [ -n "$1" ] || die "Usage: omada-maintenance switch <version>   (see 'status')"
    finish_switch "$1"
}

cmd_rollback() {
    is_managed || die "Nothing to roll back to: this install isn't using versioned releases yet."
    local cur target snap="" snapd d aside realdata
    cur="$(current_name)"
    target="${1:-$(previous_name)}"
    [ -n "$target" ] || die "No previous release recorded; name one: omada-maintenance rollback <version>"
    [ -d "${RELEASES}/${target}" ] || die "No release '${target}' in ${RELEASES}."
    [ "$target" = "$cur" ] && die "${target} is already active."

    snapd="$(snapshot_dir)"
    if [ "$KEEP_DATA" = 0 ]; then
        # The snapshot taken when we switched from TARGET to the current release.
        snap="$(ls -1d "${snapd}"/*__"${target}"__"${cur}" 2>/dev/null | sort | tail -n1)"
        if [ -z "$snap" ]; then
            warn "No database snapshot for ${target} -> ${cur}. ${target} would start on the"
            warn "database ${cur} has already migrated, which it may not be able to read."
            warn "Safer: restore a UI backup (.cfg) afterwards, or pass --keep-data to accept this."
            [ "$ASSUME_YES" = 1 ] || confirm "Roll back WITHOUT restoring a snapshot?" || die "Rollback cancelled."
        fi
    fi
    echo
    echo "  ${BOLD}Rollback${RST}  ${cur} -> ${BOLD}${target}${RST}"
    [ -n "$snap" ] && echo "  Database restored from ${snap##*/} ${DIM}(UI changes since then are lost;"
    [ -n "$snap" ] && echo "  the current database is kept under ${snapd})${RST}"
    confirm "Roll back now?" || die "Rollback cancelled."

    local t0=$SECONDS
    omada_stop
    if [ -n "$snap" ]; then
        realdata="$(readlink -f "${SHARED}/data")"
        aside="${snapd}/$(date +%Y%m%d-%H%M%S)__${cur}__abandoned"
        mkdir -p "$aside"
        # Move contents (not the dir) so a mountpoint or relocation symlink stays intact.
        for d in "$realdata"/* "$realdata"/.[!.]*; do [ -e "$d" ] && mv "$d" "$aside/"; done
        cp -a --reflink=auto "${snap}/." "${realdata}/" || die "Restoring ${snap} failed. Current database is in ${aside}."
        ok "Database restored from ${snap##*/} (previous one kept in ${aside##*/})."
    fi
    swap_link "releases/${cur}" "$PREVIOUS"
    swap_link "releases/${target}" "$CURRENT"
    ok "Switched: ${cur} -> ${target}"
    omada_start
    if wait_healthy; then
        ok "${target} is up. Downtime: $(( (SECONDS-t0)/60 ))m $(( (SECONDS-t0)%60 ))s"
    else
        die "${target} didn't come up; check ${INSTALL_LINK}/logs/server.log."
    fi
}

cmd_adopt() {
    is_managed && { ok "Already using versioned releases."; return 0; }
    confirm "Convert ${INSTALL_LINK} to versioned releases? (stops + restarts the controller)" || die "Cancelled."
    omada_stop; adopt_layout; omada_start
    wait_healthy && ok "Controller is up on the versioned layout." || warn "Controller didn't answer yet; check the logs."
}

# Keep the newest $KEEP releases and snapshots; never current/previous.
prune() {
    local keep="$1" cur prev r n=0
    cur="$(current_name)"; prev="$(previous_name)"
    for r in $(ls -1t "$RELEASES" 2>/dev/null); do
        [ -d "${RELEASES}/${r}" ] || continue
        [ "$r" = "$cur" ] || [ "$r" = "$prev" ] && { n=$((n+1)); continue; }
        n=$((n+1)); [ "$n" -le "$keep" ] && continue
        rm -rf "${RELEASES:?}/${r}" && ok "Removed old release ${r}"
    done
    n=0
    for r in $(ls -1dt "$(snapshot_dir)"/*__* 2>/dev/null); do
        case "$r" in *__"${prev}"__"${cur}") continue ;; esac      # the one `rollback` needs
        n=$((n+1)); [ "$n" -le "$keep" ] && continue
        rm -rf "$r" && ok "Removed old snapshot ${r##*/}"
    done
    rm -rf "$DOWNLOADS"/*.part 2>/dev/null
    return 0
}
prune_quiet(){ prune "$KEEP" >/dev/null 2>&1 || true; }

# --- arguments ----------------------------------------------------------------------------
ASSUME_YES=0; FILE=""; URL=""; LATEST=""; SHA256=""; NAME=""; FORCE=0
PREPARE_ONLY=0; NO_SNAPSHOT=0; AUTO_ROLLBACK=0; KEEP_DATA=0; POS=()
[ $# -gt 0 ] || { usage; exit 1; }
CMD="$1"; shift
while [ $# -gt 0 ]; do
    case "$1" in
        -y|-Y)            ASSUME_YES=1 ;;
        --file)           shift; FILE="${1:-}" ;;
        --file=*)         FILE="${1#*=}" ;;
        --url)            shift; URL="${1:-}" ;;
        --url=*)          URL="${1#*=}" ;;
        --latest)         LATEST=1 ;;
        --sha256)         shift; SHA256="${1:-}" ;;
        --sha256=*)       SHA256="${1#*=}" ;;
        --name)           shift; NAME="${1:-}" ;;
        --name=*)         NAME="${1#*=}" ;;
        --keep)           shift; KEEP="${1:-3}" ;;
        --keep=*)         KEEP="${1#*=}" ;;
        --force)          FORCE=1 ;;
        --prepare-only)   PREPARE_ONLY=1 ;;
        --no-snapshot)    NO_SNAPSHOT=1 ;;
        --auto-rollback)  AUTO_ROLLBACK=1 ;;
        --keep-data)      KEEP_DATA=1 ;;
        -h|--help)        usage; exit 0 ;;
        -*)               die "Unknown option '$1'." ;;
        *)                POS+=("$1") ;;
    esac
    shift
done
case "$KEEP" in ''|*[!0-9]*) die "--keep needs a number." ;; esac

case "$CMD" in -h|--help|help) usage; exit 0 ;; esac
[ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0 $CMD"

case "$CMD" in
    status)   cmd_status ;;
    check)    cmd_check ;;
    update)   cmd_update ;;
    switch)   cmd_switch "${POS[0]:-}" ;;
    rollback) cmd_rollback "${POS[0]:-}" ;;
    adopt)    cmd_adopt ;;
    prune)    is_managed || die "Not using versioned releases yet."; prune "$KEEP" ;;
    *)        usage; exit 1 ;;
esac
