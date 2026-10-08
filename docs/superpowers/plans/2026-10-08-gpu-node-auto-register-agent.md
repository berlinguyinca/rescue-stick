# gpu-node Auto-Registration Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A GPU node installed from the stick enrolls with every configured InferWeave gateway using the tokenless proof protocol, registers its hardware, and keeps heartbeating.

**Architecture:** One stdlib-only Python 3 script, `fiehnlab-register`, baked into the `gpu-node` autoinstall seed and run by a systemd unit. It holds one Ed25519 identity (via `openssl`), and runs one independent worker per gateway URL. Hardware collection is pure functions over injectable command/file readers so it can be tested with fixtures.

**Tech Stack:** Python 3.12 (stdlib `unittest`, `http.server`, `urllib`), OpenSSL 3 for Ed25519, bash, cloud-init autoinstall YAML.

**Spec:** `docs/superpowers/specs/2026-10-08-gpu-node-auto-register-design.md` (this plan is spec build-order step 4 and the stick wiring of §4; steps 1-3, the specs repo and both gateways, are separate plans).

## Global Constraints

- Protocol is canonical in `inferweave/inferweave` (`crates/iw-gateway/src/server.rs:1232-1237`, `node_control.rs`). JSON keys are camelCase.
- Enrollment is tokenless: `POST /v1/node/key`, `/v1/node/challenge`, `/v1/node/proof`. No code, token or secret may be placed in the seed, the script or the repo.
- Signed bytes are `iw_core::signature::proof_transcript`: domain `iw-proof-enrollment-v1`, big-endian `u32` length-prefixed fields, `nonce` as 8 big-endian bytes, optional fields as `0x00` or `0x01`+field. Public key and signature are lowercase hex (32 and 64 raw bytes).
- Role string is `node`. Node id is `node_` + first 16 hex chars of SHA-256 of the raw public key.
- No pip dependencies on the node. Ed25519 only through `openssl` (3.0 on Ubuntu 24.04).
- A registering node serves nothing and is never routed to. The agent never starts an engine.
- Log `OK:`/`FAILED:` lines to `/var/log/fiehnlab-provision.log`, like the other first-boot units.
- Default gateway list is `https://llm.metabolomics.us`. Seed values come from `LLM_GATEWAY`-style build-time variables, never hard-coded secrets.

## Review Focus

- Box with no GPU, or `nvidia-smi` present but failing: must still register with `gpus: []` and a note, never crash.
- One gateway down or returning 5xx while another works: the working one must register and heartbeat on time.
- Gateway URL list with whitespace, blank lines, comments, trailing slash, a `/v1` suffix (the existing `LLM_GATEWAY_URL` default has one) or duplicates.
- Credential rejected (401/403) or connection id unknown (404) after a gateway restart: must re-enroll or re-register, not loop on a dead credential.
- Hardware changes between boots (GPU swapped, RAM added): must re-register; an unchanged report must not.
- Key file unreadable, wrong mode, or lost: must not silently continue under a new id without logging it.
- Unresolved placeholder in the rendered seed (the existing check ignores digits, and `B64` has digits).

---

## File Structure

- Create `autoinstall/files/fiehnlab-register` — the agent (single file, sections: crypto, collector, client, worker, main).
- Create `tests/register/test_register.py` — unit tests plus an in-process mock gateway.
- Create `tests/register/fixtures/` — canned `nvidia-smi`, `lspci`, `/proc` text.
- Create `tests/test_render.sh` — renders the gpu-node seed and checks it.
- Modify `autoinstall/gpu-node.user-data.tmpl` — agent file, unit, gateways file, enable.
- Modify `stick/forge-stick.sh` — new `NODE_GATEWAYS` and agent placeholders; digit-safe placeholder check.
- Modify `stick/README.md`, `docs/systems/gpu-node.md` — document.

The test module loads the agent by path with `importlib` because the script has no `.py` extension.

---

### Task 1: Ed25519 identity and proof transcript

**Files:**
- Create: `autoinstall/files/fiehnlab-register`
- Test: `tests/register/test_register.py`

**Interfaces:**
- Produces:
  - `proof_transcript(challenge_id: str, nonce: int, claim: dict) -> bytes`
  - `ensure_key(path: str) -> None` (creates a 0600 PEM if missing)
  - `public_hex(path: str) -> str`
  - `node_id_for(pub_hex: str) -> str`
  - `sign_hex(path: str, message: bytes) -> str`

- [ ] **Step 1: Write the failing tests**

