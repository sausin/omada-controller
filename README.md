# Omada Network Application — Raspberry Pi installer

Helper scripts that install [TP-Link's Omada Network Application](https://www.tp-link.com/support/download/omada-software-controller/) (the self-hosted Omada / EAP controller) on a **64-bit Raspberry Pi**, handling the Java, `jsvc` and — most importantly — **MongoDB** prerequisites that the official Linux package expects you to set up yourself.

The stock `install.sh` in TP-Link's Linux `.tar.gz` only *checks* for Java 17, `jsvc`, `curl` and a `mongod` binary and exits if any is missing. On a Raspberry Pi, getting MongoDB installed is the hard part, because MongoDB has strict CPU and packaging constraints on ARM. These scripts do it correctly, then hand off to TP-Link's own installer.

> **Not affiliated with TP-Link.** This is an independent, unofficial helper. The scripts are MIT-licensed; the Omada Network Application itself is proprietary TP-Link software under its own EULA and is **not** included in this repo — you download it from TP-Link. See [Legal](#legal).

---

## Why this exists

The Omada Linux package is architecture-neutral **Java** — it will run on ARM under OpenJDK just fine. The friction is entirely in the external dependencies:

- **MongoDB on ARM is version-locked to the CPU.** Starting with MongoDB 5.0, `mongod` requires the **ARMv8.2-A** microarchitecture. A Raspberry Pi 4 (and earlier) is only ARMv8.0-A, so MongoDB 5.0+ crashes immediately with `Illegal instruction (core dumped)`. Only a Raspberry Pi 5 can run modern MongoDB.
- **MongoDB ships no `arm64` packages in its Debian repo.** The obvious `deb .../apt/debian bookworm/...` line has no ARM packages and fails. MongoDB *does* publish `arm64` packages under its **Ubuntu** repo, which install cleanly on Debian-based Raspberry Pi OS. These scripts use that.
- **32-bit ARM has no MongoDB at all.** There are no modern MongoDB builds for `armhf`, so a 32-bit Raspberry Pi OS simply cannot run Omada.

The installer detects your board's CPU capability and OS, then selects and installs the right MongoDB version from the right repo — so you don't have to reverse-engineer any of the above.

---

## Compatibility

| Board | CPU | Microarch | MongoDB it installs | Status |
|---|---|---|---|---|
| **Raspberry Pi 5** | Cortex-A76 | ARMv8.2-A | 7.0 (or 8.0) | ✅ Recommended |
| **Raspberry Pi 4 / 400 / CM4** | Cortex-A72 | ARMv8.0-A | 4.4 (end-of-life) | ⚠️ Works, but stuck on EOL MongoDB 4.4 |
| **Raspberry Pi 3 / 3B+** | Cortex-A53 | ARMv8.0-A | 4.4 (end-of-life) | ⚠️ Works but RAM-limited (1 GB); fine for a handful of devices |
| **Any Pi on a 32-bit OS** | — | `armhf` | none | ❌ Not supported — reflash a 64-bit OS |

**Requirements**

- Raspberry Pi OS / Raspbian, **64-bit** (Debian *bullseye* or *bookworm*). Check with `uname -m` → must be `aarch64`.
- Root access (`sudo`).
- Internet access (to fetch packages).

> **On a Pi 4 you will be on MongoDB 4.4, which is past end-of-life upstream.** It runs Omada perfectly well, but receives no security updates. If that matters to you, use a Raspberry Pi 5.

---

## Installation

1. **Download the official Omada package** for Linux from TP-Link and copy it to your Pi:
   [tp-link.com/support/download/omada-software-controller](https://www.tp-link.com/support/download/omada-software-controller/) → the **Linux (tar.gz)** file.

2. **Extract it and enter the folder:**
   ```bash
   tar -xzf Omada_Network_Application_v*_linux_x64.tar.gz
   cd Omada_Network_Application_v*_linux_x64
   ```

3. **Drop the two scripts from this repo into that folder** (next to the stock `install.sh`):
   ```bash
   # e.g. clone this repo elsewhere and copy the scripts in:
   cp /path/to/omada-raspberrypi/install-raspberrypi.sh   .
   cp /path/to/omada-raspberrypi/uninstall-raspberrypi.sh .
   ```

4. **Run it:**
   ```bash
   sudo bash install-raspberrypi.sh
   ```

The script installs OpenJDK 17, `jsvc`, `curl` and the correct MongoDB, then calls TP-Link's `install.sh` to install the controller and register it as a service. When it finishes, open:

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
| `sudo bash install-raspberrypi.sh --deps-only` | Install/verify prerequisites only, then stop |
| `sudo bash install-raspberrypi.sh --relocate-only --data-dir /mnt/ssd/omada` | Move an **existing** install's data to another disk; no (re)install |
| `sudo bash install-raspberrypi.sh init-cluster-mode` | Passed through to TP-Link's installer for cluster setups |
| `sudo MONGO_VERSION=8.0 bash install-raspberrypi.sh` | Force a MongoDB version instead of auto-detecting |
| `sudo JAVA_PKG=openjdk-21-jre-headless bash install-raspberrypi.sh` | Use a different JDK/JRE package |

Run interactively (no flags) and the script asks two questions before doing any work: whether your root filesystem is read-only, and where to store Omada's data. See [SD-card longevity & read-only root](#sd-card-longevity--read-only-root).

**MongoDB version selection.** By default the script auto-detects: a Pi 5 (ARMv8.2) gets **MongoDB 7.0**, a Pi 4/3 (ARMv8.0) gets **MongoDB 4.4**. On a Pi 5 you can opt into **8.0** with `MONGO_VERSION=8.0`. If you pin a 5.0+ version on a CPU that can't run it, the script warns you before proceeding.

---

## Uninstalling

```bash
sudo bash uninstall-raspberrypi.sh                  # remove the Omada app only
sudo bash uninstall-raspberrypi.sh -y               # ... without prompts
sudo bash uninstall-raspberrypi.sh --remove-mongodb # also purge MongoDB + its apt repo
sudo bash uninstall-raspberrypi.sh --remove-deps    # also purge Java + jsvc
sudo bash uninstall-raspberrypi.sh --purge-all      # app + MongoDB + Java + jsvc
```

By default the uninstaller only removes the Omada application (via TP-Link's own `uninstall.sh`) and leaves the system packages alone, since Java/`curl`/MongoDB may be used by other things on the box. Package removal is opt-in via the flags above. `curl`, `gnupg` and `ca-certificates` are always kept, and the system MongoDB data dir `/var/lib/mongodb` is never auto-deleted. If TP-Link's uninstaller kept a database backup, it points you to `/opt/tplink/omada_db_backup/omada.db.tar.gz`.

---

## What the installer actually does

1. **Refuses 32-bit.** Exits early unless `dpkg --print-architecture` is `arm64` and `uname -m` is `aarch64`.
2. **Detects the board and CPU.** Reads `/proc/device-tree/model` and checks `/proc/cpuinfo` for the `atomics` (LSE) feature — present on ARMv8.2 (Pi 5), absent on ARMv8.0 (Pi 4/3) — to decide which MongoDB series is safe.
3. **Installs base packages:** `openjdk-17-jre-headless`, `jsvc`, `curl`, `gnupg`, `ca-certificates`.
4. **Adds the MongoDB apt repo** from MongoDB's **Ubuntu** channel with `arch=arm64` (`focal` for 4.4, `jammy` for 7.0/8.0), imports the signing key, and installs `mongodb-org-server`.
5. **Fixes the Pi 4 / MongoDB 4.4 `libssl1.1` gap** on bookworm (which ships `libssl3` instead), pulling `libssl1.1` from the Debian archive if apt can't provide it.
6. **Disables the distro `mongod.service`,** because Omada launches and manages its *own* `mongod` on port `27217` with its own data dir — leaving the system service running would just waste memory on a second, unused instance.
7. **Hands off to `install.sh`** to install Omada and register the `tpeap` service.
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

## Troubleshooting

**`Illegal instruction (core dumped)` from mongod.** You installed a MongoDB ≥ 5.0 on a Pi 4 or earlier. Those CPUs are ARMv8.0 and cannot run it. Reinstall with `MONGO_VERSION=4.4`, or move to a Pi 5.

**`/bin/bash^M: bad interpreter` or `syntax error near unexpected token`.** The script has Windows (CRLF) line endings. Fix with `sed -i 's/\r$//' install-raspberrypi.sh` (or `dos2unix`). The included `.gitattributes` prevents this when committing from Windows.

**`E: Unable to locate package mongodb-org-server`.** The MongoDB repo didn't apply — usually a non-`arm64`/32-bit OS (unsupported), or `apt-get update` couldn't reach the repo. Confirm `uname -m` is `aarch64` and that you have internet access.

**`jsvc not found` / `JRE is not installed`.** Run the prerequisite step again (`--deps-only`); these are installed by this script, not by TP-Link's.

**Port 8043 / 8088 in use, or can't reach the web UI.** Check the service with `sudo tpeap status` and logs under `/opt/tplink/EAPController/logs/`. Make sure nothing else is bound to Omada's ports (see `properties/omada.properties`).

**Omada won't start after enabling read-only root (relocated data).** Your data disk almost certainly isn't mounted at boot, so the `data`/`logs`/`work` symlinks point at nothing. Confirm the disk is in `/etc/fstab` and mounts before Omada starts (`findmnt /mnt/ssd/omada`), then `sudo tpeap start`.

**`libssl1.1` couldn't be installed (Pi 4 on bookworm).** The archive URL's point-release rotates over time. Grab the current `libssl1.1` `arm64` `.deb` from the [Debian buster security pool](http://security.debian.org/debian-security/pool/updates/main/o/openssl/), `sudo dpkg -i` it, and re-run.

---

## Notes & caveats

- These scripts are tested for **syntax and logic** but the maintainer can't exercise every Pi-model / OS-version combination. PRs and issue reports with your board + OS + outcome are welcome.
- The scripts are **version-agnostic** — they don't hard-code an Omada version and work with current v5.x/v6.x Linux packages. They rely on the stock `install.sh` being present in the same folder.
- MongoDB 4.4 on a Pi 4 is **end-of-life** upstream; understand the security trade-off.
- Always keep backups of your Omada configuration (Settings → Maintenance → Backup) before upgrading either Omada or MongoDB.

---

## Legal

This project is an independent, unofficial helper and is **not affiliated with, endorsed by, or supported by TP-Link**. It does **not** redistribute the Omada Network Application; you must download that from TP-Link and accept TP-Link's license. The scripts and documentation in this repository are released under the [MIT License](LICENSE). "Omada", "TP-Link", "MongoDB", "Raspberry Pi", "Debian" and "Ubuntu" are trademarks of their respective owners.

## References

- MongoDB — ARM64 microarchitecture requirement (ARMv8.2-A for 5.0+): [Production Notes](https://www.mongodb.com/docs/manual/administration/production-notes/)
- MongoDB — [Install on Debian/Ubuntu](https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-debian/) (see the supported-platforms matrix for `arm64` availability)
- MongoDB community thread on missing Debian `arm64` packages: [Why no arm64 for Debian 12?](https://www.mongodb.com/community/forums/t/whys-there-no-community-server-arm64-packages-for-debian-12-bookworm/292998)
- MongoDB 5.0 core-dump on Raspberry Pi 4 (ARMv8.0): [MongoDB forums](https://www.mongodb.com/community/forums/t/core-dump-on-mongodb-5-0-on-rpi-4/115291)
- TP-Link — [Omada Software Controller downloads](https://www.tp-link.com/support/download/omada-software-controller/)
