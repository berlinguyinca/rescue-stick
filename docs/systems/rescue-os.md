# rescue-os

A **live** Ubuntu Desktop image — boots from USB straight to RAM, amnesic
(nothing persists across reboots unless you explicitly unlock the secrets
container). It doubles as a portable workstation and as a rescue/diagnostic
toolkit for whatever PC you plug it into. For anyone who needs a trusted,
fully-equipped environment on hardware they don't otherwise control.

## How it boots

The live session logs in automatically and opens the **Rescue Assistant** in a
terminal (the stock Ubuntu first-boot wizard is suppressed so it never covers
the greeting). You just type what's wrong — "the wifi is slow", "this PC
won't start", "is my network safe?" — and it uses your LLM gateway if a real
key is reachable, otherwise the baked local model.

## What you get

### Coding & runtimes

| Tool | What it's for |
|---|---|
| Base CLI | `build-essential`, `git`, `jq`/`yq`, `ripgrep`, `fd`, `fzf`, `bat`, `vim`, `btop`, `tmux`, `tree`, `mc` (Midnight Commander), and the usual archive/disk utilities |
| **Go**, **Rust**, **Python 3** (venv/pip), **Node.js 22** | Language runtimes (Node is pinned to NodeSource 22.x — the stock apt package is too old for the coding agents below) |
| **Docker + Compose**, **Apptainer** | Containers |
| **[gh](https://cli.github.com)**, **AWS CLI v2**, **mcli** (MinIO client) | Cloud/git CLIs |
| **PostgreSQL / MariaDB / Redis / SQLite clients** | Quick DB access from a rescue session |

### AI / agents

| Tool | What it's for |
|---|---|
| **[Claude Code](https://claude.com/claude-code)**, **[Codex](https://github.com/openai/codex)**, **pi**, **herdr** | General-purpose coding agents, all on `PATH` |
| **pi-rescue** + **pi-engineering** | Two `pi` extensions baked in as the rescue brains — see [berlinguyinca/pi-rescue](https://github.com/berlinguyinca/pi-rescue) below |
| **RAG index** | A knowledge-base vector index is pre-built at image bake time (via the embeddings model) so `/assist`/`/diagnose` are fast from first boot |

### Networking & diagnostics

| Tool | What it's for |
|---|---|
| Base net kit | `nmap`, `tcpdump`, `mtr`, `iperf3`, `ethtool`, `dnsutils`, `arp-scan`, `iftop`, `nethogs`, `snmp`, `wavemon` |
| **inxi, lynis, lm-sensors, dmidecode, nvme-cli, stress-ng, fio, memtester, nvtop, radeontop, glances** | Hardware/system diagnostics and stress-testing |
| **masscan, lldpd, netdiscover** | Network discovery (installed but left **disabled** — opt-in via `systemctl start`, never auto-sniffing) |
| **ansible** | Config management, for fixing things at scale |

### Forensics & reverse-engineering

*Authorized-use tooling — for diagnosing and inspecting devices and traffic you have permission to examine, not for unattended attack.*

| Tool | What it's for |
|---|---|
| **sleuthkit, [volatility3](https://volatilityfoundation.org/) (`vol`), binwalk** | Disk and memory forensics |
| **testdisk, gddrescue, gparted, partclone, chntpw** | Disk recovery, imaging, partition repair, Windows password reset |
| **rkhunter, chkrootkit, clamav** | Rootkit/malware scanning |
| **[mitmproxy](https://mitmproxy.org), bettercap, sslsplit, ssh-mitm, [testssl.sh](https://testssl.sh)** | TLS/traffic interception and inspection |
| **[Wireshark](https://www.wireshark.org)/tshark** (setuid off), **ntopng** | Packet capture and traffic analysis (ntopng ships disabled) |
| **[frida-tools](https://frida.re), [jadx](https://github.com/skylot/jadx), apktool, [Ghidra](https://ghidra-sre.org)** | Dynamic instrumentation, Android/Java decompiling, binary reverse-engineering |
| **age, sops** | Secret encryption/decryption |

### Browsers & clients

| Tool | What it's for |
|---|---|
| **Firefox** (seeded on the base ISO), **[Google Chrome](https://www.google.com/chrome/)** | Browsers |
| **PostgreSQL / MariaDB / Redis / SQLite clients** | See Coding & runtimes above |

### Local LLM stack

| Component | What it's for |
|---|---|
| **[llama.cpp](https://github.com/ggml-org/llama.cpp)** (CUDA + Vulkan builds) | Runs the local models; auto-picks CUDA → real Vulkan GPU → CPU at every boot, whatever hardware it lands on |
| **Qwen3-8B** (`qwen3-local`, :8080) | Default always-on chat model, 16k context |
| **gemma-3-1b** | Low-RAM fallback — one edit to `/etc/default/llama-chat` to switch |
| **nomic-embed-text** (:18081) | Always-on embeddings model, backs the RAG index |
| **[llama-swap](https://github.com/mostlygeek/llama-swap)** (:9090) | On-demand tier for any extra model you pull mid-session |
| **`fiehnlab-models`**, **`fiehnlab-pull-model`**, **`hf`** | Pick a curated model, search Hugging Face, or pull any GGUF by repo — registers it into llama-swap automatically |

No GPU driver is ever baked into the image — `fiehnlab-gpu` installs the
right one (NVIDIA or AMD) for *this* boot's hardware, on demand, since the
live kernel can't persist a driver build across reboots anyway.

## pi-rescue skills

The Rescue Assistant's actual skills live in the separate
[**berlinguyinca/pi-rescue**](https://github.com/berlinguyinca/pi-rescue)
repo, baked into the image as a `pi` extension. At a high level:

| Area | Skills |
|---|---|
| **Triage** | assist, diagnose, incident-triage |
| **Network** | network-triage, network-audit, mikrotik |
| **System repair** | harden, disk-rescue, boot-repair |
| **Remote / RE** | ssh-tunnel, remote, keys, intercept, reverse |

## Security / hardening

- **Secrets stay off the squashfs.** Running **Unlock** (`fiehnlab-unlock`,
  desktop icon or command) scans for an encrypted LUKS container on the
  stick, prompts for one passphrase, and loads whatever's inside — LLM
  gateway key, GitHub/AWS credentials, SSH keys, lab credentials — into the
  live session's RAM only. Nothing is ever written back to the image; it's
  gone at power-off.
- **Read-only by default.** GNOME automount is disabled and `mdadm` won't
  auto-assemble arrays it finds — `mount-rw <device>` is the explicit opt-in
  for anything that needs to be writable.
- **No driver, no daemon, by default.** No GPU driver is baked in (see
  above); network-discovery/sniffing daemons (`lldpd`, `ntopng`) are
  installed but disabled until you start them; Wireshark's setuid helper is
  off.
- **The RE/MITM toolset is for authorized use only** — diagnosing and
  inspecting systems and traffic you have permission to examine.

## Build flags

The default build bakes everything above. `--skip-rescue-tools` and
`--skip-re-tools` skip the forensics/RE apt lists for faster iteration;
`--no-ghidra` skips the ~1GB Ghidra download. A few tools (`boot-repair`,
`clonezilla`, `ntopng`) are best-effort and silently skipped if unavailable
for the current Ubuntu release. See
[`live-rescue/README.md`](../../live-rescue/README.md) for the full build
writeup.