```python
# tests/register/test_register.py
import hashlib, importlib.machinery, importlib.util, json, os, stat, subprocess, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
AGENT = os.path.join(HERE, "..", "..", "autoinstall", "files", "fiehnlab-register")


def load():
    loader = importlib.machinery.SourceFileLoader("fiehnlab_register", AGENT)
    spec = importlib.util.spec_from_loader("fiehnlab_register", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


fr = load()
SPKI_ED25519_PREFIX = bytes.fromhex("302a300506032b6570032100")


def openssl_verify(pub_hex, message, sig_hex):
    with tempfile.TemporaryDirectory() as d:
        pub = os.path.join(d, "pub.der")
        msg = os.path.join(d, "msg")
        sig = os.path.join(d, "sig")
        open(pub, "wb").write(SPKI_ED25519_PREFIX + bytes.fromhex(pub_hex))
        open(msg, "wb").write(message)
        open(sig, "wb").write(bytes.fromhex(sig_hex))
        r = subprocess.run(
            ["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", pub, "-keyform", "DER",
             "-rawin", "-in", msg, "-sigfile", sig],
            capture_output=True)
        return r.returncode == 0


class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.key = os.path.join(self.tmp.name, "node-key")

    def tearDown(self):
        self.tmp.cleanup()

    def test_ensure_key_creates_private_file_once(self):
        fr.ensure_key(self.key)
        self.assertEqual(stat.S_IMODE(os.stat(self.key).st_mode), 0o600)
        first = open(self.key).read()
        fr.ensure_key(self.key)
        self.assertEqual(first, open(self.key).read(), "an existing key is never replaced")

    def test_public_hex_is_32_bytes_and_node_id_is_derived(self):
        fr.ensure_key(self.key)
        pub = fr.public_hex(self.key)
        self.assertRegex(pub, r"^[0-9a-f]{64}$")
        want = "node_" + hashlib.sha256(bytes.fromhex(pub)).hexdigest()[:16]
        self.assertEqual(fr.node_id_for(pub), want)

    def test_signature_verifies_with_openssl(self):
        fr.ensure_key(self.key)
        sig = fr.sign_hex(self.key, b"hello")
        self.assertRegex(sig, r"^[0-9a-f]{128}$")
        self.assertTrue(openssl_verify(fr.public_hex(self.key), b"hello", sig))
        self.assertFalse(openssl_verify(fr.public_hex(self.key), b"other", sig))


class TranscriptTests(unittest.TestCase):
    def test_role_only_claim_bytes(self):
        claim = {"role": "node", "model": None, "contextClass": None, "resourceClaim": None}
        got = fr.proof_transcript("c1", 7, claim)
        want = (
            len(b"iw-proof-enrollment-v1").to_bytes(4, "big") + b"iw-proof-enrollment-v1"
            + (2).to_bytes(4, "big") + b"c1"
            + (7).to_bytes(8, "big")
            + (4).to_bytes(4, "big") + b"node"
            + b"\x00\x00\x00"
        )
        self.assertEqual(got, want)

    def test_present_empty_differs_from_absent(self):
        a = {"role": "node", "model": None, "contextClass": None, "resourceClaim": None}
        b = dict(a, model="")
        self.assertNotEqual(fr.proof_transcript("c", 1, a), fr.proof_transcript("c", 1, b))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -I -m unittest discover -s tests/register -v`
Expected: FAIL (`FileNotFoundError` / agent file missing).

- [ ] **Step 3: Write the implementation**

```python
#!/usr/bin/env python3
"""fiehnlab-register: enroll this node with InferWeave gateways and advertise its hardware.

Speaks the inferweave/inferweave node protocol: /v1/node/{key,challenge,proof}
(tokenless proof enrollment), /v1/node/register and /v1/node/heartbeat.
Stdlib only; Ed25519 goes through openssl.
"""
import argparse
import hashlib
import json
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

PROOF_DOMAIN = b"iw-proof-enrollment-v1"
ROLE = "node"

# ---------------------------------------------------------------- crypto


def _field(data):
    return struct.pack(">I", len(data)) + data


def _optional(value):
    if value is None:
        return b"\x00"
    return b"\x01" + _field(value.encode())


def proof_transcript(challenge_id, nonce, claim):
    """The exact bytes a proof signs (iw_core::signature::proof_transcript)."""
    out = _field(PROOF_DOMAIN) + _field(challenge_id.encode())
    out += struct.pack(">Q", nonce)
    out += _field(claim["role"].encode())
    out += _optional(claim.get("model"))
    out += _optional(claim.get("contextClass"))
    out += _optional(claim.get("resourceClaim"))
    return out


def _openssl(args, data=None):
    r = subprocess.run(["openssl"] + args, input=data, capture_output=True, check=True)
    return r.stdout


def ensure_key(path):
    if os.path.exists(path):
        return
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    old = os.umask(0o077)
    try:
        _openssl(["genpkey", "-algorithm", "ed25519", "-out", path])
    finally:
        os.umask(old)
    os.chmod(path, 0o600)


def public_hex(path):
    der = _openssl(["pkey", "-in", path, "-pubout", "-outform", "DER"])
    return der[-32:].hex()


def node_id_for(pub_hex):
    return "node_" + hashlib.sha256(bytes.fromhex(pub_hex)).hexdigest()[:16]


def sign_hex(path, message):
    with tempfile.NamedTemporaryFile() as f:
        f.write(message)
        f.flush()
        sig = _openssl(["pkeyutl", "-sign", "-inkey", path, "-rawin", "-in", f.name])
    return sig.hex()
```

- [ ] **Step 4: Run to verify pass**

Run: `python3 -I -m unittest discover -s tests/register -v`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
chmod +x autoinstall/files/fiehnlab-register
git add docs/superpowers autoinstall/files/fiehnlab-register tests/register/test_register.py
git commit -m "feat(register): ed25519 identity and proof transcript"
```

---

### Task 2: Hardware collector

**Files:**
- Modify: `autoinstall/files/fiehnlab-register` (append section)
- Create: `tests/register/fixtures/nvidia-smi.csv`, `lspci-amd.txt`, `meminfo.txt`, `cpuinfo.txt`
- Test: `tests/register/test_register.py`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `parse_nvidia_smi(text: str) -> list[dict]`
  - `parse_lspci_gpus(text: str) -> list[dict]`
  - `collect(run, read, listdir) -> dict` where `run(cmd: list[str]) -> str|None`, `read(path: str) -> str|None`, `listdir(path: str) -> list[str]`
  - `register_vram(report: dict) -> int`
- Report shape (`version` 1): `{"version":1,"hostname","machineId","role","kernel","os","cpu":{"model","threads"},"memBytes","disks":[{"name","sizeBytes","rotational"}],"nics":[{"name","speedMbps"}],"gpus":[{"vendor","model","uuid","pciId","vramBytes","driver","index"}],"notes":[str]}`

- [ ] **Step 1: Create fixtures**

`tests/register/fixtures/nvidia-smi.csv`:
```
0, GPU-aaaa1111, NVIDIA RTX PRO 6000 Blackwell Workstation Edition, 97887, 580.65.06, 00000000:01:00.0
1, GPU-bbbb2222, NVIDIA RTX PRO 6000 Blackwell Workstation Edition, 97887, 580.65.06, 00000000:41:00.0
```
`tests/register/fixtures/lspci-amd.txt`:
```
03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 31 [Radeon RX 7900 XTX] [1002:744c] (rev c8)
00:02.0 VGA compatible controller [0300]: ASPEED Technology, Inc. ASPEED Graphics Family [1a03:2000] (rev 41)
```
`tests/register/fixtures/meminfo.txt`:
```
MemTotal:       263921456 kB
MemFree:        100000 kB
```
`tests/register/fixtures/cpuinfo.txt`:
```
processor	: 0
model name	: AMD EPYC 7763 64-Core Processor
processor	: 1
model name	: AMD EPYC 7763 64-Core Processor
```

- [ ] **Step 2: Write the failing tests**

```python
FIX = os.path.join(HERE, "fixtures")


