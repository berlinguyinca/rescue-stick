# Forge & extend the stick

`forge-stick.sh` builds the whole USB from [`stick.manifest`](stick.manifest).
You install Ventoy **once**; after that every ISO is just a file on the stick,
and `forge-stick.sh` writes the autoinstall config for you.

```
stick/
├── stick.manifest   one line per bootable system:  role | iso | source | seed
├── forge-stick.sh   install-ventoy | fetch | render | sync | all
└── secrets/         encrypted-container scripts (tooling only — never secrets)
                       create-secrets.sh · add-ssh-key.sh · add-secrets-extra.sh
```

## Build a fresh stick

```bash
cd stick

# 1) Install Ventoy — this ERASES the device, so double-check /dev/sdX.
./forge-stick.sh install-ventoy /dev/sdX

# 2) Put your per-machine values in ~/.config/fiehnlab/stick-secrets.env.
#    They're never committed; forge injects them into the autoinstall logins:
#      PRIMARY_USER=alice
#      USER_PW_HASH='...'        # single-quoted! make one with:  openssl passwd -6
#      SSH_AUTHORIZED_KEY='ssh-ed25519 AAAA... you@host'   # or just have ~/.ssh/id_ed25519.pub
#      LLM_GATEWAY_URL=https://llm.example.com/v1          # optional (online model gateway)

# 3) Fetch the ISOs, then write the stick.
./forge-stick.sh fetch           # downloads/copies the manifest's ISOs into ~/fiehnlab-stick/isos
./forge-stick.sh all /dev/sdX    # render logins + copy ISOs + write ventoy.json
```

`fiehnlab-live` is a large custom build — build it with
[`../live-rescue/build-live.sh`](../live-rescue) and drop the resulting ISO into
`~/fiehnlab-stick/isos/` before step 3.

## Refresh a stick you already have

```bash
./forge-stick.sh all /media/$USER/FIEHNLAB     # or pass the /dev node
```

Only changed ISOs are recopied; the secrets container is never overwritten.

## Add another system

1. Append a line to [`stick.manifest`](stick.manifest) (`role | iso | source | seed`).
2. `./forge-stick.sh fetch` (or drop the ISO in `~/fiehnlab-stick/isos/`).
3. `./forge-stick.sh sync <device|mount>`.

Boot the stick and Ventoy lists every ISO; autoinstall entries run unattended.

## Secrets

`fiehnlab-secrets.luks` is an encrypted (LUKS2) container on the stick holding
your SSH key, gateway / GitHub / AWS creds, tailscale key, BMC & MikroTik logins
and `.pgpass`. Create and fill it in a real terminal — it prompts for a
passphrase, and nothing is echoed:

```bash
sudo bash secrets/create-secrets.sh        # make the container
sudo bash secrets/add-ssh-key.sh           # add your SSH identity
sudo bash secrets/add-secrets-extra.sh     # tailscale / BMC / MikroTik / .pgpass
```

On the live image, `fiehnlab-unlock` opens it (passphrase) and loads everything
into RAM for that session only. Lose the stick and — without the passphrase —
nothing leaks.
