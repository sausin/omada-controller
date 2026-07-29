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
- **`libssl1.1` is gone on modern OSes, and the Pi 4 builds still need it.** The official Pi 5 packages use `libssl3` (shipped by bookworm/trixie). But *both* legacy MongoDB 4.4 **and** the unofficial themattman Pi 4 builds are linked against **OpenSSL 1.1** (`libcrypto.so.1.1`), which bookworm/trixie dropped — so on a Pi 4 the installer adds `libssl1.1` back automatically. The Pi 4 builds may also need a newer `libstdc++` (GCC 11+); the installer handles that too, verifying by actually running `mongod`.
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

- Raspberry Pi OS / Raspbian, **64-bit** (Debian *bullseye*, *bookworm*, or *trixie*). Check with `uname -m` → must be `aarch64`.
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
| `sudo MONGO_VERSION=8.0 bash install-raspberrypi.sh` | Force a MongoDB version/series instead of auto-detecting |
| `sudo MONGO_SOURCE=apt bash install-raspberrypi.sh` | On a Pi 4/3, use official MongoDB 4.4 instead of the unofficial modern build |
| `sudo JAVA_PKG=openjdk-21-jre-headless bash install-raspberrypi.sh` | Force a specific JRE package |

Run interactively (no flags) and the script asks two questions before doing any work: whether your root filesystem is read-only, and where to store Omada's data. See [SD-card longevity & read-only root](#sd-card-longevity--read-only-root).