def fixture(name):
    return open(os.path.join(FIX, name)).read()


def fake_env(files=None, cmds=None, dirs=None):
    files, cmds, dirs = files or {}, cmds or {}, dirs or {}
    return (
        lambda cmd: cmds.get(tuple(cmd)),
        lambda path: files.get(path),
        lambda path: dirs.get(path, []),
    )


class CollectorTests(unittest.TestCase):
    def test_parse_nvidia_smi(self):
        gpus = fr.parse_nvidia_smi(fixture("nvidia-smi.csv"))
        self.assertEqual(len(gpus), 2)
        self.assertEqual(gpus[0]["vendor"], "nvidia")
        self.assertEqual(gpus[0]["uuid"], "GPU-aaaa1111")
        self.assertEqual(gpus[0]["vramBytes"], 97887 * 1024 * 1024)
        self.assertEqual(gpus[0]["driver"], "580.65.06")
        self.assertEqual(gpus[1]["index"], 1)

    def test_parse_nvidia_smi_ignores_garbage(self):
        self.assertEqual(fr.parse_nvidia_smi(""), [])
        self.assertEqual(fr.parse_nvidia_smi("NVIDIA-SMI has failed\n"), [])
        self.assertEqual(fr.parse_nvidia_smi(None), [])

    def test_parse_lspci_picks_amd_and_skips_bmc_vga(self):
        gpus = fr.parse_lspci_gpus(fixture("lspci-amd.txt"))
        vendors = {g["pciId"]: g["vendor"] for g in gpus}
        self.assertEqual(vendors["03:00.0"], "amd")
        self.assertEqual(vendors["00:02.0"], "other")

    def test_collect_amd_uses_sysfs_vram(self):
        run, read, listdir = fake_env(
            cmds={("lspci", "-nn"): fixture("lspci-amd.txt")},
            files={
                "/sys/bus/pci/devices/0000:03:00.0/mem_info_vram_total": "25753026560\n",
                "/proc/meminfo": fixture("meminfo.txt"),
                "/proc/cpuinfo": fixture("cpuinfo.txt"),
            })
        rep = fr.collect(run, read, listdir)
        amd = [g for g in rep["gpus"] if g["vendor"] == "amd"]
        self.assertEqual(len(amd), 1)
        self.assertEqual(amd[0]["vramBytes"], 25753026560)
        self.assertEqual(rep["cpu"], {"model": "AMD EPYC 7763 64-Core Processor", "threads": 2})
        self.assertEqual(rep["memBytes"], 263921456 * 1024)

    def test_collect_with_nothing_available_still_returns_a_report(self):
        rep = fr.collect(*fake_env())
        self.assertEqual(rep["version"], 1)
        self.assertEqual(rep["gpus"], [])
        self.assertIn("no GPU found", " ".join(rep["notes"]))
        json.dumps(rep)

    def test_collect_nvidia_smi_failing_falls_back_to_lspci(self):
        lspci = "01:00.0 3D controller [0302]: NVIDIA Corporation GB202 [10de:2bb1] (rev a1)\n"
        rep = fr.collect(*fake_env(cmds={("lspci", "-nn"): lspci}))
        self.assertEqual(rep["gpus"][0]["vendor"], "nvidia")
        self.assertEqual(rep["gpus"][0]["vramBytes"], 0)
        self.assertIn("driver", " ".join(rep["notes"]))

    def test_disks_skip_virtual_and_nics_skip_loopback(self):
        run, read, listdir = fake_env(
            dirs={"/sys/block": ["nvme0n1", "loop0", "zram0", "sda"],
                  "/sys/class/net": ["lo", "eno1", "docker0", "veth12"]},
            files={
                "/sys/block/nvme0n1/size": "1000215216\n", "/sys/block/nvme0n1/queue/rotational": "0\n",
                "/sys/block/sda/size": "2000000\n", "/sys/block/sda/queue/rotational": "1\n",
                "/sys/class/net/eno1/speed": "10000\n",
            })
        rep = fr.collect(run, read, listdir)
        self.assertEqual([d["name"] for d in rep["disks"]], ["nvme0n1", "sda"])
        self.assertEqual(rep["disks"][0]["sizeBytes"], 1000215216 * 512)
        self.assertFalse(rep["disks"][0]["rotational"])
        self.assertTrue(rep["disks"][1]["rotational"])
        self.assertEqual(rep["nics"], [{"name": "eno1", "speedMbps": 10000}])

    def test_register_vram_sums_gpus(self):
        self.assertEqual(fr.register_vram({"gpus": [{"vramBytes": 3}, {"vramBytes": 4}]}), 7)
```

- [ ] **Step 3: Run to verify failure**

Run: `python3 -I -m unittest tests.register.test_register 2>&1 | tail -5` (or the discover command from Task 1).
Expected: FAIL with `AttributeError: ... has no attribute 'parse_nvidia_smi'`.

- [ ] **Step 4: Append the implementation**

```python
# ------------------------------------------------------------- collector

VENDORS = {"10de": "nvidia", "1002": "amd"}
LSPCI_GPU = re.compile(
    r"^(\S+) (?:VGA compatible controller|3D controller|Display controller) \[[0-9a-f]{4}\]: "
    r"(.*) \[([0-9a-f]{4}):[0-9a-f]{4}\]")
