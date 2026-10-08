#!/usr/bin/env python3
"""Generate harden-existing.sh from gpu-node.user-data.tmpl so the standalone
installer for already-running boxes stays identical to the image hardening.
Run:  python3 gen-harden-existing.py   (regenerates harden-existing.sh)"""
import yaml, os
HERE = os.path.dirname(__file__)
d = yaml.safe_load(open(os.path.join(HERE, 'gpu-node.user-data.tmpl')))['autoinstall']
wf = {w['path']: w['content'] for w in d['user-data']['write_files']}
HARDEN_PATHS = [
    '/etc/ssh/sshd_config.d/10-fiehnlab-hardening.conf',
    '/etc/sysctl.d/99-fiehnlab-hardening.conf',
    '/etc/apt/apt.conf.d/20auto-upgrades',
    '/etc/apt/apt.conf.d/52fiehnlab-unattended',
    '/etc/audit/rules.d/fiehnlab.rules',
    '/etc/fiehnlab/ufw-docker-after.rules',
    '/usr/local/sbin/fiehnlab-harden.sh',
]
o = ['#!/usr/bin/env bash',
 '# AUTO-GENERATED from gpu-node.user-data.tmpl by gen-harden-existing.py — do not edit by hand.',
 '# Applies the SAME pragmatic hardening to an ALREADY-INSTALLED box (no re-image).',
 '# Run as root:  sudo bash harden-existing.sh   [--drivers]',
 '# Restricts SSH to ADMIN_USER (defaults to the invoking sudo user); override with',
 '#   ADMIN_USER=alice sudo -E bash harden-existing.sh',
 '# --drivers also installs latest NVIDIA (CUDA repo cuda-drivers) / ROCm on a GPU box.',
 'set -euo pipefail',
 '[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }',
 'WANT_DRIVERS=0; [ "${1:-}" = "--drivers" ] && WANT_DRIVERS=1',
 'ADMIN_USER="${ADMIN_USER:-$(logname 2>/dev/null || echo "${SUDO_USER:-}")}"',
 'export DEBIAN_FRONTEND=noninteractive',
 'echo "== installing hardening packages =="',
 'apt-get update',
 'apt-get install -y ufw unattended-upgrades auditd apparmor-utils',
 'mkdir -p /etc/fiehnlab',
 '[ -f /etc/fiehnlab/role ] || echo desktop > /etc/fiehnlab/role']
for p in HARDEN_PATHS:
    o += [f'echo "== writing {p} =="',
          f'install -d -m0755 "$(dirname {p})"',
          f"cat > {p} <<'FIEHNLAB_EOF'",
          wf[p].rstrip('\n'),
          'FIEHNLAB_EOF']
# Resolve the SSH AllowUsers placeholder at RUNTIME (the configs above are
# written verbatim via single-quoted heredocs, so @@PRIMARY_USER@@ lands
# literally). Never leave a root-only AllowUsers — that would lock everyone out
# since PermitRootLogin is no.
o += ['SSHD_HARDEN=/etc/ssh/sshd_config.d/10-fiehnlab-hardening.conf',
 'if [ -n "$ADMIN_USER" ] && [ "$ADMIN_USER" != root ]; then',
 '  sed -i "s/@@PRIMARY_USER@@/$ADMIN_USER/g" "$SSHD_HARDEN"',
 '  echo "== SSH restricted to AllowUsers $ADMIN_USER =="',
 'else',
 '  sed -i "/^AllowUsers @@PRIMARY_USER@@/d" "$SSHD_HARDEN"',
 '  echo "WARN: no non-root admin user resolved; left SSH AllowUsers unrestricted. Re-run with ADMIN_USER=<you> to restrict." >&2',
 'fi']
o += ['chmod 0755 /usr/local/sbin/fiehnlab-harden.sh',
 'echo "== running fiehnlab-harden.sh =="',
 'bash /usr/local/sbin/fiehnlab-harden.sh',
 'if [ "$WANT_DRIVERS" = 1 ]; then',
 '  V=$(lspci -nn | grep -iE "VGA|3D|Display" || true)',
 '  if echo "$V" | grep -qi nvidia; then',
 '    D=$(. /etc/os-release; echo ${VERSION_ID//./})',
 '    curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${D}/x86_64/cuda-keyring_1.1-1_all.deb" -o /tmp/cuda-keyring.deb && dpkg -i /tmp/cuda-keyring.deb',
 '    apt-get update && apt-get install -y "linux-headers-$(uname -r)" cuda-drivers && echo "latest NVIDIA installed (reboot to load)"',
 '  elif echo "$V" | grep -qiE "\\[1002:"; then',
 '    REL=$(. /etc/os-release; echo $VERSION_CODENAME); AI=$(curl -fsSL "https://repo.radeon.com/amdgpu-install/latest/ubuntu/$REL/" | grep -oE "amdgpu-install_[^\\" ]+_all\\.deb" | head -1)',
 '    curl -fsSL -o /tmp/amdgpu-install.deb "https://repo.radeon.com/amdgpu-install/latest/ubuntu/$REL/$AI" && apt-get install -y /tmp/amdgpu-install.deb && amdgpu-install -y --usecase=rocm --no-dkms && echo "latest ROCm installed"',
 '  else echo "no discrete GPU; skipping drivers"; fi',
 'fi',
 'echo "== DONE. Review /var/log/fiehnlab-provision.log =="']
open(os.path.join(HERE,'harden-existing.sh'),'w').write('\n'.join(o)+'\n')
print("regenerated harden-existing.sh")
