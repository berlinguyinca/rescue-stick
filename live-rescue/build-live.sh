#!/bin/bash
# rescue-os: remaster an Ubuntu 24.04 Desktop LIVE ISO into a portable
# workstation + rescue/diagnostic tool (boots from USB to GNOME, amnesic).
#
# Image #4 in this repo. See README.md in this directory for the full
# design writeup (layer choice, what's baked vs. on-demand, deferrals).
#
# Pipeline (all of it proven against ubuntu-24.04.5.1-desktop-amd64.iso):
#   1. Extract casper/{minimal,minimal.standard,minimal.standard.live}.squashfs
#      from the base ISO. The live boot chain is driven by
#      casper/conf.d/default-layer.conf -> LAYERFS_PATH=minimal.standard.live.squashfs,
#      which casper's own initrd script expands into the dotted-parent chain
#      minimal -> minimal.standard -> minimal.standard.live. We modify ONLY
#      the top (live) layer; minimal/minimal.standard are mounted read-only
#      as overlayfs lowers, never touched.
#   2. overlayfs: lowerdir=minimal.standard:minimal, upperdir/workdir on an
#      ext4 loop image (NOT the host's zfs - overlayfs whiteouts/xattrs on
#      zfs are not reliable), upperdir seeded by unsquashfs'ing the original
#      live layer so we *add to* it rather than replace it.
#   3. chroot into the merged view, apt-mark hold the running kernel
#      (linux-image/-modules for the booted uname -r, since casper/vmlinuz
#      is fixed and can't be rebuilt), divert update-initramfs to /bin/true
#      (we never touch casper/initrd), block service starts via
#      policy-rc.d, install the payload (see payload_* functions below).
#   4. mksquashfs the upper dir back into minimal.standard.live.squashfs
#      (same xz/131072 settings as the original), regenerate
#      minimal.standard.live.{manifest,size} and the top-level md5sum.txt
#      for just the changed files.
#   5. xorriso -indev SRC -outdev OUT -boot_image any replay -map ...
#      rebuilds a hybrid BIOS+UEFI ISO without touching El Torito/GPT by
#      hand.
#
# Idempotent-ish: safe to re-run against the same WORK dir; apt/curl steps
# skip-or-reinstall sanely. NOT safe to run two builds against the same
# WORK dir concurrently (shared loop devices/mounts).
#
# Usage:
#   sudo -n true   # this script needs passwordless sudo for mount/chroot/squashfs
#   ./build-live.sh --base-iso /path/to/ubuntu-24.04.5.1-desktop-amd64.iso \
#                    --out /path/to/rescue-os-v1.iso \
#                    --work /path/to/scratch-workdir \
#                    [--phase0-only] [--bake-model qwen2.5-coder:7b] [--skip-rescue-tools]
#
set -uo pipefail

# ============================================================================
# Config / args
# ============================================================================
BASE_ISO=""
OUT_ISO=""
WORK=""
PHASE0_ONLY=false
SKIP_RESCUE_TOOLS=false
SKIP_RE_TOOLS=false
WITH_GHIDRA=true
PHASE0_PKG="htop"       # the walking-skeleton proof package

# v3: llama.cpp replaces Ollama. Model baking is no longer optional/parametric
# (no --bake-model) - the chat+embed pair below is always baked, it's what
# llama-chat.service/llama-embed.service/rescue.yaml/models.json all assume.
# Pinned to a known-good llama.cpp release as a rate-limit-safe fallback;
# resolved LIVE against the real "latest" release first (see
# payload_llamacpp) - see https://github.com/ggml-org/llama.cpp/releases.
LLAMACPP_TAG_FALLBACK="b11490"
LLAMA_SWAP_TAG_FALLBACK="v262"
QWEN3_HF_REPO="Qwen/Qwen3-8B-GGUF"           # ungated, apache-2.0, text-only instruct
QWEN3_HF_FILE="Qwen3-8B-Q4_K_M.gguf"
GEMMA_HF_REPO="ggml-org/gemma-3-1b-it-GGUF"  # ungated re-upload (google/gemma-3-1b-it is gated)
GEMMA_HF_FILE="gemma-3-1b-it-Q4_K_M.gguf"
NOMIC_HF_REPO="nomic-ai/nomic-embed-text-v1.5-GGUF"
NOMIC_HF_FILE="nomic-embed-text-v1.5.Q8_0.gguf"
LLM_GATEWAY_URL="${LLM_GATEWAY_URL:-https://llm.example.com/v1}"   # online LLM gateway baked into models.json; set to your real gateway for your own build

usage() {
  cat <<'EOF'
Usage: build-live.sh --base-iso ISO --out OUT_ISO --work WORKDIR [options]

Required:
  --base-iso PATH     Ubuntu 24.04 Desktop ISO to remaster
  --out PATH           Output ISO path (NOT inside the git repo)
  --work PATH          Scratch work directory (NOT inside the git repo;
                        needs ~35-45GB free, must support loop mounts)

Options:
  --phase0-only         Only prove the pipeline (install $PHASE0_PKG, repack,
                         stop). Use this before trusting a modified pipeline.
  --skip-rescue-tools    Skip the curated forensic/rescue apt list (faster
                         iteration while developing the dev/AI payload).
  --skip-re-tools        Skip the v2 RE/traffic/network toolset (mitmproxy,
                         wireshark, frida, jadx, ghidra, masscan, ...).
  --with-ghidra          Bake Ghidra (~1GB GitHub release zip). Default ON.
  --no-ghidra             Skip Ghidra (apktool/jadx still installed).
  -h, --help             This.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base-iso) BASE_ISO="$2"; shift 2 ;;
    --out) OUT_ISO="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --phase0-only) PHASE0_ONLY=true; shift ;;
    --skip-rescue-tools) SKIP_RESCUE_TOOLS=true; shift ;;
    --skip-re-tools) SKIP_RE_TOOLS=true; shift ;;
    --with-ghidra) WITH_GHIDRA=true; shift ;;
    --no-ghidra) WITH_GHIDRA=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

[ -n "$BASE_ISO" ] && [ -f "$BASE_ISO" ] || { echo "ERROR: --base-iso required and must exist" >&2; exit 1; }
[ -n "$OUT_ISO" ] || { echo "ERROR: --out required" >&2; exit 1; }
[ -n "$WORK" ] || { echo "ERROR: --work required" >&2; exit 1; }
sudo -n true 2>/dev/null || { echo "ERROR: passwordless sudo required (mount/chroot/squashfs)" >&2; exit 1; }

# Resolved ONCE, before the cd "$WORK" below, as an absolute path. Every
# payload_* function that copies a static file from files/ MUST use
# $SCRIPT_DIR, never a bare dirname-of-$0 - $0 is relative ("./build-live.sh")
# whenever invoked that way, and dirname of a relative $0 silently starts
# resolving against the CURRENT directory, which is $WORK after the cd
# below, not this script's own directory. (Real bug, found when every
# files/* copy failed with "cannot stat './files/...'" after a run
# invoked as ./build-live.sh from this directory.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

M="$WORK/mnt/merged"
LOWER_MIN="$WORK/mnt/lower-minimal"
LOWER_STD="$WORK/mnt/lower-standard"
UPPER_IMG="$WORK/work.img"
UPPER_MNT="$WORK/mnt/work-ext4"
L=/var/log/rescue-os-build.log   # inside the chroot

mkdir -p "$WORK" "$M" "$LOWER_MIN" "$LOWER_STD" "$UPPER_MNT"
cd "$WORK"

log(){ echo "[$(date -Is)] $*"; }
fatal(){ echo "[$(date -Is)] FATAL: $*" >&2; exit 1; }

# v3 (llama.cpp) helpers -----------------------------------------------
resolve_latest_gh_tag() {
  # $1=owner/repo $2=fallback-tag. Uses the /releases/latest 302 redirect
  # on github.com itself (NOT api.github.com) so this never trips the
  # anonymous REST API's 60-requests/hour rate limit - confirmed live: that
  # limit is exactly what silently dropped jadx/ghidra from an earlier
  # build of this image (api.github.com returned 403, the chroot-side
  # grep found nothing, and the stage logged a bare "FAILED"/"SKIP" that
  # never stopped the build). The redirect trick costs zero API quota.
  local repo="$1" fallback="$2" tag
  tag=$(curl -fsSI --max-time 10 "https://github.com/$repo/releases/latest" 2>/dev/null \
        | tr -d '\r' | awk -F/ '/^[Ll]ocation:/{print $NF}')
  if [ -z "$tag" ]; then
    echo "resolve_latest_gh_tag: could not resolve $repo live, using pinned fallback $fallback" >&2
    tag="$fallback"
  fi
  echo "$tag"
}

resolve_ghidra_asset_url() {
  # Ghidra's asset filename embeds a build date (ghidra_X.Y.Z_PUBLIC_<date>.zip)
  # so, unlike jadx, the URL cannot be built from the tag alone - this needs
  # one real API lookup. Prefer the authenticated `gh api` (5000/hr) over an
  # anonymous api.github.com call (60/hr, the thing that failed last time).
  local url=""
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    url=$(gh api repos/NationalSecurityAgency/ghidra/releases/latest \
          --jq '.assets[] | select(.name | test("_PUBLIC_.*\\.zip$")) | .browser_download_url' 2>/dev/null | head -1)
  fi
  if [ -z "$url" ]; then
    url=$(curl -fsSL https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest 2>/dev/null \
          | grep -oE '"browser_download_url": *"[^"]+_PUBLIC_[^"]+\.zip"' | cut -d'"' -f4 | head -1)
  fi
  echo "$url"
}

resolve_llamacpp_tag() {
  # llama.cpp's GitHub "latest" release (the /releases/latest redirect
  # resolve_latest_gh_tag relies on) is a semver-tagged release (vX.Y.Z)
  # that carries NO binary assets at all - confirmed live: it has exactly
  # one file, nightly-tag.txt. The actual prebuilt binaries are attached
  # only to the frequent "b#####" CI-build tags, which GitHub marks as
  # prereleases and therefore excludes from /releases/latest. This must
  # list releases and pick the first b##### tag, not trust the redirect.
  local tag=""
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    tag=$(gh api "repos/ggml-org/llama.cpp/releases?per_page=5" \
          --jq '.[] | select(.tag_name | test("^b[0-9]+$")) | .tag_name' 2>/dev/null | head -1)
  fi
  if [ -z "$tag" ]; then
    tag=$(curl -fsSL "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=5" 2>/dev/null \
          | grep -oE '"tag_name": *"b[0-9]+"' | head -1 | cut -d'"' -f4)
  fi
  if [ -z "$tag" ]; then
    echo "resolve_llamacpp_tag: could not resolve a b#### build tag live, using pinned fallback $LLAMACPP_TAG_FALLBACK" >&2
    tag="$LLAMACPP_TAG_FALLBACK"
  fi
  echo "$tag"
}

