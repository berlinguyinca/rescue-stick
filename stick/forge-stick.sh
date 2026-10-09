#!/usr/bin/env bash
# forge-stick.sh — (re)build the fiehnlab provisioning USB from stick.manifest.
#
# A Ventoy multiboot stick: install Ventoy once, then ISOs are just files on the
# exFAT data partition and Ventoy's auto_install plugin maps each to its
# autoinstall seed. This script makes that reproducible and extensible.
#
# Subcommands:
#   install-ventoy <device>   Install/refresh Ventoy on <device> (DESTRUCTIVE: wipes it).
#   fetch                     Download/collect the manifest's ISOs into the staging dir.
#   render                    Render autoinstall .tmpl seeds (injects the password hash).
#   sync <device|mountpoint>  Copy ISOs + seeds + write ventoy.json onto the stick.
#   all  <device|mountpoint>  render + sync (ISOs must already be staged/fetched).
#
# Nothing secret is ever written to the repo. The only injected secret is the
# render values (user, password hash, SSH key, gateway); see README. None are committed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION="$(cd "$HERE/.." && pwd)"
MANIFEST="${STICK_MANIFEST:-$HERE/stick.manifest}"
STAGING="${STICK_STAGING:-$HOME/fiehnlab-stick}"
ISODIR="$STAGING/isos"
SEEDDIR="$STAGING/seeds"
VENTOY_VER="${VENTOY_VER:-1.1.05}"