**MongoDB source/version selection.** By default: a **Pi 5** (ARMv8.2) gets **MongoDB 8.0** from the official Debian apt repo; a **Pi 4/3** (ARMv8.0) gets **MongoDB 7.0** from the unofficial [themattman](https://github.com/themattman/mongodb-raspberrypi-binaries) builds (since official 5.0+ won't run on that CPU). Override with `MONGO_VERSION=` (e.g. `7.0` on a Pi 5, `6.0` on a Pi 4) and `MONGO_SOURCE=apt|themattman`. On a Pi 4, `MONGO_SOURCE=apt` gives official EOL 4.4.

**Java selection.** Auto-picked per OS: `openjdk-17-jre-headless` on bookworm/bullseye, `openjdk-21-jre-headless` on trixie. Override with `JAVA_PKG=`. The script verifies the installed JRE is 17+ (Omada's minimum) before continuing.

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
2. **Detects the board and CPU.** Reads `/proc/device-tree/model` and checks `/proc/cpuinfo` for the `atomics` (LSE) feature — present on ARMv8.2 (Pi 5), absent on ARMv8.0 (Pi 4/3) — to choose the MongoDB source and version.
3. **Installs base packages:** the OS-appropriate JRE (`openjdk-17` or `openjdk-21`), `jsvc`, `curl`, `gnupg`, `ca-certificates`, and verifies Java is 17+.
4. **Installs MongoDB.** On a Pi 5: imports the signing key **first**, then adds the official **Debian** `arm64` repo (component `main`; `bookworm` codename even on trixie) and installs `mongodb-org-server`. On a Pi 4/3: downloads the matching unofficial [themattman](https://github.com/themattman/mongodb-raspberrypi-binaries) `mongod` build into `/usr/local/bin` (or, with `MONGO_SOURCE=apt`, the official 4.4 repo).
5. **Installs the runtime libraries the Pi 4 build needs, verified by running `mongod`.** It loops, fixing whatever the loader reports: OpenSSL 1.1 (`libcrypto.so.1.1`) via `libssl1.1` — auto-discovering the newest `arm64` `.deb` from the Debian pool — and, on older OSes like bullseye, a GCC 11+ `libstdc++` from [themattman](https://github.com/themattman/raspberrypi-binaries) (repointing `libstdc++.so.6`, recording the original for uninstall). The Pi 5 apt path uses `libssl3`/`libstdc++` from the OS and skips all of this.
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

## Troubleshooting

**`Illegal instruction (core dumped)` from mongod.** An official MongoDB ≥ 5.0 ran on a Pi 4 or earlier (ARMv8.0). The default Pi 4 path avoids this by using the unofficial [themattman](https://github.com/themattman/mongodb-raspberrypi-binaries) build; if you hit this you probably forced `MONGO_SOURCE=apt` with a modern version — use `MONGO_SOURCE=apt` (→ 4.4) or the default themattman build, or move to a Pi 5.

**`NO_PUBKEY` during `apt-get update` after adding the MongoDB repo.** The signing key wasn't imported before the repo. The installer does this in the right order; if you set it up by hand, `curl -fsSL https://pgp.mongodb.com/server-8.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg` **before** writing the `.list` file.

**`/bin/bash^M: bad interpreter` or `syntax error near unexpected token`.** The script has Windows (CRLF) line endings. Fix with `sed -i 's/\r$//' install-raspberrypi.sh` (or `dos2unix`). The included `.gitattributes` prevents this when committing from Windows.

**`E: Unable to locate package mongodb-org-server`.** The MongoDB repo didn't apply — usually a wrong codename (on trixie the repo must use `bookworm`), a missing key, or no internet. Confirm `uname -m` is `aarch64`, the key exists in `/usr/share/keyrings/`, and `apt-get update` succeeds.

**Unofficial MongoDB won't run (Pi 4): `No ... build found` or a library error.** The GitHub lookup couldn't find a matching build, or the binary is missing a shared library. Browse [the releases](https://github.com/themattman/mongodb-raspberrypi-binaries/releases), pick an available series, and set `MONGO_VERSION=` (e.g. `6.0`). If `ldd $(command -v mongod)` shows a missing lib, install it or fall back to `MONGO_SOURCE=apt`.

**`mongod: error while loading shared libraries: libcrypto.so.1.1` (Pi 4).** The themattman `mongod` is linked against OpenSSL 1.1, which bookworm/trixie replaced with OpenSSL 3. The installer fixes this automatically by adding `libssl1.1` (it provides `libcrypto.so.1.1` and `libssl.so.1.1`). To do it by hand: install `libssl1.1` (newest `arm64` `.deb` from the [Debian security pool](http://security.debian.org/debian-security/pool/updates/main/o/openssl/)), then re-run.

**`... version 'GLIBCXX_3.4.29' not found` (Pi 4).** The unofficial `mongod` needs a GCC 11+ `libstdc++`; your OS (typically bullseye) is older. The installer detects this and installs [themattman's prebuilt `libstdc++`](https://github.com/themattman/raspberrypi-binaries/tree/main/libstdc%2B%2B) automatically, repointing `/lib/aarch64-linux-gnu/libstdc++.so.6` (a newer libstdc++ is backward-compatible, and the uninstaller restores the original). If you're doing it by hand, download the `.so` there and `ln -sf` it over `libstdc++.so.6`. Bookworm/trixie don't need this.

**`Cannot locate Java Home` / `JSVC is less than 1.1.0` during install.** Cosmetic — it comes from TP-Link's `install.sh` running `jsvc -help` without `JAVA_HOME` set. The installer now exports `JAVA_HOME` before the handoff, so you shouldn't see it; if you run the stock `install.sh` directly you will, but the service still starts fine (the launcher passes the Java home to jsvc explicitly).

**`jsvc not found` / `JRE is not installed`.** Run the prerequisite step again (`--deps-only`); these are installed by this script, not by TP-Link's.

**Port 8043 / 8088 in use, or can't reach the web UI.** Check the service with `sudo tpeap status` and logs under `/opt/tplink/EAPController/logs/`. Make sure nothing else is bound to Omada's ports (see `properties/omada.properties`).

**Omada won't start after enabling read-only root (relocated data).** Your data disk almost certainly isn't mounted at boot, so the `data`/`logs`/`work` symlinks point at nothing. Confirm the disk is in `/etc/fstab` and mounts before Omada starts (`findmnt /mnt/ssd/omada`), then `sudo tpeap start`.

**`libssl1.1` couldn't be installed automatically (Pi 4 on bookworm/trixie).** Both the themattman builds and MongoDB 4.4 need `libssl1.1`, which modern Debian dropped; the installer normally pulls it from the Debian pool, but if that fails (network/mirror), grab the newest `libssl1.1` `arm64` `.deb` from the [Debian security pool](http://security.debian.org/debian-security/pool/updates/main/o/openssl/) and `sudo dpkg -i` it, then re-run. (A Pi 5 uses `libssl3` and avoids this entirely.)

---

## Notes & caveats

- These scripts are tested for **syntax and logic** but the maintainer can't exercise every Pi-model / OS-version combination. PRs and issue reports with your board + OS + outcome are welcome.
- The scripts are **version-agnostic** — they don't hard-code an Omada version and work with current v5.x/v6.x Linux packages. They rely on the stock `install.sh` being present in the same folder.
- **On a Pi 4/3, the default MongoDB is an unofficial community build** ([themattman](https://github.com/themattman/mongodb-raspberrypi-binaries)) installed to `/usr/local/bin` and not managed by apt (no automatic security updates — update it by re-running or replacing the binary). The official alternative (`MONGO_SOURCE=apt`) is end-of-life MongoDB 4.4. Understand the trade-off; a Pi 5 runs official current MongoDB.
- Always keep backups of your Omada configuration (Settings → Maintenance → Backup) before upgrading either Omada or MongoDB.

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