#!/usr/bin/env bash
# Create a fresh, EMPTY encrypted secrets container (fiehnlab-secrets.luks) and
# seed the directory layout that fiehnlab-unlock expects. Optionally fills in the
# "core" secrets (gateway key, gh token, AWS) inline; SSH keys and
# tailscale/BMC/MikroTik/pgpass are added afterwards with the sibling helpers.
#
# Run as root in a REAL terminal (cryptsetup prompts for the NEW passphrase):
#   sudo bash create-secrets.sh [/path/to/fiehnlab-secrets.luks]
# Default target is the Ventoy stick. Refuses to overwrite an existing container.
set -euo pipefail

OUT="${1:-$(ls /media/*/*/fiehnlab-secrets.luks 2>/dev/null | head -1)}"
SIZE_MB="${SIZE_MB:-64}"
MAP="fiehnlab-secrets-new"
MNT="$(mktemp -d /run/fiehnlab-new.XXXXXX)"
SRC_USER="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"
SRC_HOME="$(getent passwd "$SRC_USER" | cut -d: -f6)"

say(){ printf '[create-secrets] %s\n' "$*"; }
die(){ printf '[create-secrets] ERROR: %s\n' "$*" >&2; exit 1; }
cleanup(){ mountpoint -q "$MNT" && umount "$MNT" 2>/dev/null || true
           [ -e "/dev/mapper/$MAP" ] && cryptsetup luksClose "$MAP" 2>/dev/null || true
           rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT
ask(){  printf '%s' "$1" > /dev/tty; IFS= read -r REPLY < /dev/tty; printf '%s' "$REPLY"; }
asks(){ printf '%s' "$1" > /dev/tty; IFS= read -rs REPLY < /dev/tty; printf '\n' > /dev/tty; printf '%s' "$REPLY"; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
[ ! -e "$OUT" ]      || die "refusing to overwrite existing $OUT (delete it yourself if you mean to)"
command -v cryptsetup >/dev/null || die "cryptsetup not installed"

say "allocating ${SIZE_MB}MiB container at $OUT"
truncate -s "${SIZE_MB}M" "$OUT"
say "formatting LUKS2 (AES-XTS-512, Argon2id) — choose a STRONG passphrase:"
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --pbkdf argon2id "$OUT"
say "opening + making ext4 filesystem inside"
cryptsetup luksOpen "$OUT" "$MAP"
mkfs.ext4 -q -L fiehnsecrets "/dev/mapper/$MAP"
mount "/dev/mapper/$MAP" "$MNT"

# Layout fiehnlab-unlock reads.
install -d -m700 "$MNT/ssh" "$MNT/aws" "$MNT/fiehnlab-creds" "$MNT/tailscale"
umask 177

# --- optional core secrets -------------------------------------------------
K="$(asks 'Metabolomics gateway API key (sk-...), or Enter to skip: ')"
[ -n "$K" ] && { printf '%s' "$K" > "$MNT/llm-api-key"; chmod 600 "$MNT/llm-api-key"; say "stored llm-api-key"; }
G="$(asks 'GitHub token (ghp_/github_pat_...), or Enter to skip: ')"
[ -n "$G" ] && { printf '%s' "$G" > "$MNT/gh-token"; chmod 600 "$MNT/gh-token"; say "stored gh-token"; }
{ echo "export METABOLOMICS_API_KEY=$(printf '%q' "${K:-}")"
  echo "export GH_TOKEN=$(printf '%q' "${G:-}")"; } > "$MNT/secrets.env"
chmod 600 "$MNT/secrets.env"; unset K G

A="$(ask "Copy your AWS profiles from $SRC_HOME/.aws? [y/N]: ")"
if [ "$A" = y ] || [ "$A" = Y ]; then
  if [ -d "$SRC_HOME/.aws" ]; then cp -a "$SRC_HOME/.aws/." "$MNT/aws/"; chmod -R go-rwx "$MNT/aws"; say "copied ~/.aws";
  else say "WARN: $SRC_HOME/.aws not found, skipped"; fi
fi

sync
say "created $OUT with layout:"; find "$MNT" -maxdepth 2 | sed "s#$MNT#.#"
say "next: add-ssh-key.sh  and  add-secrets-extra.sh  to populate SSH + tailscale/BMC/MikroTik/pgpass."
