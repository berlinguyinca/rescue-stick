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
        with open(pub, "wb") as f:
            f.write(SPKI_ED25519_PREFIX + bytes.fromhex(pub_hex))
        with open(msg, "wb") as f:
            f.write(message)
        with open(sig, "wb") as f:
            f.write(bytes.fromhex(sig_hex))
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
        with open(self.key) as f:
            first = f.read()
        fr.ensure_key(self.key)
        with open(self.key) as f:
            self.assertEqual(first, f.read(), "an existing key is never replaced")

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



FIX = os.path.join(HERE, "fixtures")


def fixture(name):
    with open(os.path.join(FIX, name)) as f:
        return f.read()


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


if __name__ == "__main__":
    unittest.main()
