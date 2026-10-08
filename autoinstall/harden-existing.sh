#!/usr/bin/env bash
# AUTO-GENERATED from gpu-node.user-data.tmpl by gen-harden-existing.py — do not edit by hand.
# Applies the SAME pragmatic hardening to an ALREADY-INSTALLED box (no re-image).
# Run as root:  sudo bash harden-existing.sh   [--drivers]
# Restricts SSH to ADMIN_USER (defaults to the invoking sudo user); override with
#   ADMIN_USER=alice sudo -E bash harden-existing.sh
# --drivers also installs latest NVIDIA (CUDA repo cuda-drivers) / ROCm on a GPU box.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
WANT_DRIVERS=0; [ "${1:-}" = "--drivers" ] && WANT_DRIVERS=1
ADMIN_USER="${ADMIN_USER:-$(logname 2>/dev/null || echo "${SUDO_USER:-}")}"
export DEBIAN_FRONTEND=noninteractive
echo "== installing hardening packages =="
apt-get update
apt-get install -y ufw unattended-upgrades auditd apparmor-utils
mkdir -p /etc/fiehnlab
[ -f /etc/fiehnlab/role ] || echo desktop > /etc/fiehnlab/role
echo "== writing /etc/ssh/sshd_config.d/10-fiehnlab-hardening.conf =="
install -d -m0755 "$(dirname /etc/ssh/sshd_config.d/10-fiehnlab-hardening.conf)"
cat > /etc/ssh/sshd_config.d/10-fiehnlab-hardening.conf <<'FIEHNLAB_EOF'
# Key-only SSH. Named 10- so it is read before 50-cloud-init.conf (sshd
# takes the first value seen). Password auth is also disabled at install
# via autoinstall ssh.allow-pw:false. MaxAuthTries kept at the default 6
# so an agent offering several keys before the right one is not locked out.
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
PermitEmptyPasswords no
AllowUsers @@PRIMARY_USER@@
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
FIEHNLAB_EOF
echo "== writing /etc/sysctl.d/99-fiehnlab-hardening.conf =="
install -d -m0755 "$(dirname /etc/sysctl.d/99-fiehnlab-hardening.conf)"
cat > /etc/sysctl.d/99-fiehnlab-hardening.conf <<'FIEHNLAB_EOF'
# Network + kernel hardening. rp_filter=2 (loose), NOT 1 (strict): strict
# breaks docker's many interfaces / multi-homed hosts. Deliberately NOT set
# (docker/apptainer need them): ip_forward, unprivileged_userns_clone,
# bridge-nf-*, unprivileged_bpf_disabled.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.perf_event_paranoid = 3
net.core.bpf_jit_harden = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
FIEHNLAB_EOF
echo "== writing /etc/apt/apt.conf.d/20auto-upgrades =="
install -d -m0755 "$(dirname /etc/apt/apt.conf.d/20auto-upgrades)"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'FIEHNLAB_EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
FIEHNLAB_EOF
echo "== writing /etc/apt/apt.conf.d/52fiehnlab-unattended =="
install -d -m0755 "$(dirname /etc/apt/apt.conf.d/52fiehnlab-unattended)"
cat > /etc/apt/apt.conf.d/52fiehnlab-unattended <<'FIEHNLAB_EOF'
// Security-only auto-updates, NO auto-reboot. GPU driver + container
// packages are blacklisted so an unattended upgrade cannot cause a
// driver/library version mismatch or restart dockerd (killing running
// jobs) on a box that never auto-reboots.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
    "nvidia-driver-";
    "nvidia-dkms-";
    "nvidia-kernel-";
    "libnvidia-";
    "nvidia-container";
    "docker.io";
    "docker-ce";
    "containerd";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