NVIDIA_QUERY = "index,uuid,name,memory.total,driver_version,pci.bus_id"
SKIP_DISK = ("loop", "ram", "zram", "sr", "fd", "dm-", "md")
SKIP_NIC = ("lo", "docker", "veth", "br-", "virbr", "tailscale")


def default_run(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def default_read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def default_listdir(path):
    try:
        return sorted(os.listdir(path))
    except OSError:
        return []


def parse_nvidia_smi(text):
    gpus = []
    for line in (text or "").splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 6:
            continue
        try:
            index = int(parts[0])
            vram = int(float(parts[3])) * 1024 * 1024
        except ValueError:
            continue
        gpus.append({"vendor": "nvidia", "index": index, "uuid": parts[1], "model": parts[2],
                     "vramBytes": vram, "driver": parts[4], "pciId": parts[5]})
    return gpus


def parse_lspci_gpus(text):
    gpus = []
    for line in (text or "").splitlines():
        m = LSPCI_GPU.match(line)
        if not m:
            continue
        slot, desc, vendor_id = m.groups()
        gpus.append({"vendor": VENDORS.get(vendor_id, "other"), "index": len(gpus), "uuid": "",
                     "model": desc, "vramBytes": 0, "driver": "", "pciId": slot})
    return gpus


def _int(text, default=0):
    try:
        return int((text or "").strip())
    except ValueError:
        return default


def _gpus(run, read, notes):
    smi = parse_nvidia_smi(run(["nvidia-smi", f"--query-gpu={NVIDIA_QUERY}", "--format=csv,noheader,nounits"]))
    seen = parse_lspci_gpus(run(["lspci", "-nn"]))
    gpus = list(smi)
    if not smi:
        gpus += [g for g in seen if g["vendor"] == "nvidia"]
        if any(g["vendor"] == "nvidia" for g in gpus):
            notes.append("NVIDIA card present but nvidia-smi gave nothing: driver not loaded yet")
    for g in seen:
        if g["vendor"] == "amd":
            g["vramBytes"] = _int(read(f"/sys/bus/pci/devices/0000:{g['pciId']}/mem_info_vram_total"))
            gpus.append(g)
    for i, g in enumerate(gpus):
        g["index"] = i
    if not gpus:
        notes.append("no GPU found")
    return gpus


def _disks(read, listdir):
    out = []
    for name in listdir("/sys/block"):
        if name.startswith(SKIP_DISK):
            continue
        sectors = _int(read(f"/sys/block/{name}/size"))
        if not sectors:
            continue
        out.append({"name": name, "sizeBytes": sectors * 512,
                    "rotational": _int(read(f"/sys/block/{name}/queue/rotational")) == 1})
    return out


def _nics(read, listdir):
    out = []
    for name in listdir("/sys/class/net"):
        if name.startswith(SKIP_NIC):
            continue
        speed = _int(read(f"/sys/class/net/{name}/speed"), -1)
        out.append({"name": name, "speedMbps": speed if speed > 0 else None})
    return out


def collect(run=default_run, read=default_read, listdir=default_listdir):
    notes = []
    cpuinfo = read("/proc/cpuinfo") or ""
    models = re.findall(r"^model name\s*:\s*(.+)$", cpuinfo, re.M)
    mem = re.search(r"^MemTotal:\s+(\d+) kB", read("/proc/meminfo") or "", re.M)
    osr = re.search(r'^PRETTY_NAME="?([^"\n]*)"?', read("/etc/os-release") or "", re.M)
    return {
        "version": 1,
        "hostname": (read("/etc/hostname") or socket.gethostname()).strip(),
        "machineId": (read("/etc/machine-id") or "").strip(),
        "role": (read("/etc/fiehnlab/role") or "").strip(),
        "kernel": (read("/proc/sys/kernel/osrelease") or "").strip(),
        "os": osr.group(1) if osr else "",
        "cpu": {"model": models[0] if models else "", "threads": len(models)},
        "memBytes": int(mem.group(1)) * 1024 if mem else 0,
        "disks": _disks(read, listdir),
        "nics": _nics(read, listdir),
        "gpus": _gpus(run, read, notes),
        "notes": notes,
    }


def register_vram(report):
    return sum(g["vramBytes"] for g in report["gpus"])
```

- [ ] **Step 5: Run to verify pass, then commit**

Run: `python3 -I -m unittest discover -s tests/register -v`
Expected: PASS.

```bash
git add autoinstall/files/fiehnlab-register tests/register
git commit -m "feat(register): hardware collector with fixtures"
```

---

### Task 3: Gateway client and enrollment handshake

**Files:**
- Modify: `autoinstall/files/fiehnlab-register`
- Test: `tests/register/test_register.py` (adds `MockGateway`)

**Interfaces:**
- Consumes: `ensure_key`, `public_hex`, `node_id_for`, `sign_hex`, `proof_transcript`, `register_vram`.
- Produces:
  - `class GatewayError(Exception)` with `.status: int|None`
  - `post(base: str, path: str, body: dict, timeout: float = 15) -> dict`
  - `enroll(base: str, key_path: str) -> dict` returning `{"nodeId","credential","expiresAt"}`
  - `register_body(node_id: str, credential: str, report: dict) -> dict`
  - `register(base: str, body: dict) -> dict` returning the gateway's `RegisterResponse`
  - `heartbeat(base: str, node_id: str, connection_id: str) -> dict`

**Dependency note:** `register_body` sends `endpoint: ""`, `deployment: ""`, `models: []` and a `hardware` object. The Rust gateway rejects or ignores some of this until gateway plan step 2 lands (hardware-only registration). The mock below models the post-change behaviour. Verify against a real gateway in Task 6.

- [ ] **Step 1: Add the mock gateway and failing tests**

```python
import http.server, threading, secrets


class MockGateway:
    """Implements the Rust node protocol shapes; verifies signatures with openssl."""

    def __init__(self):
        self.keys, self.challenges, self.creds = {}, {}, {}
        self.registered, self.heartbeats = [], []
        self.fail_status = None  # force every request to this status
        self.calls = []
        mock = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                mock.calls.append((self.path, body))
                if mock.fail_status:
                    return self.reply(mock.fail_status, {"error": {"code": "forced"}})
                status, out = mock.handle(self.path, body)
                self.reply(status, out)

            def reply(self, status, out):
                data = json.dumps(out).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()

    def handle(self, path, b):
        if path == "/v1/node/key":
            self.keys[b["nodeId"]] = b["publicKey"]
            return 200, {"status": "ok"}
        if path == "/v1/node/challenge":
            cid = secrets.token_hex(8)
            claim = {"role": b["role"], "model": None, "contextClass": None, "resourceClaim": None}
            self.challenges[cid] = (b["nodeId"], 42, claim)
            return 200, {"challengeId": cid, "nonce": 42, "claim": claim, "expiresAt": 9999999999}
        if path == "/v1/node/proof":
            node, nonce, claim = self.challenges[b["challengeId"]]
            if b["claim"] != claim:
                return 401, {"error": {"code": "claim_mismatch"}}
            msg = fr.proof_transcript(b["challengeId"], nonce, claim)
            if not openssl_verify(self.keys[node], msg, b["signature"]):
                return 401, {"error": {"code": "bad_signature"}}
            cred = secrets.token_hex(16)
            self.creds[cred] = node
            return 200, {"nodeId": node, "role": claim["role"], "credential": cred, "expiresAt": 9999999999}
        if path == "/v1/node/register":
            if self.creds.get(b["credential"]) != b["nodeId"]:
                return 401, {"error": {"code": "unauthorized"}}
            self.registered.append(b)
            return 200, {"nodeId": b["nodeId"], "connectionId": f"conn-{len(self.registered)}",
                         "freshnessTtlSecs": 30, "capabilities": []}
        if path == "/v1/node/heartbeat":
            if not b["connectionId"].startswith("conn-"):
                return 404, {"error": {"code": "unknown_connection"}}
            self.heartbeats.append(b)
            return 200, {"status": "ok"}
        return 404, {}


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.key = os.path.join(self.tmp.name, "node-key")
        fr.ensure_key(self.key)
        self.gw = MockGateway()

    def tearDown(self):
        self.gw.stop()
        self.tmp.cleanup()

    def report(self):
        return fr.collect(*fake_env())

    def test_enroll_earns_a_credential_without_any_token(self):
        cred = fr.enroll(self.gw.url, self.key)
        self.assertEqual(cred["nodeId"], fr.node_id_for(fr.public_hex(self.key)))
        self.assertTrue(cred["credential"])
        self.assertEqual([p for p, _ in self.gw.calls],
                         ["/v1/node/key", "/v1/node/challenge", "/v1/node/proof"])

    def test_register_body_carries_hardware_and_no_endpoint(self):
        cred = fr.enroll(self.gw.url, self.key)
        body = fr.register_body(cred["nodeId"], cred["credential"], self.report())
        self.assertEqual(body["role"], "node")
        self.assertEqual(body["models"], [])
        self.assertEqual(body["endpoint"], "")
        self.assertEqual(body["hardware"]["version"], 1)
        resp = fr.register(self.gw.url, body)
        self.assertEqual(resp["connectionId"], "conn-1")
        fr.heartbeat(self.gw.url, cred["nodeId"], resp["connectionId"])
        self.assertEqual(self.gw.heartbeats[0]["status"],
                         {"busySlots": 0, "queueDepth": 0, "residentModels": []})

    def test_http_errors_become_gateway_errors_with_status(self):
        self.gw.fail_status = 503
        with self.assertRaises(fr.GatewayError) as cm:
            fr.enroll(self.gw.url, self.key)
        self.assertEqual(cm.exception.status, 503)

    def test_unreachable_gateway_is_a_gateway_error_without_status(self):
        with self.assertRaises(fr.GatewayError) as cm:
            fr.post("http://127.0.0.1:9", "/v1/node/key", {}, timeout=1)
        self.assertIsNone(cm.exception.status)
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -I -m unittest discover -s tests/register -v`
Expected: FAIL (`AttributeError: ... 'enroll'`).

- [ ] **Step 3: Append the implementation**

```python
# ---------------------------------------------------------------- client


class GatewayError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def post(base, path, body, timeout=15):
    data = json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        raise GatewayError(f"{path}: HTTP {e.code}", e.code) from e
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise GatewayError(f"{path}: {e}") from e


def enroll(base, key_path):
    pub = public_hex(key_path)
    node_id = node_id_for(pub)
    post(base, "/v1/node/key", {"nodeId": node_id, "publicKey": pub})
    ch = post(base, "/v1/node/challenge", {"nodeId": node_id, "role": ROLE})
    sig = sign_hex(key_path, proof_transcript(ch["challengeId"], ch["nonce"], ch["claim"]))
    return post(base, "/v1/node/proof", {"nodeId": node_id, "challengeId": ch["challengeId"],
                                         "claim": ch["claim"], "signature": sig})


def register_body(node_id, credential, report):
    gpus = report["gpus"]
    return {
        "nodeId": node_id, "role": ROLE, "credential": credential,
        "endpoint": "", "models": [], "deployment": "",
        "vramBytes": register_vram(report), "kvBytes": 0, "kvBytesPerToken": 0,
        "gpuIds": [f"gpu{g['index']}" for g in gpus],
        "card": gpus[0]["model"] if gpus else None,
        "capabilities": [], "hardware": report,
    }


def register(base, body):
    return post(base, "/v1/node/register", body)


def heartbeat(base, node_id, connection_id):
    return post(base, "/v1/node/heartbeat", {
        "nodeId": node_id, "connectionId": connection_id,
        "status": {"busySlots": 0, "queueDepth": 0, "residentModels": []}})
```

- [ ] **Step 4: Run to verify pass, then commit**

Run: `python3 -I -m unittest discover -s tests/register -v`
Expected: PASS.

```bash
git add autoinstall/files/fiehnlab-register tests/register/test_register.py
git commit -m "feat(register): tokenless enrollment, register and heartbeat client"
```

---

### Task 4: Per-gateway worker, config parsing, main loop

**Files:**
- Modify: `autoinstall/files/fiehnlab-register`
- Test: `tests/register/test_register.py`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `parse_gateways(text: str) -> list[str]`
  - `class Worker(url, key_path, state_dir, get_report, log, clock=time.monotonic)` with `step() -> float` (seconds to sleep) and attributes `registered: bool`
  - `main(argv=None) -> int`
- State file: `<state_dir>/gateways/<sha256(url)[:12]>.json` = `{"credential","nodeId"}`, mode 0600.

- [ ] **Step 1: Write the failing tests**

```python
class ParseGatewaysTests(unittest.TestCase):
    def test_cleans_the_list(self):
        text = """
        # comment
        https://llm.metabolomics.us/
        https://a.example/v1 , https://llm.metabolomics.us

        https://b.example:8080//
        """
        self.assertEqual(fr.parse_gateways(text),
                         ["https://llm.metabolomics.us", "https://a.example", "https://b.example:8080"])

    def test_empty_is_empty(self):
        self.assertEqual(fr.parse_gateways(""), [])


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.key = os.path.join(self.tmp.name, "node-key")
        fr.ensure_key(self.key)
        self.gw = MockGateway()
        self.lines = []
        self.report = fr.collect(*fake_env())

    def tearDown(self):
        self.gw.stop()
        self.tmp.cleanup()

    def worker(self, url=None):
        return fr.Worker(url or self.gw.url, self.key, self.tmp.name,
                         lambda: self.report, self.lines.append)

    def test_first_step_enrolls_and_registers_then_heartbeats(self):
        w = self.worker()
        w.step()
        self.assertTrue(w.registered)
        self.assertEqual(len(self.gw.registered), 1)
        w.step()
        self.assertEqual(len(self.gw.registered), 1, "unchanged hardware is not re-registered")
        self.assertEqual(len(self.gw.heartbeats), 1)
        self.assertTrue(any(l.startswith("OK:") for l in self.lines))

    def test_changed_hardware_re_registers(self):
        w = self.worker()
        w.step()
        self.report = dict(self.report, memBytes=self.report["memBytes"] + 1)
        w.step()
        self.assertEqual(len(self.gw.registered), 2)

    def test_credential_is_reused_across_restarts(self):
        self.worker().step()
        self.gw.calls.clear()
        self.worker().step()
        self.assertNotIn("/v1/node/key", [p for p, _ in self.gw.calls])

    def test_rejected_credential_re_enrolls(self):
        w = self.worker()
        w.step()
        self.gw.creds.clear()  # gateway forgot us
        self.report = dict(self.report, memBytes=1)
        w.step()           # register -> 401, credential dropped
        w.step()           # re-enroll + register
        self.assertTrue(w.registered)
        self.assertEqual(len(self.gw.registered), 2)

    def test_unknown_connection_re_registers(self):
        w = self.worker()
        w.step()
        w.connection_id = "gone"
        w.step()           # heartbeat 404 -> mark unregistered
        w.step()
        self.assertEqual(len(self.gw.registered), 2)

    def test_failure_backs_off_and_logs_failed(self):
        self.gw.fail_status = 503
        w = self.worker()
        first = w.step()
        second = w.step()
        self.assertFalse(w.registered)
        self.assertGreater(second, first)
        self.assertLessEqual(second, 300)
        self.assertTrue(any(l.startswith("FAILED:") for l in self.lines))

    def test_one_dead_gateway_does_not_block_another(self):
        dead = self.worker("http://127.0.0.1:9")
        live = self.worker()
        dead.step()
        live.step()
        self.assertFalse(dead.registered)
        self.assertTrue(live.registered)
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 -I -m unittest discover -s tests/register -v`
Expected: FAIL (`AttributeError: ... 'parse_gateways'`).

- [ ] **Step 3: Append the implementation**

```python
# ---------------------------------------------------------------- worker

BACKOFF_START = 5.0
BACKOFF_MAX = 300.0
REPORT_TTL = 300.0


def parse_gateways(text):
    urls = []
    for line in (text or "").splitlines():
        line = line.split("#", 1)[0]
        for item in line.split(","):
            url = item.strip().rstrip("/")
            if url.endswith("/v1"):
                url = url[:-3].rstrip("/")
            if url and url not in urls:
                urls.append(url)
    return urls


def _report_hash(report):
    return hashlib.sha256(json.dumps(report, sort_keys=True).encode()).hexdigest()


class Worker:
    """One gateway. step() does the next useful thing and returns seconds to sleep."""

    def __init__(self, url, key_path, state_dir, get_report, log):
        self.url, self.key_path, self.log, self.get_report = url, key_path, log, get_report
        d = os.path.join(state_dir, "gateways")
        os.makedirs(d, mode=0o700, exist_ok=True)
        self.state_path = os.path.join(d, hashlib.sha256(url.encode()).hexdigest()[:12] + ".json")
        self.node_id = node_id_for(public_hex(key_path))
        self.credential = self._load()
        self.registered = False
        self.connection_id = None
        self.registered_hash = None
        self.interval = 10.0
        self.backoff = BACKOFF_START

    def _load(self):
        try:
            with open(self.state_path) as f:
                saved = json.load(f)
            return saved["credential"] if saved.get("nodeId") == self.node_id else None
        except (OSError, ValueError, KeyError):
            return None

    def _save(self):
        fd = os.open(self.state_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"nodeId": self.node_id, "credential": self.credential}, f)

    def _forget_credential(self):
        self.credential = None
        self.registered = False
        try:
            os.remove(self.state_path)
        except OSError:
            pass

    def step(self):
        try:
            if not self.credential:
                cred = enroll(self.url, self.key_path)
                self.credential = cred["credential"]
                self._save()
                self.log(f"OK: enrolled {self.node_id} with {self.url}")
            report = self.get_report()
            digest = _report_hash(report)
            if not self.registered or digest != self.registered_hash:
                resp = register(self.url, register_body(self.node_id, self.credential, report))
                self.connection_id = resp["connectionId"]
                self.interval = max(5.0, float(resp.get("freshnessTtlSecs", 30)) / 3)
                self.registered, self.registered_hash = True, digest
                self.log(f"OK: registered {self.node_id} with {self.url}"
                         f" ({len(report['gpus'])} GPU(s))")
            else:
                heartbeat(self.url, self.node_id, self.connection_id)
            self.backoff = BACKOFF_START
            return self.interval
        except GatewayError as e:
            if e.status in (401, 403):
                self._forget_credential()
            elif e.status == 404:
                self.registered = False
            self.log(f"FAILED: {self.url}: {e}")
        except (KeyError, ValueError, subprocess.SubprocessError, OSError) as e:
            self.log(f"FAILED: {self.url}: unexpected {type(e).__name__}: {e}")
        wait = self.backoff
        self.backoff = min(self.backoff * 2, BACKOFF_MAX)
        return wait


