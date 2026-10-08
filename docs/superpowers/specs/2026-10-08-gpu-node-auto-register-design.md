# gpu-node auto-registration with InferWeave gateways

- **Date:** 2026-10-08 (revised after review)
- **Status:** draft, awaiting review
- **Repos:** `rescue-stick` (node agent), `inferweave/inferweave` (protocol, canonical),
  `metabolomics-us/inferweave-gateway` (in-house Go gateway, must conform)

## Goal

A GPU node installed from the stick registers itself with every configured
InferWeave gateway, with no manual step, and advertises the hardware it has.
For now that is all. Later the gateway tells the node which images to
download and which profile to run.

## Decisions (from review, 2026-10-08)

1. **`inferweave/inferweave` defines the protocol.** The in-house gateway
   (`metabolomics-us/inferweave-gateway`) is a different implementation and
   must be protocol-identical, so that any node works against either.
   No gateway-specific endpoint is invented for the stick.
2. **Gateways trust registering nodes.** Enrollment uses the existing
   tokenless proof path (`/v1/node/key`, `/challenge`, `/proof`). No code,
   token or secret is placed on the stick.
3. **A node may register with several gateways.** The stick configures a
   list, and the agent registers with each independently.
4. **Default gateway list is `https://llm.metabolomics.us`**, overridden at
   build time by `LLM_GATEWAY_URL` (comma-separated) and on the node by
   `/etc/fiehnlab/gateways`.

Tension noted: the peer-trust spec argues token-free enrolment makes bans easy
to evade. Open registration accepts that. The Ed25519 identity keeps
quarantine and revocation by key working, and a newly registered node gets
the lowest trust tier.

## Non-goals

- Pulling images or choosing profiles (a later, gateway-driven step).
- Serving models. The node reports hardware only.
- The rescue-os live ISO.

## Findings that shape the design

- Rust already has tokenless enrollment: `/v1/node/key` (register a public
  key), `/v1/node/challenge`, `/v1/node/proof` (returns the credential).
- Rust `/v1/node/register` already takes `vram_bytes`, `kv_bytes`, `gpu_ids`
  and `card`, and follows an additive-optional-field convention (older nodes
  keep joining). It does not carry CPU, RAM, disks or NICs.
- Go routes only `enroll`, `enroll-code`, `register`, `heartbeat`. It lacks
  `/key`, `/challenge` and `/proof`.

## Design

### 1. Protocol changes (inferweave/inferweave, then specs)

- Add one optional field to `RegisterRequest`: `hardware`, a versioned object
  with CPU model and threads, RAM, disks, NICs, kernel/OS, and per-GPU
  vendor, UUID, PCI id, driver and CUDA/ROCm version. Absent means an older
  node, as with `card` today.
- Allow a registration that serves no models yet (`models: []`) and
  advertises no data-plane endpoint, so a hardware-only node can register.
  To be confirmed against current validation, including `endpoint` and
  `deployment`, which are required today.
- Reserve `assignments` in the register/heartbeat response for the later
  image/profile instructions. Always empty for now.
- A node that has registered but serves nothing is never routed to.
- `InferWeave/inferweave-specs` is authoritative, so the field and the
  empty-models rule are specified there first (or in lockstep) and covered by
  `conformance/` vectors that both gateways must pass.

### 2. Go gateway conformance (metabolomics-us/inferweave-gateway)

- Implement `POST /v1/node/key`, `/challenge`, `/proof` with the same wire
  shapes, and tokenless proof enrollment.
- Accept the `hardware` field and empty-model registrations, store them and
  show them in the console.
- Pass the shared conformance vectors. Passing them is the definition of
  "protocol identical" here.

### 3. Node agent `fiehnlab-register` (rescue-stick)

- Installed by the `gpu-node` autoinstall with a `fiehnlab-register.service`,
  ordered after `fiehnlab-gpu-container.service` and `network-online.target`.
- Identity: an Ed25519 keypair generated on first run in
  `/var/lib/fiehnlab/node-key` (0600 root). One identity, used for every
  gateway.
- For each URL in `/etc/fiehnlab/gateways`, independently: `/key`,
  `/challenge`, `/proof`, store that gateway's credential, then
  `/register` with the hardware report, then `/heartbeat` on the interval the
  gateway returns.
- Re-registers when the hardware report changes. Retries with capped backoff
  and never exits on network failure. One gateway being down does not delay
  another.
- Logs `OK`/`FAILED` per gateway to `/var/log/fiehnlab-provision.log`.
- Language: Python 3 with the standard library; Ed25519 via `openssl pkeyutl`
  so the stick adds no pip dependency.

### 4. Build-time wiring (rescue-stick)

- `stick/forge-stick.sh` renders the gateway list into the gpu-node seed;
  default `https://llm.metabolomics.us` (replacing the `llm.example.com/v1`
  placeholder).
- `autoinstall/gpu-node.user-data.tmpl` installs the agent, unit and
  `/etc/fiehnlab/gateways`, and enables the unit.
- `docs/systems/gpu-node.md` documents it.

## Failure handling

| Failure | Behaviour |
|---|---|
| A gateway unreachable | Retry that gateway with backoff; the others proceed |
| Gateway lacks the tokenless path | Log FAILED naming the missing route; keep retrying |
| No GPU found | Register with `gpus: []` and a note, so the gap is visible |
| Key file lost | New identity, new records; old ones age out |
| Clock far off | Gateway rejects stale proofs; the agent logs the skew |

## Testing

- Collector: fixtures for `nvidia-smi`, `rocm-smi`, `lspci`, `/proc`
  (NVIDIA, AMD-only, no-GPU).
- Signing and the enrollment handshake against a Rust gateway test instance.
- Agent: first registration, change detection, retry, two gateways with one
  down.
- Both gateways pass the new conformance vectors.
- QEMU autoinstall of the gpu-node image against a mock gateway.

## Build order

1. Spec the `hardware` field and hardware-only registration in
   inferweave-specs and add conformance vectors.
2. Rust gateway: field and empty-model support.
3. Go gateway: `/key`, `/challenge`, `/proof`, field, empty-model support.
4. Node agent and stick wiring, tested against the Rust gateway.
5. QEMU end to end, then a real node, against both gateways.
