# gpu-node

A **headless Ubuntu Server** install for a compute box. Unattended, hardened by
default, and picks up the latest NVIDIA or AMD driver automatically. For anyone
who wants to plug a stick into a bare machine and get back a GPU box ready for
containers — no desktop, no manual tuning.

## What you get

| Component | What it's for |
|---|---|
| **Base system** | Ubuntu Server (minimal), DHCP networking, a random unused hostname picked at install time |
| **Admin account** | The user you set at build time, full sudo (password-gated), key-only SSH |
| **vim, htop, curl, pciutils** | A minimal CLI kit — this image has no dev toolchain, it's a compute appliance |

### GPU & containers

| Component | What it's for |
|---|---|
| **NVIDIA driver (`cuda-drivers`)** | Installed on first real boot from NVIDIA's CUDA repo against the running kernel — always the latest, not the installer's bundled driver |
| **AMD ROCm (`amdgpu-install`)** | Same idea for AMD cards, via Radeon's install script |
| **Docker + Compose, nvidia-container-toolkit** | `docker run --gpus all` works out of the box once the driver lands; NVIDIA CDI is generated automatically |
| **Apptainer** | `apptainer run --nv` / `--rocm` against the host driver |
| **[prometheus-node-exporter](https://github.com/prometheus/node_exporter)** (:9100) + **nvidia_gpu_exporter** (:9835) | Feeds the lab's Prometheus/Grafana |

Driver installation and the container GPU wiring both finish on the *first real
boot* (not during install) — the installer environment has no GPU to test
against.

## Security / hardening

- **SSH**: key-only (`PasswordAuthentication no`), root login disabled, idle
  timeout.
- **ufw**: default-deny inbound. Only SSH (22) is open from anywhere; the
  metrics ports (9100/9835) are restricted to private + Tailscale ranges. A
  docker-bypasses-ufw hole is closed so published container ports still only
  reach private sources.
- **Unattended security updates**, no auto-reboot — GPU driver and
  container packages are excluded so an update can't desync the driver or
  bounce a running job.
- **auditd** (identity/sudo/sshd/privileged-exec watches) + **AppArmor**
  enforced.
- **Root account locked** (`passwd -l root`) — the admin user is the only way
  in.
- Secure Boot stays off (required for the NVIDIA driver's DKMS module); no
  fail2ban (key-only SSH already defeats brute force).

See [`autoinstall/README.md`](../../autoinstall/README.md) for the full
hardening writeup and build steps.
