#!/usr/bin/env python3
"""Count the blocks a validator signed / missed over the last N blocks.

Usage:
    check-missed-blocks.py <validator-address> [--blocks N] [--rpc URL]
"""

import argparse

import requests

DEFAULT_RPC = "https://rpc.mainnet.samourai.live"
DEFAULT_BLOCKS = 500


def parse_args():
    parser = argparse.ArgumentParser(
        description="Count signed/missed blocks for a gnoland validator."
    )
    parser.add_argument(
        "validator",
        help="validator address (g1...)",
    )
    parser.add_argument(
        "-n", "--blocks",
        type=int,
        default=DEFAULT_BLOCKS,
        help=f"analysis window, in blocks (default: {DEFAULT_BLOCKS})",
    )
    parser.add_argument(
        "--rpc",
        default=DEFAULT_RPC,
        help=f"gnoland RPC endpoint (default: {DEFAULT_RPC})",
    )
    args = parser.parse_args()
    if args.blocks < 1:
        parser.error("--blocks must be >= 1")
    args.rpc = args.rpc.rstrip("/")
    return args


def get_json(rpc, path, params=None):
    r = requests.get(f"{rpc}{path}", params=params, timeout=10)
    r.raise_for_status()
    return r.json()["result"]


def main():
    args = parse_args()

    print(f"Validator: {args.validator}")
    print(f"RPC      : {args.rpc}")

    # Current height
    status = get_json(args.rpc, "/status")
    latest_height = int(status["sync_info"]["latest_block_height"])

    # Height H can only be checked once H+1 exists.
    last_checkable_height = latest_height - 1
    start_height = max(1, last_checkable_height - args.blocks + 1)

    print(f"Latest height     : {latest_height}")
    print(f"Checking blocks   : {start_height} -> {last_checkable_height}")
    print()

    missed = []
    signed = 0
    errors = []

    # The commit for block H lives in the last_commit of block H+1.
    for height in range(start_height, last_checkable_height + 1):
        try:
            block = get_json(args.rpc, "/block", {"height": height + 1})

            last_commit = block["block"].get("last_commit") or {}
            sigs = last_commit.get("precommits") or []

            found = False

            for sig in sigs:
                if not sig:
                    continue

                # Extra safety: the precommit must really be for height H.
                sig_height = int(sig.get("height", 0))
                addr = sig.get("validator_address")
                signature = sig.get("signature")

                if (
                    sig_height == height
                    and addr == args.validator
                    and signature
                ):
                    found = True
                    break

            if found:
                signed += 1
            else:
                missed.append(height)
                print(f"MISSED: {height}")

        except Exception as e:
            errors.append(height)
            print(f"ERROR block {height}: {e}")

    checked = signed + len(missed)

    print()
    print("===== RESULT =====")
    print(f"Checked : {checked}")
    print(f"Signed  : {signed}")
    print(f"Missed  : {len(missed)}")
    print(f"Errors  : {len(errors)}")

    if checked:
        uptime = signed / checked * 100
        print(f"Uptime  : {uptime:.3f}%")

    if missed:
        print()
        print("Missed blocks:")
        print(", ".join(map(str, missed)))

    if errors:
        print()
        print("Blocks not checked because of errors:")
        print(", ".join(map(str, errors)))


if __name__ == "__main__":
    main()
