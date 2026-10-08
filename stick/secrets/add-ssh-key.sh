#!/usr/bin/env bash
# Add your SSH identity to the ENCRYPTED fiehnlab-secrets.luks container on the
# Ventoy stick. The key goes straight from your ~/.ssh into the LUKS container;
# it is never copied anywhere else, never printed, never put in the image/git.
# Run as root (it needs cryptsetup) via:  ! sudo bash <this script>
# You will be prompted for the LUKS passphrase (the same one you set when the
# container was created). fiehnlab-unlock on the live image reads ssh/ back out.
set -euo pipefail

LUKS="${1:-$(ls /media/*/*/fiehnlab-secrets.luks 2>/dev/null | head -1)}"
MAP="fiehnlab-secrets-add"
MNT="$(mktemp -d /run/fiehnlab-add.XXXXXX)"
SRC_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
SRC_HOME="$(getent passwd "$SRC_USER" | cut -d: -f6)"
SRC_SSH="$SRC_HOME/.ssh"

say(){ printf '[add-ssh-key] %s\n' "$*"; }
cleanup(){ mountpoint -q "$MNT" && umount "$MNT" 2>/dev/null || true
           [ -e "/dev/mapper/$MAP" ] && cryptsetup luksClose "$MAP" 2>/dev/null || true
           rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || { say "ERROR: run as root (sudo)"; exit 1; }
[ -f "$LUKS" ]            || { say "ERROR: no container at $LUKS"; exit 1; }
[ -f "$SRC_SSH/id_ed25519" ] || { say "ERROR: $SRC_SSH/id_ed25519 not found"; exit 1; }

say "opening $LUKS ..."
if [ -r /dev/tty ]; then
  # Read the passphrase from the controlling terminal and feed it to cryptsetup
  # on stdin (--key-file=-). Works whether or not cryptsetup can grab a TTY.
  printf 'LUKS passphrase for fiehnlab-secrets: ' > /dev/tty
  IFS= read -rs PASS < /dev/tty
  printf '\n' > /dev/tty
  printf '%s' "$PASS" | cryptsetup luksOpen --key-file=- "$LUKS" "$MAP"
  unset PASS
else
  # No controlling terminal (e.g. launched from a non-interactive wrapper):
  cryptsetup luksOpen "$LUKS" "$MAP"
fi
mount "/dev/mapper/$MAP" "$MNT"

install -d -m700 "$MNT/ssh"
install -m600 "$SRC_SSH/id_ed25519"      "$MNT/ssh/id_ed25519"
[ -f "$SRC_SSH/id_ed25519.pub" ] && install -m644 "$SRC_SSH/id_ed25519.pub" "$MNT/ssh/id_ed25519.pub"
# Optional extras if present (safe to include; comment out if you'd rather not):
[ -f "$SRC_SSH/known_hosts" ] && install -m600 "$SRC_SSH/known_hosts" "$MNT/ssh/known_hosts"
[ -f "$SRC_SSH/config" ]      && install -m600 "$SRC_SSH/config"      "$MNT/ssh/config"

sync
say "stored into the encrypted container:"
ls -l "$MNT/ssh"
say "done. The key is now ONLY in the LUKS container (and your ~/.ssh); not in the image."
