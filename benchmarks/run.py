#!/usr/bin/env python3
"""Measure FilecoinPayV2 operation gas against any Ethereum JSON-RPC node.

Reported gas is whatever unit the node charges: EVM gas on anvil, Filecoin gas on fvm-anvil.
Against fvm-anvil the runner also records filecoin_getGasBreakdown and filecoin_getGasTrace,
aggregating each trace by ref-FVM charge name.
"""

from __future__ import annotations

import argparse
import http.client
import itertools
import json
import os
import subprocess
import sys
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import ballast

REPO = Path(__file__).resolve().parents[1]
MNEMONIC = "test test test test test test test test test test test junk"
NATIVE_TOKEN = 0

# src/lib/Script.sol opcodes
POP, PUSH, RESET, SUDO, SETTOKEN, AUTHORIZE = 0, 1, 2, 3, 4, 5
SETRAIL, CREATERAIL, SETTLERAIL = 6, 7, 8
WITHDRAW, DEPOSIT, WITHDRAWTO, DEPOSITTO = 9, 10, 11, 12
TRANSFER, TRANSFERFROM, TRANSFERALL = 13, 14, 15
INCREASERATE, DECREASERATE, SETRATE = 16, 17, 18
DISBURSEALL, DISBURSE, LOCK, UNLOCK, SETAVAILABLE = 19, 20, 21, 22, 23
TERMINATERAIL, TERMINATERAILBY = 24, 25
NATIVE = "0x" + "00" * 20
# src/lib/Permissions.sol, suffixed so no permission reads as one of the opcodes above
ALL_PERMISSION = (1 << 256) - 1
TRANSFER_PERMISSION = 1 << 2
CREATE_RAIL_PERMISSION = 1 << 3

