# desktop

A full **Ubuntu GNOME desktop** install — hardened, with a dev toolchain and
coding agents baked in. For a daily-driver workstation that's ready to code on
as soon as you log in, and joins the GPU cluster automatically if the hardware
is there.

## What you get

| Component | What it's for |
|---|---|
| **Base system** | Full GNOME desktop (GDM login), DHCP networking, a random unused hostname picked at install time |
| **Admin account** | The user you set at build time, full sudo (password-gated), key-only SSH |
| **Base CLI** | `vim`, `btop`, `tmux`, `git`, `build-essential`, `curl`, plus the usual archive/network utilities |
| **[Google Chrome](https://www.google.com/chrome/)**, Firefox | Browsers (Firefox ships with the desktop ISO, Chrome is installed) |
| **[Tailscale](https://tailscale.com)** | Join the lab tailnet (`tailscale up` after first login) |

### Dev toolchain & coding agents

| Component | What it's for |
|---|---|
| **Go** (official tarball), **Rust** (rustup), **Node/npm**, **sdkman**, **uv** | Language toolchains, installed system-wide or per-user on first login |
| **AWS CLI v2**, **Docker + Compose**, **Apptainer** | Cloud and container tooling |
| **[Claude Code](https://claude.com/claude-code)**, **[Codex](https://github.com/openai/codex)**, **pi** (`@earendil-works/pi-coding-agent`), **herdr** | Coding agents, installed per-user on first login |

`pi` is pre-wired to your LLM gateway as its default model. Two things are
left for you to do by hand after first login (noted in
`/var/log/fiehnlab-provision.log`): set the real API key in
`~/.pi/agent/models.json`, and clone the private `pi-engineering` extension
once your git auth is available.

### GPU & containers

Same driver/container story as [gpu-node](gpu-node.md) — NVIDIA or AMD driver
installed on first real boot, Docker/Apptainer wired for GPU access, metrics
exporters running. This box joins the GPU cluster only if it actually has the
hardware; either way it's not a Slurm node.

## Security / hardening

Same baseline as [gpu-node](gpu-node.md) — key-only SSH, default-deny ufw,
unattended security updates (driver/container packages excluded), auditd,
AppArmor, locked root — except the first-boot service disable list only turns
off `whoopsie`/`apport` (gpu-node also disables desktop-irrelevant daemons
like avahi/cups/bluetooth, since it's headless).

See [`autoinstall/README.md`](../../autoinstall/README.md) for the full
hardening writeup and build steps.