log(){ printf '\033[1;34m[forge]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[forge] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
confirm(){ printf '%s [type YES]: ' "$1"; read -r a; [ "$a" = YES ] || die "aborted"; }

# Read manifest rows into arrays (role iso source seed), skipping comments.
load_manifest(){
  ROLES=(); ISOS=(); SRCS=(); SEEDS=()
  while IFS='|' read -r role iso src seed; do
    [ -z "${role:-}" ] && continue
    case "$role" in \#*) continue;; esac
    ROLES+=("$role"); ISOS+=("$iso"); SRCS+=("$src"); SEEDS+=("$seed")
  done < <(grep -vE '^\s*(#|$)' "$MANIFEST")
  [ "${#ROLES[@]}" -gt 0 ] || die "no systems in $MANIFEST"
}

# Every key that may log in to a freshly installed system, as one YAML flow list in SSH_KEYS_YAML.
# Sources, merged and de-duplicated: SSH_AUTHORIZED_KEY (may hold several lines), the keys file
# (SSH_AUTHORIZED_KEYS_FILE, default ~/.config/fiehnlab/authorized_keys) and this host's own
# ~/.ssh/*.pub. Revoked files do not end in .pub, so they are never picked up. Set
# SSH_AUTHORIZED_KEYS_ONLY=1 to skip the host's own keys. Seeds are key-only SSH, so a key
# missing here means nobody can log in: every key is checked with ssh-keygen and anything
# that could break sed or YAML is refused.
collect_ssh_keys(){
  local file="${SSH_AUTHORIZED_KEYS_FILE:-$HOME/.config/fiehnlab/authorized_keys}"
  local -a keys=() seen=()
  local line key f fp
  add_key(){
    key="$(printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$key" ] && return 0
    case "$key" in \#*) return 0;; esac
    printf '%s' "$key" | grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+( [^"|&\\`$]*)?$' \
      || die "not an acceptable SSH public key line (options such as command= are not supported; no quotes, | & \\ \` \$ allowed): $key"
    fp="$(printf '%s\n' "$key" | ssh-keygen -l -f /dev/stdin 2>/dev/null | awk '{print $2}')"
    [ -n "$fp" ] || die "ssh-keygen rejects this public key: $key"
    for s in "${seen[@]:-}"; do [ "$s" = "$fp" ] && return 0; done
    seen+=("$fp"); keys+=("$key")
  }
  while IFS= read -r line; do add_key "$line"; done <<< "${SSH_AUTHORIZED_KEY:-}"
  if [ -f "$file" ]; then while IFS= read -r line || [ -n "$line" ]; do add_key "$line"; done < "$file"
  elif [ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" ]; then die "SSH_AUTHORIZED_KEYS_FILE $file does not exist"; fi
  if [ "${SSH_AUTHORIZED_KEYS_ONLY:-0}" != 1 ]; then
    for f in "$HOME"/.ssh/*.pub; do [ -f "$f" ] && while IFS= read -r line || [ -n "$line" ]; do add_key "$line"; done < "$f"; done
  fi
  SSH_KEYS_YAML=""
  [ "${#keys[@]}" -gt 0 ] || return 0
  for key in "${keys[@]}"; do SSH_KEYS_YAML="${SSH_KEYS_YAML:+$SSH_KEYS_YAML, }\"$key\""; done
  SSH_KEYS_YAML="[ $SSH_KEYS_YAML ]"
  log "authorizing ${#keys[@]} SSH key(s): $(printf '%s ' "${seen[@]}")"
}

load_config(){
  # Resolve render values from the environment or the uncommitted secrets file.
  # NONE are stored in the repo. stick-secrets.env may set PRIMARY_USER,
  # USER_PW_HASH, SSH_AUTHORIZED_KEY, LLM_GATEWAY_URL.
  local f="${STICK_SECRETS_ENV:-$HOME/.config/fiehnlab/stick-secrets.env}"
  [ -f "$f" ] && { set -a; . "$f"; set +a; }
  : "${PRIMARY_USER:=}"; : "${USER_PW_HASH:=}"; : "${SSH_AUTHORIZED_KEY:=}"
  : "${LLM_GATEWAY_URL:=https://llm.example.com/v1}"
  : "${NODE_GATEWAYS:=https://llm.metabolomics.us}"   # comma-separated InferWeave gateways a gpu-node registers with
  collect_ssh_keys
  # NODE_GATEWAYS goes through sed into the seed: allow only URL characters and commas.
  printf '%s' "$NODE_GATEWAYS" | grep -qE '^[A-Za-z0-9:/._,-]+$' \
    || die "NODE_GATEWAYS may contain only letters, digits and : / . _ , - (comma-separated URLs); got: $NODE_GATEWAYS"
  local miss=""
  [ -n "$PRIMARY_USER" ]       || miss="$miss PRIMARY_USER"
  [ -n "$USER_PW_HASH" ]       || miss="$miss USER_PW_HASH"
  [ -n "$SSH_KEYS_YAML" ]      || miss="$miss SSH_AUTHORIZED_KEY"
  [ -z "$miss" ] || die "missing render value(s):$miss
  Put them in $f (or the environment):
    PRIMARY_USER=alice
    USER_PW_HASH=\$(openssl passwd -6)                        # login/sudo password hash
    SSH_AUTHORIZED_KEY='ssh-ed25519 AAAA... you@host'         # one or several (one per line); this host's ~/.ssh/*.pub are added too
    SSH_AUTHORIZED_KEYS_FILE=~/.config/fiehnlab/authorized_keys  # optional: more keys, one per line (this is the default path)
    LLM_GATEWAY_URL=https://llm.example.com/v1                # optional (online gateway)
    NODE_GATEWAYS=https://llm.metabolomics.us                 # optional (gateways gpu-nodes register with, comma-separated)"
}

cmd_install_ventoy(){
  local dev="${1:?usage: install-ventoy <device e.g. /dev/sdX>}"
  [ -b "$dev" ] || die "$dev is not a block device"
  lsblk -dno NAME,SIZE,MODEL,TRAN "$dev" || true
  confirm "This ERASES $dev and installs Ventoy"
  local tgz="$STAGING/cache/ventoy-$VENTOY_VER-linux.tar.gz"
  mkdir -p "$(dirname "$tgz")"
  [ -s "$tgz" ] || { log "downloading Ventoy $VENTOY_VER ..."; \
    curl -fL "https://github.com/ventoy/Ventoy/releases/download/v$VENTOY_VER/ventoy-$VENTOY_VER-linux.tar.gz" -o "$tgz"; }
  local d="$STAGING/cache/ventoy-$VENTOY_VER"; [ -d "$d" ] || tar -C "$STAGING/cache" -xzf "$tgz"
  log "installing Ventoy onto $dev (exFAT data partition, GPT, secure-boot on) ..."
  sudo bash "$d/Ventoy2Disk.sh" -i -g -L FIEHNLAB "$dev"
  log "Ventoy installed. Re-plug the stick, then: $0 all $dev"
}

cmd_fetch(){
  load_manifest; mkdir -p "$ISODIR"
  for i in "${!ROLES[@]}"; do
    local iso="${ISOS[$i]}" src="${SRCS[$i]}" dest="$ISODIR/${ISOS[$i]}"
    [ -s "$dest" ] && { log "have ${iso}"; continue; }
    case "$src" in
      url:*)   log "downloading ${iso} ..."; curl -fL "${src#url:}" -o "$dest.part" && mv "$dest.part" "$dest" ;;
      zip:*)   log "downloading + extracting ${iso} ..."; \
               command -v unzip >/dev/null || die "unzip not installed (needed for zip: sources: apt install unzip)"; \
               local tmp; tmp="$(mktemp -d)"; \
               curl -fL "${src#zip:}" -o "$tmp/dl.zip" || { rm -rf "$tmp"; die "${iso}: download failed"; }; \
               local inner; inner="$(unzip -Z1 "$tmp/dl.zip" '*.iso' 2>/dev/null | head -1)"; \
               [ -n "$inner" ] || { rm -rf "$tmp"; die "${iso}: no .iso found inside the downloaded zip"; }; \
               unzip -p "$tmp/dl.zip" "$inner" > "$dest.part" && mv "$dest.part" "$dest"; rm -rf "$tmp" ;;
      file:*)  local p="${src#file:}"; [ -n "$p" ] || die "${iso}: source is file: but no path given (edit manifest)"; \
               log "copying ${iso} from $p"; cp -f "${p/#\~/$HOME}" "$dest" ;;
      built:*) die "${iso}: build it with ${src#built:} then place it at $dest (heavy build; not auto-run)" ;;
      *)       die "${iso}: unknown source '$src'" ;;
    esac
  done
  log "staged ISOs in $ISODIR"
}

cmd_render(){
  load_manifest; load_config; mkdir -p "$SEEDDIR"
  cp -f "$PROVISION/autoinstall/meta-data" "$SEEDDIR/meta-data" 2>/dev/null || true
  for i in "${!ROLES[@]}"; do
    local seed="${SEEDS[$i]}" role="${ROLES[$i]}"
    [ "$seed" = "-" ] && continue
    [ -f "$PROVISION/$seed" ] || die "$role: template $PROVISION/$seed not found"
    local agent_b64; agent_b64="$(base64 -w0 "$PROVISION/autoinstall/files/fiehnlab-register")"
    sed -e "s|@@PRIMARY_USER@@|$PRIMARY_USER|g" \
        -e "s|@@USER_PW_HASH@@|$USER_PW_HASH|g" \
        -e "s|@@LLM_GATEWAY_URL@@|$LLM_GATEWAY_URL|g" \
        -e "s|@@NODE_GATEWAYS@@|$NODE_GATEWAYS|g" \
        -e "s|@@REGISTER_AGENT_B64@@|$agent_b64|g" \
        -e "s|@@SSH_AUTHORIZED_KEYS@@|$SSH_KEYS_YAML|g" \
        "$PROVISION/$seed" > "$SEEDDIR/${role}-user-data"
    if grep -qE '@@[A-Z0-9_]+@@' "$SEEDDIR/${role}-user-data"; then
      die "$role: unresolved placeholder(s): $(grep -oE '@@[A-Z0-9_]+@@' "$SEEDDIR/${role}-user-data" | sort -u | tr '\n' ' ')"
    fi
    log "rendered ${role}-user-data"
  done
  chmod 600 "$SEEDDIR"/*-user-data 2>/dev/null || true
}

resolve_mount(){
  local tgt="$1"
  if [ -b "$tgt" ]; then findmnt -nro TARGET "${tgt}1" 2>/dev/null || findmnt -nro TARGET "$tgt" 2>/dev/null || \
      die "$tgt not mounted; plug the stick in (it automounts) and pass the mountpoint"; \
  elif [ -d "$tgt" ]; then printf '%s' "$tgt"; else die "$tgt is neither a device nor a mountpoint"; fi
}

cmd_sync(){
  load_manifest
  local mnt; mnt="$(resolve_mount "${1:?usage: sync <device|mountpoint>}")"
  [ -w "$mnt" ] || die "$mnt not writable"
  log "target stick: $mnt"
  mkdir -p "$mnt/ventoy"
  # ISOs
  for i in "${!ROLES[@]}"; do
    local iso="${ISOS[$i]}"
    if [ -s "$ISODIR/$iso" ]; then
      if [ "$ISODIR/$iso" -nt "$mnt/$iso" ] || [ ! -s "$mnt/$iso" ]; then
        log "copying $iso -> stick"; rsync -h --inplace --info=progress2 "$ISODIR/$iso" "$mnt/$iso"
      else log "up-to-date: $iso"; fi
    elif [ -s "$mnt/$iso" ]; then log "keeping existing on-stick: $iso (not staged)";
    else log "MISSING: $iso (run: $0 fetch, or stage it) — skipping"; fi
  done
  # Seeds + meta-data
  [ -f "$SEEDDIR/meta-data" ] && cp -f "$SEEDDIR/meta-data" "$mnt/ventoy/meta-data"
  for i in "${!ROLES[@]}"; do
    [ "${SEEDS[$i]}" = "-" ] && continue
    local s="$SEEDDIR/${ROLES[$i]}-user-data"
    [ -f "$s" ] || die "seed for ${ROLES[$i]} not rendered — run: $0 render"
    cp -f "$s" "$mnt/ventoy/${ROLES[$i]}-user-data"
  done
  # ventoy.json auto_install mapping (only rows with a seed)
  { echo '{'; echo '  "auto_install": ['; local first=1
    for i in "${!ROLES[@]}"; do
      [ "${SEEDS[$i]}" = "-" ] && continue
      [ "$first" = 1 ] || echo '    },'; first=0
      echo '    {'
      echo "      \"image\": \"/${ISOS[$i]}\","
      echo "      \"template\": \"/ventoy/${ROLES[$i]}-user-data\""
    done
    echo '    }'; echo '  ]'; echo '}'
  } > "$mnt/ventoy/ventoy.json"
  log "wrote $mnt/ventoy/ventoy.json"
  # Secrets container: copy a staged one only if the stick has none (never overwrite).
  if [ -s "$STAGING/fiehnlab-secrets.luks" ] && [ ! -s "$mnt/fiehnlab-secrets.luks" ]; then
    log "placing fiehnlab-secrets.luks (staged)"; cp -f "$STAGING/fiehnlab-secrets.luks" "$mnt/fiehnlab-secrets.luks"
  elif [ -s "$mnt/fiehnlab-secrets.luks" ]; then log "keeping existing fiehnlab-secrets.luks (untouched)";
  else log "NOTE: no secrets container on the stick — create one with secrets/create-secrets.sh"; fi
  sync; log "sync complete. Eject safely."
}

case "${1:-}" in
  install-ventoy) shift; cmd_install_ventoy "$@" ;;
  fetch)          cmd_fetch ;;
  render)         cmd_render ;;
  sync)           shift; cmd_sync "$@" ;;
  all)            shift; cmd_render; cmd_sync "$@" ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