# test/Auth.t.sol:testPushSudoDepositPopDeposit
SUDO_DEPOSIT = 100
SELF_DEPOSIT = 30
# the token entry points and the script that moves balances around with every move op
TOKEN_DEPOSIT = 100
TOKEN_DEPOSIT_TO = 50
TOKEN_MOVE = 10
# what the heaviest holder can send out of their own wallet across a whole sequence
TOKEN_MINT = SUDO_DEPOSIT + SELF_DEPOSIT + TOKEN_DEPOSIT + 2 * TOKEN_DEPOSIT_TO
# Rail.t.sol amounts, scaled so per-block drain cannot outrun the payer between transactions
RAIL_DEPOSIT = 10**6
RAIL_RATE = 50
RAIL_LOCK = 50
RAIL_DISBURSE = 25
RAIL_WITHDRAW = 100
# the lockup script leaves room to disburse and unlock before it empties the lockup
RAIL_AVAILABLE = 200
RAIL_UNLOCK = 75
RAIL_RATE_DELTA = 25
RAIL_RATE_FINAL = 10
# the rails sequence ends on a terminated nonce 0, so the script creates a rail that never existed
SCRIPT_RAIL_NONCE = 1
# the operator-side terminate ends a rail of its own, so it opens one no other step holds
TERMINATE_RAIL_NONCE = 2


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
        url = urllib.parse.urlsplit(self.rpc_url)
        opener = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
        self.connection = opener(url.hostname, url.port)
        self.rpc_path = url.path or "/"
        self.calls = itertools.count(1)
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
                    self.rpc("eth_getBlockByNumber", "latest", False)["gasLimit"]
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

    def rpc(self, method: str, *params: Any) -> Any:
        """Kept-alive HTTP rather than `cast rpc`: the prefill alone makes thousands of calls."""
        self.connection.request(
            "POST",
            self.rpc_path,
            json.dumps({"jsonrpc": "2.0", "id": next(self.calls), "method": method, "params": params}),
            {"Content-Type": "application/json"},
        )
        answer = json.loads(self.connection.getresponse().read())
        if "error" in answer:
            raise RuntimeError(f"{method} failed: {json.dumps(answer['error'])}")
        return answer["result"]

    def try_rpc(self, method: str, *params: Any) -> Any | None:
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
        total = str(TOKEN_MINT)
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

    def prefill(self) -> None:
        """Write the ballast accounts, so no measured write walks a nearly empty state tree.

        The first owner is funded by a real deposit, which proves the recorded slots still
        match the contract's layout; the rest are written into the actor's storage directly,
        since 2048 transactions take minutes to leave the same bytes behind. Those balances
        would otherwise be unbacked, so the contract is credited for the ones not deposited.
        """
        accounts = ballast.accounts()
        canary, proof = accounts[0]
        self.step(
            "ballast depositTo", self.operator, measured=False, value=ballast.BALANCE,
            signature="depositTo(address)", arguments=["0x%040x" % canary],
        )
        deposited = quantity(self.rpc("eth_getStorageAt", self.pay, hex(proof), "latest"))
        if deposited != ballast.BALANCE:
            raise RuntimeError(f"depositTo left {deposited} in the recorded slot of owner {canary}")
        word = "0x" + ballast.BALANCE.to_bytes(32, "big").hex()
        for _, slot in accounts[1:]:
            self.rpc("anvil_setStorageAt", self.pay, hex(slot), word)
        held = quantity(self.rpc("eth_getBalance", self.pay, "latest"))
        self.rpc("anvil_setBalance", self.pay, hex(held + (len(accounts) - 1) * ballast.BALANCE))
        self.result["configuration"]["ballast"] = {
            "accounts": len(accounts),
            "prefixBits": ballast.PREFIX_BITS,
            "balance": ballast.BALANCE,
        }
        print(
            f"prefilled {len(accounts)} accounts, {ballast.PER_BUCKET} in each of"
            f" {ballast.BUCKETS} KAMT buckets",
            file=sys.stderr, flush=True,
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

    def create_rail_script(self) -> str:
        """The script op against the external entry point, on a nonce no other step holds."""
        return "0x" + b"".join(
            (
                bytes([CREATERAIL]),
                bytes.fromhex(self.alice[2:]),
                bytes.fromhex(self.bob[2:]),
                SCRIPT_RAIL_NONCE.to_bytes(4, "big"),
            )
        ).hex()

    def authorize_script(self) -> str:
        """The script op, granting every permission bit the scope it runs under allows."""
        return "0x" + b"".join(
            (
                bytes([AUTHORIZE]),
                bytes.fromhex(self.carol[2:]),
                bytes([0xFF]),
            )
        ).hex()

    def set_rail_script(self) -> str:
        """SETRAIL reaches the rail the preceding script created, which LOCK then draws on."""
        return "0x" + b"".join(
            (
                bytes([SETRAIL]),
                bytes.fromhex(self.alice[2:]),
                bytes.fromhex(self.bob[2:]),
                SCRIPT_RAIL_NONCE.to_bytes(4, "big"),
                bytes([LOCK]),
                RAIL_LOCK.to_bytes(16, "big"),
            )
        ).hex()

    def move_ops_script(self) -> str:
        """Every op that moves a balance. Bob runs it: he is alice's operator, so TRANSFERFROM
        needs no allowance, and TRANSFERALL goes last because it empties him."""
        return "0x" + b"".join(
            (
                bytes([SETTOKEN]),
                bytes.fromhex(self.token[2:]),
                bytes([DEPOSITTO]),
                TOKEN_DEPOSIT_TO.to_bytes(16, "big"),
                bytes.fromhex(self.alice[2:]),
                bytes([TRANSFER]),
                bytes.fromhex(self.carol[2:]),
                TOKEN_MOVE.to_bytes(16, "big"),
                bytes([TRANSFERFROM]),
                bytes.fromhex(self.carol[2:]),
                TOKEN_MOVE.to_bytes(16, "big"),
                bytes.fromhex(self.alice[2:]),
                bytes([WITHDRAW]),
                TOKEN_MOVE.to_bytes(16, "big"),
                bytes([WITHDRAWTO]),
                TOKEN_MOVE.to_bytes(16, "big"),
                bytes.fromhex(self.carol[2:]),
                bytes([TRANSFERALL]),
                bytes.fromhex(self.alice[2:]),
            )
        ).hex()

    def rate_ops_script(self) -> str:
        """The three rate ops against the rail SETRAIL names, each settling at the same block."""
        return "0x" + b"".join(
            (
                bytes([SETRAIL]),
                bytes.fromhex(self.alice[2:]),
                bytes.fromhex(self.bob[2:]),
                SCRIPT_RAIL_NONCE.to_bytes(4, "big"),
                bytes([INCREASERATE]),
                RAIL_RATE.to_bytes(11, "big"),
                bytes([DECREASERATE]),
                RAIL_RATE_DELTA.to_bytes(11, "big"),
                bytes([SETRATE]),
                RAIL_RATE_FINAL.to_bytes(11, "big"),
            )
        ).hex()

    def lockup_ops_script(self) -> str:
        """Every lockup op, ordered so the lockup never runs dry before DISBURSEALL empties it."""
        return "0x" + b"".join(
            (
                bytes([SETRAIL]),
                bytes.fromhex(self.alice[2:]),
                bytes.fromhex(self.bob[2:]),
                SCRIPT_RAIL_NONCE.to_bytes(4, "big"),
                bytes([SETAVAILABLE]),
                RAIL_AVAILABLE.to_bytes(16, "big"),
                bytes([DISBURSE]),
                RAIL_DISBURSE.to_bytes(16, "big"),
                bytes([UNLOCK]),
                RAIL_UNLOCK.to_bytes(16, "big"),
                bytes([DISBURSEALL]),
            )
        ).hex()

    def settle_reset_script(self) -> str:
        """SETTLERAIL names its rail outright, so the nested frame it runs in is thrown away."""
        return "0x" + b"".join(
            (
                bytes([PUSH, SETTLERAIL]),
                bytes.fromhex(self.alice[2:]),
                bytes.fromhex(self.bob[2:]),
                SCRIPT_RAIL_NONCE.to_bytes(4, "big"),
                bytes.fromhex(self.operator[2:]),
                bytes([POP, RESET]),
            )
        ).hex()

    def terminate_ops_script(self) -> str:
        """Both terminate ops. The operator ends a rail it opens here, then authenticates as the
        payer to end the one the earlier script created, which is the only side that names it."""
        return "0x" + b"".join(
            (
                bytes([CREATERAIL]),
                bytes.fromhex(self.alice[2:]),
                bytes.fromhex(self.bob[2:]),
                TERMINATE_RAIL_NONCE.to_bytes(4, "big"),
                bytes([TERMINATERAIL]),
                bytes([SUDO]),
                bytes.fromhex(self.alice[2:]),
                bytes([SETRAIL]),
                bytes.fromhex(self.alice[2:]),
                bytes.fromhex(self.bob[2:]),
                SCRIPT_RAIL_NONCE.to_bytes(4, "big"),
                bytes([TERMINATERAILBY]),
                bytes.fromhex(self.operator[2:]),
            )
        ).hex()

    def sequences(self) -> dict[str, list[dict[str, Any]]]:
        """Ordered operations per scenario; each step's predecessors are its prerequisites."""
        rail = [self.alice, self.bob, "0", str(NATIVE_TOKEN)]
        return {
            "erc6909": [
                {"name": "authorize(bob, ALL)", "sender": self.alice,
                 "signature": "authorize(address,uint256)",
                 "arguments": [self.bob, str(ALL_PERMISSION)]},
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
                {"name": "executeScript/authorize", "sender": self.alice,
                 "signature": "executeScript(bytes)", "arguments": [self.authorize_script()]},
                # the same script through the scoped entry point, to price the scope argument.
                # the scope has to narrow the grant, or the write repeats the step before it and
                # the FVM flushes nothing, which costs 14M less and compares against nothing
                {"name": "executeScript(scope)/authorize", "sender": self.alice,
                 "signature": "executeScript(uint256,bytes)",
                 "arguments": [str(ALL_PERMISSION ^ TRANSFER_PERMISSION), self.authorize_script()]},
                {"name": "deposit (token)", "sender": self.alice,
                 "signature": "deposit(address,uint256)",
                 "arguments": [self.token, str(TOKEN_DEPOSIT)]},
                {"name": "depositTo (token)", "sender": self.alice,
                 "signature": "depositTo(address,address,uint256)",
                 "arguments": [self.token, self.bob, str(TOKEN_DEPOSIT_TO)]},
                {"name": "withdraw (token)", "sender": self.alice,
                 "signature": "withdraw(address,uint256)",
                 "arguments": [self.token, str(TOKEN_MOVE)]},
                {"name": "withdrawTo (token)", "sender": self.alice,
                 "signature": "withdrawTo(address,address,uint256)",
                 "arguments": [self.token, self.carol, str(TOKEN_MOVE)]},
                {"name": "executeScript/moveOps", "sender": self.bob,
                 "signature": "executeScript(bytes)", "arguments": [self.move_ops_script()]},
            ],
            "rails": [
                {"name": "authorize(operator, CREATE_RAIL)", "sender": self.alice,
                 "signature": "authorize(address,uint256)",
                 "arguments": [self.operator, str(CREATE_RAIL_PERMISSION)]},
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
                {"name": "executeScript/createRail", "sender": self.operator,
                 "signature": "executeScript(bytes)", "arguments": [self.create_rail_script()]},
                {"name": "executeScript/setRail", "sender": self.operator,
                 "signature": "executeScript(bytes)", "arguments": [self.set_rail_script()]},
                {"name": "depositTo (native)", "sender": self.alice,
                 "signature": "depositTo(address)", "arguments": [self.bob], "value": RAIL_DEPOSIT},
                {"name": "withdraw (native)", "sender": self.alice,
                 "signature": "withdraw(address,uint256)",
                 "arguments": [NATIVE, str(RAIL_WITHDRAW)]},
                {"name": "executeScript/rateOps", "sender": self.operator,
                 "signature": "executeScript(bytes)", "arguments": [self.rate_ops_script()]},
                {"name": "executeScript/lockupOps", "sender": self.operator,
                 "signature": "executeScript(bytes)", "arguments": [self.lockup_ops_script()]},
                {"name": "executeScript/settleReset", "sender": self.operator,
                 "signature": "executeScript(bytes)", "arguments": [self.settle_reset_script()]},
                # last: it ends the rail the steps above operate on
                {"name": "executeScript/terminateOps", "sender": self.operator,
                 "signature": "executeScript(bytes)", "arguments": [self.terminate_ops_script()]},
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
        self.prefill()
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
