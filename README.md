# Omada Network Application — Raspberry Pi installer

Helper scripts that install [TP-Link's Omada Network Application](https://www.tp-link.com/support/download/omada-software-controller/) (the self-hosted Omada / EAP controller) on a **64-bit Raspberry Pi**, handling the Java, `jsvc` and — most importantly — **MongoDB** prerequisites that the official Linux package expects you to set up yourself.

The stock `install.sh` in TP-Link's Linux `.tar.gz` only *checks* for Java 17+, `jsvc`, `curl` and a `mongod` binary and exits if any is missing. On a Raspberry Pi, getting MongoDB installed is the hard part, because MongoDB has strict CPU and packaging constraints on ARM. These scripts do it correctly, then hand off to TP-Link's own installer.

> **Not affiliated with TP-Link.** This is an independent, unofficial helper. The scripts are MIT-licensed; the Omada Network Application itself is proprietary TP-Link software under its own EULA and is **not** included in this repo — you download it from TP-Link. See [Legal](#legal).

---

## Why this exists

The Omada Linux package is architecture-neutral **Java** — it will run on ARM under OpenJDK just fine. The friction is entirely in the external dependencies:

- **MongoDB on ARM is version-locked to the CPU.** Starting with MongoDB 5.0, `mongod` requires the **ARMv8.2-A** microarchitecture. A Raspberry Pi 4 (and earlier) is only ARMv8.0-A, so official MongoDB 5.0+ crashes immediately with `Illegal instruction (core dumped)`. A Pi 5 runs modern MongoDB natively; a Pi 4 needs either EOL MongoDB 4.4 or the unofficial patched builds described below.
- **The MongoDB apt repo has correct package names but non-obvious codenames.** The GPG signing key must be imported *before* the repo, or `apt-get update` fails with `NO_PUBKEY`. The official **Debian** repo does carry `arm64` packages — but on **Debian 13 "trixie"** you must point the repo at the **`bookworm`** codename, because MongoDB has not published a trixie server component yet (its trixie path only has the shell). The bookworm packages run fine on trixie.
- **Java differs by release.** Omada needs Java 17+. Bookworm/bullseye ship `openjdk-17`; **trixie ships `openjdk-21`** (no 17). The installer picks the right one automatically.
- **`libssl1.1` is gone on modern OSes, and the Pi 4 builds still need it.** The official Pi 5 packages use `libssl3` (shipped by bookworm/trixie). But *both* legacy MongoDB 4.4 **and** the unofficial themattman Pi 4 builds are linked against **OpenSSL 1.1** (`libcrypto.so.1.1`), which bookworm/trixie (and DietPi images built on them) dropped — so on a Pi 4 the installer adds `libssl1.1` back automatically. The last distro to ship it, Debian 11 *bullseye*, is end-of-life and has moved to `archive.debian.org`, so that's where the installer fetches it from (see [libssl1.1 details](#libssl11-on-bookworm--trixie--dietpi-pi-4)). The Pi 4 builds may also need a newer `libstdc++` (GCC 11+); the installer handles that too, verifying by actually running `mongod`.
- **32-bit ARM has no MongoDB at all.** There are no modern MongoDB builds for `armhf`, so a 32-bit Raspberry Pi OS simply cannot run Omada.

The installer detects your board's CPU capability and OS, then selects and installs the right MongoDB source and version — so you don't have to reverse-engineer any of the above.

---

## Compatibility

| Board | CPU | Microarch | MongoDB installed | Status |
|---|---|---|---|---|
| **Raspberry Pi 5** | Cortex-A76 | ARMv8.2-A | 8.0 (official apt) | ✅ Recommended |
| **Raspberry Pi 4 / 400 / CM4** | Cortex-A72 | ARMv8.0-A | 7.0 (unofficial [themattman](https://github.com/themattman/mongodb-raspberrypi-binaries) build) — or official 4.4 with `MONGO_SOURCE=apt` | ⚠️ Works; modern MongoDB is a community build |
| **Raspberry Pi 3 / 3B+** | Cortex-A53 | ARMv8.0-A | same as Pi 4 | ⚠️ Works but RAM-limited (1 GB); fine for a handful of devices |
| **Any Pi on a 32-bit OS** | — | `armhf` | none | ❌ Not supported — reflash a 64-bit OS |

**Requirements**

- Raspberry Pi OS / Raspbian or **DietPi**, **64-bit** (Debian *bullseye*, *bookworm*, or *trixie* based). Check with `uname -m` → must be `aarch64`.
- Root access (`sudo`).
- Internet access (to fetch packages).

> **Pi 4 / Pi 3 MongoDB options.** Because these boards are ARMv8.0, official MongoDB caps at end-of-life 4.4. By default the installer uses [themattman/mongodb-raspberrypi-binaries](https://github.com/themattman/mongodb-raspberrypi-binaries) — unofficial, best-effort builds that run **modern MongoDB 7.0** on the Pi 4's CPU. If you'd rather stay on official packages, pass `MONGO_SOURCE=apt` to get MongoDB 4.4 (note: 4.4 also needs `libssl1.1`, which isn't in Debian 12/13). A Pi 5 avoids the whole dilemma.

---

## Installation

1. **Download the official Omada package** for Linux from TP-Link and copy it to your Pi:
   [tp-link.com/support/download/omada-software-controller](https://www.tp-link.com/support/download/omada-software-controller/) → the **Linux (tar.gz)** file.

2. **Extract it and enter the folder:**
   ```bash
   tar -xzf Omada_Network_Application_v*_linux_x64.tar.gz
   cd Omada_Network_Application_v*_linux_x64
   ```

3. **Drop the scripts from this repo into that folder** (next to the stock `install.sh`):
   ```bash
   # e.g. clone this repo elsewhere and copy the scripts in:
   cp /path/to/omada-raspberrypi/*.sh .
   ```
   The installer also installs the three helpers (`omada-service.sh`, `omada-maintenance.sh`, `omada-network.sh`) as `/usr/local/sbin/omada-service`, `omada-maintenance` and `omada-network`, and sets up a [systemd service](#managing-the-service-systemd).

4. **Run it:**
   ```bash
   sudo bash install-raspberrypi.sh
   ```

The script installs OpenJDK 17, `jsvc`, `curl` and the correct MongoDB, then calls TP-Link's `install.sh` to install the controller and register it as a service. Before it starts it checks the Pi has an address on `192.168.0.x`, the network new Omada devices come up on, and if it doesn't, it prints the config to add one at the end (see [Network](#network-reaching-new-omada-devices-1921680x--vlan)). When it finishes, open:

```
https://<your-pi-ip>:8043
```

to complete the Omada setup wizard. (HTTP is on `:8088`, HTTPS on `:8043` by default.)

### Install options

| Command | What it does |
|---|---|
| `sudo bash install-raspberrypi.sh` | Install prerequisites, then run the Omada installer |
| `sudo bash install-raspberrypi.sh -y` | Same, non-interactive (passes `-y` through to `install.sh`) |
| `sudo bash install-raspberrypi.sh --data-dir /mnt/ssd/omada` | Put Omada's data/logs/work on this path (symlinked in) |
| `sudo bash install-raspberrypi.sh --fast-start` | Also enable AppCDS faster boot (Java 19+) |
| `sudo bash install-raspberrypi.sh --deps-only` | Install/verify prerequisites only, then stop |
| `sudo bash install-raspberrypi.sh --relocate-only --data-dir /mnt/ssd/omada` | Move an **existing** install's data to another disk; no (re)install |
| `sudo bash install-raspberrypi.sh --optimize-only` | Add AppCDS faster boot to an **existing** install; nothing else |
| `sudo bash install-raspberrypi.sh --upgrade` | Upgrade an **existing** install to the Omada version of the package this script is in — see [Upgrading Omada](#upgrading-omada-to-a-newer-release) |
| `sudo bash install-raspberrypi.sh --no-systemd` | Don't install the native systemd unit; keep TP-Link's SysV `tpeap` service only |
| `sudo bash install-raspberrypi.sh --skip-network-check` | Skip the `192.168.0.x` address check |
| `sudo bash install-raspberrypi.sh init-cluster-mode` | Passed through to TP-Link's installer for cluster setups |
| `sudo MONGO_VERSION=8.0 bash install-raspberrypi.sh` | Force a MongoDB version/series instead of auto-detecting |
| `sudo MONGO_SOURCE=apt bash install-raspberrypi.sh` | On a Pi 4/3, use official MongoDB 4.4 instead of the unofficial modern build |
| `sudo JAVA_PKG=openjdk-21-jre-headless bash install-raspberrypi.sh` | Force a specific JRE package |
| `sudo LIBSSL11_DEB=/path/libssl1.1_…_arm64.deb bash install-raspberrypi.sh` | Use a `libssl1.1` package you downloaded yourself (Pi 4/3; also picked up automatically if the `.deb` sits next to the script) |

Run interactively (no flags) and the script asks two questions before doing any work: whether your root filesystem is read-only, and where to store Omada's data. See [SD-card longevity & read-only root](#sd-card-longevity--read-only-root).

**MongoDB source/version selection.** By default: a **Pi 5** (ARMv8.2) gets **MongoDB 8.0** from the official Debian apt repo; a **Pi 4/3** (ARMv8.0) gets **MongoDB 7.0** from the unofficial [themattman](https://github.com/themattman/mongodb-raspberrypi-binaries) builds (since official 5.0+ won't run on that CPU). Override with `MONGO_VERSION=` (e.g. `7.0` on a Pi 5, `6.0` on a Pi 4) and `MONGO_SOURCE=apt|themattman`. On a Pi 4, `MONGO_SOURCE=apt` gives official EOL 4.4.

**Java selection.** Auto-picked per OS: `openjdk-17-jre-headless` on bookworm/bullseye, `openjdk-21-jre-headless` on trixie. Override with `JAVA_PKG=`. The script verifies the installed JRE is 17+ (Omada's minimum) before continuing.

---

## Managing the service (systemd)

TP-Link's installer registers an old-style SysV script (`/etc/init.d/tpeap`). `omada-service` replaces it with a native systemd unit, `/etc/systemd/system/tpeap.service` (alias `omada.service`). Because a native unit takes the place of the generated one with the same name, the controller can never be started twice. The unit:

- tracks the JVM through control.sh's PID file and **restarts it after a crash** (`Restart=on-failure`);
- gives the first boot after an upgrade **20 minutes** to migrate the database before calling it failed;
- waits for the disk that holds **relocated data** (`RequiresMountsFor=`), so a USB SSD that mounts late doesn't leave Omada with dangling symlinks;
- calls `/opt/tplink/EAPController/bin/control.sh`, so it keeps working across upgrades and with versioned releases.

The installer sets it up automatically. To add it to an existing install:

```bash
sudo bash omada-service.sh install       # writes + enables the unit, installs the `omada-service` command
```

Day to day:

```bash
sudo omada-service start | stop | restart
sudo omada-service status                # systemd state + whether the web UI answers
sudo omada-service logs                  # follow logs/server.log (Ctrl-C to quit)
sudo omada-service enable | disable      # start at boot, or don't
sudo omada-service uninstall             # remove the unit; `tpeap` takes over again
```

Plain `systemctl restart omada` works too. Avoid `tpeap stop`: it stops the process behind systemd's back.

---

## Updating with versioned releases (recommended)

`omada-maintenance` keeps every Omada version in its own folder, keeps the data in one shared place, and makes `/opt/tplink/EAPController` a symlink to the active version:

```
/opt/tplink/
  EAPController -> omada/current            # TP-Link's path: tpeap, init.d, the systemd unit all keep working
  omada/
    current  -> releases/6.0.0.24
    previous -> releases/5.15.24.18         # what `rollback` returns to
    releases/<version>/                     # bin lib properties …   data, logs, work -> ../../shared
    shared/{data,logs,work}                 # or symlinks to your relocated data disk
    snapshots/<time>__<from>__<to>/         # database copy taken at every switch
```

(With relocated data, snapshots go next to the data, e.g. `/mnt/ssd/omada/omada-snapshots/`.)

```bash
sudo omada-maintenance check                              # installed vs. newest on TP-Link's site
sudo omada-maintenance update --latest                    # find, download, prepare, switch
sudo omada-maintenance update --file ~/Omada_Network_Application_v6.0.0.24_linux_x64.tar.gz
sudo omada-maintenance update --url https://static.tp-link.com/…/….tar.gz --sha256 <hash>
sudo omada-maintenance status                             # releases, snapshots, health
sudo omada-maintenance rollback                           # back to `previous`, database included
```

**How close to zero downtime it gets.** An update runs in two phases:

1. **Prepare. The controller keeps running.** The script downloads and checks the package, unpacks it into `releases/<version>`, links it to the shared data and carries your settings over: the memory profile and AppCDS lines in `control.sh`, and the `omada.properties` values you or the installer changed (ports, MongoDB cache, `max.device`). It does not run TP-Link's `install.sh`.
2. **Switch. This is the only downtime.** Stop, snapshot the database, atomically flip `current`, start, then wait until the web UI answers. Downtime is one stop plus one start, a few minutes on a Pi, and the script prints how long it was.

True zero downtime isn't possible. Omada runs a single MongoDB on its data, and the new version migrates that database on first start, so the two versions can't run side by side. During the switch your **APs, switches and gateways keep forwarding traffic**; only management, statistics and captive portal pause.

Useful options for `update`:

| Option | Effect |
|---|---|
| `--prepare-only` | Do phase 1 now; switch later (e.g. at night) with `sudo omada-maintenance switch <version>` |
| `--auto-rollback` | If the new version doesn't answer within 15 min (`OMADA_HEALTH_TIMEOUT`), roll back automatically |
| `-y` | No prompts |
| `--no-snapshot` | Skip the database copy (faster, but rollback can't restore the database) |
| `--name <ver>` | Release name, if the version can't be read from the file name |
| `--force` | Rebuild an already-prepared release, or allow a downgrade |

**Rollback** points `current` back at `previous` **and restores the database snapshot** taken when you left that version. This matters because the old version can't read a database the new one has migrated. Changes made in the web UI after the switch are lost, and the database you abandoned is kept under `snapshots/…__abandoned`. `rollback <version>` goes back to any release still on disk. Use `--keep-data` to skip the restore when you know the versions share a database format.

**First run.** The first `update` converts a classic install (made by `install-raspberrypi.sh` or TP-Link's own `install.sh`) into this layout during the switch, so there's no extra restart. Run `sudo omada-maintenance adopt` to convert it on its own. Relocated data stays where it is.

**Housekeeping.** After each successful update, the newest 3 releases and snapshots are kept (`OMADA_KEEP`). `current`, `previous` and the snapshot that `rollback` needs are never deleted. Run `sudo omada-maintenance prune --keep N` to trim by hand. Each snapshot is a full copy of `data/`; on btrfs/XFS it's an instant reflink copy.

**`--latest`** reads TP-Link's download page for the newest Linux `.tar.gz` (`OMADA_DOWNLOAD_PAGE` changes the page). If TP-Link changes the page layout it may stop finding anything; then download the file yourself and use `--file`. Only `https://` URLs are accepted, and `--sha256` checks the file before anything is unpacked.

> Read the release notes before a big jump (e.g. 4.x → 5.x). If TP-Link requires an intermediate version, update to that first. If a release's `install.sh` does more than copy files, which is rare, use the TP-Link-style `--upgrade` below for that one step.

---

## Network: reaching new Omada devices (192.168.0.x / VLAN)

Factory-default Omada gear lives on **192.168.0.0/24**. A gateway such as the ER605 hands out that subnet from `192.168.0.1`, and APs and switches without a DHCP lease fall back to `192.168.0.254`. The controller finds new devices with a **broadcast** on that segment (UDP 29810). If the Pi only has an address in another subnet, say your home LAN on `10.0.0.x`, it won't see them until each one is pointed at the controller by hand (Discovery Utility, DHCP option 138, or the device's inform URL).

The fix is to give the Pi a **second address** in `192.168.0.0/24` with no gateway, so normal routing is untouched. Put it on the same cable, or on a **VLAN interface** if your Omada devices are on a tagged management VLAN. The installer checks for this, and `omada-network` prints the exact config for the network stack your OS uses:

```bash
omada-network check                       # is there a 192.168.0.x address?
omada-network suggest                     # second address on the same (untagged) LAN
omada-network suggest --vlan 10           # VLAN interface eth0.10 with 192.168.0.250/24
sudo omada-network apply-temp --vlan 10   # try it now; gone after reboot (remove-temp to undo)
```

| OS / setup | Network stack detected | What it suggests |
|---|---|---|
| Ubuntu (server & desktop) | **netplan** | `/etc/netplan/60-omada.yaml` (`vlans:` or extra `addresses:`), applied with `netplan try`, which reverts by itself if you lose access |
| Raspberry Pi OS bookworm+, Debian/Ubuntu desktop, many Arch installs | **NetworkManager** | `nmcli con add type vlan …` or `nmcli con mod … +ipv4.addresses` |
| Arch, minimal Debian | **systemd-networkd** | `.netdev` + `.network` for the VLAN plus a drop-in on your existing `.network` file |
| Debian server | **ifupdown** (`/etc/network/interfaces`) | `interfaces.d/` stanza with `vlan-raw-device` (needs the `vlan` package) |
| Raspberry Pi OS bullseye and older | **dhcpcd** | ifupdown VLAN + `dhcpcd.conf` static, or a small systemd unit |

Options: `--ip 192.168.0.250/24` (the default sits outside the gateway's default DHCP pool and avoids `.1` and `.254`), `--iface eth0`, `--manager <name>` to show another stack's config. For a VLAN, the switch port the Pi is plugged into must carry that VLAN **tagged**. Once your devices are adopted and moved onto your own network, you can remove the extra address. Nothing is written to your network config; the script only prints suggestions, plus the optional `apply-temp`.

---

## Upgrading Omada to a newer release

> **Prefer [`omada-maintenance update`](#updating-with-versioned-releases-recommended)**: it switches versions with minimal downtime and rolls back in one command. The `--upgrade` flow below is TP-Link's uninstall-then-reinstall path, kept for classic (non-versioned) installs. On a versioned install, `--upgrade` refuses and points you to `omada-maintenance`.

TP-Link ships new Omada Network Application releases (formerly *Omada SDN Controller*) as a fresh Linux `.tar.gz`. There's no in-place updater for the tar.gz install: TP-Link's supported path is *uninstall the old version, install the new one, let it migrate the database*. Doing that by hand on a Pi set up with this project would also throw away what the installer layered on top — the relocated `data`/`logs`/`work` symlinks, the memory profile and AppCDS — and leave you trusting the stock uninstaller's database backup. `--upgrade` does the whole thing safely in one command.

### Before you start

1. **Take a backup in the web UI**: *Settings → Maintenance → Backup & Restore → Backup*, and download the `.cfg` file to another machine. This is TP-Link's own, version-independent backup and the best way back if anything goes wrong.
2. **Read the release notes** for the version you're moving to on [TP-Link's download page](https://www.tp-link.com/support/download/omada-software-controller/). In particular:
   - **Upgrade path.** Small jumps (e.g. 5.14 → 5.15, 5.15 → 6.x) are fine. For big jumps from old versions (e.g. 3.x/4.x → 5.x or later), TP-Link sometimes requires an intermediate version first — follow what the notes say.
   - **Java / MongoDB requirements.** Omada 5.15.20+ needs Java 17+ (this installer already provides 17 or 21); MongoDB is supported up to 8.0. If a future release raises either minimum, upgrade that first.
   - **Downgrades aren't supported.** The new version migrates the database on first start and the old version can't read it afterwards — that's what the snapshot below is for.
3. **Make the root filesystem writable** if you use the read-only / overlay root (the upgrade writes to `/opt/tplink`). Re-enable it afterwards.

### Upgrade (recommended)

```bash
# 1. Get the new Linux package from TP-Link onto the Pi and extract it
tar -xzf Omada_Network_Application_v<NEW>_linux_x64.tar.gz
cd Omada_Network_Application_v<NEW>_linux_x64

# 2. Put this repo's scripts next to the NEW install.sh (pull this repo first for the latest fixes)
cp /path/to/omada-raspberrypi/install-raspberrypi.sh   .
cp /path/to/omada-raspberrypi/uninstall-raspberrypi.sh .

# 3. Upgrade (add -y to skip the confirmation prompt)
sudo bash install-raspberrypi.sh --upgrade
```

What `--upgrade` does:

1. **Records your current setup** — relocated data paths, the memory profile in use, whether AppCDS is on.
2. **Stops Omada and snapshots `data/`** (the database, keystore and autobackups) to `omada-data-<timestamp>.tar.gz` in `/opt/tplink/omada-rpi-backups/`, or next to your relocated data (`<data-disk>/omada-rpi-backups/`). Set `OMADA_BACKUP_DIR=` to put it elsewhere. It checks there's enough free space first.
3. **Moves `data/`, `logs/` and `work/` out of the install tree** into `/opt/tplink/omada-rpi-upgrade/` (an instant `mv` on the same disk). Relocated directories are only unlinked — the data never leaves your SSD.
4. **Runs the old version's `uninstall.sh`, then the new package's `install.sh`.** If the old version doesn't uninstall cleanly, your data is put straight back and nothing has changed.
5. **Puts your data back** (as symlinks again if it was relocated), keeping any new top-level folders the new version created. Your existing database is never mixed with the fresh one.
6. **Re-applies your memory profile and AppCDS** (TP-Link's installer overwrites `control.sh` and `omada.properties`), then **starts the controller**. The first start after an upgrade migrates the database and can take several minutes on a Pi — give it time before refreshing `https://<pi-ip>:8043`.

If the upgrade is interrupted (power loss, network failure, new `install.sh` fails), your data stays safe in `/opt/tplink/omada-rpi-upgrade/`. Fix the problem and run `sudo bash install-raspberrypi.sh --upgrade` again from the new package folder: it notices the staged data and **resumes** rather than starting over.

To change the memory profile during the upgrade, pass it: `--upgrade --profile oc300`. To turn on AppCDS at the same time, add `--fast-start`.

### Rolling back

If the new version misbehaves, go back to the old package with the pre-upgrade snapshot:

```bash
# from the OLD package folder (with this repo's scripts copied in)
sudo bash uninstall-raspberrypi.sh -y            # removes the new version (relocated data is left alone)
sudo bash install-raspberrypi.sh -y              # installs the old version (add --data-dir/--profile as before)
sudo tpeap stop
sudo find /opt/tplink/EAPController/data/ -mindepth 1 -delete
sudo tar -xzf /opt/tplink/omada-rpi-backups/omada-data-<timestamp>.tar.gz -C /opt/tplink/EAPController/data/
sudo tpeap start
```

(If your data was relocated, the snapshot is under `<data-disk>/omada-rpi-backups/`, and `data/` points at the data disk, so the commands above restore it in place.) Or install the old version fresh and restore the `.cfg` from the web UI.

### Upgrading the rest of the stack

- **Java / jsvc / libssl1.1** come from apt (or a `.deb`) and are updated with the rest of the system: `sudo apt update && sudo apt full-upgrade`. Restart Omada afterwards (`sudo tpeap restart`).
- **MongoDB on a Pi 5** (official apt) gets **minor** updates with `apt full-upgrade`. A **major** MongoDB upgrade (e.g. 7.0 → 8.0) is a separate, one-major-at-a-time job with a `featureCompatibilityVersion` step — only do it when an Omada release needs it, after a UI backup.
- **MongoDB on a Pi 4/3** (unofficial themattman build in `/usr/local/bin`) is never updated automatically. To move to a newer build of the **same** series, stop Omada, remove `/usr/local/bin/mongod`, and run `sudo MONGO_VERSION=7.0 bash install-raspberrypi.sh --deps-only`. Don't change major versions without a backup.
- **This repo's scripts**: `git pull` before an upgrade so the new package gets the latest fixes.

### Upgrading by hand (TP-Link's way)

If you'd rather not use `--upgrade`: take the UI backup, then `sudo tpeap stop`, run `sudo bash /opt/tplink/EAPController/uninstall.sh` and answer **y** to keeping a database backup (saved to `/opt/tplink/omada_db_backup/`), then run `sudo bash install.sh` from the new package folder (answer **y** if it offers to restore that backup). Afterwards, re-run `--relocate-only --data-dir …` if you had relocated data (the old data on the other disk is still there and is kept), `--profile-only --profile <name>`, and `--optimize-only` to restore those tweaks.

---

## Uninstalling

```bash
sudo bash uninstall-raspberrypi.sh                  # remove the Omada app only
sudo bash uninstall-raspberrypi.sh -y               # ... without prompts
sudo bash uninstall-raspberrypi.sh --remove-mongodb # also purge MongoDB + its apt repo
sudo bash uninstall-raspberrypi.sh --remove-deps    # also purge Java + jsvc
sudo bash uninstall-raspberrypi.sh --purge-all      # app + MongoDB + Java + jsvc
```

The uninstaller also removes the `omada-service` systemd unit and the helper commands. On a versioned install it leaves `/opt/tplink/omada` (releases, shared data, snapshots) in place and tells you, so you decide when the data goes. By default the uninstaller only removes the Omada application (via TP-Link's own `uninstall.sh`) and leaves the system packages alone, since Java/`curl`/MongoDB may be used by other things on the box. Package removal is opt-in via the flags above. `curl`, `gnupg` and `ca-certificates` are always kept, and the system MongoDB data dir `/var/lib/mongodb` is never auto-deleted. If TP-Link's uninstaller kept a database backup, it points you to `/opt/tplink/omada_db_backup/omada.db.tar.gz`.

---

## What the installer actually does

1. **Refuses 32-bit.** Exits early unless `dpkg --print-architecture` is `arm64` and `uname -m` is `aarch64`.
2. **Detects the board and CPU.** Reads `/proc/device-tree/model` and checks `/proc/cpuinfo` for the `atomics` (LSE) feature — present on ARMv8.2 (Pi 5), absent on ARMv8.0 (Pi 4/3) — to choose the MongoDB source and version.
3. **Installs base packages:** the OS-appropriate JRE (`openjdk-17` or `openjdk-21`), `jsvc`, `curl`, `gnupg`, `ca-certificates`, and verifies Java is 17+.
4. **Installs MongoDB.** On a Pi 5: imports the signing key **first**, then adds the official **Debian** `arm64` repo (component `main`; `bookworm` codename even on trixie) and installs `mongodb-org-server`. On a Pi 4/3: downloads the matching unofficial [themattman](https://github.com/themattman/mongodb-raspberrypi-binaries) `mongod` build into `/usr/local/bin` (or, with `MONGO_SOURCE=apt`, the official 4.4 repo).
5. **Installs the runtime libraries the Pi 4 build needs, verified by running `mongod`.** It loops, fixing whatever the loader reports: OpenSSL 1.1 (`libcrypto.so.1.1`) via `libssl1.1` — from a `.deb` you supplied, apt, or the newest `arm64` build on `archive.debian.org` (see [below](#libssl11-on-bookworm--trixie--dietpi-pi-4)) — and, on older OSes like bullseye, a GCC 11+ `libstdc++` from [themattman](https://github.com/themattman/raspberrypi-binaries) (repointing `libstdc++.so.6`, recording the original for uninstall). The Pi 5 apt path uses `libssl3`/`libstdc++` from the OS and skips all of this.
6. **Disables the distro `mongod.service`** (apt path only), because Omada launches and manages its *own* `mongod` on port `27217` with its own data dir.
7. **Exports `JAVA_HOME` and hands off to `install.sh`** to install Omada and register the `tpeap` service. (Exporting `JAVA_HOME` keeps the stock installer's jsvc version-check from printing a harmless "Cannot locate Java Home".)
8. **Relocates the writable data** (if you gave a `--data-dir` / answered the prompt) to that path and symlinks it back — see below.

---

## SD-card longevity & read-only root

SD cards wear out, and Omada is hard on them: MongoDB writes device/client statistics and its journal continuously. The two ways to protect the card are to **move the writes off it** and to **run the OS root read-only**. This installer supports both, and is designed so they work together.

**Where Omada writes.** Everything lives under `/opt/tplink/EAPController`, and all runtime writes fall into three directories: `data/` (the MongoDB database, keystore, autobackups), `logs/` (server and mongod logs), and `work/` (scratch). Nothing else under the install tree is written at runtime.

**Relocating the data.** When you pass `--data-dir /path` (or answer the prompt), the installer moves those three directories to your chosen disk after installation and replaces them with symlinks. Omada follows the symlinks transparently, so no configuration changes are needed. Point it at a USB SSD or a dedicated partition and the SD card sees essentially no runtime writes.

**Read-only / overlay root.** Because only symlinks then remain under `/opt/tplink`, you can enable Raspberry Pi OS's overlay filesystem (`raspi-config` → Performance Options → Overlay File System) and Omada keeps running — its data lives on the separate writable disk. The installer helps you get there safely:

- It **checks at the start** whether your root is already read-only or overlay-backed and stops with instructions if so, because installation itself needs a writable root. (Answer the read-only prompt honestly, or let auto-detection catch it.)
- After relocating, it reminds you that it's now safe to re-enable the overlay.

**Two important requirements for the read-only setup:**

1. The data disk **must be mounted at boot before Omada starts** — add it to `/etc/fstab`. If it isn't mounted, the symlinks dangle and MongoDB can't start.
2. The data path **must be on a separate filesystem from `/`**. The installer warns you if the path you gave is actually on the root device (which would defeat both goals).

**Retrofitting an existing install.** Already installed and want to move the data without reinstalling? Run:

```bash
sudo bash install-raspberrypi.sh --relocate-only --data-dir /mnt/ssd/omada
```

This stops Omada, moves `data`/`logs`/`work` to the new path, symlinks them, and restarts — no packages touched.

**Uninstall safety.** Because the relocated directories are symlinks, uninstalling (which does `rm -rf /opt/tplink/EAPController`) removes only the links, never your data on the separate disk. The uninstaller prints the external paths it left behind so you can remove them yourself if you want.

Complementary tweaks worth considering: mount the data disk with `noatime`, and keep MongoDB **journaling enabled** (`linux.mongod.nojournal=false`, the default) — it's what protects the database if the Pi loses power, so don't disable it to save writes; move the writes to better storage instead.

---

## Faster startup (AppCDS)

Omada is a large Spring Boot application (~500 jars), so first-boot on a Pi takes several minutes — most of it JVM class loading and Spring context initialization, not something a config flag makes "instant." But there's one lever that helps with **no downside for a controller that runs 24/7 and rarely restarts**: **Application Class-Data Sharing (AppCDS)**.

AppCDS memory-maps a pre-parsed archive of the application's classes, so on each boot the JVM skips re-parsing and re-verifying all those jars (and reads fewer files off the SD card). On Java 19+ it's self-managing via `-XX:+AutoCreateSharedArchive`: the archive is built on the first start, reused on every start after, and regenerated automatically if the classpath changes (e.g. an Omada upgrade).

Crucially, AppCDS has **no steady-state performance penalty**. The usual "fast Java startup" trick — `-XX:TieredStopAtLevel=1` — does: it caps the JIT at the C1 compiler, permanently lowering throughput for the whole uptime. That's the wrong trade for a box that boots rarely and then runs for weeks, so this project uses AppCDS instead.

Enable it at install time with `--fast-start`, or add it to an existing install without reinstalling:

```bash
sudo bash install-raspberrypi.sh --optimize-only
```

This appends the AppCDS flags to `control.sh`'s `JAVA_OPTS` (backing up the original as `control.sh.orig-omada-rpi`, idempotent), then restarts once to build the archive under `data/omada-app-cds.jsa` (on your SSD if you relocated data). The build restart itself isn't faster — the boot *after* it is. Because the flags live in `control.sh`, TP-Link's installer overwrites them on an upgrade — [`--upgrade`](#upgrading-omada-to-a-newer-release) puts them back for you (after a manual upgrade, re-run `--optimize-only`).

Measure the effect from the log — Spring records its own startup time:

```bash
grep -iE 'Started .* in .* seconds' /opt/tplink/EAPController/logs/*.log
```

Realistic expectation: AppCDS trims the class-loading portion (often ~20–40% of it), and moving `data/` to an SSD speeds MongoDB and the archive read — together a meaningful cut, but a big Spring app on a Pi won't become truly instant. Requires Java 19+ (so trixie's OpenJDK 21; on bookworm's OpenJDK 17 the script skips it with a notice).

---

## libssl1.1 on bookworm / trixie / DietPi (Pi 4)

Only Pi 4/3 installs need this (the unofficial themattman MongoDB and official 4.4 are built against OpenSSL 1.1); a Pi 5 uses the system `libssl3`.

`libssl1.1` was last shipped by Debian 11 *bullseye*. Bullseye is now end-of-life, so its packages are no longer on `deb.debian.org` / `security.debian.org` — they live on **`archive.debian.org`**. That's why older versions of this installer (and older guides) that fetched from `security.debian.org` now fail on fresh bookworm, trixie and DietPi systems.

The installer tries, in order, and checks every `.deb` really is `libssl1.1` for `arm64` before installing it:

1. A package you supply: `LIBSSL11_DEB=/path/to/file.deb` (or an `https://` URL), or any `libssl1.1_*_arm64.deb` placed **next to `install-raspberrypi.sh`**.
2. Your configured apt sources (works on bullseye itself).
3. The newest `libssl1.1` `arm64` build found in the Debian pools — `archive.debian.org/debian-security`, then `archive.debian.org/debian`, then the live mirrors.
4. A pinned, known-good build: [`libssl1.1_1.1.1w-0+deb11u1_arm64.deb`](https://archive.debian.org/debian/pool/main/o/openssl/libssl1.1_1.1.1w-0+deb11u1_arm64.deb) (bullseye's final point release; override with `LIBSSL11_FALLBACK_URL=`).

**Installing it yourself** (e.g. the Pi has no internet, or a proxy blocks `archive.debian.org`):

```bash
wget https://archive.debian.org/debian/pool/main/o/openssl/libssl1.1_1.1.1w-0+deb11u1_arm64.deb
sudo dpkg -i libssl1.1_1.1.1w-0+deb11u1_arm64.deb
# or drop the .deb next to install-raspberrypi.sh and just run the installer
```

`libssl1.1` installs alongside the system `libssl3` and doesn't replace it; only the MongoDB binary uses it. OpenSSL 1.1 is itself end-of-life upstream, which is one more reason a Pi 5 (system OpenSSL 3, official MongoDB) is the better long-term host.

---

## Troubleshooting

**`Illegal instruction (core dumped)` from mongod.** An official MongoDB ≥ 5.0 ran on a Pi 4 or earlier (ARMv8.0). The default Pi 4 path avoids this by using the unofficial [themattman](https://github.com/themattman/mongodb-raspberrypi-binaries) build; if you hit this you probably forced `MONGO_SOURCE=apt` with a modern version — use `MONGO_SOURCE=apt` (→ 4.4) or the default themattman build, or move to a Pi 5.

**`NO_PUBKEY` during `apt-get update` after adding the MongoDB repo.** The signing key wasn't imported before the repo. The installer does this in the right order; if you set it up by hand, `curl -fsSL https://pgp.mongodb.com/server-8.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg` **before** writing the `.list` file.

**`/bin/bash^M: bad interpreter` or `syntax error near unexpected token`.** The script has Windows (CRLF) line endings. Fix with `sed -i 's/\r$//' install-raspberrypi.sh` (or `dos2unix`). The included `.gitattributes` prevents this when committing from Windows.

**`E: Unable to locate package mongodb-org-server`.** The MongoDB repo didn't apply — usually a wrong codename (on trixie the repo must use `bookworm`), a missing key, or no internet. Confirm `uname -m` is `aarch64`, the key exists in `/usr/share/keyrings/`, and `apt-get update` succeeds.

**Unofficial MongoDB won't run (Pi 4): `No ... build found` or a library error.** The GitHub lookup couldn't find a matching build, or the binary is missing a shared library. Browse [the releases](https://github.com/themattman/mongodb-raspberrypi-binaries/releases), pick an available series, and set `MONGO_VERSION=` (e.g. `6.0`). If `ldd $(command -v mongod)` shows a missing lib, install it or fall back to `MONGO_SOURCE=apt`.

**`mongod: error while loading shared libraries: libcrypto.so.1.1` (Pi 4).** The themattman `mongod` is linked against OpenSSL 1.1, which bookworm/trixie replaced with OpenSSL 3. The installer fixes this automatically by adding `libssl1.1` (it provides `libcrypto.so.1.1` and `libssl.so.1.1`). To do it by hand, see [libssl1.1 on bookworm / trixie / DietPi](#libssl11-on-bookworm--trixie--dietpi-pi-4), then re-run.

**`... version 'GLIBCXX_3.4.29' not found` (Pi 4).** The unofficial `mongod` needs a GCC 11+ `libstdc++`; your OS (typically bullseye) is older. The installer detects this and installs [themattman's prebuilt `libstdc++`](https://github.com/themattman/raspberrypi-binaries/tree/main/libstdc%2B%2B) automatically, repointing `/lib/aarch64-linux-gnu/libstdc++.so.6` (a newer libstdc++ is backward-compatible, and the uninstaller restores the original). If you're doing it by hand, download the `.so` there and `ln -sf` it over `libstdc++.so.6`. Bookworm/trixie don't need this.

**`Cannot locate Java Home` / `JSVC is less than 1.1.0` during install.** Cosmetic — it comes from TP-Link's `install.sh` running `jsvc -help` without `JAVA_HOME` set. The installer now exports `JAVA_HOME` before the handoff, so you shouldn't see it; if you run the stock `install.sh` directly you will, but the service still starts fine (the launcher passes the Java home to jsvc explicitly).

**`jsvc not found` / `JRE is not installed`.** Run the prerequisite step again (`--deps-only`); these are installed by this script, not by TP-Link's.

**Port 8043 / 8088 in use, or can't reach the web UI.** Check the service with `sudo tpeap status` and logs under `/opt/tplink/EAPController/logs/`. Make sure nothing else is bound to Omada's ports (see `properties/omada.properties`).

**Omada won't start after enabling read-only root (relocated data).** Your data disk almost certainly isn't mounted at boot, so the `data`/`logs`/`work` symlinks point at nothing. Confirm the disk is in `/etc/fstab` and mounts before Omada starts (`findmnt /mnt/ssd/omada`), then `sudo tpeap start`.

**`libssl1.1` couldn't be installed automatically (Pi 4 on bookworm/trixie/DietPi).** Both the themattman builds and MongoDB 4.4 need `libssl1.1`, which modern Debian dropped. The installer pulls it from `archive.debian.org`; if that's unreachable (no internet, proxy, firewall), download [`libssl1.1_1.1.1w-0+deb11u1_arm64.deb`](https://archive.debian.org/debian/pool/main/o/openssl/libssl1.1_1.1.1w-0+deb11u1_arm64.deb) on any machine, copy it next to `install-raspberrypi.sh` (or `sudo dpkg -i` it), then re-run. (A Pi 5 uses `libssl3` and avoids this entirely.)

**New Omada devices don't show up for adoption.** The controller probably isn't on their `192.168.0.x` segment. Run `omada-network suggest` (add `--vlan <ID>` for a tagged management VLAN) and see [Network](#network-reaching-new-omada-devices-1921680x--vlan).

**`omada-maintenance update` says the new version didn't come up.** Look at `sudo omada-service logs`. A database migration on a Pi can take a long time, so raise `OMADA_HEALTH_TIMEOUT` (seconds) if it was still migrating. `sudo omada-maintenance rollback` returns to the previous release and database. If the update was interrupted mid-switch, `omada-maintenance status` shows which release is active, and `switch` or `rollback` finishes the job.

**`--upgrade` stopped part-way.** Your data is in `/opt/tplink/omada-rpi-upgrade/` (relocated data never moved) and there's a snapshot in `omada-rpi-backups/`. Fix the cause shown in the log, then run `sudo bash install-raspberrypi.sh --upgrade` again from the **new** package folder — it resumes. Don't delete `/opt/tplink/omada-rpi-upgrade/` by hand.

---

## Notes & caveats

- These scripts are tested for **syntax and logic** but the maintainer can't exercise every Pi-model / OS-version combination. PRs and issue reports with your board + OS + outcome are welcome.
- The scripts are **version-agnostic** — they don't hard-code an Omada version and work with current v5.x/v6.x Linux packages. They rely on the stock `install.sh` being present in the same folder.
- **On a Pi 4/3, the default MongoDB is an unofficial community build** ([themattman](https://github.com/themattman/mongodb-raspberrypi-binaries)) installed to `/usr/local/bin` and not managed by apt (no automatic security updates — update it by re-running or replacing the binary). The official alternative (`MONGO_SOURCE=apt`) is end-of-life MongoDB 4.4. Understand the trade-off; a Pi 5 runs official current MongoDB.
- Always keep backups of your Omada configuration (Settings → Maintenance → Backup) before upgrading either Omada or MongoDB. See [Upgrading Omada](#upgrading-omada-to-a-newer-release).

---

## Legal

This project is an independent, unofficial helper and is **not affiliated with, endorsed by, or supported by TP-Link**. It does **not** redistribute the Omada Network Application; you must download that from TP-Link and accept TP-Link's license. The scripts and documentation in this repository are released under the [MIT License](LICENSE). "Omada", "TP-Link", "MongoDB", "Raspberry Pi", and "Debian" are trademarks of their respective owners.

## References

- Omada — [Linux install requirements](https://support.omadanetworks.com/us/document/13088/) (Java 17+ for v5.15.20+, MongoDB up to v8)
- MongoDB — ARM64 microarchitecture requirement (ARMv8.2-A for 5.0+): [Production Notes](https://www.mongodb.com/docs/manual/administration/production-notes/)
- MongoDB — [Install on Debian](https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-debian/) (key-before-repo, apt setup)
- [themattman/mongodb-raspberrypi-binaries](https://github.com/themattman/mongodb-raspberrypi-binaries) — unofficial modern MongoDB builds for the Pi 4 (ARMv8.0)
- MongoDB 5.0 core-dump on Raspberry Pi 4 (ARMv8.0): [MongoDB forums](https://www.mongodb.com/community/forums/t/core-dump-on-mongodb-5-0-on-rpi-4/115291)
- Omada on Debian 13 (trixie) walkthrough: [gist](https://gist.github.com/subtlecaffeine/8d5113d9739e7da110cc4ee995b06fba)
- TP-Link — [Omada Software Controller downloads](https://www.tp-link.com/support/download/omada-software-controller/)