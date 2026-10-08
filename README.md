# rescue-stick

Reproducibly build the **fiehnlab provisioning + rescue USB**: a single Ventoy
multiboot stick that can unattended-install our systems, boot a full
rescue/work environment, and carry our secrets encrypted — "plug it into any
box and install it, rescue it, or start working."

Everything here is **tooling and templates only** — no ISOs, no keys, no
passwords. Secrets live in an encrypted LUKS container on the stick and are
loaded into RAM at boot; the password hash for autoinstall is injected at build
time from an uncommitted source. See [`stick/README.md`](stick/README.md).

## What's on the stick

| System | Built by | Boot behavior |
|--------|----------|---------------|
| **gpu-node** (Ubuntu Server autoinstall) | [`autoinstall/gpu-node.user-data.tmpl`](autoinstall) | Unattended install, hardened, latest NVIDIA/ROCm |
| **desktop** (Ubuntu Desktop autoinstall) | [`autoinstall/desktop.user-data.tmpl`](autoinstall) | Unattended install, hardened |
| **fiehnlab-live** (rescue + work) | [`live-rescue/build-live.sh`](live-rescue) | Live desktop that boots straight into an AI rescue assistant (local llama.cpp model + [pi-rescue](https://github.com/berlinguyinca/pi-rescue)), full RE/network/forensics toolset |
| **Rocky** (kvm-node / recovery / minimal) | kickstarts built in `fsc-forge-tokens` (ISOs ship pre-baked) | Kickstart installs |

## Components

- **[`stick/`](stick)** — `forge-stick.sh` + `stick.manifest`: install Ventoy,
  render autoinstall seeds, write `ventoy.json`, copy ISOs. Data-driven; adding a
  system is one manifest line. Includes the encrypted-secrets lifecycle scripts.
- **[`autoinstall/`](autoinstall)** — Ubuntu Subiquity/cloud-init templates
  (hardening, GPU drivers, error capture) + `harden-existing.sh` for live boxes.
- **[`live-rescue/`](live-rescue)** — the `fiehnlab-live` ISO remaster pipeline.

Rocky kickstarts live in `fsc-forge-tokens` (they carry a user password hash, so
they stay in the private cluster repo); the Rocky ISOs are added to the stick as
pre-built `file:` entries in the manifest.

## Quick start

```bash
cd stick
./forge-stick.sh install-ventoy /dev/sdX     # once, ERASES the device
# render values (never committed) go in ~/.config/fiehnlab/stick-secrets.env:
#   PRIMARY_USER=alice
#   USER_PW_HASH='...'          # SINGLE-QUOTED; generate with: openssl passwd -6
#   SSH_AUTHORIZED_KEY='ssh-ed25519 AAAA... you@host'   # or rely on ~/.ssh/id_ed25519.pub
#   LLM_GATEWAY_URL=https://llm.example.com/v1          # optional (online gateway)
./forge-stick.sh fetch                        # get the ISOs into staging
./forge-stick.sh all /dev/sdX                 # render seeds + write the stick
# then create + populate the encrypted secrets container — see stick/README.md
```

## Relationship to the rest of the fleet

The autoinstall/live-rescue/kickstart content is also used by the cluster
provisioning repo (`fsc-forge-tokens`); this repo is the standalone, portable
home for building the USB itself. The AI rescue brains ship from the separate
[`berlinguyinca/pi-rescue`](https://github.com/berlinguyinca/pi-rescue) extension,
cloned into the image at build time.

> Private by design: the templates reference internal hostnames, addressing, and
> BMC/network topology.