# ------------------------------------------------------------------ main


def make_logger(path):
    lock = threading.Lock()

    def log(line):
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        text = f"{stamp} fiehnlab-register {line}"
        with lock:
            print(text, flush=True)
            try:
                with open(path, "a") as f:
                    f.write(text + "\n")
            except OSError:
                pass

    return log


class ReportCache:
    def __init__(self):
        self.lock, self.value, self.at = threading.Lock(), None, 0.0

    def get(self):
        with self.lock:
            if self.value is None or time.monotonic() - self.at > REPORT_TTL:
                self.value, self.at = collect(), time.monotonic()
            return self.value


def run_worker(worker, stop):
    while not stop.is_set():
        stop.wait(worker.step())


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--gateways-file", default="/etc/fiehnlab/gateways")
    ap.add_argument("--state-dir", default="/var/lib/fiehnlab")
    ap.add_argument("--log-file", default="/var/log/fiehnlab-provision.log")
    ap.add_argument("--once", action="store_true",
                    help="one pass over every gateway, exit 0 only if all registered")
    args = ap.parse_args(argv)
    log = make_logger(args.log_file)

    try:
        with open(args.gateways_file) as f:
            urls = parse_gateways(f.read())
    except OSError as e:
        log(f"FAILED: cannot read {args.gateways_file}: {e}")
        return 2
    if not urls:
        log(f"FAILED: no gateways listed in {args.gateways_file}")
        return 2

    key_path = os.path.join(args.state_dir, "node-key")
    existed = os.path.exists(key_path)
    ensure_key(key_path)
    log(f"{'using existing' if existed else 'generated new'} identity "
        f"{node_id_for(public_hex(key_path))}")

    cache = ReportCache()
    workers = [Worker(u, key_path, args.state_dir, cache.get, log) for u in urls]
    if args.once:
        for w in workers:
            w.step()
        return 0 if all(w.registered for w in workers) else 1

    stop = threading.Event()
    threads = [threading.Thread(target=run_worker, args=(w, stop), daemon=True) for w in workers]
    for t in threads:
        t.start()
    try:
        for t in threads:
            t.join()
    except KeyboardInterrupt:
        stop.set()
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run to verify pass**