FIEHNLAB_EOF
echo "== writing /etc/audit/rules.d/fiehnlab.rules =="
install -d -m0755 "$(dirname /etc/audit/rules.d/fiehnlab.rules)"
cat > /etc/audit/rules.d/fiehnlab.rules <<'FIEHNLAB_EOF'
# Lightweight forensic baseline: identity files, sudo scope, sshd config,
# and privileged (uid!=euid -> euid 0) execs.
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k privileged
FIEHNLAB_EOF
echo "== writing /etc/fiehnlab/ufw-docker-after.rules =="
install -d -m0755 "$(dirname /etc/fiehnlab/ufw-docker-after.rules)"
cat > /etc/fiehnlab/ufw-docker-after.rules <<'FIEHNLAB_EOF'
# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward
-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16
-A DOCKER-USER -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 172.16.0.0/12
-A DOCKER-USER -j RETURN
-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP
COMMIT
# END UFW AND DOCKER
FIEHNLAB_EOF
echo "== writing /usr/local/sbin/fiehnlab-harden.sh =="
install -d -m0755 "$(dirname /usr/local/sbin/fiehnlab-harden.sh)"
cat > /usr/local/sbin/fiehnlab-harden.sh <<'FIEHNLAB_EOF'
#!/usr/bin/env bash
# First-boot hardening finalizer (idempotent). Applies the config files
# written alongside it, plus the imperative bits that need the real kernel
# (ufw) or runtime state (root lock, service disables). role-aware via
# /etc/fiehnlab/role. Logs OK/FAILED to the provision log.
set +e
L=/var/log/fiehnlab-provision.log
ROLE=$(cat /etc/fiehnlab/role 2>/dev/null)
echo "=== fiehnlab-harden $(date -Is) role=$ROLE ===" >> "$L"
sysctl --system >>"$L" 2>&1 && echo "OK: sysctl" >>"$L" || echo "FAILED: sysctl" >>"$L"
systemctl reload ssh >>"$L" 2>&1 || systemctl reload sshd >>"$L" 2>&1; echo "OK: sshd reloaded" >>"$L"
passwd -l root >>"$L" 2>&1 && echo "OK: root locked" >>"$L" || echo "FAILED: root lock" >>"$L"
if command -v ufw >/dev/null; then
  ufw --force reset >>"$L" 2>&1
  ufw default deny incoming >>"$L" 2>&1
  ufw default allow outgoing >>"$L" 2>&1
  ufw allow 22/tcp >>"$L" 2>&1
  for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
    ufw allow from "$net" to any port 9100 proto tcp >>"$L" 2>&1
    ufw allow from "$net" to any port 9835 proto tcp >>"$L" 2>&1
  done
  if ! grep -q 'BEGIN UFW AND DOCKER' /etc/ufw/after.rules 2>/dev/null; then
    printf '\n' >> /etc/ufw/after.rules
    cat /etc/fiehnlab/ufw-docker-after.rules >> /etc/ufw/after.rules
  fi
  ufw --force enable >>"$L" 2>&1 && echo "OK: ufw enabled" >>"$L" || echo "FAILED: ufw" >>"$L"
fi
systemctl enable --now auditd >>"$L" 2>&1 && augenrules --load >>"$L" 2>&1 && echo "OK: auditd" >>"$L" || echo "WARN: auditd" >>"$L"
systemctl enable --now apparmor >>"$L" 2>&1 && echo "OK: apparmor" >>"$L" || echo "WARN: apparmor" >>"$L"
systemctl enable --now unattended-upgrades >>"$L" 2>&1
systemctl enable apt-daily.timer apt-daily-upgrade.timer >>"$L" 2>&1 && echo "OK: unattended-upgrades" >>"$L" || echo "WARN: uu-timers" >>"$L"
if [ "$ROLE" = "gpu-node" ]; then
  SVCS="avahi-daemon cups cups-browsed bluetooth ModemManager whoopsie"
else
  SVCS="whoopsie apport"
fi
for s in $SVCS; do systemctl disable --now "$s" >>"$L" 2>&1; done
apt-get -y purge whoopsie >>"$L" 2>&1
echo "OK: hardening complete (role=$ROLE)" >>"$L"
FIEHNLAB_EOF
SSHD_HARDEN=/etc/ssh/sshd_config.d/10-fiehnlab-hardening.conf
if [ -n "$ADMIN_USER" ] && [ "$ADMIN_USER" != root ]; then
  sed -i "s/@@PRIMARY_USER@@/$ADMIN_USER/g" "$SSHD_HARDEN"
  echo "== SSH restricted to AllowUsers $ADMIN_USER =="
else
  sed -i "/^AllowUsers @@PRIMARY_USER@@/d" "$SSHD_HARDEN"
  echo "WARN: no non-root admin user resolved; left SSH AllowUsers unrestricted. Re-run with ADMIN_USER=<you> to restrict." >&2
fi
chmod 0755 /usr/local/sbin/fiehnlab-harden.sh
echo "== running fiehnlab-harden.sh =="
bash /usr/local/sbin/fiehnlab-harden.sh
if [ "$WANT_DRIVERS" = 1 ]; then
  V=$(lspci -nn | grep -iE "VGA|3D|Display" || true)
  if echo "$V" | grep -qi nvidia; then
    D=$(. /etc/os-release; echo ${VERSION_ID//./})
    curl -fsSL "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${D}/x86_64/cuda-keyring_1.1-1_all.deb" -o /tmp/cuda-keyring.deb && dpkg -i /tmp/cuda-keyring.deb
    apt-get update && apt-get install -y "linux-headers-$(uname -r)" cuda-drivers && echo "latest NVIDIA installed (reboot to load)"
  elif echo "$V" | grep -qiE "\[1002:"; then
    REL=$(. /etc/os-release; echo $VERSION_CODENAME); AI=$(curl -fsSL "https://repo.radeon.com/amdgpu-install/latest/ubuntu/$REL/" | grep -oE "amdgpu-install_[^\" ]+_all\.deb" | head -1)
    curl -fsSL -o /tmp/amdgpu-install.deb "https://repo.radeon.com/amdgpu-install/latest/ubuntu/$REL/$AI" && apt-get install -y /tmp/amdgpu-install.deb && amdgpu-install -y --usecase=rocm --no-dkms && echo "latest ROCm installed"
  else echo "no discrete GPU; skipping drivers"; fi
fi
echo "== DONE. Review /var/log/fiehnlab-provision.log =="
