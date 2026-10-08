# rescue-stick

Build **one USB stick that can install, rescue, or work on almost any PC**. It's a
[Ventoy](https://www.ventoy.net) multiboot stick holding several bootable systems
plus an AI-assisted live rescue environment.

Plug it in, pick an entry from the boot menu:

| Entry | What it does |
|-------|--------------|
| [**gpu-node**](docs/systems/gpu-node.md) | Unattended Ubuntu Server install — hardened, latest NVIDIA/ROCm drivers |
| [**desktop**](docs/systems/desktop.md) | Unattended Ubuntu Desktop install — hardened |
| [**rescue-os**](docs/systems/rescue-os.md) | Live desktop that boots straight into an AI rescue assistant (offline local model + optional online gateway), with networking, forensics and reverse-engineering tools ready to go |
| **Rocky** | Rocky Linux installers |

The rescue assistant is powered by [berlinguyinca/pi-rescue](https://github.com/berlinguyinca/pi-rescue).

## Build (or rebuild) the stick

```bash
cd stick
./forge-stick.sh install-ventoy /dev/sdX   # first time only — ERASES the device
./forge-stick.sh all /dev/sdX              # copy the ISOs + write the config
```

That's the short version. The full walkthrough — ISOs, the autoinstall login,
and the encrypted secrets container — is in **[stick/README.md](stick/README.md)**.

## Add another system later

Add one line to [`stick/stick.manifest`](stick/stick.manifest), then
`./forge-stick.sh sync <stick>`. Done.

## No secrets in this repo

Only tooling and templates live here — no ISOs, keys, or passwords. Per-machine
values (login user, password hash, SSH key, gateway URL) are filled in **at build
time** from an uncommitted file on your own machine, and runtime secrets live in
an **encrypted LUKS container** on the stick that unlocks into RAM at boot.
Details: [stick/README.md#secrets](stick/README.md#secrets).