Run: `python3 -I -m unittest discover -s tests/register -v`
Expected: PASS (all tests).

- [ ] **Step 5: Add and run an end-to-end CLI test, then commit**

```python
class CliTests(unittest.TestCase):
    def test_once_registers_with_two_gateways_one_down(self):
        gw = MockGateway()
        with tempfile.TemporaryDirectory() as d:
            gfile = os.path.join(d, "gateways")
            open(gfile, "w").write(f"{gw.url}\nhttp://127.0.0.1:9\n")
            rc = fr.main(["--gateways-file", gfile, "--state-dir", d,
                          "--log-file", os.path.join(d, "log"), "--once"])
            self.assertEqual(rc, 1, "one gateway is down, so not all registered")
            self.assertEqual(len(gw.registered), 1)
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(d, "node-key")).st_mode), 0o600)
            self.assertIn("OK: registered", open(os.path.join(d, "log")).read())
        gw.stop()
```

Run: `python3 -I -m unittest discover -s tests/register -v` — Expected: PASS.

```bash
git add autoinstall/files/fiehnlab-register tests/register/test_register.py
git commit -m "feat(register): per-gateway worker with backoff and re-enrollment"
```

---

### Task 5: Seed, forge-stick and docs wiring

**Files:**
- Modify: `autoinstall/gpu-node.user-data.tmpl` (write_files + runcmd)
- Modify: `stick/forge-stick.sh:45-50,111-122`
- Create: `tests/test_render.sh`
- Modify: `stick/README.md`, `docs/systems/gpu-node.md`