dl_cache() {
  # $1=URL $2=destination filename under $WORK/dl-cache. Idempotent - a
  # previous successful download under this WORK dir is never re-fetched,
  # same spirit as extract_layers()'s "[ -f ... ] && continue".
  local url="$1" name="$2" dest
  mkdir -p "$WORK/dl-cache"
  dest="$WORK/dl-cache/$name"
  # IMPORTANT: this function's stdout IS its return value (every caller
  # does X="$(dl_cache ...)") - log() writes to stdout too, so calling it
  # in here would silently prepend the log line to the returned path,
  # corrupting every caller. Real bug found running this exact function:
  # a perfectly successful download (curl 100%, mv succeeded) still FATAL'd
  # downstream because $CUDA_MAIN was "[timestamp]  downloading foo.tar.gz\n/real/path"
  # - diagnostic lines in here go to stderr ONLY, never through log().
  if [ -s "$dest" ]; then
    echo "  cached: $name" >&2
  else
    echo "  downloading $name ..." >&2
    curl -fL --retry 3 --max-time 1800 -o "$dest.part" "$url" && mv "$dest.part" "$dest" \
      || fatal "download failed: $url"
  fi
  echo "$dest"
}

# Hard stage gate: a payload_* function logging "OK" is not proof it ran -
# a shell parse corruption (quote imbalance inside a chroot_run string, the
# exact bug found and fixed in payload_ai_brains/payload_ollama during v2
# development) can make the REST of a function's body silently become dead
# text that never executes, while the stage header still printed and the
# build still "succeeds". Call this right after a payload_* whose whole
# point is a specific file landing in the image, with the exact path that
# proves the stage's body actually ran - a missing path here is fatal, not
# best-effort, because every later stage would otherwise look green too.
require_in_upper(){
  local rel="$1" what="$2"
  # Checked by chroot-ing in, NOT by testing the host path directly: several
  # of these (mitmdump, jadx, ghidraRun, ...) are absolute symlinks into
  # /opt/..., and an absolute symlink resolves against the CALLER's root -
  # `test -e` on the bare host path follows the link into the host's real
  # /opt (which doesn't have it), reporting a false negative for a perfectly
  # real in-image file. chroot gives the same root the live system itself
  # has, so this matches what actually boots.
  sudo -n chroot "$M" test -e "/$rel" 2>/dev/null || fatal "$what did not land at /$rel - the payload stage silently did nothing (see the log above for where it stopped); fix the script, do not re-run blind"
}

# ============================================================================
# Phase 0 helpers: extract layers, build the overlay, chroot hygiene
# ============================================================================

extract_layers() {
  log "extracting casper squashfs layers + grub/md5sum metadata"
  for f in minimal minimal.standard minimal.standard.live; do
    [ -f "$f.squashfs" ] && continue
    xorriso -osirrox on -indev "$BASE_ISO" -extract "/casper/$f.squashfs" "./$f.squashfs"
  done
  for f in /boot/grub/grub.cfg:grub.cfg.orig /md5sum.txt:md5sum.txt.orig \
           /casper/minimal.manifest:minimal.manifest.orig \
           /casper/minimal.standard.manifest:minimal.standard.manifest.orig; do
    src="${f%%:*}"; dst="${f##*:}"
    [ -f "$dst" ] && continue
    xorriso -osirrox on -indev "$BASE_ISO" -extract "$src" "./$dst" 2>&1 | tail -2
  done
}

setup_overlay() {
  log "building the overlay (upper/work on an ext4 loop image, not zfs)"
  if ! findmnt -n "$UPPER_MNT" >/dev/null 2>&1; then
    if [ ! -f "$UPPER_IMG" ]; then
      sudo -n truncate -s 40G "$UPPER_IMG"
      sudo -n mkfs.ext4 -q -F "$UPPER_IMG"
    fi
    sudo -n mount -o loop "$UPPER_IMG" "$UPPER_MNT"
  fi
  sudo -n mkdir -p "$UPPER_MNT/upper" "$UPPER_MNT/work"
  if [ ! -e "$UPPER_MNT/upper/usr" ]; then
    log "seeding upper from the original live layer (unsquashfs)"
    sudo -n unsquashfs -f -d "$UPPER_MNT/upper" minimal.standard.live.squashfs
  fi
  findmnt -n "$LOWER_MIN" >/dev/null 2>&1 || sudo -n mount -o loop,ro minimal.squashfs "$LOWER_MIN"
  findmnt -n "$LOWER_STD" >/dev/null 2>&1 || sudo -n mount -o loop,ro minimal.standard.squashfs "$LOWER_STD"
  findmnt -n "$M" >/dev/null 2>&1 || sudo -n mount -t overlay overlay \
    -o "lowerdir=$LOWER_STD:$LOWER_MIN,upperdir=$UPPER_MNT/upper,workdir=$UPPER_MNT/work,index=off,metacopy=off,redirect_dir=off,xino=off" \
    "$M"
}

chroot_enter() {
  log "chroot hygiene: binds, resolv.conf, policy-rc.d, initramfs diversion, kernel hold"
  sudo -n mount --bind /dev "$M/dev"
  sudo -n mount --bind /dev/pts "$M/dev/pts"
  # CRITICAL: the host's /dev is a SHARED mount (systemd default). Without this,
  # the chroot's /dev/pts activity propagates BACK onto the host's /dev/pts,
  # stacking dead devtmpfs overlays that bury the real devpts - after enough
  # build runs the host can no longer allocate any pty (sudo use_pty / openpty
  # fail with ENODEV: "unable to allocate pty: No such device"). Making the
  # chroot's /dev subtree a slave keeps propagation one-way (host -> chroot).
  sudo -n mount --make-rslave "$M/dev"
  sudo -n mount -t proc proc "$M/proc"
  sudo -n mount -t sysfs sysfs "$M/sys"
  sudo -n mount --bind /run "$M/run"
  sudo -n mount --make-rslave "$M/run"
  [ -f "$WORK/resolv.conf.orig.bak" ] || sudo -n cp -a "$M/etc/resolv.conf" "$WORK/resolv.conf.orig.bak" 2>/dev/null || true
  sudo -n rm -f "$M/etc/resolv.conf"
  sudo -n cp /etc/resolv.conf "$M/etc/resolv.conf"
  sudo -n bash -c "printf '#!/bin/sh\nexit 101\n' > '$M/usr/sbin/policy-rc.d'"
  sudo -n chmod +x "$M/usr/sbin/policy-rc.d"
  sudo -n chroot "$M" dpkg-divert --local --rename --add /usr/sbin/update-initramfs 2>/dev/null || true
  sudo -n ln -sf /bin/true "$M/usr/sbin/update-initramfs"
  # Hold exactly the kernel packages matching the booted live kernel (the
  # one casper/vmlinuz + casper/initrd actually boot) so nothing in the
  # payload can bump them and desync lib/modules from vmlinuz.
  sudo -n chroot "$M" bash -c 'apt-mark hold $(dpkg -l | awk "/^.i  linux-(image|modules)-[0-9]/{print \$2}") 2>&1' || true
}

chroot_exit() {
  log "chroot cleanup: undo diversion/policy-rc.d/resolv.conf, unmount binds"
  sudo -n rm -f "$M/usr/sbin/update-initramfs"
  sudo -n chroot "$M" dpkg-divert --local --rename --remove /usr/sbin/update-initramfs 2>/dev/null || true
  sudo -n rm -f "$M/usr/sbin/policy-rc.d"
  sudo -n rm -f "$M/etc/resolv.conf"
  if [ -s "$WORK/resolv.conf.orig.bak" ]; then
    sudo -n cp -a "$WORK/resolv.conf.orig.bak" "$M/etc/resolv.conf"
  else
    sudo -n ln -sf ../run/systemd/resolve/stub-resolv.conf "$M/etc/resolv.conf" 2>/dev/null || true
  fi
  for d in run sys proc dev/pts dev; do sudo -n umount -R "$M/$d" 2>/dev/null || true; done
  # Safety: never rm -rf a workdir with live bind mounts still attached.
  if findmnt -R "$M" | grep -vq "^$M\$" 2>/dev/null; then
    echo "WARNING: $M still has mounts under it after cleanup - inspect before deleting anything" >&2
  fi
}

chroot_run() { sudo -n chroot "$M" bash -c "$1"; }

# ============================================================================
# Payload: priority order per the task spec. Each function is best-effort
# internally (log OK/FAILED per item) so one bad package name doesn't sink
# the whole build; the caller should still treat a FAILED on anything in
# the "must-have" list as worth a second look.
# ============================================================================

