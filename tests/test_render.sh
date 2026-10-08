#!/usr/bin/env bash
# tests/test_render.sh — render the stick seeds with dummy values and inspect the gpu-node one.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# Work on a copy so the digit-placeholder case can edit a template safely.
mkdir "$T/repo"; tar -C "$SRC" --exclude=.git -cf - . | tar -C "$T/repo" -xf -
cd "$T/repo"
export STICK_STAGING="$T/stage" STICK_SECRETS_ENV=/dev/null
export PRIMARY_USER=tester USER_PW_HASH='$6$x$y' SSH_AUTHORIZED_KEY='ssh-ed25519 AAAA test'
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

# An overridden list is honoured.
NODE_GATEWAYS='https://a.example,https://b.example' stick/forge-stick.sh render >/dev/null
grep -q 'https://b.example' "$T/stage/seeds/gpu-node-user-data" || fail "NODE_GATEWAYS override ignored"

# A placeholder containing digits that is left unresolved must abort the render.
echo '# @@UNRESOLVED_B64@@' >> autoinstall/gpu-node.user-data.tmpl
if stick/forge-stick.sh render >/dev/null 2>&1; then fail "digit placeholder was not caught"; fi
echo "PASS"