**Interfaces:**
- Consumes: `autoinstall/files/fiehnlab-register`.
- Produces: rendered `gpu-node-user-data` containing the agent (cloud-init `encoding: b64`), `/etc/fiehnlab/gateways`, `fiehnlab-register.service` enabled.

- [ ] **Step 1: Write the failing render test**

```bash
#!/usr/bin/env bash
# tests/test_render.sh — render the stick seeds with dummy values and inspect the gpu-node one.
set -euo pipefail
cd "$(dirname "$0")/.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export STICK_STAGING="$T" STICK_SECRETS_ENV=/dev/null
export PRIMARY_USER=tester USER_PW_HASH='$6$x$y' SSH_AUTHORIZED_KEY='ssh-ed25519 AAAA test'
fail(){ echo "FAIL: $*" >&2; exit 1; }

stick/forge-stick.sh render >/dev/null
S="$T/seeds/gpu-node-user-data"
grep -q '@@' "$S" && fail "unresolved placeholder in rendered seed"
grep -q 'fiehnlab-register.service' "$S" || fail "service missing"
grep -q 'https://llm.metabolomics.us' "$S" || fail "default gateway missing"

# The embedded agent must round-trip byte for byte and still be valid Python.
python3 - "$S" <<'PY'
import base64, re, sys, hashlib
seed = open(sys.argv[1]).read()
m = re.search(r"path: /usr/local/sbin/fiehnlab-register\n\s+permissions: \"0755\"\n\s+encoding: b64\n\s+content: (\S+)", seed)
assert m, "agent write_files entry not found"
got = base64.b64decode(m.group(1))
want = open("autoinstall/files/fiehnlab-register", "rb").read()
assert got == want, "embedded agent differs from source"
compile(got.decode(), "fiehnlab-register", "exec")
PY

# An overridden list is honoured and an unresolved digit placeholder is caught.
NODE_GATEWAYS='https://a.example,https://b.example' stick/forge-stick.sh render >/dev/null
grep -q 'https://b.example' "$T/seeds/gpu-node-user-data" || fail "NODE_GATEWAYS override ignored"
echo "PASS"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_render.sh`
Expected: `FAIL: service missing`.

