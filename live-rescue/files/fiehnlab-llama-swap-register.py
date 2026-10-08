#!/usr/bin/env python3
"""Register (or replace) one model entry in /etc/llama-swap/config.yaml.

Shared by fiehnlab-pull-model and fiehnlab-models so both write the exact
same shape of entry. llama-swap runs with -watch-config (the CLI default,
see llama-swap.service) so saving this file is enough to pick the model up
- no reload command needed.

Usage: fiehnlab-llama-swap-register.py <name> <gguf-path> [--embeddings] [--ctx N]
"""
import argparse
import os
import sys

import yaml

CONFIG = "/etc/llama-swap/config.yaml"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("name", help="model id clients will request, e.g. --model <name>")
    ap.add_argument("gguf_path", help="absolute path to the .gguf file")
    ap.add_argument("--embeddings", action="store_true", help="serve as an embeddings model")
    ap.add_argument("--ctx", type=int, default=8192)
    args = ap.parse_args()

    if not os.path.isfile(args.gguf_path):
        print(f"ERROR: {args.gguf_path} does not exist", file=sys.stderr)
        return 1

    try:
        with open(CONFIG, "r") as f:
            cfg = yaml.safe_load(f) or {}
    except FileNotFoundError:
        cfg = {}

    cfg.setdefault("models", {})
    cmd = (
        "/usr/local/bin/fiehnlab-llama llama-server --port ${PORT} "
        f"--alias {args.name} -m {args.gguf_path} -c {args.ctx}"
    )
    if args.embeddings:
        cmd += " --embeddings"
    else:
        cmd += " -np 1 --reasoning off"

    cfg["models"][args.name] = {"cmd": cmd, "ttl": 1800}

    tmp = CONFIG + ".tmp"
    with open(tmp, "w") as f:
        yaml.safe_dump(cfg, f, sort_keys=False)
    os.replace(tmp, CONFIG)
    print(f"OK: registered '{args.name}' -> {args.gguf_path} in {CONFIG} (llama-swap will pick it up automatically)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
