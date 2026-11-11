#!/usr/bin/env python3
"""The accounts prefilled before anything is measured, and the search that chose them.

fvm-anvil keeps EVM storage in a KAMT keyed on the unhashed big-endian slot, five bits per
level, one entry per bucket. A contract whose tree is nearly empty charges a measured write
for a short walk no deployed contract would enjoy, so the benchmark prefills accounts first.
Two levels of five bits is 1024 buckets; BALLAST_ACCOUNTS fills each of them equally, so no
measured slot is cheaper or dearer than another for where keccak happened to put it.

Which owners land in which bucket is keccak's business, so finding a set that covers every
bucket takes several times more candidates than it keeps. Run this module to do that search
and record the result in OWNERS; the benchmark reads it and never searches again.
"""

from __future__ import annotations

import itertools
import sys
from pathlib import Path

from keccak import keccak256

OWNERS = Path(__file__).resolve().parent / "ballast.txt"
PREFIX_BITS = 10
BALLAST_ACCOUNTS = 2048
# one account per bucket per copy; the balance is what a plain 1 FIL deposit leaves behind
BUCKETS = 1 << PREFIX_BITS
PER_BUCKET = BALLAST_ACCOUNTS // BUCKETS
BALANCE = 10**18


def slot(owner: int, token: int = 0) -> int:
    """Slot of users[owner].accounts[token].latest.

    `users` is the contract's only state variable, and `User.accounts` and `Account.latest`
    both start at offset 0, so the mapping hashes nest with no offset to add.
    """
    user = keccak256(owner.to_bytes(32, "big") + bytes(32))
    return int.from_bytes(keccak256(token.to_bytes(32, "big") + user), "big")


def bucket(slot: int) -> int:
    return slot >> (256 - PREFIX_BITS)


def search() -> list[int]:
    """Consecutive integers read as addresses, kept until every bucket holds PER_BUCKET."""
    found: dict[int, list[int]] = {}
    complete = 0
    for owner in itertools.count(1):
        if complete == BUCKETS:
            return [owner for key in sorted(found) for owner in found[key]]
        chosen = found.setdefault(bucket(slot(owner)), [])
        if len(chosen) < PER_BUCKET:
            chosen.append(owner)
            complete += len(chosen) == PER_BUCKET
    raise AssertionError("unreachable")


def accounts() -> list[tuple[int, int]]:
    """Recorded owners with their slots, rejecting a set that no longer covers the tree evenly."""
    owners = [int(line) for line in OWNERS.read_text().split()]
    if len(owners) != BALLAST_ACCOUNTS:
        raise RuntimeError(f"{OWNERS} holds {len(owners)} owners, expected {BALLAST_ACCOUNTS}")
    paired = [(owner, slot(owner)) for owner in owners]
    counts = {key: 0 for key in range(BUCKETS)}
    for _, account in paired:
        counts[bucket(account)] += 1
    uneven = {key: count for key, count in counts.items() if count != PER_BUCKET}
    if uneven:
        raise RuntimeError(f"{OWNERS} leaves {len(uneven)} of {BUCKETS} KAMT buckets uneven")
    return paired


def main() -> int:
    owners = search()
    OWNERS.write_text("".join(f"{owner}\n" for owner in owners))
    print(f"wrote {OWNERS}: {len(owners)} owners from {max(owners)} candidates", file=sys.stderr)
    accounts()
    print(f"every one of {BUCKETS} buckets holds {PER_BUCKET}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
