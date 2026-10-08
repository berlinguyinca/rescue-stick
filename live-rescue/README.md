# rescue-os (build pipeline)

`build-live.sh` remasters an **Ubuntu 24.04 Desktop live ISO** into **rescue-os**:
a portable live USB that boots straight into an AI rescue assistant with a full
engineering/forensics toolset and your secrets available (from an encrypted
container) in RAM.

For the user-facing "what you actually get," see
[`../docs/systems/rescue-os.md`](../docs/systems/rescue-os.md). This file is the
**build/design** reference.

## What the build produces

- **Local LLM stack (llama.cpp, no cloud needed):**
  - `llama-chat` on `:8080` — alias `qwen3-local`, serving **Qwen3-8B** (Q4_K_M),
    with **Qwen3-1.7B** (Q4_K_M) baked as a low-RAM fallback (small, with tool-calling).
  - `llama-embed` on `:18081` — **nomic-embed-text v1.5** (Q8) for RAG.
  - `llama-swap` on `:9090` — on-demand models fetched later via `fiehnlab-models` / `hf`.
  - `fiehnlab-llama` picks the backend at boot: NVIDIA→CUDA, AMD/Intel→Vulkan,
    else CPU. Both llama.cpp builds are **userspace only** — the image never ships
    a kernel GPU driver (a build gate enforces this).
- **AI brains:** the [pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
  coding agent + the [pi-rescue](https://github.com/berlinguyinca/pi-rescue) and
  pi-engineering extensions, baked under `/opt/*-runtime`. Routing prefers your
  online gateway when reachable and falls back to the local model offline.
- **Zero-knowledge boot:** `fiehnlab-assist` autostarts a plain-language Rescue
  Assistant greeting (the stock Ubuntu first-run wizard is suppressed).
- **Secrets:** `fiehnlab-unlock` opens the LUKS container on the stick (passphrase)
  and loads SSH keys, gateway/gh/AWS creds, tailscale, BMC/MikroTik/recovery creds
  and `.pgpass` into the session's RAM only — nothing is baked into the image.

## Build it

```bash
./build-live.sh --base-iso ubuntu-24.04.5.1-desktop-amd64.iso --out rescue-os.iso
```

Useful flags: `--no-bake-model` (ship a puller instead of baking weights),
`--bake-model <hf-repo>`, `--skip-rescue-tools`, `--no-ghidra`, `--phase0-only`.

## How the remaster works

1. Extract the Desktop ISO's layered casper squashfs
   (`minimal → minimal.standard → minimal.standard.live`).
2. Mount an **overlay** (fresh upper on an ext4 loop) over the live layer and
   chroot in — kernel held, `update-initramfs` diverted, `policy-rc.d` blocking
   services. The chroot's `/dev` and `/run` are made **rslave** so a build can
   never leak mounts back onto the host's `/dev/pts`.
3. Install the toolset, llama.cpp + models, pi extensions; run a build-time
   rehearsal (start chat+embed on throwaway ports, build the RAG index, smoke-test
   pi) so a broken image fails the build rather than the user.
4. Purge any GPU driver (gate: `dpkg -l | grep ^ii` must show none), repack the
   live layer with `mksquashfs`, and rebuild the ISO with `xorriso … -boot_image
   any replay` so the original boot/EFI config is preserved.

## Verify

Boot the ISO in QEMU (OVMF) and read the serial console: `fiehnlab-selftest`
checks that `qwen3-local` serves on `:8080`, embeddings return a 768-dim vector on
`:18081`, pi loads pi-rescue, the RE/network tools resolve, and no GPU driver is
present — then confirm the Rescue Assistant greeting is frontmost.
