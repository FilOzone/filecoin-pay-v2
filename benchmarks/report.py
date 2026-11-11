#!/usr/bin/env python3
"""Render markdown tables from run.py results: EVM against Filecoin gas, and charge shares."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

CHARGE_GROUPS: dict[str, tuple[str, ...]] = {
    "State tree (IPLD blocks and actor records)": (
        "OnBlockLink", "OnBlockOpenBase", "OnBlockOpen", "OnBlockCreate", "OnBlockRead",
        "OnBlockStat", "OnScanIpldLinks", "OnActorUpdate", "OnActorLookup", "OnActorGetRoot",
        "OnActorSetRoot", "OnCreateActor", "OnValueTransfer",
    ),
    "EVM interpreter (wasm)": ("wasm_exec", "wasm_memory_init", "wasm_memory_grow"),
    "Syscalls and invocation": (
        "OnSyscall", "OnMethodInvocation", "OnHashing", "OnActorEvent", "OnLookupAddress",
        "OnMessageContext", "OnNetworkContext", "OnResolveAddress", "OnReturnValue",
        "OnGetActorCodeCid", "OnGetBuiltinActorType", "OnGetCodeCidForType",
    ),
    "Chain message": ("OnChainMessage", "OnChainReturnValue"),
}


def load(path: Path) -> list[dict[str, Any]]:
    return json.loads(path.read_text())["steps"]


def comparison(evm: list[dict[str, Any]], filecoin: list[dict[str, Any]]) -> None:
    print("| Step | EVM gas | Filecoin gas | Ratio |")
    print("| --- | ---: | ---: | ---: |")
    for left, right in zip(evm, filecoin, strict=True):
        if left["name"] != right["name"]:
            raise RuntimeError(f"step mismatch: {left['name']} vs {right['name']}")
        ratio = right["gasUsed"] / left["gasUsed"]
        print(f"| `{left['name']}` | {left['gasUsed']:,} | {right['gasUsed']:,} | {ratio:.0f}x |")


def shares(filecoin: list[dict[str, Any]]) -> None:
    grouped = {name for names in CHARGE_GROUPS.values() for name in names}
    print("\n| Step | " + " | ".join(CHARGE_GROUPS) + " |")
    print("| --- |" + " ---: |" * len(CHARGE_GROUPS))
    for step in filecoin:
        summary = step.get("traceSummary")
        if summary is None:
            raise RuntimeError(f"{step['name']} has no Filecoin gas trace")
        charges = summary["chargesByName"]
        if ungrouped := set(charges) - grouped:
            raise RuntimeError(f"unknown charge names: {sorted(ungrouped)}")
        total = summary["chargedMilligas"]
        cells = [
            f"{100 * sum(charges[n]['totalMilligas'] for n in names if n in charges) / total:.1f}%"
            for names in CHARGE_GROUPS.values()
        ]
        print(f"| `{step['name']}` | " + " | ".join(cells) + " |")


def main() -> int:
    results = Path(__file__).resolve().parent / "results"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evm", type=Path, default=results / "evm-gas.json")
    parser.add_argument("--filecoin", type=Path, default=results / "filecoin-gas.json")
    args = parser.parse_args()
    filecoin = load(args.filecoin)
    comparison(load(args.evm), filecoin)
    shares(filecoin)
    return 0


if __name__ == "__main__":
    sys.exit(main())
