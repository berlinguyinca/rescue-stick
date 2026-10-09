#!/usr/bin/env bash
# tests/test_render.sh — render the stick seeds with dummy values and inspect the gpu-node one.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# Work on a copy so the digit-placeholder case can edit a template safely.
mkdir "$T/repo"; tar -C "$SRC" --exclude=.git -cf - . | tar -C "$T/repo" -xf -
cd "$T/repo"
export HOME="$T/home"; mkdir -p "$HOME/.ssh" "$HOME/.config/fiehnlab"
mkkey(){ ssh-keygen -q -t ed25519 -N '' -C "$2" -f "$T/k-$1" && cat "$T/k-$1.pub"; }
export STICK_STAGING="$T/stage" STICK_SECRETS_ENV=/dev/null
export PRIMARY_USER=tester USER_PW_HASH='$6$x$y' SSH_AUTHORIZED_KEY="$(mkkey 0 base@test)"
fail(){ echo "FAIL: $*" >&2; exit 1; }

stick/forge-stick.sh render >/dev/null
S="$T/stage/seeds/gpu-node-user-data"
grep -q '@@' "$S" && fail "unresolved placeholder in rendered seed"
grep -q 'fiehnlab-register.service' "$S" || fail "service missing"
grep -q 'https://llm.metabolomics.us' "$S" || fail "default gateway missing"

# The embedded agent must round-trip byte for byte and still be valid Python.
python3 - "$S" <<'PY'
import base64, re, sys
seed = open(sys.argv[1]).read()
m = re.search(r"path: /usr/local/sbin/fiehnlab-register\n\s+permissions: \"0755\"\n\s+encoding: b64\n\s+content: (\S+)", seed)
assert m, "agent write_files entry not found"
got = base64.b64decode(m.group(1))
want = open("autoinstall/files/fiehnlab-register", "rb").read()
assert got == want, "embedded agent differs from source"
compile(got.decode(), "fiehnlab-register", "exec")
PY

# The register unit must not be ordered after the GPU container unit: that unit is After=multi-user.target
# and both are WantedBy=multi-user.target, which is an ordering cycle systemd breaks by deleting a job.
python3 - "$S" "$T/units" <<'PY'
import re, sys, yaml, os
seed = yaml.safe_load(open(sys.argv[1]))
def walk(o):
    if isinstance(o, dict):
        if "write_files" in o: return o["write_files"]
        for v in o.values():
            r = walk(v)
            if r: return r
files = {e["path"]: e["content"] for e in walk(seed)}
unit = files["/etc/systemd/system/fiehnlab-register.service"]
assert "fiehnlab-gpu-container" not in unit, "register unit is ordered after the GPU unit (ordering cycle)"
os.makedirs(sys.argv[2])
for path, content in files.items():
    if path.startswith("/etc/systemd/system/"):
        open(os.path.join(sys.argv[2], os.path.basename(path)), "w").write(content)
open(os.path.join(sys.argv[2], "fiehnlab-gpu-container.service"), "w").write(files["/etc/systemd/system/fiehnlab-gpu-container.service"])
# first boot must actually start the service
rc = seed["autoinstall"]["user-data"]["runcmd"]
assert any(c[:2] == ["systemctl", "enable"] and "--now" in c and "fiehnlab-register.service" in c for c in rc if isinstance(c, list)), \
    "runcmd does not start fiehnlab-register on the first boot"
PY
if command -v systemd-analyze >/dev/null; then
  out="$(cd "$T/units" && systemd-analyze verify --man=no ./fiehnlab-register.service ./fiehnlab-gpu-container.service 2>&1 || true)"
  if echo "$out" | grep -qi "ordering cycle"; then fail "systemd ordering cycle: $out"; fi
fi

# NODE_GATEWAYS is substituted by sed: refuse anything but URL characters and commas.
for bad in 'https://a|b' 'https://a&b' 'https://a\b' "$(printf 'https://a\nhttps://b')"; do
  if NODE_GATEWAYS="$bad" stick/forge-stick.sh render >/dev/null 2>&1; then fail "NODE_GATEWAYS accepted: $bad"; fi
done

# An overridden list is honoured.
NODE_GATEWAYS='https://a.example,https://b.example' stick/forge-stick.sh render >/dev/null
grep -q 'https://b.example' "$T/stage/seeds/gpu-node-user-data" || fail "NODE_GATEWAYS override ignored"

