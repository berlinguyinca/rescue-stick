#!/usr/bin/env bash
# Interactively add Tailscale / BMC+recovery / MikroTik / pgpass secrets into the
# ENCRYPTED fiehnlab-secrets.luks container. Every value is read from your
# terminal (passwords never echoed), written straight into the LUKS container,
# and never printed or sent anywhere. Each prompt is skippable (press Enter).
# Run as root in a real terminal:  sudo bash add-secrets-extra.sh
set -euo pipefail

LUKS="${1:-$(ls /media/*/*/fiehnlab-secrets.luks 2>/dev/null | head -1)}"
MAP="fiehnlab-secrets-add2"
MNT="$(mktemp -d /run/fiehnlab-add2.XXXXXX)"
SRC_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
SRC_HOME="$(getent passwd "$SRC_USER" | cut -d: -f6)"

say(){ printf '[add-secrets] %s\n' "$*"; }
cleanup(){ mountpoint -q "$MNT" && umount "$MNT" 2>/dev/null || true
           [ -e "/dev/mapper/$MAP" ] && cryptsetup luksClose "$MAP" 2>/dev/null || true
           rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT
ask(){   printf '%s' "$1" > /dev/tty; IFS= read -r REPLY < /dev/tty; printf '%s' "$REPLY"; }
asks(){  printf '%s' "$1" > /dev/tty; IFS= read -rs REPLY < /dev/tty; printf '\n' > /dev/tty; printf '%s' "$REPLY"; }

[ "$(id -u)" -eq 0 ] || { say "ERROR: run as root (sudo)"; exit 1; }
[ -f "$LUKS" ]       || { say "ERROR: no container at $LUKS"; exit 1; }

say "opening $LUKS ..."
printf 'LUKS passphrase for fiehnlab-secrets: ' > /dev/tty
IFS= read -rs PASS < /dev/tty; printf '\n' > /dev/tty
printf '%s' "$PASS" | cryptsetup luksOpen --key-file=- "$LUKS" "$MAP"; unset PASS
mount "/dev/mapper/$MAP" "$MNT"

ENV="$MNT/fiehnlab-creds/env"
install -d -m700 "$MNT/fiehnlab-creds"
touch "$ENV"; chmod 600 "$ENV"
printf '\n# --- added %s ---\n' "$(date -Is)" >> "$ENV"

# 1) Tailscale auth key ------------------------------------------------------
TS="$(asks 'Tailscale auth key (tskey-...), or Enter to skip: ')"
if [ -n "$TS" ]; then
  install -d -m700 "$MNT/tailscale"; umask 177
  printf '%s\n' "$TS" > "$MNT/tailscale/authkey"; chmod 600 "$MNT/tailscale/authkey"
  say "stored tailscale/authkey"
fi; unset TS

# 2) BMC / iLO + cluster recovery -------------------------------------------
BU="$(ask 'BMC/iLO username (Enter to skip BMC): ')"
if [ -n "$BU" ]; then
  BP="$(asks 'BMC/iLO password: ')"
  BH="$(ask  'BMC host or base (e.g. 10.x.x. or a specific IP; Enter to skip): ')"
  { echo "export BMC_USER=$(printf '%q' "$BU")"
    echo "export BMC_PASS=$(printf '%q' "$BP")"
    [ -n "$BH" ] && echo "export BMC_HOST=$(printf '%q' "$BH")"; } >> "$ENV"
  say "stored BMC creds into fiehnlab-creds/env"; unset BP
fi; unset BU
CK="$(ask 'Path to a cluster-recovery SSH key to include (router-jump / vault key), or Enter to skip: ')"
if [ -n "$CK" ] && [ -f "$CK" ]; then
  install -m600 "$CK" "$MNT/fiehnlab-creds/cluster-recovery-key"
  [ -f "$CK.pub" ] && install -m644 "$CK.pub" "$MNT/fiehnlab-creds/cluster-recovery-key.pub"
  say "stored cluster-recovery-key"
elif [ -n "$CK" ]; then say "WARN: $CK not found, skipped"; fi

# 3) MikroTik / RouterOS -----------------------------------------------------
MH="$(ask 'MikroTik host/IP (Enter to skip MikroTik): ')"
if [ -n "$MH" ]; then
  MU="$(ask  'MikroTik username: ')"
  MP="$(asks 'MikroTik password: ')"
  { echo "export MIKROTIK_HOST=$(printf '%q' "$MH")"
    echo "export MIKROTIK_USER=$(printf '%q' "$MU")"
    echo "export MIKROTIK_PASS=$(printf '%q' "$MP")"; } >> "$ENV"
  say "stored MikroTik creds into fiehnlab-creds/env"; unset MP
fi

# 4) Postgres .pgpass --------------------------------------------------------
PG="$(ask "Path to a .pgpass to copy [default $SRC_HOME/.pgpass if it exists; Enter to skip]: ")"
[ -z "$PG" ] && [ -f "$SRC_HOME/.pgpass" ] && PG="$SRC_HOME/.pgpass"
if [ -n "$PG" ] && [ -f "$PG" ]; then
  install -m600 "$PG" "$MNT/pgpass"; say "stored pgpass (from $PG)"
elif [ -n "$PG" ]; then say "WARN: $PG not found, skipped"; fi

# tidy: drop the env file if nothing was written to it this run beyond the header
sync
say "container now holds:"; find "$MNT/tailscale" "$MNT/fiehnlab-creds" "$MNT/pgpass" -maxdepth 2 2>/dev/null | sed "s#$MNT/##"
say "done. Secrets are ONLY in the LUKS container; nothing printed or put in the image."