- [ ] **Step 3: Edit `forge-stick.sh`**

In `load_config`, after the `LLM_GATEWAY_URL` default line add:
```bash
  : "${NODE_GATEWAYS:=https://llm.metabolomics.us}"   # comma-separated InferWeave gateways a gpu-node registers with
```
In `cmd_render`, before the `sed` call add:
```bash
    local agent_b64; agent_b64="$(base64 -w0 "$PROVISION/autoinstall/files/fiehnlab-register")"
```
Add two `-e` lines to the `sed`:
```bash
        -e "s|@@NODE_GATEWAYS@@|$NODE_GATEWAYS|g" \
        -e "s|@@REGISTER_AGENT_B64@@|$agent_b64|g" \
```
Change both placeholder checks from `@@[A-Z_]+@@` to `@@[A-Z0-9_]+@@`.

- [ ] **Step 4: Edit `gpu-node.user-data.tmpl`**

Add to `write_files` (next to the other `/usr/local/sbin` entries):
```yaml
      - path: /usr/local/sbin/fiehnlab-register
        permissions: "0755"
        encoding: b64
        content: @@REGISTER_AGENT_B64@@
      - path: /etc/fiehnlab/gateways
        permissions: "0644"
        content: |
          # InferWeave gateways this node registers with (comma or newline separated).
          # Edit and `systemctl restart fiehnlab-register` to change.
          @@NODE_GATEWAYS@@
      - path: /etc/systemd/system/fiehnlab-register.service
        content: |
          [Unit]
          Description=Register this node and its hardware with InferWeave gateways
          After=network-online.target fiehnlab-gpu-container.service
          Wants=network-online.target
          [Service]
          ExecStart=/usr/local/sbin/fiehnlab-register
          Restart=always
          RestartSec=30
          [Install]
          WantedBy=multi-user.target
```
Add to `runcmd`:
```yaml
      - [ systemctl, enable, fiehnlab-register.service ]
```

- [ ] **Step 5: Run to verify pass**

Run: `bash tests/test_render.sh && python3 -I -m unittest discover -s tests/register`
Expected: `PASS` and all unit tests passing. Also run `shellcheck stick/forge-stick.sh tests/test_render.sh` if installed.

- [ ] **Step 6: Document**

`docs/systems/gpu-node.md`: add a "Registers with InferWeave" subsection under "GPU & containers" describing the service, `/etc/fiehnlab/gateways`, the identity at `/var/lib/fiehnlab/node-key`, that nothing is served until a gateway assigns work, and `journalctl -u fiehnlab-register`.
`stick/README.md`: document `NODE_GATEWAYS` next to `LLM_GATEWAY_URL` in the render values.

- [ ] **Step 7: Commit**

```bash
git add autoinstall stick tests docs
git commit -m "feat(gpu-node): register with InferWeave gateways on first boot"
```

---

### Task 6: Verify against real gateways and the installed image

**Files:** none (verification only; record results in `docs/systems/gpu-node.md` if something differs).

- [ ] **Step 1: Against the Rust gateway.** Start a gateway from `inferweave/inferweave` locally (see its README "Start a gateway with an empty catalog"), then run:
`python3 autoinstall/files/fiehnlab-register --gateways-file <(echo http://127.0.0.1:8080) --state-dir $(mktemp -d) --log-file /dev/null --once`
Expected: `OK: enrolled` then `OK: registered`, exit 0. If `/register` is refused for empty `models`, `endpoint` or `deployment`, that is gateway plan step 2 (hardware-only registration) not yet landed: record the exact error and stop.

- [ ] **Step 2: Against the in-house Go gateway.** Same command with its URL. Expected before its conformance plan lands: `FAILED` naming `/v1/node/key` HTTP 404. That is the signal the Go plan is needed, not an agent bug.

- [ ] **Step 3: QEMU autoinstall.** Build the stick, boot the `gpu-node` seed in QEMU (technique in `live-rescue/README.md`) with a mock gateway on the host, and confirm `systemctl is-active fiehnlab-register`, the identity file mode 0600, and a registration at the mock.

- [ ] **Step 4: Real node.** Install one GPU node from the stick; confirm its hardware report appears at the gateway.

---

## Self-Review

- **Spec coverage:** identity and key handling (T1), hardware report (T2), tokenless enrollment + register + heartbeat (T3), several gateways independently with backoff and re-enrollment (T4), `/etc/fiehnlab/gateways`, `NODE_GATEWAYS` default `https://llm.metabolomics.us`, systemd ordering, docs (T5), QEMU and both-gateway verification (T6). Spec §1 (protocol field), §2 (Go conformance) are other repos' plans and are listed as dependencies.
- **Placeholders:** none; the only open item is the explicit gateway dependency in Task 3 and Task 6.
- **Types:** `Worker(url, key_path, state_dir, get_report, log)`, `collect(run, read, listdir)`, `register_body(node_id, credential, report)` and the report keys match across tasks and tests.
- **Review Focus:** no-GPU (T2), one-gateway-down (T4), URL list cleanup (T4), 401/404 recovery (T4), hardware change and no-change (T4), key permissions and identity logging (T1, T4), placeholder regex with digits (T5).
