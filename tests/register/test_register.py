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
