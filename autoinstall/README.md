# Fiehnlab unattended Ubuntu autoinstall images

Autonomous ("touch nothing") Ubuntu installs that ride on the one-stick Ventoy multiboot
drive alongside the Rocky node ISOs. Two images today, same backbone (USB-safe whole-disk
install, DHCP, dynamic hostname, admin `@@PRIMARY_USER@@` with the admin-workstation key):

| Image | Role label | What it is |
|-------|-----------|------------|
| `gpu-node.user-data.tmpl` | `gpu-node` | Minimal **Ubuntu Server** for a headless GPU/compute box. Build from the **live-server** ISO. |
| `desktop.user-data.tmpl`  | `desktop`  | Full **GNOME desktop** daily driver (`source.id: ubuntu-desktop`) with the full dev toolset + coding agents. Build from the **live-desktop** ISO — `ubuntu-desktop` is not a valid source id on the server ISO. |

## Files

| File | What it is |
|------|------------|
| `gpu-node.user-data.tmpl`, `desktop.user-data.tmpl` | The autoinstall config **templates** (committed). Each has the placeholder `@@USER_PW_HASH@@` — **no real secret is in git** (per the "no passwords in GitHub" rule). |
| `meta-data` | NoCloud meta-data. The ISO build writes `/server/meta-data` with a per-image `instance-id` (e.g. `gpu-node` / `desktop`). |
| `*.user-data` (no `.tmpl`) | The **deployable** config with the real password hash substituted in. **Never commit these.** Produce them at build time (below) into the scratchpad. |

## Common backbone (both images)

- **Dynamic hostname** — `early-commands` picks a random Futurama character that does **not**
  already resolve in DNS (`getent hosts <name>.fiehnlab.ucdavis.edu`), and writes it into
  `/autoinstall.yaml` (subiquity re-reads the file after early-commands). `fry`/`admin-workstation`/
  `zoidberg` are excluded as taken. Nothing is hard-coded — build one stick, install many
  boxes, each self-names. (The static `identity.hostname` is only a fallback.) The name is
  set locally; adding a DNS A record / DHCP reservation is a separate manual step.
