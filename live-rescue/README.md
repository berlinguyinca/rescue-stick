# fiehnlab-live

A remastered Ubuntu 24.04 Desktop **LIVE** ISO (image #4 in this repo):
boots from USB to RAM/GNOME, amnesic, and doubles as a portable
workstation + rescue/diagnostic tool. Unlike images #1-3 (`provision/autoinstall/*`),
this does **not** install anything — it's a live session, every boot is a
clean slate.

Build script: `build-live.sh`. Static helper scripts it bakes into the
image verbatim: `files/fiehnlab-unlock`, `files/fiehnlab-gpu`,
`files/fiehnlab-pull-model`, `files/fiehnlab-unlock.desktop`,
`files/fiehnlab-assist`, `files/fiehnlab-assist.desktop`,
`files/fiehnlab-assist-autostart.desktop`, `files/fiehnlab-selftest`.

## v2: AI rescue brains + local model + RE/network tools + zero-knowledge autostart

Everything in "Why the pipeline looks like this" and "Overlay build
mechanics"/"Repack" below is **unchanged from v1** — v2 extends the same
casper-layer/overlay/chroot/resquash/xorriso pipeline and the same
`purge_any_gpu_driver` safety net, it does not replace any of it. What's new
is additional payload baked into the same live layer:

- **`pi-rescue` + `pi-engineering`** (both `berlinguyinca` repos, private,
  cloned on the **host** where `gh`/`git` auth already exists — the chroot
  never gets credentials) are copied into `/opt/pi-rescue-runtime` and
  `/opt/pi-engineering-runtime` inside the image, `npm install --omit=dev`'d
  against the chroot's NodeSource Node 22, and wired into
  `/etc/skel/.pi/agent/settings.json`'s `"packages"` as absolute paths. This
  **supersedes** the v1 design note below that said pi-engineering is "not
  cloned at build time" — v2 deliberately bakes both so the live user gets a
  working rescue agent with zero network/auth setup. `/opt` (not
  `/etc/skel`) so casper's per-boot skel→home copy never has to duplicate
  two `node_modules` trees into RAM on every boot.
- **RAG index**: `ollama pull nomic-embed-text` + pi-rescue's
  `build-index` run during the build (one `ollama serve` window, see
  `payload_ollama`), baking `kb/.vectors/index.json` into the image. If that
  step fails for any reason the image still works — pi-rescue builds the
  index lazily (slower) on first `/assist`/`/diagnose` use instead; this is
  logged clearly either way, not silently dropped.
- **sqlite-vec**: the fast path. It's a plain prebuilt-binary npm package
  (not a `pi-rescue` project dependency, by that repo's own design) that
  loads as a `node:sqlite` loadable extension — verified working against
  Node 22 with no compiler and no `--experimental-sqlite` flag (just a
  harmless `ExperimentalWarning` the code already swallows). Installed
  best-effort (`npm install sqlite-vec --no-save`) into `pi-rescue-runtime`;
  on any failure the documented, unit-tested pure-JS cosine store
  (`InMemoryCosineStore`) is what actually runs — same as upstream CI.
- **Local model**: `qwen2.5-coder:7b` (~4.5GB) is now baked **by default**
  (`--bake-model` still exists, now defaulting to this; `--no-bake-model`
  restores exact v1 behavior — ship `fiehnlab-pull-model` instead, no RAG
  index baked either since that needs `nomic-embed-text` to embed). This
  **supersedes** the v1 "Deferred" note below ("the Ollama model weights").
  Baking doubles the live-layer squashfs (see "Sizes" for v1 vs v2 numbers)
  — approved tradeoff for v2, since pi-rescue's whole offline story depends
  on this model actually being present.
- **RE / traffic / network toolset**: mitmproxy (venv), wireshark+tshark
  (apt, setuid preseeded off), bettercap, sslsplit, ssh-mitm (venv),
  frida-tools (venv), apktool, jadx (GitHub release), Ghidra (GitHub
  release, ~1GB, gated by `--with-ghidra`/`--no-ghidra`, default **on**),
  masscan, lldpd, netdiscover, testssl.sh (git clone), sslscan,
  tcptraceroute, ntopng — see `payload_re_tools()`. Each item is logged
  OK/FAILED/SKIP independently; one bad package never aborts the build.
  Daemon-shaped tools (`lldpd`, `ntopng`) are `systemctl disable`d right
  after install — the stick must never auto-sniff/auto-serve on whatever
  network it's plugged into; they're opt-in via `systemctl start`. This
  **supersedes** the v1 "Deferred" note about MITM/RE tools.
- **Zero-knowledge autostart**: `fiehnlab-assist` (friendly greeting + `pi
  --rescue-assist`, auto-picks the gateway if a real key is reachable else
  the baked local model) is baked as `/usr/local/bin/fiehnlab-assist`, a
  `Rescue Assistant` desktop launcher (app grid + Desktop icon), and a GNOME
  autostart entry at `/etc/skel/.config/autostart` that opens it in a
  terminal on login — closeable, never blocks the rest of the desktop. See
  `payload_assist()` and `files/fiehnlab-assist`.

New flags: `--skip-re-tools`, `--with-ghidra`/`--no-ghidra`,
`--no-bake-model` (in addition to v1's `--bake-model NAME`,
`--skip-rescue-tools`, `--phase0-only`). All idempotent/best-effort the same
way v1's payload functions are.

## Why the pipeline looks like this

Ubuntu 24.04 Desktop uses a **layered casper filesystem**, not one big
`filesystem.squashfs`. `casper/conf.d/default-layer.conf` sets
`LAYERFS_PATH=minimal.standard.live.squashfs`; casper's own initrd script
(`scripts/casper`, function around "Multi-layer filesystem") splits that
dotted name into a parent chain and mounts each as a read-only overlay
layer, lowest first:

```
minimal.squashfs            (2.2GB)  <- base
minimal.standard.squashfs   (561MB)  <- adds the GNOME desktop
minimal.standard.live.squashfs (1.2GB) <- live-session-only bits (casper itself, etc.)
```

This was **verified by reading the actual initrd scripts**, not assumed —
`unmkinitramfs` on `casper/initrd`, then `grep -rn LAYERFS_PATH`. There is
no separate per-language layer in the default boot chain (those exist as
`minimal.standard.<lang>.squashfs` for the installer's language picker,
irrelevant to live boot).

**We only ever modify `minimal.standard.live.squashfs`** — the top layer.
`minimal.squashfs` and `minimal.standard.squashfs` are mounted read-only as
overlayfs lowers and never touched. This means `casper/vmlinuz`,
`casper/initrd`, and the kernel ABI are never at risk — only userspace
above the kernel changes.

### Overlay build mechanics

- `upperdir`/`workdir` for the overlay live on an **ext4 loop image in the
  scratch work dir**, not the host filesystem directly. The host (the build host)
  is ZFS; overlayfs whiteouts/`trusted.*` xattrs on ZFS are not reliable.
  This is the single most important "don't fight this" lesson from Phase 0.
- `upperdir` is **seeded by unsquashfs'ing the original live layer into
  it**, so the build adds to/modifies the existing layer rather than
  replacing it from empty.
- Mount options: `index=off,metacopy=off,redirect_dir=off,xino=off`.
  `metacopy=on` (the default) leaves data-less "copy-up" placeholder files
  that squash into a broken layer; `redirect_dir` can interact badly with
  casper's own directory structure.
- Chroot hygiene the script does on every run: bind `/dev /dev/pts /proc
  /sys /run`, swap in a live `/etc/resolv.conf` (restored after), a
  `policy-rc.d` returning 101 so nothing tries to actually start a
  service, and an `update-initramfs` → `/bin/true` dpkg-diversion (we
  never rebuild `casper/initrd`, so there's no point letting any package
  postinst try).
- **Kernel packages are held** (`apt-mark hold`) for exactly the running
  `uname -r` the whole chroot inherits from the booted live kernel,
  because `lib/modules/<kver>` inside the image must keep matching
  `casper/vmlinuz` — a kernel bump inside the squashfs with no matching
  `casper/vmlinuz` rebuild is an unbootable image.

### Repack

`mksquashfs` with the **same compression settings as the original**
(`-comp xz -b 131072`, checked via `unsquashfs -s` on the original file).
`casper/minimal.standard.live.{manifest,size}` get regenerated (diff-style
manifest matching the original's own format, `.size` = sum of
`Installed-Size` across the full package set) and `/md5sum.txt` gets new
hashes for just the 3 changed files. None of `.manifest`/`.size` are
actually read by the live-boot path (confirmed: nothing in casper's
scripts references them) — they only matter if someone launches "Install
Ubuntu" from the live session, so getting them exactly right is
best-effort, not boot-critical.

ISO rebuild is `xorriso -indev SRC -outdev OUT -boot_image any replay -map
...` — this replays the base ISO's own El Torito/GPT boot catalog instead
of re-deriving BIOS+UEFI hybrid boot by hand, which is the single most
fragile part of ISO remastering if you get it wrong.

## Payload: what's baked vs. on-demand

### Baked in (every build)

**Dev toolchain**: go (official tarball → `/usr/local/go`), rust (rustup,
installed **system-wide** under `/opt/rust` + `/etc/profile.d`, not
`~/.cargo` — the live user doesn't exist at build time), python3 + venv +
pip, **nodejs via NodeSource 22.x** (see "Node version" below, not the
stock apt package), build-essential, git, jq, yq, ripgrep, fd (symlinked
from `fdfind`), fzf, bat (symlinked from `batcat`).

**AI agents**: `pi` (`@earendil-works/pi-coding-agent`) and `codex`
(`@openai/codex`) via `npm install -g` with a **system-wide npm prefix**
(`/etc/npmrc` → `prefix=/usr/local`) so they land in `/usr/local/bin`
without needing a per-user npm config. `claude` and `herdr` use installers
that default to a **per-user** `~/.local/bin` install; the build runs each
installer against a throwaway `HOME`, then copies (dereferencing any
symlink) the resulting binary to `/usr/local/bin`. `claude`'s installer
additionally refuses to run as root without `CLAUDE_INSTALL_ALLOW_SUDO=1`
— the chroot is always root, so that's always set.

pi's config (`/etc/skel/.pi/agent/{settings,models}.json`) replicates
`provision/autoinstall/desktop.user-data.tmpl`'s exact
`defaultModel`/`pi-engineering` package wiring, pointed at
`the gateway base URL` as the `metabolomics` provider, **plus**
a second `ollama` provider (`http://localhost:11434/v1`) for manual/local
fallback — pi has no automatic network failover between providers, so
switching to the Ollama one if `the gateway` is unreachable is a
one-line edit to `defaultModel`, not automatic. This config lives in
`/etc/skel` (not `/root` or a build-time user's `$HOME`) because **the
live user account doesn't exist until casper creates it from `/etc/skel`
at boot** — this was verified by checking `/etc/passwd` and `/home` in the
built image before boot: no `ubuntu` user, no `/home/ubuntu`, nothing in
the initrd scripts calls `useradd`/`adduser` either, so account creation
happens from a systemd unit inside the squashfs itself, which (like any
standard `useradd -m`) seeds from skel.

**v1 said** `pi-engineering` (the private extension repo) is not cloned at
build time (no git credential inside the chroot) and that `fiehnlab-unlock`
clones it post-boot instead. **v2 supersedes this**: both `pi-engineering`
*and* `pi-rescue` are cloned on the **host** (which already has `gh`/`git`
auth) and baked into `/opt/{pi-rescue,pi-engineering}-runtime` — see the "v2"
section at the top of this file for why, and `fiehnlab-unlock` now checks
`[ -d /opt/pi-engineering-runtime ]` first and skips its own clone when the
v2 bake is already present (no duplicate-extension-load risk).

**fiehnlab-unlock** (`/usr/local/sbin/fiehnlab-unlock` +
`/usr/local/bin` symlink + a `Terminal=true` desktop launcher seeded into
`/etc/skel/Desktop` and `/usr/share/applications`): scans mounted/
mountable exFAT volumes for `fiehnlab-secrets.luks`, `cryptsetup luksOpen`
(interactive passphrase), mounts it read-only under `/run`, then for the
real (non-root) invoking user: sources `secrets.env` into a
`~/.fiehnlab-session-env` the user's `.bashrc` picks up, runs
`gh auth login --with-token < gh-token`, clones `pi-engineering` now that
auth exists, copies `aws/` → `~/.aws/`, and writes `llm-api-key` into
`~/.pi/agent/models.json`'s `metabolomics.apiKey` via `jq`. Everything it
writes lands in the live session's tmpfs/overlay (the squashfs media is
never writable), so it's inherently gone on reboot — "never persist keys
to the squashfs" doesn't need special-casing, it's just how a live image
works.

**Read-only discipline**: GNOME automount disabled via a dconf default
(`org/gnome/desktop/media-handling` `automount=false`/`automount-open=false`,
compiled with `dconf update`), `mdadm.conf` gets `AUTO -all` so udev
doesn't auto-assemble arrays it finds, and `/usr/local/bin/mount-rw <dev>
[mountpoint]` is the explicit opt-in for anything that needs to be
writable.

**GPU**: the CUDA apt repo (`cuda-keyring` for ubuntu2404) and the NVIDIA
container-toolkit repo are staged (just the `sources.list.d` entries +
keyring, `apt-get update` run once) — **no driver package is ever
installed at build time**. `fiehnlab-gpu` (`/usr/local/sbin`, also
symlinked to `/usr/local/bin`) is a `sudo`-escalating helper that `lspci`s
the machine it's actually running on and installs `cuda-drivers` (NVIDIA)
or fetches+runs the release-matched `amdgpu-install --usecase=rocm
--no-dkms` (AMD) against **that boot's** running kernel. This is correct
for a portable stick: the live kernel is fixed per-boot and DKMS can't
persist across reboots anyway, so a driver install is only ever good for
the current session regardless, and baking one locks the image to one
vendor/one kernel ABI for a stick meant to plug into arbitrary hardware.
**Do not change this without re-reading this paragraph** — an earlier pass
in this build silently pulled in the full NVIDIA driver stack (+3-4GB)
because `ollama`'s own `install.sh` probes `/sys` and finds whatever GPU
the *build host* has; `purge_any_gpu_driver` in `build-live.sh` runs
unconditionally right before every resquash specifically to catch this
category of regression and will `exit 1` the build if it ever finds
`cuda-drivers`/`nvidia-driver*` still installed.

**Ollama**: the runtime (binary + systemd unit) is always installed.
`fiehnlab-pull-model` is the always-baked wrapper (`ollama pull
"${1:-qwen2.5-coder:7b}"`). The model weights themselves are **not**
baked by default — see "Deferred" below. `--bake-model NAME` to change
that.

**Curated rescue/forensic toolset** (apt unless noted): `inxi lynis
ansible lm-sensors dmidecode nvme-cli edac-utils stress-ng fio memtester
nvtop radeontop glances tshark iperf3 ethtool dnsutils arp-scan iftop
nethogs snmp snmp-mibs-downloader wavemon partclone chntpw rclone restic
borgbackup nwipe sleuthkit rkhunter chkrootkit clamav binwalk neovim
hwinfo gdisk smartmontools testdisk gddrescue gparted parted lvm2 mdadm
cryptsetup ntfs-3g exfatprogs btrfs-progs xfsprogs hdparm lshw pciutils
usbutils strace`, plus `micro` (static binary via getmic.ro), `age` +
`sops` (static GitHub release binaries), `volatility3` (its own venv at
`/opt/volatility3-venv`, symlinked as `/usr/local/bin/vol`),
`boot-repair` (PPA `yannubuntu/boot-repair` — best-effort, skipped if the
PPA has no build for the current release), and `clonezilla`
(apt if available, else skipped — `partclone` already covers imaging).
`tshark` is preseeded non-interactively
(`wireshark-common/install-setuid boolean false`) so the install doesn't
hang on a debconf prompt.

**DB clients**: `postgresql-client mariadb-client redis-tools sqlite3`.

**Containers**: `docker.io` + `apptainer` (PPA, with a GitHub-release deb
fallback if the PPA lags the release).

### Node.js version — a real bug found and fixed

The stock Ubuntu noble `nodejs` apt package is **18.19.1**. `pi` crashes
on it: `import { createRequire, enableCompileCache } from "node:module"`
— `enableCompileCache` was only added in Node 20.1+. The build installs
**NodeSource 22.x** instead of the apt package and reinstalls `pi`/`codex`
against it. Verified in QEMU: `pi --version` → `1.0.4` (was a
`SyntaxError` crash before the fix). If you ever see this package list
simplified back to plain `apt-get install nodejs npm`, that reintroduces
the bug.

### Deferred in v1, resolved in v2 (kept here for history)

- **The Ollama model weights.** v1 deferred these (~4.5-5GB, almost pure
  high-entropy data that barely compresses, roughly doubling the live-layer
  squashfs). **v2 bakes `qwen2.5-coder:7b` by default** — see the "v2"
  section at the top of this file. `--no-bake-model` restores exact v1
  behavior (ships `fiehnlab-pull-model` instead, no RAG index baked).
- **MITM/RE-style tools** beyond what v1 listed (wireshark GUI,
  radare2/ghidra, yara, ...) were out of scope for v1. **v2 adds** the full
  RE/traffic/network toolset — see `payload_re_tools()` and the "v2" section
  above. `radare2` itself still isn't baked (not in the v2 spec's tool list;
  `jadx`+`ghidra`+`apktool` cover the decompile path it asked for); `yara`
  likewise wasn't in the v2 list.
- **herdr's model backend.** Only the binary is installed; unlike `pi`,
  there's no documented config schema for wiring herdr to
  `the gateway`/Ollama in this repo yet (the reference
  `desktop.user-data.tmpl` doesn't configure it either — same scope as
  there). `fiehnlab-unlock` drops the raw API key at `~/.herdr/llm-api-key`
  for manual wiring once herdr's config format is known.
- **A fully-automatic pi primary→Ollama failover.** pi has no such
  built-in mechanism; the `ollama` provider entry is there to switch to
  by hand (`defaultModel` in `~/.pi/agent/settings.json`).

## Known MinIO client (`mc`/`mcli`) download change

`dl.min.io/client/mc/release/linux-amd64/mc` returns **HTTP 410** as of
this build (2026-10) — MinIO retired the public `mc` binary download,
folding it into their closed-source AIStor product. The still-working
path used here is `dl.min.io/aistor/mc/release/linux-amd64/mc`. If that
also goes away, the GitHub release asset pinned at
`RELEASE.2025-08-13T08-35-41Z` or extracting `/usr/bin/mc` from the
`quay.io/minio/mc` container image are the documented fallbacks.

## Sizes

| | v1 (no model baked) | v2 (default flags) |
|---|---|---|
| Base ISO | 6.25 GB | 6.25 GB |
| Modified `minimal.standard.live.squashfs` | ~3.87 GiB (4,151,361,536 bytes) | see build report (AI brains + qwen2.5-coder:7b + nomic-embed-text + RE toolset + Ghidra added; expected roughly double, ~9-10 GiB) |
| Final ISO | ~8.55 GiB (9,179,627,520 bytes) `fiehnlab-live-v1.iso` | ~13-14 GiB expected `fiehnlab-live-v2.iso` |

v1's single-file squashfs was only 143MB under the plain ISO9660 4 GiB−1
per-file limit; v2's is expected well over 4 GiB. **Verified before trusting
any v2 build**: `xorriso -boot_image any replay -map <file >4GiB> ...`
transparently multi-extents the file (no `-compliance iso_9660_level=3`
flag needed), and the Linux kernel's iso9660 loop-mount driver reads a
4.3GB round-trip test file back byte-identical (`md5sum` match). This is
the single most likely hard-blocker for v2 and it is **not** a blocker.

## Usage

```bash
sudo -n true   # must already work - the script needs passwordless sudo
./build-live.sh \
  --base-iso /path/to/ubuntu-24.04.5.1-desktop-amd64.iso \
  --out /path/to/fiehnlab-live-v2.iso \
  --work /path/to/scratch-workdir   # NOT inside this repo; needs ~35-45GB free

# Walking-skeleton proof only (installs htop, repacks, stops):
./build-live.sh --base-iso ... --out ... --work ... --phase0-only

# Faster iteration on the dev/AI payload, skip the big rescue-tool apt list:
./build-live.sh --base-iso ... --out ... --work ... --skip-rescue-tools

# v2 defaults: qwen2.5-coder:7b + RAG index baked, RE toolset + Ghidra baked.
./build-live.sh --base-iso ... --out ... --work ...

# Smaller/faster v2 iteration: skip the RE toolset and Ghidra, keep the brains:
./build-live.sh --base-iso ... --out ... --work ... --skip-re-tools --no-ghidra

# Exact v1 behavior (no model, no RAG index, no RE toolset beyond v1's list):
./build-live.sh --base-iso ... --out ... --work ... --no-bake-model --skip-re-tools
```

The script is safe to re-run against the same `--work` dir (apt/curl
steps skip-or-reinstall sanely); it is **not** safe to run two builds
against the same `--work` dir concurrently (shared loop devices/mounts).
`chroot_exit` refuses to silently continue if mounts are still present
under the merged dir after cleanup — a crashed build can leave `/dev
/proc /sys /run` bind-mounted inside `$WORK/mnt/merged`, and `rm -rf`ing
that without checking `findmnt` first would be the exact "deleted-through-
a-live-mount" mistake this project's memory notes warn about.

## QEMU verification

This was boot-tested end to end with QEMU/OVMF (headless, VNC + serial),
automated via the QEMU monitor's `sendkey`/`screendump` over a unix
socket — the same technique already used for images #2-3 in this repo
(see the `qemu`/`deskvm`/`gpuvm` scratch dirs from those builds). Example
launch:

```bash
qemu-system-x86_64 \
  -machine q35,accel=kvm -cpu host -smp 8 -m 16G \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=OVMF_VARS.fd \
  -drive if=none,id=iso,format=raw,readonly=on,file=fiehnlab-live-v2.iso \
  -device ide-cd,drive=iso,bootindex=0 \
  -nic user,model=virtio-net-pci -vga std -display none \
  -vnc 127.0.0.1:9 -monitor unix:/tmp/v2.sock,server,nowait \
  -serial file:serial.log -name fiehnlab-live-v2
```

v2 needs more RAM than v1's `8G` — CPU inference on the baked 7B model
plus GNOME plus the tmpfs overlay is tight otherwise — and the model blob
is xz-compressed inside the squashfs, so the *first* `ollama run` in a
session is slow to load off the virtual CD; a long timeout there is
expected, not a failure.

Confirmed for v1: GRUB → UEFI boot → casper layered-squashfs → full GNOME
Shell live session as user `ubuntu` (casper.conf default) → real
login-shell PATH has `go rustc python3/uv node pi herdr claude codex gh
mc/mcli psql nmap smartctl inxi lynis ansible tailscale ollama`, the three
v1 `fiehnlab-*` helpers exist with correct permissions, and `dpkg -l | grep
-iE 'cuda-drivers|nvidia-driver'` is empty (no baked GPU driver). `md5sum -c
md5sum.txt` on the rebuilt ISO is clean.

**v2 additionally checks** (run `fiehnlab-selftest` over the serial console
for a single clean OK/FAILED/NOTE report covering all of this at once):
the autostart greeting appears without any login action; `pi --version`
and both pi-rescue (`/assist`, `/diagnose`) and pi-engineering commands are
registered; `ollama run qwen2.5-coder:7b "say hi"` answers from the local
model; `kb/.vectors/index.json` exists (RAG index baked) or pi-rescue
builds it lazily on first `/assist`; `sqlite-vec` import succeeds (fast
path) or the pure-JS cosine store is confirmed as what's actually running;
spot-check `mitmproxy`/`tshark`/`frida`/`jadx`/`masscan`/`lldpcli`/
`testssl.sh` (and `ghidraRun` unless `--no-ghidra`); `dpkg -l` is still
empty for any GPU driver (the safety net runs for every v2 payload the same
as v1); and both `fiehnlab-*` v2 helpers exist with correct permissions.