payload_dev_and_cli() {
  log "=== payload: dev toolchain + CLI kit + db clients + containers + gh + mcli ==="
  chroot_run '
    set -uo pipefail; L='"$L"'; log(){ echo "[$(date -Is)] $*" | tee -a "$L"; }
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >>"$L" 2>&1
    apt-get install -y --no-install-recommends \
      git build-essential curl wget gnupg ca-certificates apt-transport-https software-properties-common \
      python3-venv python3-pip \
      jq yq ripgrep fd-find fzf bat tree mc httpie ncdu unzip vim btop tmux \
      nmap tcpdump mtr-tiny openssh-client rsync pciutils usbutils \
      postgresql-client mariadb-client redis-tools sqlite3 \
      docker.io docker-compose-v2 \
      smartmontools nvme-cli testdisk gddrescue gparted parted lvm2 mdadm cryptsetup \
      ntfs-3g exfatprogs btrfs-progs xfsprogs hdparm lshw strace \
      >>"$L" 2>&1
    apt-get install -y tldr >>"$L" 2>&1 || python3 -m pip install --break-system-packages tldr >>"$L" 2>&1 || log "WARN: tldr"
    ln -sf /usr/bin/fdfind /usr/local/bin/fd
    ln -sf /usr/bin/batcat /usr/local/bin/bat

    # nodejs: the Ubuntu noble apt package (18.19.1) is too old for the pi
    # CLI (needs node:module enableCompileCache, Node >=20.1) - go straight
    # to NodeSource 22.x LTS instead of apt nodejs/npm.
    install -d -m0755 /usr/share/keyrings
    curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh >>"$L" 2>&1 \
      && bash /tmp/nodesource_setup.sh >>"$L" 2>&1 && apt-get install -y nodejs >>"$L" 2>&1 \
      && log "OK: nodejs $(node --version)" || log "FAILED: nodejs (NodeSource)"

    ( add-apt-repository -y ppa:apptainer/ppa && apt-get update && apt-get install -y apptainer ) >>"$L" 2>&1 \
      || { U=$(curl -fsSL https://api.github.com/repos/apptainer/apptainer/releases/latest | grep -oE "https://[^\" ]+_amd64\.deb" | grep -v suid | head -1); curl -fsSL -o /tmp/apptainer.deb "$U" && apt-get install -y /tmp/apptainer.deb; } >>"$L" 2>&1
    command -v apptainer >/dev/null && log "OK: apptainer" || log "FAILED: apptainer"

    install -d -m0755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg >>"$L" 2>&1
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
    apt-get update >>"$L" 2>&1 && apt-get install -y gh >>"$L" 2>&1 && log "OK: gh" || log "FAILED: gh"

    # dl.min.io/client/* returns HTTP 410 (MinIO retired the public mc
    # download in 2026, folded into their closed-source AIStor product);
    # the still-live path is dl.min.io/aistor/mc/release/linux-amd64/mc.
    curl -fsSL -o /usr/local/bin/mcli https://dl.min.io/aistor/mc/release/linux-amd64/mc >>"$L" 2>&1 \
      && chmod 0755 /usr/local/bin/mcli && log "OK: mcli" || log "FAILED: mcli"

    ( curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip \
      && cd /tmp && unzip -q -o awscliv2.zip && ./aws/install --update && rm -rf /tmp/aws /tmp/awscliv2.zip ) >>"$L" 2>&1 \
      && log "OK: aws-cli v2" || log "FAILED: aws-cli"

    ( install -d -m0755 /usr/share/keyrings; rm -f /usr/share/keyrings/google-chrome.gpg; curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --batch --yes --dearmor -o /usr/share/keyrings/google-chrome.gpg \
      && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
      && apt-get update && apt-get install -y google-chrome-stable ) >>"$L" 2>&1 && log "OK: chrome" || log "FAILED: chrome"
    ls /var/lib/snapd/seed/snaps 2>/dev/null | grep -qi firefox && log "OK: firefox snap already seeded on the ISO" || log "NOTE: firefox snap not found in seed"

    if [ ! -x /usr/local/go/bin/go ]; then
      V=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
      curl -fsSL "https://go.dev/dl/$V.linux-amd64.tar.gz" | tar -C /usr/local -xz >>"$L" 2>&1
      ln -sf /usr/local/go/bin/go /usr/local/bin/go; ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
      log "OK: go $V"
    fi

    install -d -m0755 /opt/rust
    export RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo
    if [ ! -x /opt/rust/cargo/bin/cargo ]; then
      curl -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh >>"$L" 2>&1
      sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal >>"$L" 2>&1
      log "OK: rust (system-wide /opt/rust)"
    fi
    chmod -R a+rX /opt/rust
    for b in /opt/rust/cargo/bin/*; do ln -sf "$b" "/usr/local/bin/$(basename "$b")"; done
    printf "export RUSTUP_HOME=/opt/rust/rustup\nexport CARGO_HOME=/opt/rust/cargo\nexport PATH=\$CARGO_HOME/bin:\$PATH\n" > /etc/profile.d/zz-fiehnlab-rust.sh

    if [ ! -x /usr/local/bin/uv ]; then
      curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_UNMANAGED_INSTALL=1 sh >>"$L" 2>&1 && log "OK: uv"
    fi
  '
}

payload_ai_agents() {
  log "=== payload: AI agents (pi/herdr/claude/codex) + pi config in /etc/skel ==="
  chroot_run '
    set -uo pipefail; L='"$L"'; log(){ echo "[$(date -Is)] $*" | tee -a "$L"; }
    echo "prefix=/usr/local" > /etc/npmrc
    npm install -g @earendil-works/pi-coding-agent @openai/codex >>"$L" 2>&1 \
      && log "OK: pi + codex (npm global, system-wide, against the NodeSource runtime)" || log "FAILED: pi/codex npm install"

    if [ ! -x /usr/local/bin/claude ]; then
      install -d -m0755 /tmp/claude-install-home
      env HOME=/tmp/claude-install-home CLAUDE_INSTALL_ALLOW_SUDO=1 bash -c "curl -fsSL https://claude.ai/install.sh | bash" >>"$L" 2>&1
      [ -e /tmp/claude-install-home/.local/bin/claude ] \
        && cp -L /tmp/claude-install-home/.local/bin/claude /usr/local/bin/claude && chmod 0755 /usr/local/bin/claude \
        && log "OK: claude (relocated system-wide; needs CLAUDE_INSTALL_ALLOW_SUDO=1 under a root chroot)" \
        || log "FAILED: claude"
      rm -rf /tmp/claude-install-home
    fi

    if [ ! -x /usr/local/bin/herdr ]; then
      install -d -m0755 /tmp/herdr-install-home
      env HOME=/tmp/herdr-install-home bash -c "curl -fsSL https://herdr.dev/install.sh | sh" >>"$L" 2>&1
      HBIN=$(find /tmp/herdr-install-home -maxdepth 6 -type f -name herdr 2>/dev/null | head -1)
      [ -n "$HBIN" ] && cp "$HBIN" /usr/local/bin/herdr && chmod 0755 /usr/local/bin/herdr && log "OK: herdr" || log "FAILED: herdr"
      rm -rf /tmp/herdr-install-home
    fi

    # pi config: the live user (casper creates it from /etc/skel at boot -
    # it does not exist yet at build time) gets the exact toolset/config
    # from provision/autoinstall/desktop.user-data.tmpl, plus a local
    # "local" provider entry pointed at llama-chat.service (:8080) pi can
    # be pointed at manually if the gateway is unreachable (pi has
    # no automatic failover). v3: unlike the old ollama provider, the
    # local model here is FIXED (qwen3-local, baked by payload_llamacpp,
    # not pulled on demand) so the full entry - including the model id -
    # can be written here upfront; nothing downstream needs to patch this
    # file in with jq once a pull succeeds.
    # "packages" is filled in by payload_ai_brains() below once
    # pi-rescue/pi-engineering are actually cloned+installed under /opt
    # (absolute paths - see that function for why not /etc/skel).
    install -d -m0755 /etc/skel/.pi/agent /etc/skel/IdeaProjects
    printf "%s" "{\"defaultModel\":\"metabolomics/qwen3.8-flash-next\",\"defaultThinkingLevel\":\"low\",\"theme\":\"dark\",\"packages\":[],\"hideThinkingBlock\":false}" > /etc/skel/.pi/agent/settings.json
    # IMPORTANT (real bug found + fixed during v2 host preflight): pi only
    # lists models for a CUSTOM (non-catalog) provider from this own
    # "models" array in models.json - it does NOT discover them dynamically
    # from the endpoint, even for an OpenAI-compatible /v1/models-serving
    # target like llama-server. An empty "models":[] makes every
    # "provider/id" --model reference (and defaultModel) fail with "Model
    # ... not found", silently breaking both the gateway default AND the
    # local-fallback story. Verified against docs/models.md, section
    # "Configure a compatible endpoint".
    printf "%s" "{\"providers\":{\"metabolomics\":{\"baseUrl\":\"@@LLM_GATEWAY_URL@@\",\"api\":\"openai-completions\",\"apiKey\":\"REPLACE_WITH_YOUR_KEY\",\"compat\":{\"supportsDeveloperRole\":false,\"supportsReasoningEffort\":true,\"max_tokens_field\":\"max_tokens\"},\"models\":[{\"id\":\"qwen3.8-flash-next\"}]},\"local\":{\"baseUrl\":\"http://127.0.0.1:8080/v1\",\"api\":\"openai-completions\",\"apiKey\":\"sk-local\",\"compat\":{\"supportsDeveloperRole\":false,\"supportsReasoningEffort\":false,\"max_tokens_field\":\"max_tokens\"},\"models\":[{\"id\":\"qwen3-local\",\"contextWindow\":16384}]}}}" > /etc/skel/.pi/agent/models.json
    chmod 0644 /etc/skel/.pi/agent/*.json
    printf "export RESCUE_EMBED_BASE_URL=http://127.0.0.1:18081/v1\nexport RESCUE_EMBED_MODEL=nomic-embed-text\nexport HF_HUB_ENABLE_HF_TRANSFER=1\n" > /etc/profile.d/zz-fiehnlab-llama.sh
    chmod 0644 /etc/profile.d/zz-fiehnlab-llama.sh
    # Rescue stick default: no Viking/OpenViking memory dialog on first pi
    # start (irrelevant creds for a rescue session) - explicit opt-in only.
    printf "export PI_OPENVIKING_ENABLED=0\n" > /etc/profile.d/zz-fiehnlab-pi.sh
    chmod 0644 /etc/profile.d/zz-fiehnlab-pi.sh
  '
  # models.json above is written inside a single-quoted chroot block, so the
  # gateway placeholder is literal there; substitute it host-side now.
  sudo -n sed -i "s|@@LLM_GATEWAY_URL@@|$LLM_GATEWAY_URL|g" "$M/etc/skel/.pi/agent/models.json"
  log "OK: models.json gateway baseUrl = $LLM_GATEWAY_URL"
}

payload_ai_brains() {
  log "=== payload: AI rescue brains - pi-rescue + pi-engineering baked as pi extensions ==="
  # Cloned on the HOST (the chroot has no git credentials, and these are
  # private repos authenticated via the host's gh/git) into /opt inside the
  # chroot - NOT /etc/skel, so casper's per-boot skel->home copy never has
  # to duplicate two node_modules trees into tmpfs on every boot.
  local SRC="$WORK/src"
  mkdir -p "$SRC"
  for repo in pi-rescue pi-engineering; do
    if [ -d "$SRC/$repo/.git" ]; then
      log "  $repo already cloned in \$WORK/src, leaving as-is (rm -rf to force a re-clone)"
    else
      git clone --depth 1 "https://github.com/berlinguyinca/$repo.git" "$SRC/$repo" \
        && log "  OK: cloned $repo" || log "  FAILED: clone $repo (check gh/git auth on the host)"
    fi
  done

  sudo -n mkdir -p "$M/opt/pi-rescue-runtime" "$M/opt/pi-engineering-runtime"
  [ -d "$SRC/pi-rescue" ] && sudo -n rsync -a --delete --exclude .git "$SRC/pi-rescue/" "$M/opt/pi-rescue-runtime/"
  [ -d "$SRC/pi-engineering" ] && sudo -n rsync -a --delete --exclude .git "$SRC/pi-engineering/" "$M/opt/pi-engineering-runtime/"

  chroot_run '
    set -uo pipefail; L='"$L"'; log(){ echo "[$(date -Is)] $*" | tee -a "$L"; }
    for d in pi-rescue-runtime pi-engineering-runtime; do
      [ -f "/opt/$d/package.json" ] || { log "SKIP: /opt/$d not cloned (host clone failed)"; continue; }
      ( cd "/opt/$d" && npm install --omit=dev >>"$L" 2>&1 ) \
        && log "OK: npm install --omit=dev in $d" || log "FAILED: npm install in $d"
    done
    # sqlite-vec fast path: a plain prebuilt-binary npm package (no project
    # dependency, by pi-rescue design - see its README "known gaps"), loaded
    # via nodeSqlite DatabaseSync.loadExtension(). Verified working against
    # Node 22 before this build (no --experimental-sqlite flag needed, just
    # an ExperimentalWarning the code already swallows). Best-effort: the
    # pure-JS InMemoryCosineStore is the documented, tested fallback.
    if [ -d /opt/pi-rescue-runtime ]; then
      ( cd /opt/pi-rescue-runtime && npm install sqlite-vec --no-save --omit=dev >>"$L" 2>&1 ) \
        && log "OK: sqlite-vec installed (fast RAG path)" \
        || log "NOTE: sqlite-vec not installed - pure-JS cosine fallback will run (documented, tested path)"
    fi

    # pi-engineering declares @earendil-works/pi-{agent-core,ai,tui} + typebox
    # as peerDependencies (and, separately, devDependencies pinned to an
    # older 0.87.1 for its own CI typechecking) - --omit=dev skips both, so
    # nothing satisfies the *runtime* imports in its own src/. Node resolves
    # a bare specifier relative to the IMPORTING file (this package root),
    # not relative to pi own global install, so these must be physically
    # present under /opt/pi-engineering-runtime/node_modules.
    if [ -d /opt/pi-engineering-runtime ]; then
      ( cd /opt/pi-engineering-runtime && npm install --no-save --omit=dev \
          @earendil-works/pi-agent-core @earendil-works/pi-ai @earendil-works/pi-tui typebox >>"$L" 2>&1 ) \
        && log "OK: pi-engineering peerDependencies installed (pi-agent-core/pi-ai/pi-tui/typebox)" \
        || log "FAILED: pi-engineering peerDependencies - extension will fail to import at runtime"
    fi
  '

  # Wire both as pi "packages" (absolute paths - resolved relative to
  # ~/.pi/agent, i.e. $HOME-independent either way; absolute is simplest and
  # matches how package-manager.js resolves local extension sources).
  sudo -n chroot "$M" bash -c '
    jq ".packages = [\"/opt/pi-rescue-runtime\", \"/opt/pi-engineering-runtime\"]" \
      /etc/skel/.pi/agent/settings.json > /tmp/settings.json.new \
      && mv /tmp/settings.json.new /etc/skel/.pi/agent/settings.json
  ' && log "OK: wired pi-rescue + pi-engineering into /etc/skel/.pi/agent/settings.json packages" \
    || log "FAILED: could not update settings.json packages (jq missing or write failed)"
}

payload_unlock_and_readonly() {
  log "=== payload: fiehnlab-unlock + read-only mount discipline ==="
  chroot_run '
    set -uo pipefail; L='"$L"'; log(){ echo "[$(date -Is)] $*" | tee -a "$L"; }
    install -d -m0755 /usr/local/sbin /etc/skel/Desktop /usr/share/applications /etc/dconf/profile /etc/dconf/db/local.d
    [ -f /etc/dconf/profile/user ] || printf "user-db:user\nsystem-db:local\n" > /etc/dconf/profile/user
    printf "[org/gnome/desktop/media-handling]\nautomount=false\nautomount-open=false\n" > /etc/dconf/db/local.d/00-fiehnlab-no-automount
    dconf update >>"$L" 2>&1 && log "OK: dconf no-automount" || log "WARN: dconf update failed"
    cat > /usr/local/bin/mount-rw <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ \$# -ge 1 ] || { echo "usage: mount-rw <device> [mountpoint]" >&2; exit 1; }
DEV="\$1"; MP="\${2:-/mnt/\$(basename "\$DEV")}"
sudo mkdir -p "\$MP"; sudo mount -o rw "\$DEV" "\$MP"
echo "mounted \$DEV at \$MP (read-write)"
EOF
    chmod 0755 /usr/local/bin/mount-rw
    if [ -f /etc/mdadm/mdadm.conf ]; then grep -q "^AUTO -all" /etc/mdadm/mdadm.conf || echo "AUTO -all" >> /etc/mdadm/mdadm.conf; fi
    log "OK: mount-rw + no-automount + mdadm AUTO -all"
  '
  # fiehnlab-unlock is long; write it from the host side for readability,
  # then copy in. See provision/live-rescue/files/fiehnlab-unlock.
  sudo -n install -m0755 "$SCRIPT_DIR/files/fiehnlab-unlock" "$M/usr/local/sbin/fiehnlab-unlock"
  sudo -n ln -sf /usr/local/sbin/fiehnlab-unlock "$M/usr/local/bin/fiehnlab-unlock"
  sudo -n install -m0644 "$SCRIPT_DIR/files/fiehnlab-unlock.desktop" "$M/usr/share/applications/fiehnlab-unlock.desktop"
  sudo -n cp "$SCRIPT_DIR/files/fiehnlab-unlock.desktop" "$M/etc/skel/Desktop/fiehnlab-unlock.desktop"
  sudo -n chmod 0755 "$M/etc/skel/Desktop/fiehnlab-unlock.desktop"
}

payload_gpu_helper() {
  log "=== payload: GPU repos staged (NO driver installed) + fiehnlab-gpu on-demand helper ==="
  # CRITICAL: this is a portable rescue stick for UNKNOWN target hardware.
  # Never apt-get install cuda-drivers/nvidia-driver/nvidia-dkms/amdgpu at
  # build time - it's +3-4GB, locked to the live kernel, and useless on
  # AMD or non-GPU targets. Only the apt repos + a helper that installs on
  # the ACTUAL target's hardware, on demand, get baked in.
  chroot_run '
    set -uo pipefail; L='"$L"'; log(){ echo "[$(date -Is)] $*" | tee -a "$L"; }
    ( install -d -m0755 /usr/share/keyrings
      D=$(. /etc/os-release; echo ${VERSION_ID//./})
      curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${D}/x86_64/cuda-keyring_1.1-1_all.deb" -o /tmp/cuda-keyring.deb \
      && dpkg -i /tmp/cuda-keyring.deb \
      && curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
      && curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" > /etc/apt/sources.list.d/nvidia-container-toolkit.list \
      && apt-get update ) >>"$L" 2>&1 && log "OK: cuda + nvidia-container-toolkit apt repos staged" || log "FAILED: cuda repo staging"
  '
  sudo -n install -m0755 "$SCRIPT_DIR/files/fiehnlab-gpu" "$M/usr/local/sbin/fiehnlab-gpu"
  sudo -n ln -sf /usr/local/sbin/fiehnlab-gpu "$M/usr/local/bin/fiehnlab-gpu"
}

payload_rescue_toolset() {
  $SKIP_RESCUE_TOOLS && { log "skipping curated rescue toolset (--skip-rescue-tools)"; return; }
  log "=== payload: curated diagnostic/rescue/forensic toolset ==="
  chroot_run '
    set -uo pipefail; L='"$L"'; log(){ echo "[$(date -Is)] $*" | tee -a "$L"; }
    export DEBIAN_FRONTEND=noninteractive
    echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections
    apt-get update >>"$L" 2>&1
    for p in inxi lynis ansible lm-sensors dmidecode nvme-cli edac-utils stress-ng fio memtester \
             nvtop radeontop glances tshark iperf3 ethtool dnsutils arp-scan iftop nethogs \
             snmp snmp-mibs-downloader wavemon partclone chntpw rclone restic borgbackup nwipe \
             sleuthkit rkhunter chkrootkit clamav binwalk neovim hwinfo gdisk; do
      apt-get install -y --no-install-recommends "$p" >>"$L" 2>&1 && log "OK: $p" || log "FAILED: $p"
    done
    ( cd /usr/local/bin && curl -fsSL https://getmic.ro | bash ) >>"$L" 2>&1 && chmod 0755 /usr/local/bin/micro && log "OK: micro" || log "FAILED: micro"
    ( AREL=$(curl -fsSL https://api.github.com/repos/FiloSottile/age/releases/latest | grep -oE "\"tag_name\": *\"[^\"]+\"" | cut -d\" -f4)
      curl -fsSL -o /tmp/age.tar.gz "https://github.com/FiloSottile/age/releases/download/${AREL}/age-${AREL}-linux-amd64.tar.gz" \
      && tar -C /tmp -xzf /tmp/age.tar.gz && install -m0755 /tmp/age/age /tmp/age/age-keygen /usr/local/bin/ && rm -rf /tmp/age /tmp/age.tar.gz ) >>"$L" 2>&1 \
      && log "OK: age" || log "FAILED: age"
    ( SREL=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | grep -oE "\"tag_name\": *\"[^\"]+\"" | cut -d\" -f4)
      curl -fsSL -o /usr/local/bin/sops "https://github.com/getsops/sops/releases/download/${SREL}/sops-${SREL}.linux.amd64" && chmod 0755 /usr/local/bin/sops ) >>"$L" 2>&1 \
      && log "OK: sops" || log "FAILED: sops"
    ( python3 -m venv /opt/volatility3-venv && /opt/volatility3-venv/bin/pip install --no-cache-dir --upgrade pip >/dev/null \
      && /opt/volatility3-venv/bin/pip install --no-cache-dir volatility3 && ln -sf /opt/volatility3-venv/bin/vol /usr/local/bin/vol ) >>"$L" 2>&1 \
      && log "OK: volatility3 (vol)" || log "FAILED: volatility3"
    ( add-apt-repository -y ppa:yannubuntu/boot-repair && apt-get update && apt-get install -y boot-repair ) >>"$L" 2>&1 \
      && log "OK: boot-repair" || log "SKIP: boot-repair (PPA unavailable for this release)"
    apt-get install -y clonezilla >>"$L" 2>&1 && log "OK: clonezilla" || log "SKIP: clonezilla (not in repos; partclone covers imaging)"
  '
}

payload_re_tools() {
  $SKIP_RE_TOOLS && { log "skipping v2 RE/traffic/network toolset (--skip-re-tools)"; return; }
  log "=== payload: RE / traffic-interception / network toolset (authorized-use; installed only, no auto-attack) ==="
  # Resolved on the HOST (not inside chroot_run) via the rate-limit-safe
  # redirect trick - see resolve_latest_gh_tag(). An earlier build of this
  # image lost jadx AND ghidra in the same run to api.github.com's
  # anonymous 60/hr limit; this is the fix, not a guess at new filenames.
  local JADX_TAG JADX_URL
  JADX_TAG="$(resolve_latest_gh_tag skylot/jadx v1.5.6)"
  JADX_URL="https://github.com/skylot/jadx/releases/download/$JADX_TAG/jadx-${JADX_TAG#v}.zip"
  log "  jadx release: $JADX_TAG"
  chroot_run '
    set -uo pipefail; L='"$L"'; log(){ echo "[$(date -Is)] $*" | tee -a "$L"; }
    export DEBIAN_FRONTEND=noninteractive
    echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections
    apt-get update >>"$L" 2>&1
    for p in wireshark tshark bettercap sslsplit masscan lldpd netdiscover sslscan tcptraceroute \
             apktool openjdk-21-jdk python3-venv; do
      apt-get install -y --no-install-recommends "$p" >>"$L" 2>&1 && log "OK: $p" || log "FAILED: $p"
    done
    apt-get install -y --no-install-recommends ntopng >>"$L" 2>&1 && log "OK: ntopng" || log "SKIP: ntopng (not available for this release/repo set)"
    # Daemons: installed for on-demand use only. policy-rc.d blocks the
    # *build-time* start, but an *enabled* unit would still auto-start on
    # every future boot on whatever network the stick is plugged into -
    # explicitly disable each one so they stay opt-in.
    for svc in lldpd ntopng redis-server; do
      systemctl disable "$svc" >>"$L" 2>&1 && log "OK: disabled $svc (opt-in via systemctl start)" || log "NOTE: $svc not present to disable"
    done

    ( python3 -m venv /opt/mitmproxy-venv \
      && /opt/mitmproxy-venv/bin/pip install --no-cache-dir --upgrade pip >/dev/null \
      && /opt/mitmproxy-venv/bin/pip install --no-cache-dir mitmproxy \
      && for b in mitmproxy mitmdump mitmweb; do ln -sf /opt/mitmproxy-venv/bin/$b /usr/local/bin/$b; done ) >>"$L" 2>&1 \
      && log "OK: mitmproxy (mitmdump/mitmweb/mitmproxy)" || log "FAILED: mitmproxy"

    ( python3 -m venv /opt/ssh-mitm-venv \
      && /opt/ssh-mitm-venv/bin/pip install --no-cache-dir --upgrade pip >/dev/null \
      && /opt/ssh-mitm-venv/bin/pip install --no-cache-dir ssh-mitm \
      && ln -sf /opt/ssh-mitm-venv/bin/ssh-mitm /usr/local/bin/ssh-mitm ) >>"$L" 2>&1 \
      && log "OK: ssh-mitm" || log "FAILED: ssh-mitm"

    ( python3 -m venv /opt/frida-venv \
      && /opt/frida-venv/bin/pip install --no-cache-dir --upgrade pip >/dev/null \
      && /opt/frida-venv/bin/pip install --no-cache-dir frida-tools \
      && for b in /opt/frida-venv/bin/frida*; do ln -sf "$b" "/usr/local/bin/$(basename "$b")"; done ) >>"$L" 2>&1 \
      && log "OK: frida-tools ($(/opt/frida-venv/bin/frida --version 2>/dev/null))" || log "FAILED: frida-tools"

    ( curl -fsSL -o /tmp/jadx.zip "'"$JADX_URL"'" \
      && install -d -m0755 /opt/jadx && unzip -q -o /tmp/jadx.zip -d /opt/jadx && rm -f /tmp/jadx.zip \
      && chmod +x /opt/jadx/bin/jadx /opt/jadx/bin/jadx-gui \
      && ln -sf /opt/jadx/bin/jadx /usr/local/bin/jadx && ln -sf /opt/jadx/bin/jadx-gui /usr/local/bin/jadx-gui ) >>"$L" 2>&1 \
      && log "OK: jadx" || log "FAILED: jadx"

    ( install -d -m0755 /opt/testssl.sh && git clone --depth 1 https://github.com/drwetter/testssl.sh /opt/testssl.sh ) >>"$L" 2>&1 \
      && ln -sf /opt/testssl.sh/testssl.sh /usr/local/bin/testssl.sh \
      && log "OK: testssl.sh" || log "FAILED: testssl.sh"
  '
  require_in_upper "usr/local/bin/jadx" "jadx install"
  require_in_upper "usr/local/bin/testssl.sh" "testssl.sh install"
  require_in_upper "usr/local/bin/mitmdump" "mitmproxy venv (mitmdump)"
  require_in_upper "usr/local/bin/ssh-mitm" "ssh-mitm venv"
  require_in_upper "usr/local/bin/frida" "frida-tools venv"
  require_in_upper "usr/bin/tcptraceroute" "tcptraceroute (apt)"

  if $WITH_GHIDRA; then
    log "=== payload: Ghidra (~1GB GitHub release; --no-ghidra to skip) ==="
    # Host-resolved (gh api, authenticated - see resolve_ghidra_asset_url):
    # the asset filename embeds a build date, so unlike jadx it cannot be
    # built from the tag alone, and an anonymous in-chroot api.github.com
    # call is exactly what lost this tool last time (rate limit).
    local GHIDRA_URL
    GHIDRA_URL="$(resolve_ghidra_asset_url)"
    [ -n "$GHIDRA_URL" ] || fatal "could not resolve a ghidra release asset URL (gh api + anonymous fallback both failed) - ghidraRun is a required tool, not optional"
    log "  ghidra asset: $GHIDRA_URL"
    chroot_run '
      set -uo pipefail; L='"$L"'; log(){ echo "[$(date -Is)] $*" | tee -a "$L"; }
      ( curl -fsSL -o /tmp/ghidra.zip "'"$GHIDRA_URL"'" \
        && install -d -m0755 /opt \
        && unzip -q -o /tmp/ghidra.zip -d /tmp/ghidra-extract \
        && GDIR=$(find /tmp/ghidra-extract -maxdepth 1 -type d -iname "ghidra_*" | head -1) \
        && [ -n "$GDIR" ] && rm -rf /opt/ghidra && mv "$GDIR" /opt/ghidra \
        && rm -rf /tmp/ghidra.zip /tmp/ghidra-extract \
        && chmod +x /opt/ghidra/ghidraRun \
        && ln -sf /opt/ghidra/ghidraRun /usr/local/bin/ghidraRun
      ) >>"$L" 2>&1 \
        && log "OK: ghidra ($(du -sh /opt/ghidra 2>/dev/null | cut -f1))" \
        || log "FAILED: ghidra download/extract - see $L"
    '
    require_in_upper "opt/ghidra/ghidraRun" "ghidra install"
    require_in_upper "usr/local/bin/ghidraRun" "ghidraRun symlink on PATH"
  else
    log "NOTE: --no-ghidra given - Ghidra not baked (apktool/jadx still installed)"
  fi
}

payload_assist() {
  log "=== payload: zero-knowledge 'Rescue Assistant' autostart (fiehnlab-assist) ==="
  local F="$SCRIPT_DIR/files"
  sudo -n install -m0755 "$F/fiehnlab-assist" "$M/usr/local/bin/fiehnlab-assist"
  sudo -n sed -i "s|@@LLM_GATEWAY_URL@@|$LLM_GATEWAY_URL|g" "$M/usr/local/bin/fiehnlab-assist"
  sudo -n install -d -m0755 "$M/etc/skel/Desktop" "$M/usr/share/applications" "$M/etc/skel/.config/autostart"
  sudo -n install -m0644 "$F/fiehnlab-assist.desktop" "$M/usr/share/applications/fiehnlab-assist.desktop"
  sudo -n install -m0755 "$F/fiehnlab-assist.desktop" "$M/etc/skel/Desktop/fiehnlab-assist.desktop"
  sudo -n install -m0644 "$F/fiehnlab-assist-autostart.desktop" "$M/etc/skel/.config/autostart/fiehnlab-assist.desktop"
  sudo -n install -m0755 "$F/fiehnlab-selftest" "$M/usr/local/bin/fiehnlab-selftest"
  # Mirrors the full selftest report to /dev/ttyS0 at every boot - this is
  # what makes a serial-console capture (QEMU `-serial file:...`, or a real
  # headless box) prove gates 2-5 without any interactive login. Enabled in
  # payload_llamacpp() instead of here, once its After= dependencies
  # (llama-chat/llama-embed units) actually exist.
  sudo -n install -m0644 "$F/fiehnlab-selftest.service" "$M/etc/systemd/system/fiehnlab-selftest.service"
  log "OK: fiehnlab-assist + desktop launcher + autostart entry + fiehnlab-selftest baked into /etc/skel"
}

payload_boot_ux_fixes() {
  # Gate 8: the stock Ubuntu "Welcome to Ubuntu" first-boot wizard must
  # never sit on top of fiehnlab-assist's Rescue Assistant greeting.
  #
  # The actual on-top wizard is NOT gnome-initial-setup (casper's own
  # casper-bottom/52gnome_initial_setup already touches
  # ~/.config/gnome-initial-setup-done at every boot, which satisfies the
  # ConditionPathExists/AutostartCondition guards on every initial-setup
  # unit and xdg autostart entry) and there is no ubiquity/
  # ubuntu-desktop-installer*.desktop in /etc/xdg/autostart to disable
  # either. The real culprit is the ubuntu-desktop-bootstrap SNAP's
  # systemd --user unit, enabled by the package itself via
  # /etc/systemd/user/graphical-session.target.wants/ubuntu-desktop-installer.service
  # -> .../usr/lib/systemd/user/ubuntu-desktop-installer.service, which
  # runs `ubuntu_bootstrap --try-or-install` (the Flutter installer UI,
  # "Welcome to Ubuntu"/"Install Ubuntu") on every graphical session start,
  # unconditionally. We mask it the same way `systemctl --global mask`
  # would (remove the .wants symlink, symlink the unit name to /dev/null)
  # rather than deleting/disabling via the snap, since snapd owns those
  # paths and can regenerate anything we touch under /var/lib/snapd.
  #
  # We still apply the gnome-initial-setup + ubiquity/installer suppression
  # the task asked for as defense-in-depth, in case a future base ISO drops
  # the casper-bottom suppression or starts shipping a real
  # ubiquity.desktop/ubuntu-desktop-installer*.desktop autostart entry.
  log "=== payload: Gate 8 - stock first-boot wizard must never cover the Rescue Assistant greeting ==="

  log "-- masking the ubuntu-desktop-bootstrap snap's --user autostart unit (the actual 'Welcome to Ubuntu' trigger)"
  sudo -n rm -f "$M/etc/systemd/user/graphical-session.target.wants/ubuntu-desktop-installer.service"
  sudo -n ln -sf /dev/null "$M/etc/systemd/user/ubuntu-desktop-installer.service"

  log "-- defense-in-depth: Hidden=true on gnome-initial-setup's own autostart entries"
  for f in gnome-initial-setup-first-login.desktop gnome-initial-setup-copy-worker.desktop; do
    if [ -f "$M/etc/xdg/autostart/$f" ] && ! sudo -n grep -q '^Hidden=true$' "$M/etc/xdg/autostart/$f"; then
      sudo -n bash -c "printf 'Hidden=true\n' >> '$M/etc/xdg/autostart/$f'"
    fi
  done
  for f in "$M"/etc/xdg/autostart/*ubiquity*.desktop "$M"/etc/xdg/autostart/*install*.desktop "$M"/etc/xdg/autostart/*ubuntu-desktop-installer*.desktop; do
    [ -f "$f" ] || continue
    sudo -n grep -q '^Hidden=true$' "$f" || sudo -n bash -c "printf 'Hidden=true\n' >> '$f'"
    log "-- also hid unexpected autostart entry: $f"
  done

  log "-- defense-in-depth: pre-seed gnome-initial-setup-done for every future live user via /etc/skel"
  sudo -n install -d -m0755 "$M/etc/skel/.config"
  sudo -n bash -c "printf 'yes\n' > '$M/etc/skel/.config/gnome-initial-setup-done'"
  sudo -n chmod 0644 "$M/etc/skel/.config/gnome-initial-setup-done"

  log "OK: ubuntu-desktop-installer.service masked, gnome-initial-setup autostart hidden, gnome-initial-setup-done seeded"
}

payload_hf_cli() {
  log "=== payload: hf CLI (pipx, system-wide: PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin) + hf_transfer ==="
  chroot_run '
    set -uo pipefail; L='"$L"'; log(){ echo "[$(date -Is)] $*" | tee -a "$L"; }
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >>"$L" 2>&1
    apt-get install -y --no-install-recommends pipx python3-yaml >>"$L" 2>&1 \
      && log "OK: pipx + python3-yaml (apt)" || log "FAILED: pipx/python3-yaml apt install"
    export PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin
    install -d -m0755 "$PIPX_HOME"
    pipx install "huggingface_hub[cli]" >>"$L" 2>&1 \
      && log "OK: hf CLI installed via pipx" || log "FAILED: hf CLI pipx install"
    pipx inject huggingface_hub hf_transfer >>"$L" 2>&1 \
      && log "OK: hf_transfer injected into the hf venv" || log "NOTE: hf_transfer inject failed (slower downloads, not fatal)"
    chmod -R a+rX /opt/pipx
    printf "export HF_HUB_ENABLE_HF_TRANSFER=1\n" > /etc/profile.d/zz-fiehnlab-hf.sh
    chmod 0644 /etc/profile.d/zz-fiehnlab-hf.sh
    command -v hf >/dev/null 2>&1 && log "OK: hf on PATH ($(hf --version 2>&1 | tail -1))" || log "FAILED: hf not on PATH"
    runuser -u nobody -- env -i HOME=/tmp PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin hf --help >/dev/null 2>&1 \
      && log "OK: hf runs for a non-root user on a plain PATH (PIPX_BIN_DIR symlink + venv perms are world-executable)" \
      || log "FAILED: hf did not run as a non-root user - check /opt/pipx perms"
  '
}

payload_llamacpp() {
  log "=== payload: llama.cpp portable prebuilts - cuda AND vulkan, NO driver packages ==="
  # Exact asset names resolved LIVE (not guessed) against
  # https://github.com/ggml-org/llama.cpp/releases - see resolve_latest_gh_tag().
  local TAG; TAG="$(resolve_llamacpp_tag)"
  log "  llama.cpp release: $TAG"
  local BASE="https://github.com/ggml-org/llama.cpp/releases/download/$TAG"
  local CUDA_MAIN CUDA_RT VULKAN_MAIN
  CUDA_MAIN="$(dl_cache "$BASE/llama-$TAG-bin-ubuntu-cuda-12.8-x64.tar.gz" "llama-$TAG-cuda-12.8-x64.tar.gz")"
  CUDA_RT="$(dl_cache "$BASE/cudart-llama-$TAG-bin-ubuntu-cuda-12.8-x64.tar.gz" "cudart-llama-$TAG-cuda-12.8-x64.tar.gz")"
  VULKAN_MAIN="$(dl_cache "$BASE/llama-$TAG-bin-ubuntu-vulkan-x64.tar.gz" "llama-$TAG-vulkan-x64.tar.gz")"

  sudo -n install -d -m0755 "$M/opt/llama.cpp/cuda" "$M/opt/llama.cpp/vulkan"
  sudo -n tar -xzf "$CUDA_MAIN"   -C "$M/opt/llama.cpp/cuda"   --strip-components=1
  sudo -n tar -xzf "$CUDA_RT"     -C "$M/opt/llama.cpp/cuda"   --strip-components=1
  sudo -n tar -xzf "$VULKAN_MAIN" -C "$M/opt/llama.cpp/vulkan" --strip-components=1
  sudo -n chmod -R a+rX "$M/opt/llama.cpp"
  require_in_upper "opt/llama.cpp/cuda/llama-server" "llama.cpp cuda build extraction"
  require_in_upper "opt/llama.cpp/cuda/libcudart.so.12" "cudart bundle extraction (portable cuda runtime libs)"
  require_in_upper "opt/llama.cpp/vulkan/llama-server" "llama.cpp vulkan build extraction"

  sudo -n install -m0755 "$SCRIPT_DIR/files/fiehnlab-llama" "$M/usr/local/bin/fiehnlab-llama"
  sudo -n install -m0644 "$SCRIPT_DIR/files/llama-chat.default" "$M/etc/default/llama-chat"
  sudo -n install -m0644 "$SCRIPT_DIR/files/llama-chat.service" "$M/etc/systemd/system/llama-chat.service"
  sudo -n install -m0644 "$SCRIPT_DIR/files/llama-embed.service" "$M/etc/systemd/system/llama-embed.service"
  require_in_upper "usr/local/bin/fiehnlab-llama" "fiehnlab-llama GPU-detect wrapper install"

  chroot_run '
    set -uo pipefail; L='"$L"'; log(){ echo "[$(date -Is)] $*" | tee -a "$L"; }
    systemctl daemon-reload >>"$L" 2>&1
    systemctl enable llama-chat llama-embed >>"$L" 2>&1 \
      && log "OK: llama-chat + llama-embed enabled (start at boot)" || log "FAILED: systemctl enable llama-chat/llama-embed"
    systemctl enable fiehnlab-selftest >>"$L" 2>&1 \
      && log "OK: fiehnlab-selftest.service enabled (serial-console boot report)" || log "FAILED: systemctl enable fiehnlab-selftest"
  '

  log "=== downloading baked GGUF models via hf: qwen3-8b (chat), gemma-3-1b (low-RAM fallback), nomic-embed-text (embeddings) ==="
  chroot_run '
    set -uo pipefail; L='"$L"'; log(){ echo "[$(date -Is)] $*" | tee -a "$L"; }
    command -v hf >/dev/null 2>&1 || { log "FAILED: hf CLI missing - payload_hf_cli must run before payload_llamacpp"; exit 0; }
    export HF_HUB_ENABLE_HF_TRANSFER=1
    install -d -m0755 /opt/models
    [ -s /opt/models/'"$QWEN3_HF_FILE"' ] && log "cached: '"$QWEN3_HF_FILE"' already in /opt/models" || \
      { hf download '"$QWEN3_HF_REPO"' '"$QWEN3_HF_FILE"' --local-dir /opt/models >>"$L" 2>&1 \
        && log "OK: baked '"$QWEN3_HF_FILE"' (default chat model)" || log "FAILED: hf download '"$QWEN3_HF_REPO"'"; }
    [ -s /opt/models/'"$GEMMA_HF_FILE"' ] && log "cached: '"$GEMMA_HF_FILE"' already in /opt/models" || \
      { hf download '"$GEMMA_HF_REPO"' '"$GEMMA_HF_FILE"' --local-dir /opt/models >>"$L" 2>&1 \
        && log "OK: baked '"$GEMMA_HF_FILE"' (low-RAM fallback - edit /etc/default/llama-chat to switch)" || log "FAILED: hf download '"$GEMMA_HF_REPO"'"; }
    [ -s /opt/models/'"$NOMIC_HF_FILE"' ] && log "cached: '"$NOMIC_HF_FILE"' already in /opt/models" || \
      { hf download '"$NOMIC_HF_REPO"' '"$NOMIC_HF_FILE"' --local-dir /opt/models >>"$L" 2>&1 \
        && log "OK: baked '"$NOMIC_HF_FILE"' (embeddings)" || log "FAILED: hf download '"$NOMIC_HF_REPO"'"; }
    chmod -R a+rX /opt/models
  '
  require_in_upper "opt/models/$QWEN3_HF_FILE" "qwen3-8b GGUF download"
  require_in_upper "opt/models/$GEMMA_HF_FILE" "gemma-3-1b GGUF download"
  require_in_upper "opt/models/$NOMIC_HF_FILE" "nomic-embed-text GGUF download"

  # Stable symlinks so the systemd units never hardcode an exact GGUF filename
  # (a case typo in llama-chat.default once pointed at a nonexistent path and
  # llama-chat never served). Relative targets resolve inside the booted image.
  sudo -n ln -sf "$QWEN3_HF_FILE" "$M/opt/models/chat-default.gguf"
  sudo -n ln -sf "$GEMMA_HF_FILE" "$M/opt/models/chat-lowram.gguf"
  sudo -n ln -sf "$NOMIC_HF_FILE" "$M/opt/models/embed-default.gguf"
  require_in_upper "opt/models/chat-default.gguf" "chat-default.gguf stable symlink"
  require_in_upper "opt/models/embed-default.gguf" "embed-default.gguf stable symlink"

  log "=== build-time rehearsal: run chat+embed llama-server directly (no init in a chroot), build pi-rescue's RAG index, verify pi end to end ==="
  # Same reasoning payload_ollama (v2) used for the exact same reason: the
  # chroot shares the HOST's PID/network namespace (no netns of its own,
  # and no running systemd to systemctl-start against) - launch
  # llama-server directly and kill the EXACT PIDs this script started,
  # never pkill by name. FIEHNLAB_LLAMA_BACKEND=cpu is forced here because
  # the chroot has no GPU driver of its own (see fiehnlab-llama header) -
  # auto-detection would probably also land on cpu/vulkan-lavapipe-excluded,
  # but forcing it is deterministic and faster to start.
  #
  # Every FATAL gate here is decided by the OUTER script re-reading a
  # result file after this returns (right below), never by this inner
  # log text - chroot_run'"'"'s own exit status does not propagate (see
  # purge_any_gpu_driver'"'"'s comment on the exact same bug).
  # Build-time-only ports: this build HOST is a busy, shared machine with
  # its own persistent services already bound to the real :8080/:8081 (a
  # docker-proxy and an unrelated gateway were found squatting on them
  # live, mid-build - the chroot shares the host's network namespace
  # entirely, so that is a real collision, not a hypothetical one). The
  # SHIPPED systemd units still bind exactly :8080/:8081 (that only matters
  # once this image boots in its own isolated VM/hardware); this rehearsal
  # just needs to prove the MODELS work, so it uses throwaway ports and
  # patches a throwaway copy of models.json to match, never touching 8080/8081.
  chroot_run '
    set -uo pipefail; L='"$L"'; log(){ echo "[$(date -Is)] $*" | tee -a "$L"; }
    export FIEHNLAB_LLAMA_BACKEND=cpu
    : > /tmp/fiehnlab-embed-dim.txt
    : > /tmp/fiehnlab-chat-answer.txt
    rm -f /tmp/fiehnlab-pi-smoke.ok
    REHEARSAL_CHAT_PORT=28080
    REHEARSAL_EMBED_PORT=28081
    if curl -fsS --max-time 1 http://127.0.0.1:$REHEARSAL_CHAT_PORT/health >/dev/null 2>&1 || curl -fsS --max-time 1 http://127.0.0.1:$REHEARSAL_EMBED_PORT/health >/dev/null 2>&1; then
      log "FAILED: :$REHEARSAL_CHAT_PORT/:$REHEARSAL_EMBED_PORT already answer before we started anything - refusing to touch a foreign server; skipping bake-time rehearsal"
    else
      /usr/local/bin/fiehnlab-llama llama-server --host 127.0.0.1 --port $REHEARSAL_EMBED_PORT --embeddings --alias nomic-embed-text -c 2048 -b 2048 -ub 2048 -m /opt/models/'"$NOMIC_HF_FILE"' >/tmp/llama-embed-build.log 2>&1 &
      EMBED_PID=$!
      /usr/local/bin/fiehnlab-llama llama-server --host 127.0.0.1 --port $REHEARSAL_CHAT_PORT --alias qwen3-local -c 16384 -np 1 --reasoning off -m /opt/models/'"$QWEN3_HF_FILE"' >/tmp/llama-chat-build.log 2>&1 &
      CHAT_PID=$!
      EMBED_READY=false; CHAT_READY=false
      for i in $(seq 1 90); do
        curl -fsS --max-time 1 http://127.0.0.1:$REHEARSAL_EMBED_PORT/health >/dev/null 2>&1 && EMBED_READY=true
        curl -fsS --max-time 1 http://127.0.0.1:$REHEARSAL_CHAT_PORT/health >/dev/null 2>&1 && CHAT_READY=true
        $EMBED_READY && $CHAT_READY && break
        sleep 2
      done
      $EMBED_READY || log "FAILED: llama-embed (pid $EMBED_PID) never answered on :$REHEARSAL_EMBED_PORT - see /tmp/llama-embed-build.log"
      $CHAT_READY  || log "FAILED: llama-chat (pid $CHAT_PID) never answered on :$REHEARSAL_CHAT_PORT - see /tmp/llama-chat-build.log"

      if $EMBED_READY; then
        curl -fsS --max-time 30 http://127.0.0.1:$REHEARSAL_EMBED_PORT/v1/embeddings -H "content-type: application/json" \
          -d "{\"model\":\"nomic-embed-text\",\"input\":\"warm up\"}" 2>/dev/null \
          | node -e "let d=\"\";process.stdin.on(\"data\",c=>d+=c);process.stdin.on(\"end\",()=>{try{console.log(JSON.parse(d).data[0].embedding.length)}catch(e){console.log(0)}})" \
          > /tmp/fiehnlab-embed-dim.txt
        log "embeddings warm-up dim: $(cat /tmp/fiehnlab-embed-dim.txt)"

        if [ -f /opt/pi-rescue-runtime/scripts/pi-rescue.ts ]; then
          ( cd /opt/pi-rescue-runtime && RESCUE_EMBED_BASE_URL=http://127.0.0.1:$REHEARSAL_EMBED_PORT/v1 RESCUE_EMBED_MODEL=nomic-embed-text node scripts/pi-rescue.ts build-index >>"$L" 2>&1 ) \
            && [ -s /opt/pi-rescue-runtime/kb/.vectors/index.json ] \
            && log "OK: pi-rescue build-index -> kb/.vectors/index.json ($(wc -c < /opt/pi-rescue-runtime/kb/.vectors/index.json) bytes)" \
            || log "FAILED: pi-rescue build-index (RAG index not baked)"
        else
          log "FAILED: /opt/pi-rescue-runtime missing - payload_ai_brains must run before payload_llamacpp"
        fi
      fi

      if $CHAT_READY; then
        curl -fsS --max-time 60 http://127.0.0.1:$REHEARSAL_CHAT_PORT/v1/chat/completions -H "content-type: application/json" \
          -d "{\"model\":\"qwen3-local\",\"messages\":[{\"role\":\"user\",\"content\":\"say hi in exactly three words\"}],\"max_tokens\":64}" 2>/dev/null \
          | node -e "let d=\"\";process.stdin.on(\"data\",c=>d+=c);process.stdin.on(\"end\",()=>{try{console.log(JSON.parse(d).choices[0].message.content||\"\")}catch(e){console.log(\"\")}})" \
          > /tmp/fiehnlab-chat-answer.txt
        log "chat completion at build time: $(cat /tmp/fiehnlab-chat-answer.txt)"

        if command -v pi >/dev/null 2>&1; then
          TMPHOME=$(mktemp -d)
          cp -a /etc/skel/.pi "$TMPHOME/" 2>/dev/null
          jq --arg url "http://127.0.0.1:$REHEARSAL_CHAT_PORT/v1" ".providers.local.baseUrl = \$url" \
            "$TMPHOME/.pi/agent/models.json" > "$TMPHOME/.pi/agent/models.json.new" \
            && mv "$TMPHOME/.pi/agent/models.json.new" "$TMPHOME/.pi/agent/models.json"
          if HOME="$TMPHOME" PI_OPENVIKING_ENABLED=0 PI_RESCUE_ASSIST=1 \
             timeout 300 pi --model "local/qwen3-local" \
             --print "say hi in exactly three words" >/tmp/pi-smoke.log 2>&1; then
            touch /tmp/fiehnlab-pi-smoke.ok
            log "OK: pi smoke test (extensions loaded, local provider answered) - $(tail -c 300 /tmp/pi-smoke.log | tr -d "\n")"
          else
            log "FAILED: pi smoke test - see /tmp/pi-smoke.log: $(tail -c 500 /tmp/pi-smoke.log | tr -d "\n")"
          fi
          rm -rf "$TMPHOME"
        fi
      fi

      kill "$EMBED_PID" "$CHAT_PID" 2>/dev/null || true
      wait "$EMBED_PID" "$CHAT_PID" 2>/dev/null || true
    fi
  '

  # Hard gates, enforced here in the OUTER script (see the comment above
  # this chroot_run for why they cannot live inside it).
  local EMBED_DIM CHAT_ANSWER EMBEDDER_CHECK
  EMBED_DIM="$(sudo -n chroot "$M" cat /tmp/fiehnlab-embed-dim.txt 2>/dev/null || echo 0)"
  [ "$EMBED_DIM" = "768" ] || fatal "build-time embeddings warm-up (rehearsal port :28081) did not return a 768-dim vector (got '$EMBED_DIM') - see $WORK/logs and $M/tmp/llama-embed-build.log"
  CHAT_ANSWER="$(sudo -n chroot "$M" cat /tmp/fiehnlab-chat-answer.txt 2>/dev/null || true)"
  [ -n "$CHAT_ANSWER" ] || fatal "build-time chat completion (rehearsal port :28080, qwen3-local) returned no content - see $M/tmp/llama-chat-build.log"
  log "  qwen3-local answered at build time: $CHAT_ANSWER"
  EMBEDDER_CHECK="$(sudo -n chroot "$M" node -e 'try{console.log(JSON.parse(require("fs").readFileSync("/opt/pi-rescue-runtime/kb/.vectors/index.json","utf8")).embedderId||"")}catch(e){console.log("")}' 2>/dev/null)"
  [ "$EMBEDDER_CHECK" = "openai:nomic-embed-text" ] || fatal "baked RAG index embedderId is '$EMBEDDER_CHECK', expected openai:nomic-embed-text"
  sudo -n chroot "$M" test -e /tmp/fiehnlab-pi-smoke.ok || fatal "pi smoke test (local/qwen3-local) failed - see $M/tmp/pi-smoke.log"
  log "  gates OK: embeddings dim=768, chat answered, embedderId=openai:nomic-embed-text, pi smoke test passed"
}

payload_llama_swap() {
  log "=== payload: llama-swap (on-demand model tier, :9090 - decoupled from llama-chat/llama-embed) ==="
  local TAG VER TARBALL
  TAG="$(resolve_latest_gh_tag mostlygeek/llama-swap "$LLAMA_SWAP_TAG_FALLBACK")"
  VER="${TAG#v}"
  log "  llama-swap release: $TAG"
  TARBALL="$(dl_cache "https://github.com/mostlygeek/llama-swap/releases/download/$TAG/llama-swap_${VER}_linux_amd64.tar.gz" "llama-swap_${VER}_linux_amd64.tar.gz")"

  sudo -n install -d -m0755 "$M/tmp/llama-swap-extract" "$M/etc/llama-swap"
  sudo -n tar -xzf "$TARBALL" -C "$M/tmp/llama-swap-extract"
  sudo -n install -m0755 "$M/tmp/llama-swap-extract/llama-swap" "$M/usr/local/bin/llama-swap"
  sudo -n rm -rf "$M/tmp/llama-swap-extract"
  sudo -n install -m0644 "$SCRIPT_DIR/files/llama-swap-config.yaml" "$M/etc/llama-swap/config.yaml"
  sudo -n install -m0644 "$SCRIPT_DIR/files/llama-swap.service" "$M/etc/systemd/system/llama-swap.service"
  require_in_upper "usr/local/bin/llama-swap" "llama-swap binary install"

  chroot_run '
    set -uo pipefail; L='"$L"'; log(){ echo "[$(date -Is)] $*" | tee -a "$L"; }
    systemctl daemon-reload >>"$L" 2>&1
    systemctl enable llama-swap >>"$L" 2>&1 && log "OK: llama-swap.service enabled" || log "FAILED: systemctl enable llama-swap"
  '
}

payload_models_tui() {
  log "=== payload: fiehnlab-models (curated/search TUI) + fiehnlab-pull-model (hf-based) ==="
  sudo -n install -d -m0755 "$M/usr/local/lib"
  sudo -n install -m0644 "$SCRIPT_DIR/files/fiehnlab-llama-common.sh" "$M/usr/local/lib/fiehnlab-llama-common.sh"
  sudo -n install -m0755 "$SCRIPT_DIR/files/fiehnlab-llama-swap-register.py" "$M/usr/local/lib/fiehnlab-llama-swap-register.py"
  sudo -n install -m0755 "$SCRIPT_DIR/files/fiehnlab-models" "$M/usr/local/bin/fiehnlab-models"
  sudo -n install -m0755 "$SCRIPT_DIR/files/fiehnlab-pull-model" "$M/usr/local/bin/fiehnlab-pull-model"
  require_in_upper "usr/local/bin/fiehnlab-models" "fiehnlab-models TUI install"
  require_in_upper "usr/local/bin/fiehnlab-pull-model" "fiehnlab-pull-model install"

  chroot_run '
    set -uo pipefail; L='"$L"'; log(){ echo "[$(date -Is)] $*" | tee -a "$L"; }
    command -v fzf >/dev/null 2>&1 && log "OK: fzf present (fiehnlab-models)" || log "FAILED: fzf missing"
    python3 -c "import yaml" 2>/dev/null && log "OK: python3 yaml module present (fiehnlab-llama-swap-register.py)" || log "FAILED: python3 yaml module missing"
  '
}

# Safety net: NEVER let a GPU driver survive into the squashfs. ollama's own
# install.sh (and anything else probing the BUILD HOST's /sys) can silently
# apt-get install the NVIDIA driver because it sees the build host's real
# GPU through the chroot. Run this unconditionally right before squashing.
purge_any_gpu_driver() {
  log "=== safety net: purge any GPU driver that snuck in (this is a portable image, driver is on-demand only) ==="
  # Real bug found + fixed: chroot_run()'s "exit 1" only exits the INNER
  # bash -c running inside the chroot - it does NOT propagate to abort this
  # OUTER script (no `set -e` here, by design, so the many best-effort
  # payload_* steps can use `cmd || log FAILED` without taking the whole
  # build down). That silently turned this safety net into a log line, not
  # a gate: a GPU driver got baked into a real build (ollama's own
  # installer pulling it in - see payload_ollama()) and the build sailed on
  # through resquash+ISO anyway. Capture chroot_run's own exit status and
  # call the OUTER fatal() explicitly instead of trusting an inner exit.
  chroot_run '
    set -uo pipefail; L='"$L"'
    export DEBIAN_FRONTEND=noninteractive
    # Anchored to "^ii" (actually installed, not a removed-but-config-left-
    # over "rc" entry) and to the real system driver package families only -
    # never matches ollama'"'"'s own bundled lib/ollama/*.so userspace accel
    # libraries (those are files inside the ollama tarball, not a dpkg
    # package, so dpkg -l could never list them either way, but the
    # anchored match makes that explicit rather than incidental).
    GPUPAT="cuda-drivers|nvidia-driver|nvidia-dkms|nvidia-kernel"
    if dpkg -l | grep "^ii" | grep -qiE "$GPUPAT"; then
      apt-get purge -y "cuda-drivers*" "nvidia-driver*" "nvidia-dkms*" "nvidia-kernel*" \
        "libnvidia*" "nvidia-open*" "nvidia-persistenced*" "nvidia-settings*" \
        "nvidia-firmware*" "xserver-xorg-video-nvidia*" >>"$L" 2>&1
      apt-get purge -y --allow-change-held-packages "linux-generic-hwe-24.04" "linux-headers-generic-hwe-24.04" >>"$L" 2>&1 || true
      apt-get autoremove -y --purge >>"$L" 2>&1
      rm -rf /var/lib/dkms/*nvidia* /usr/src/nvidia-* /usr/src/linux-headers* /usr/src/linux-hwe* 2>/dev/null || true
    fi
    dpkg -l | grep "^ii" | grep -iE "$GPUPAT" && { echo "GPU DRIVER STILL PRESENT - BUILD SHOULD FAIL" >&2; exit 1; } || echo "confirmed: no GPU driver baked" | tee -a "$L"
  '
  [ $? -eq 0 ] || fatal "a GPU driver is still present after the purge attempt - this portable image must never ship one baked in. Check $WORK/logs/rescue-os-build.log for what pulled it in and purge manually before re-running."
}

cleanup_chroot() {
  log "=== preserving build logs to \$WORK/logs before they get truncated/wiped ==="
  mkdir -p "$WORK/logs"
  for f in "$M/var/log/rescue-os-build.log" "$M/tmp/llama-embed-build.log" "$M/tmp/llama-chat-build.log" "$M/tmp/pi-smoke.log"; do
    [ -f "$f" ] && sudo -n cp -a "$f" "$WORK/logs/$(basename "$f")" 2>/dev/null
  done
  log "=== final cleanup (apt/pip/npm caches, logs) before resquash ==="
  chroot_run '
    apt-get clean; rm -rf /var/lib/apt/lists/*
    rm -rf /root/.cache /root/.npm /tmp/* 2>/dev/null
    find /var/log -type f -exec truncate -s0 {} \; 2>/dev/null
  '
  log "preserved logs (if present) under $WORK/logs/ - rescue-os-build.log, llama-embed-build.log, llama-chat-build.log, pi-smoke.log"
}

# ============================================================================
# Repack: squashfs -> manifest/size -> md5sum.txt -> ISO
# ============================================================================

resquash_and_repack() {
  log "=== resquash the live layer (xz, 131072 block - matches the original) ==="
  sudo -n rm -f new.minimal.standard.live.squashfs
  sudo -n mksquashfs "$UPPER_MNT/upper" new.minimal.standard.live.squashfs -comp xz -b 131072 -no-recovery -noappend
  sudo -n chown "$(id -u)":"$(id -g)" new.minimal.standard.live.squashfs

  log "=== regenerate manifest (diff-style, matches the original's own format) + .size (sum of Installed-Size) ==="
  grep -E '^\+[^+]' minimal.manifest.orig | sed 's/^+//' > minimal-plus-only.txt
  grep -E '^\+[^+]' minimal.standard.manifest.orig | sed 's/^+//' > standard-plus-only.txt
  cat minimal-plus-only.txt standard-plus-only.txt | sort -u > standard-baseline-pkglist.txt
  sudo -n dpkg-query --admindir="$UPPER_MNT/upper/var/lib/dpkg" -W -f '${Package}\t${Version}\n' 2>/dev/null | sort > new-full-pkglist.txt
  comm -13 standard-baseline-pkglist.txt new-full-pkglist.txt | sed 's/^/+/' > new-plus-lines.txt
  { echo "--- /build/livecd.ubuntu.minimal.standard.manifest.full"; echo "+++ /build/livecd.ubuntu.minimal.standard.live.manifest.full"; cat new-plus-lines.txt; } > new.minimal.standard.live.manifest
  TOTKB=$(sudo -n dpkg-query --admindir="$UPPER_MNT/upper/var/lib/dpkg" -W -f '${Installed-Size}\n' 2>/dev/null | awk '{s+=$1} END{print s}')
  printf '%s' $(( TOTKB * 1024 )) > new.minimal.standard.live.size

  log "=== regenerate md5sum.txt for the 3 changed files ==="
  H_SQ=$(md5sum new.minimal.standard.live.squashfs | awk '{print $1}')
  H_MF=$(md5sum new.minimal.standard.live.manifest | awk '{print $1}')
  H_SZ=$(md5sum new.minimal.standard.live.size | awk '{print $1}')
  cp md5sum.txt.orig new.md5sum.txt; chmod u+w new.md5sum.txt
  sed -i "s#^[0-9a-f]\{32\}  \./casper/minimal\.standard\.live\.squashfs\$#${H_SQ}  ./casper/minimal.standard.live.squashfs#" new.md5sum.txt
  sed -i "s#^[0-9a-f]\{32\}  \./casper/minimal\.standard\.live\.manifest\$#${H_MF}  ./casper/minimal.standard.live.manifest#" new.md5sum.txt
  sed -i "s#^[0-9a-f]\{32\}  \./casper/minimal\.standard\.live\.size\$#${H_SZ}  ./casper/minimal.standard.live.size#" new.md5sum.txt

  log "=== xorriso replay: rebuild the hybrid BIOS+UEFI ISO ==="
  rm -f "$OUT_ISO"
  xorriso -indev "$BASE_ISO" -outdev "$OUT_ISO" \
    -boot_image any replay \
    -map new.minimal.standard.live.squashfs /casper/minimal.standard.live.squashfs \
    -map new.minimal.standard.live.manifest /casper/minimal.standard.live.manifest \
    -map new.minimal.standard.live.size /casper/minimal.standard.live.size \
    -map new.md5sum.txt /md5sum.txt
  log "ISO: $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
}

verify_offline() {
  log "=== offline verify: loop-mount + md5sum -c ==="
  MNT="$WORK/mnt/iso-verify"; mkdir -p "$MNT"
  sudo -n mount -o loop,ro "$OUT_ISO" "$MNT"
  BAD=$(cd "$MNT" && sudo -n md5sum -c md5sum.txt 2>/dev/null | grep -v ': OK' || true)
  sudo -n umount "$MNT"
  if [ -n "$BAD" ]; then echo "$BAD" >&2; echo "ERROR: md5sum mismatches in the rebuilt ISO" >&2; exit 1; fi
  log "OK: md5sum -c clean"
}

# ============================================================================
# Main
# ============================================================================

extract_layers
setup_overlay
chroot_enter

if $PHASE0_ONLY; then
  log "=== Phase 0: installing $PHASE0_PKG as the walking-skeleton proof ==="
  chroot_run "apt-get update >>$L 2>&1 && apt-get install -y --no-install-recommends $PHASE0_PKG >>$L 2>&1"
else
  payload_dev_and_cli
  payload_ai_agents
  payload_ai_brains
  require_in_upper "opt/pi-rescue-runtime/node_modules" "pi-rescue npm install"
  require_in_upper "opt/pi-engineering-runtime/node_modules" "pi-engineering npm install"
  payload_unlock_and_readonly
  payload_gpu_helper
  payload_rescue_toolset
  payload_re_tools
  payload_assist
  require_in_upper "usr/local/bin/fiehnlab-assist" "payload_assist (fiehnlab-assist)"
  require_in_upper "etc/skel/.config/autostart/fiehnlab-assist.desktop" "payload_assist (autostart entry)"
  payload_boot_ux_fixes
  require_in_upper "etc/systemd/user/ubuntu-desktop-installer.service" "payload_boot_ux_fixes (installer wizard masked)"
  require_in_upper "etc/skel/.config/gnome-initial-setup-done" "payload_boot_ux_fixes (gnome-initial-setup-done seeded)"
  payload_hf_cli
  payload_llamacpp
  payload_llama_swap
  payload_models_tui
fi

purge_any_gpu_driver
cleanup_chroot
chroot_exit
resquash_and_repack
verify_offline

log "DONE. Boot-verify manually in QEMU (OVMF, headless VNC+serial) before trusting this image -"
log "  see README.md 'QEMU verification' for the launch command and spot-check list."
