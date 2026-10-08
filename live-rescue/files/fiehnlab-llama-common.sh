# Shared helpers for fiehnlab-pull-model and fiehnlab-models. Sourced, not
# executed - no shebang, no `set -e` (don't impose that on the caller).

# Picks a directory for a multi-GB model download and WARNS loudly if the
# only candidate is RAM-backed (the live session's rootfs is an overlayfs
# over tmpfs/squashfs - a few GB download there can OOM the whole session).
# Prints the chosen directory on stdout; warnings go to stderr.
fiehnlab_pick_model_dir() {
  local candidate fstype

  # 1) explicit override
  if [ -n "${FIEHNLAB_MODEL_DIR:-}" ]; then
    echo "$FIEHNLAB_MODEL_DIR"
    return 0
  fi

  # 2) an already-mounted persistent target: an fiehnlab-unlock'd LUKS
  #    container (mounted under /mnt or /media), or a Ventoy data partition
  #    (exFAT/NTFS, also under /media/<user>/...), whichever is writable.
  for candidate in /mnt/*/Models /media/*/*/Models /media/*/Models; do
    [ -d "$(dirname "$candidate" 2>/dev/null)" ] 2>/dev/null || continue
    mkdir -p "$candidate" 2>/dev/null && [ -w "$candidate" ] && { echo "$candidate"; return 0; }
  done

  # 3) fall back to $HOME, but check what $HOME actually sits on.
  local dir="${HF_HOME:-$HOME/.cache/huggingface}"
  fstype=$(findmnt -no FSTYPE --target "$HOME" 2>/dev/null || echo unknown)
  case "$fstype" in
    overlay|tmpfs|ramfs)
      echo "WARNING: \$HOME looks RAM-backed on this live session (fstype=$fstype)." >&2
      echo "A multi-GB model download here can exhaust RAM and crash the whole session." >&2
      echo "Mount a persistent disk first (fiehnlab-unlock, or the Ventoy data" >&2
      echo "partition under /media), then re-run with FIEHNLAB_MODEL_DIR=/that/path," >&2
      echo "or create a Models/ dir under one of those mounts." >&2
      ;;
  esac
  mkdir -p "$dir"
  echo "$dir"
}

fiehnlab_persistent_warning_only() {
  # Same fstype check as above, without picking a directory - used where a
  # caller already has HF_HOME/LLAMA_CACHE set and just wants the warning.
  local fstype
  fstype=$(findmnt -no FSTYPE --target "${1:-$HOME}" 2>/dev/null || echo unknown)
  case "$fstype" in
    overlay|tmpfs|ramfs)
      echo "WARNING: '$1' looks RAM-backed (fstype=$fstype) - a large download there can OOM this session." >&2
      ;;
  esac
}