# A placeholder containing digits that is left unresolved must abort the render.
echo '# @@UNRESOLVED_B64@@' >> autoinstall/gpu-node.user-data.tmpl
if stick/forge-stick.sh render >/dev/null 2>&1; then fail "digit placeholder was not caught"; fi
sed -i '/UNRESOLVED_B64/d' autoinstall/gpu-node.user-data.tmpl

# ---- several SSH keys --------------------------------------------------------------------------
# Keys of the host that forges the stick are authorized by default; more come from a keys file and
# from a multi-line SSH_AUTHORIZED_KEY; duplicates collapse; revoked ~/.ssh files are ignored.
KA="$(mkkey a admin@hostA)"; KB="$(mkkey b laptop@hostB)"; KC="$(mkkey c mac@hostC)"; KD="$(mkkey d explicit@hostD)"
echo "$KA" > "$HOME/.ssh/id_ed25519.pub"
echo "$KB" > "$HOME/.ssh/id_rsa.pub.revoked-20260924"       # revoked: must NOT be authorized
printf '# lab keys\n%s\n\n%s\n%s\n' "$KB" "$KC" "$KA" > "$HOME/.config/fiehnlab/authorized_keys"
export SSH_AUTHORIZED_KEY="$KD"
rm -rf "$T/stage"; stick/forge-stick.sh render >/dev/null || fail "render with several keys failed"
python3 - "$T/stage/seeds" "$KA" "$KB" "$KC" "$KD" <<'PY'
import sys, yaml
seeds, a, b, c, d = sys.argv[1], *sys.argv[2:6]
for role in ("gpu-node", "desktop"):
    keys = yaml.safe_load(open(f"{seeds}/{role}-user-data"))["autoinstall"]["ssh"]["authorized-keys"]
    assert sorted(keys) == sorted({a, b, c, d}), f"{role}: {keys}"
    assert len(keys) == 4, f"{role}: duplicates not collapsed: {keys}"
PY
# the revoked-file key (KB) is only present because the keys file lists it, not because of ~/.ssh
rm "$HOME/.config/fiehnlab/authorized_keys"
rm -rf "$T/stage"; stick/forge-stick.sh render >/dev/null || fail "render failed"
python3 - "$T/stage/seeds/gpu-node-user-data" "$KA" "$KB" "$KD" <<'PY'
import sys, yaml
keys = yaml.safe_load(open(sys.argv[1]))["autoinstall"]["ssh"]["authorized-keys"]
assert sorted(keys) == sorted([sys.argv[2], sys.argv[4]]) and sys.argv[3] not in keys, keys
PY
# a multi-line SSH_AUTHORIZED_KEY works
SSH_AUTHORIZED_KEY="$(printf '%s\n%s' "$KC" "$KD")" stick/forge-stick.sh render >/dev/null || fail "multi-line SSH_AUTHORIZED_KEY failed"
python3 - "$T/stage/seeds/gpu-node-user-data" "$KC" <<'PY'
import sys, yaml
assert sys.argv[2] in yaml.safe_load(open(sys.argv[1]))["autoinstall"]["ssh"]["authorized-keys"]
PY
# SSH_AUTHORIZED_KEYS_ONLY=1 ignores the forging host's own keys
SSH_AUTHORIZED_KEYS_ONLY=1 stick/forge-stick.sh render >/dev/null || fail "ONLY=1 render failed"
python3 - "$T/stage/seeds/gpu-node-user-data" "$KA" "$KD" <<'PY'
import sys, yaml
assert yaml.safe_load(open(sys.argv[1]))["autoinstall"]["ssh"]["authorized-keys"] == [sys.argv[3]]
PY
# bad key material is refused instead of being written into a seed that would lock everyone out
for bad in 'ssh-ed25519 AAAAnotakey broken@x' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKID8795AIxQCyL4P1ETuwjvrUvBeqOHDqWBpvO30lR1 a"b' 'command="x" ssh-ed25519 AAAA y'; do
  if SSH_AUTHORIZED_KEY="$bad" stick/forge-stick.sh render >/dev/null 2>&1; then fail "accepted bad key: $bad"; fi
done
printf 'not a key\n' > "$HOME/.config/fiehnlab/authorized_keys"
if stick/forge-stick.sh render >/dev/null 2>&1; then fail "accepted a bad keys file"; fi
rm "$HOME/.config/fiehnlab/authorized_keys"
unset SSH_AUTHORIZED_KEY
echo "PASS"
