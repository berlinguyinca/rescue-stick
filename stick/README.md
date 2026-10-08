# fiehnlab provisioning USB — forge & extend

Reproducibly (re)build the Ventoy multiboot stick: the autoinstall images
(gpu-node / desktop), the `fiehnlab-live` rescue+work ISO, standalone ISOs
(Rocky, etc.), and the encrypted secrets container — all driven by
[`stick.manifest`](stick.manifest).

A Ventoy stick is simple: install Ventoy **once**, then every ISO is just a file
on the exFAT data partition. Ventoy's `auto_install` plugin (in
`/ventoy/ventoy.json`) maps each ISO to its autoinstall seed. `forge-stick.sh`
renders those seeds and writes everything out.

## Layout

```
stick/
├── stick.manifest     one line per bootable system (role | iso | source | seed)
├── forge-stick.sh     install-ventoy | fetch | render | sync | all
├── secrets/           container lifecycle (TOOLING only — never secrets)
│   ├── create-secrets.sh      make a fresh empty LUKS2 container + layout
│   ├── add-ssh-key.sh         add id_ed25519 (+ known_hosts/config)
│   └── add-secrets-extra.sh   add tailscale / BMC+recovery / MikroTik / pgpass
└── README.md
```
Seeds come from [`../autoinstall/*.user-data.tmpl`](../autoinstall); the rescue
ISO from [`../live-rescue/build-live.sh`](../live-rescue); Rocky kickstarts live in the `fsc-forge-tokens` cluster repo.

## First-time forge (fresh stick)

```bash
cd provision/stick
# 1. Install Ventoy (ERASES the device — pick the right /dev/sdX!)
./forge-stick.sh install-ventoy /dev/sdX
# 2. Put render values (never committed) in ~/.config/fiehnlab/stick-secrets.env:
#      PRIMARY_USER=alice
#      USER_PW_HASH='...'       # SINGLE-QUOTED! generate with: openssl passwd -6
#      SSH_AUTHORIZED_KEY='ssh-ed25519 AAAA... you@host'   # or rely on ~/.ssh/id_ed25519.pub
#      LLM_GATEWAY_URL=https://llm.example.com/v1          # optional
# 3. Get the ISOs into staging (~/fiehnlab-stick/isos) and render + write the stick
./forge-stick.sh fetch            # downloads url: ISOs; copies file: ISOs
#    built: ISOs (fiehnlab-live) are heavy — build then stage them:
#      ../live-rescue/build-live.sh … && cp …/fiehnlab-live.iso ~/fiehnlab-stick/isos/
./forge-stick.sh all /dev/sdX     # = render + sync  (re-plug the stick after install-ventoy)
# 4. Create + populate the encrypted secrets container (real terminal; see below)
sudo bash secrets/create-secrets.sh /media/$USER/FIEHNLAB/fiehnlab-secrets.luks
sudo bash secrets/add-ssh-key.sh      /media/$USER/FIEHNLAB/fiehnlab-secrets.luks
sudo bash secrets/add-secrets-extra.sh /media/$USER/FIEHNLAB/fiehnlab-secrets.luks
```

## Re-forge / refresh an existing stick

Ventoy is already installed — just update ISOs, seeds, and `ventoy.json`:
```bash
./forge-stick.sh all /media/$USER/FIEHNLAB      # or pass the /dev node
```
Existing ISOs are only recopied when the staged one is newer; the secrets
container on the stick is **never** overwritten.

## Add another system later

1. Append a line to `stick.manifest` (`role|iso|source|seed`).
2. Stage its ISO (`./forge-stick.sh fetch`, or drop it in `~/fiehnlab-stick/isos/`).
3. `./forge-stick.sh sync <device|mount>` — it copies the ISO and, if the row
   has an autoinstall seed, renders it and adds the `ventoy.json` mapping.

Boot the stick → Ventoy menu lists every ISO; autoinstall systems run unattended.

## Secrets container (encrypted, passphrase-gated)

`fiehnlab-secrets.luks` is a LUKS2 (AES-XTS-512 / Argon2id) container on the
exFAT partition. It holds the gateway key, gh token, AWS profiles, SSH identity,
tailscale key, BMC/MikroTik/recovery creds, and `.pgpass`. The live image's
`fiehnlab-unlock` opens it (passphrase) and loads everything into the running
session's RAM only — **nothing secret is ever written to an image or to git.**
The `secrets/` scripts only ever *prompt* for values; losing the stick without
the passphrase leaks nothing.

> Build host note: the chroot-based builders (`build-live.sh`) make the chroot's
> `/dev` and `/run` **rslave** so a build can never leak mounts back onto the
> host's `/dev/pts` (that bug manifests as `sudo: unable to allocate pty`).