- **Disk safety** — the same selector lists fixed disks, **excludes USB/removable**, prefers
  NVMe → other SSD → largest, writes the chosen `/dev/…` into `/autoinstall.yaml`, and
  **aborts** if no eligible fixed disk exists. The in-file `storage.match: {ssd: true}` is a
  second layer (subiquity's `ssd`/`size` selectors never return the install-media disk). It
  cannot wipe the Ventoy stick.
- **Admin user** — `@@PRIMARY_USER@@`, in `sudo` (full sudo, **password-gated**, not NOPASSWD) and
  `docker`; key-only SSH with the admin-workstation key; account password (injected at build) for
  console/sudo only. Role written to `/etc/fiehnlab/role`, detected GPU to `/etc/fiehnlab/gpu`.
- **GPU** — driver by vendor (NVIDIA via `drivers.install`; AMD via `amdgpu-install` ROCm +
  `render,video` groups). Container GPU access: Docker gets `nvidia-container-toolkit` +
  runtime; a **first-boot oneshot** (`fiehnlab-gpu-container.service`) finalizes NVIDIA CDI
  and the docker runtime on real hardware (can't run in the GPU-less installer). Apptainer
  uses `--nv` / `--rocm`. AMD docker: `--device=/dev/kfd --device=/dev/dri --group-add video,render`.
- **Monitoring** — `prometheus-node-exporter` (:9100) + `nvidia_gpu_exporter` (:9835, installed
  by the first-boot oneshot) for the lab Prometheus/Grafana. No fail2ban on these nodes.

## gpu-node specifics
Minimal server; Docker + compose, Apptainer. That's it — it's a headless compute box.

## desktop specifics
Full GNOME (GDM login, no auto-login). Toolset replicated from admin-workstation:

- apt/system: `vim btop tmux git build-essential nodejs npm docker.io docker-compose-v2
  python3-venv python3-pip unzip`, Apptainer (PPA), Tailscale (official script), Google
  Chrome (Google repo), Firefox (via ubuntu-desktop), **Go** (official tarball → `/usr/local/go`),
  **AWS CLI v2** (official installer → `/usr/local/bin/aws`).
- **per-user, installed on first boot as `@@PRIMARY_USER@@`** (`fiehnlab-desktop-user-setup.service`,
  since these live under `~` and the service runs as the user): **rustup**, **sdkman**, **uv**,
  npm globals **pi** (`@earendil-works/pi-coding-agent`) + **codex** (`@openai/codex`),
  **claude** (native installer), **herdr** (`herdr.dev/install.sh`).
- **pi wiring**: `~/.pi/agent/settings.json` sets `defaultModel: metabolomics/…` and the
  `pi-engineering-runtime` package; `~/.pi/agent/models.json` points provider `metabolomics`
  at `@@LLM_GATEWAY_URL@@`. **Two manual bits (by design, they're secrets/private):**
  1. set the real `apiKey` in `~/.pi/agent/models.json` (placeholder `REPLACE_WITH_YOUR_KEY`);
  2. the `berlinguyinca/pi-engineering` clone is best-effort — if it's private, clone it with
     your git auth once Tailscale is up. Both are logged as NOTE in `/var/log/fiehnlab-provision.log`.
- After install: `tailscale up` to join the tailnet; the desktop joins the GPU cluster only
  if it has the hardware (drivers are present either way). Not a Slurm node.

## Security hardening (both images)

Pragmatic, docker/GPU-safe hardening, applied on **first boot** by a role-aware
`/usr/local/sbin/fiehnlab-harden.sh` (cloud-init `runcmd`) using config dropped via
`write_files`. It never runs `ufw` in the installer chroot (that would program the
installer's own netfilter) — everything that needs the real kernel runs at first boot.

- **SSH**: key-only. `ssh.allow-pw:false` at install + `sshd_config.d/10-fiehnlab-hardening.conf`
  (`PasswordAuthentication no`, `PermitRootLogin no`, `AllowUsers @@PRIMARY_USER@@`, `X11Forwarding no`,
  idle timeout). `MaxAuthTries` left at the default 6 (a lower value locks out an agent that
  offers several keys first).
- **Host firewall (ufw)**: default-deny inbound. SSH (22) from anywhere (key-only); metrics
  `9100`/`9835` only from private + Tailscale ranges (`10/8`,`172.16/12`,`192.168/16`,`100.64/10`).
  The **docker-bypasses-ufw** hole is closed with the ufw-docker `DOCKER-USER` block appended to
  `after.rules` (published container ports reachable only from private sources).
- **Auto security updates, no auto-reboot**: `unattended-upgrades` (security origins). Blacklists
  `nvidia-driver-*`,`libnvidia-*`,`nvidia-container*`,`docker.io`,`containerd` so an unattended
  upgrade can't cause a driver/library mismatch or restart dockerd (killing jobs) on a box that
  never auto-reboots.
- **sysctl** (`99-fiehnlab-hardening.conf`): `rp_filter=2` (loose — strict breaks docker's many
  ifaces), no redirects/source-routing, syncookies, `kptr_restrict`, `dmesg_restrict`,
  `yama.ptrace_scope=1`, `fs.protected_*`, `suid_dumpable=0`. **Not touched** (docker/apptainer
  need them): `ip_forward`, user-namespaces, bridge-nf.
- **Also**: root account locked (`passwd -l root`); AppArmor enforced; lightweight **auditd**
  (identity/sudo/sshd/privileged-exec watches); unused daemons disabled (gpu-node headless:
  avahi/cups/bluetooth/ModemManager/whoopsie; desktop: whoopsie/apport only).
- **Residual (accepted)**: Secure Boot stays **off** (NVIDIA DKMS). No fail2ban (key-only SSH
  defeats brute force). Not doing CIS module-blacklist / mount-hardening / GRUB password (would
  risk docker/apptainer/GPU or need per-box tuning).

## Build the deployable user-data (inject the password hash)

```bash
# Generate the sha512crypt hash from the @@PRIMARY_USER@@ password WITHOUT storing the password
# or hash in git. Type the password at the prompt (not echoed):
read -rs PW
HASH=$(python3 -c "import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))" "$PW"); unset PW
# One per image, into a build copy OUTSIDE the repo (e.g. your scratch dir).
# Anchor the sed to the `password:` line ONLY — a global replace also rewrites the
# @@...@@ token in the line-5 header comment, leaking the hash into a second place.
for img in gpu-node desktop; do
  sed "/^ *password:/ s#@@USER_PW_HASH@@#${HASH}#" "$img.user-data.tmpl" > "/path/to/scratch/$img.user-data"
done
```

Validate before building the ISO (subiquity repo provides the schema validator):

```bash
python3 -c "import yaml; yaml.safe_load(open('gpu-node.user-data'))"
python3 subiquity/scripts/validate-autoinstall-user-data.py < gpu-node.user-data   # and desktop.user-data
```

## Put an image on the stick — baked autoinstall ISO (recommended, deterministic under Ventoy)

One remastered ISO per image; drop each on Ventoy as an ordinary file. **Use the
matching source ISO:** gpu-node ← `ubuntu-*-live-server-amd64.iso`, desktop ←
`ubuntu-*-desktop-amd64.iso` (the desktop seed's `source.id: ubuntu-desktop` only
exists on the Desktop ISO). The `/cdrom/server/` seed path below is just the
directory name on the remastered ISO; it is the same for both images.

```bash
sudo apt-get install -y xorriso
SRC=ubuntu-24.04.5-live-server-amd64.iso     # gpu-node;  desktop: ubuntu-24.04.5.1-desktop-amd64.iso
mkdir -p ext && sudo xorriso -osirrox on -indev "$SRC" -extract / ext
sudo mkdir -p ext/server
sudo cp /path/to/scratch/gpu-node.user-data ext/server/user-data          # or desktop.user-data
printf 'instance-id: gpu-node\n' | sudo tee ext/server/meta-data >/dev/null   # or 'desktop'
# Seed every boot entry (semicolon escaped for grub):
sudo sed -i 's#---#autoinstall ds=nocloud\\;s=/cdrom/server/ ---#' ext/boot/grub/grub.cfg
# Rebuild a hybrid BIOS+UEFI ISO: easiest is Canonical's `livefs-editor`, or re-run xorriso
# with the source ISO's -boot options (xorriso -indev <iso> -report_el_torito as_mkisofs).
```
Then `cp ubuntu-24.04-<image>-autoinstall.iso /mnt/ventoy/`. (Fallback: Ventoy `auto_install`
plugin with `template` pointing at the `.user-data` — less deterministic for Ubuntu autoinstall.)

## MUST verify in QEMU on admin-workstation before real hardware

The disk selector + grub seed are the risky parts (OVMF is installed on admin-workstation):

```bash
# NVMe + USB-storage stand-in: install must land on the NVMe, USB untouched.
sudo qemu-system-x86_64 -enable-kvm -m 4096 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=/tmp/vars.fd \
  -device nvme,drive=d0,serial=nvme0 -drive if=none,id=d0,file=nvme.img,format=raw \
  -drive file=/dev/sdX,format=raw,if=none,id=stick -device usb-storage,drive=stick -usb
# Run 2: one rotational virtio disk only -> HDD fallback works.
# Run 3 (negative): USB stand-in only, no fixed disk -> must ABORT, never wipe USB.
```

## Secure Boot

The NVIDIA DKMS module won't load under Secure Boot in a generic environment. For the install,
disable Secure Boot in firmware/BMC, install, then re-enable if desired (the NVIDIA path may
need SB off or a signed/MOK-enrolled module — decide per box).
