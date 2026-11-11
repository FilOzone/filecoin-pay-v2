#!/usr/bin/env python3
"""Measure FilecoinPayV2 operation gas against any Ethereum JSON-RPC node.

Reported gas is whatever unit the node charges: EVM gas on anvil, Filecoin gas on fvm-anvil.
Against fvm-anvil the runner also records filecoin_getGasBreakdown and filecoin_getGasTrace,
aggregating each trace by ref-FVM charge name.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[1]
MNEMONIC = "test test test test test test test test test test test junk"
NATIVE_TOKEN = 0

# src/lib/Script.sol opcodes
POP, PUSH, SUDO, SETTOKEN, DEPOSIT = 0, 1, 3, 4, 6
# src/lib/Permissions.sol
ALL = (1 << 256) - 1
CREATE_RAIL = 1 << 3

# test/Auth.t.sol:testPushSudoDepositPopDeposit
SUDO_DEPOSIT = 100
SELF_DEPOSIT = 30
# Rail.t.sol amounts, scaled so per-block drain cannot outrun the payer between transactions
RAIL_DEPOSIT = 10**6
RAIL_RATE = 50
RAIL_LOCK = 50
RAIL_DISBURSE = 25


def command(args: list[str], *, cwd: Path | None = None) -> str:
    completed = subprocess.run(
        args, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"command failed ({completed.returncode}): {' '.join(args[:4])}\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed.stdout.strip()


def quantity(value: str | int) -> int:
    if isinstance(value, str) and value.startswith("0x"):
        return int(value, 16)
    return int(value)


def artifact_bytecode(name: str) -> str:
    path = REPO / "out" / f"{name}.sol" / f"{name}.json"
    if not path.exists():
        raise RuntimeError(f"missing artifact {path}; run forge build")
    return json.loads(path.read_text())["bytecode"]["object"]


class Runner:
    def __init__(self, args: argparse.Namespace) -> None:
        self.rpc_url = args.rpc_url
        self.output = args.output.resolve()
        self.snapshot_path = args.snapshot.resolve()
        self.keys = [
            command(
                ["cast", "wallet", "private-key", "--mnemonic", MNEMONIC, "--mnemonic-index", str(index)]
            )
            for index in range(4)
        ]
        self.accounts = [command(["cast", "wallet", "address", "--private-key", key]) for key in self.keys]
        self.operator, self.alice, self.bob, self.carol = self.accounts

        self.filecoin = True
        self.sequence = "setup"
        self.result: dict[str, Any] = {
            "schemaVersion": 1,
            "createdAt": datetime.now(timezone.utc).isoformat(),
            "configuration": {
                "rpcUrl": self.rpc_url,
                "chainId": quantity(self.rpc("eth_chainId")),
                "clientVersion": self.rpc("web3_clientVersion"),
                "blockGasLimit": quantity(
                    self.rpc("eth_getBlockByNumber", "latest", "false")["gasLimit"]
                ),
                "operator": self.operator,
                "alice": self.alice,
                "bob": self.bob,
                "carol": self.carol,
                "revision": command(["git", "describe", "--tags", "--always", "--dirty"], cwd=REPO),
            },
            "steps": [],
        }

    def cast(self, *args: str) -> str:
        return command(["cast", *args])

    def rpc(self, method: str, *params: str) -> Any:
        return json.loads(self.cast("rpc", "--rpc-url", self.rpc_url, method, *params))

    def try_rpc(self, method: str, *params: str) -> Any | None:
        try:
            return self.rpc(method, *params)
        except RuntimeError:
            return None

    def call(self, to: str, signature: str, *arguments: str) -> str:
        return self.cast("call", "--rpc-url", self.rpc_url, to, signature, *arguments)

    def balance_of(self, owner: str, token: int) -> int:
        return int(self.call(self.pay, "balanceOf(address,uint256)(uint256)", owner, str(token)).split()[0])

    def snapshot(self) -> str:
        """Snapshots are consumed by the revert that uses them, so each revert re-takes one."""
        return self.rpc("evm_snapshot")

    def revert(self, snapshot: str) -> str:
        if not self.rpc("evm_revert", snapshot):
            raise RuntimeError(f"revert to {snapshot} refused")
        return self.snapshot()

    def step(
        self,
        name: str,
        sender: str,
        *,
        measured: bool = True,
        prerequisites: list[str] | None = None,
        to: str | None = None,
        signature: str | None = None,
        arguments: list[str] | None = None,
        value: int | None = None,
        creation_code: str | None = None,
    ) -> dict[str, Any]:
        args = [
            "send",
            "--rpc-url",
            self.rpc_url,
            "--private-key",
            self.keys[self.accounts.index(sender)],
        ]
        if value is not None:
            args.extend(["--value", str(value)])
        if creation_code is not None:
            args.extend(["--create", creation_code])
        else:
            args.append(to or self.pay)
            args.append(signature or "")
            args.extend(arguments or [])
        args.append("--json")
        receipt = json.loads(self.cast(*args))
        if receipt.get("status") != "0x1":
            raise RuntimeError(f"{name} failed: {json.dumps(receipt)}")
        if not measured:
            return receipt

        transaction_hash = receipt["transactionHash"]
        record: dict[str, Any] = {
            "sequence": self.sequence,
            "name": name,
            "sender": sender,
            "transactionHash": transaction_hash,
            "blockNumber": quantity(receipt["blockNumber"]),
            "gasUsed": quantity(receipt["gasUsed"]),
        }
        if receipt.get("contractAddress"):
            record["contractAddress"] = receipt["contractAddress"]
        if prerequisites is not None:
            record["prerequisites"] = prerequisites
        if self.filecoin:
            breakdown = self.try_rpc("filecoin_getGasBreakdown", transaction_hash)
            trace = self.try_rpc("filecoin_getGasTrace", transaction_hash)
            if breakdown is None or trace is None:
                self.filecoin = False
            else:
                record["gasBreakdown"] = {key: quantity(entry) for key, entry in breakdown.items()}
                record["traceSummary"] = self.summarize(trace, record["gasUsed"], transaction_hash)
                record["trace"] = trace

        print(f"{name:40s} {record['gasUsed']:>15,}", file=sys.stderr, flush=True)
        self.result["steps"].append(record)
        self.write()
        return record

    def summarize(self, trace: dict[str, Any], receipt_gas: int, transaction_hash: str) -> dict[str, Any]:
        if quantity(trace["exitCode"]) != 0:
            raise RuntimeError(f"gas trace reports failure for {transaction_hash}")
        if quantity(trace["gasUsed"]) != receipt_gas:
            raise RuntimeError(
                f"trace gas {quantity(trace['gasUsed'])} differs from receipt gas {receipt_gas}"
            )
        totals: dict[str, dict[str, int]] = {}
        charged = 0

        def add(charge: dict[str, Any]) -> None:
            nonlocal charged
            target = totals.setdefault(
                charge["name"],
                {"count": 0, "computeMilligas": 0, "otherMilligas": 0, "totalMilligas": 0},
            )
            target["count"] += 1
            for field in ("computeMilligas", "otherMilligas", "totalMilligas"):
                target[field] += quantity(charge[field])
            charged += quantity(charge["totalMilligas"])

        def walk(call: dict[str, Any]) -> None:
            for charge in call.get("gasCharges", []):
                add(charge)
            for subcall in call.get("subcalls", []):
                walk(subcall)

        for charge in trace.get("gasCharges", []):
            add(charge)
        for call in trace.get("calls", []):
            walk(call)
        return {
            "gasUsed": quantity(trace["gasUsed"]),
            "chargedMilligas": charged,
            "chargesByName": dict(sorted(totals.items())),
        }

    def write_snapshot(self) -> None:
        """One sorted `key (gas: n)` line per measurement, diffable like forge's .gas-snapshot."""
        lines = {}
        for step in self.result["steps"]:
            key = f"{step['sequence']}:{step['name']}"
            if key in lines:
                raise RuntimeError(f"duplicate snapshot key {key}")
            lines[key] = f"{key} (gas: {step['gasUsed']})"
        self.snapshot_path.write_text("\n".join(sorted(lines.values())) + "\n")
        print(f"wrote {self.snapshot_path}", file=sys.stderr)

    def write(self) -> None:
        self.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.output.with_suffix(self.output.suffix + ".tmp")
        temporary.write_text(json.dumps(self.result, indent=2, sort_keys=True) + "\n")
        os.replace(temporary, self.output)

    def check(self) -> None:
        if self.balance_of(self.alice, int(self.token_id)) != SUDO_DEPOSIT:
            raise RuntimeError("executeScript did not credit the sudo deposit")
        if self.balance_of(self.bob, int(self.token_id)) != SELF_DEPOSIT:
            raise RuntimeError("executeScript did not credit the self deposit")

    def deploy(self) -> None:
        self.pay = self.step(
            "deploy FilecoinPayV2", self.operator, creation_code=artifact_bytecode("FilecoinPayV2")
        )["contractAddress"]
        self.token = self.step(
            "deploy MockERC20", self.operator, creation_code=artifact_bytecode("MockERC20")
        )["contractAddress"]
        self.token_id = str(int(self.token, 16))
        self.result["configuration"]["filecoinPay"] = self.pay
        self.result["configuration"]["mockERC20"] = self.token

    def erc20_setup(self) -> None:
        total = str(SUDO_DEPOSIT + SELF_DEPOSIT)
        for label, holder in (("alice", self.alice), ("bob", self.bob)):
            self.step(
                f"MockERC20.mint({label})", self.operator, to=self.token,
                signature="mint(address,uint256)", arguments=[holder, total],
            )
        for label, holder in (("alice", self.alice), ("bob", self.bob)):
            self.step(
                f"MockERC20.approve({label})", holder, to=self.token,
                signature="approve(address,uint256)", arguments=[self.pay, str((1 << 256) - 1)],
            )

    def script(self) -> str:
        return "0x" + b"".join(
            (
                bytes([SETTOKEN]),
                bytes.fromhex(self.token[2:]),
                bytes([PUSH, SUDO]),
                bytes.fromhex(self.alice[2:]),
                bytes([DEPOSIT]),
                SUDO_DEPOSIT.to_bytes(16, "big"),
                bytes([POP, DEPOSIT]),
                SELF_DEPOSIT.to_bytes(16, "big"),
            )
        ).hex()

    def sequences(self) -> dict[str, list[dict[str, Any]]]:
        """Ordered operations per scenario; each step's predecessors are its prerequisites."""
        rail = [self.alice, self.bob, "0", str(NATIVE_TOKEN)]
        return {
            "erc6909": [
                {"name": "authorize(bob, ALL)", "sender": self.alice,
                 "signature": "authorize(address,uint256)", "arguments": [self.bob, str(ALL)]},
                {"name": "executeScript/pushSudoDepositPopDeposit", "sender": self.bob,
                 "signature": "executeScript(bytes)", "arguments": [self.script()],
                 "check": self.check},
                {"name": "transfer", "sender": self.bob,
                 "signature": "transfer(address,uint256,uint256)",
                 "arguments": [self.alice, self.token_id, "10"]},
                {"name": "approve", "sender": self.alice,
                 "signature": "approve(address,uint256,uint256)",
                 "arguments": [self.carol, self.token_id, "50"]},
                {"name": "transferFrom", "sender": self.carol,
                 "signature": "transferFrom(address,address,uint256,uint256)",
                 "arguments": [self.alice, self.carol, self.token_id, "10"]},
                {"name": "setOperator", "sender": self.alice,
                 "signature": "setOperator(address,bool)", "arguments": [self.carol, "true"]},
            ],
            "rails": [
                {"name": "authorize(operator, CREATE_RAIL)", "sender": self.alice,
                 "signature": "authorize(address,uint256)",
                 "arguments": [self.operator, str(CREATE_RAIL)]},
                {"name": "createRail", "sender": self.operator,
                 "signature": "createRail(address,address,uint32,uint256)", "arguments": rail},
                {"name": "deposit (native)", "sender": self.alice,
                 "signature": "deposit()", "value": RAIL_DEPOSIT},
                {"name": "modifyRate", "sender": self.operator,
                 "signature": "modifyRate(address,address,uint32,uint256,uint88)",
                 "arguments": rail + [str(RAIL_RATE)]},
                {"name": "settleRail", "sender": self.operator,
                 "signature": "settleRail(address,address,address,uint32,uint256)",
                 "arguments": [self.operator] + rail},
                {"name": "lock", "sender": self.operator,
                 "signature": "lock(address,address,uint32,uint256,uint256)",
                 "arguments": rail + [str(RAIL_LOCK)]},
                {"name": "disburse", "sender": self.operator,
                 "signature": "disburse(address,address,uint32,uint256,uint128)",
                 "arguments": rail + [str(RAIL_DISBURSE)]},
                {"name": "unlock", "sender": self.operator,
                 "signature": "unlock(address,address,uint32,uint256,uint256)",
                 "arguments": rail + [str(RAIL_LOCK - RAIL_DISBURSE)]},
                {"name": "terminateRail", "sender": self.operator,
                 "signature": "terminateRail(address,address,address,uint32,uint256)",
                 "arguments": [self.operator] + rail},
            ],
        }

    def send(self, pending: dict[str, Any], **overrides: Any) -> dict[str, Any]:
        pending = dict(pending)
        check = pending.pop("check", None)
        receipt = self.step(pending.pop("name"), pending.pop("sender"), **pending, **overrides)
        if check is not None:
            check()
        return receipt

    def isolated(self, sequence: list[dict[str, Any]]) -> None:
        """Measure each step from the shared baseline, replaying only its own prerequisites."""
        for index, pending in enumerate(sequence):
            for earlier in sequence[:index]:
                self.send(earlier, measured=False)
            self.send(pending, prerequisites=[earlier["name"] for earlier in sequence[:index]])
            self.baseline = self.revert(self.baseline)

    def cumulative(self, sequence: list[dict[str, Any]]) -> None:
        """Measure the sequence as one run, so each step also carries its predecessors' storage."""
        for pending in sequence:
            self.send(pending)

    def run(self, isolate: bool) -> None:
        self.deploy()
        self.erc20_setup()
        self.baseline = self.snapshot()
        self.result["configuration"]["isolated"] = isolate
        for name, sequence in self.sequences().items():
            self.sequence = name
            print(f"\n[{name}]", file=sys.stderr, flush=True)
            (self.isolated if isolate else self.cumulative)(sequence)
        self.result["configuration"]["filecoinDiagnostics"] = self.filecoin
        self.write()
        print(f"\nwrote {self.output}", file=sys.stderr)
        # a cumulative run measures different state, and an EVM run is forge snapshot's job
        if self.filecoin and isolate:
            self.write_snapshot()
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", default="http://127.0.0.1:8545")
    parser.add_argument(
        "--output", type=Path, default=Path(__file__).resolve().parent / "results" / "gas.json"
    )
    parser.add_argument("--snapshot", type=Path, default=REPO / ".filecoin-gas-snapshot")
    parser.add_argument(
        "--cumulative",
        action="store_true",
        help="measure one linear run instead of isolating each step from the baseline snapshot",
    )
    args = parser.parse_args()
    Runner(args).run(isolate=not args.cumulative)
    return 0


if __name__ == "__main__":
    sys.exit(main())
