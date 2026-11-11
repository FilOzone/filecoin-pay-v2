# Filecoin gas benchmark

`forge test` and `vm.snapshotGas` measure EVM gas.
Filecoin charges FVM gas, which prices actor state-tree access rather than EVM opcodes, so EVM gas does not rank Filecoin costs.
This benchmark replays the operations the tests exercise as real transactions and records the gas the node charges.

[`run.py`](run.py) is node-agnostic: `gasUsed` is EVM gas against `anvil` and Filecoin gas against [`fvm-anvil`](https://github.com/Kubuxu/fvm-anvil).
Against `fvm-anvil` it additionally records `filecoin_getGasBreakdown` and the complete `filecoin_getGasTrace`, aggregated by ref-FVM charge name.
Both nodes derive the same accounts from the standard development mnemonic, so one script produces both columns.
[`report.py`](report.py) renders the tables below from the two result files.

Transaction `gasUsed` includes message and calldata overhead, so these numbers are not comparable to the inner-call figure in `snapshots/executeScript.json`; they are comparable to each other.

## Isolation

Filecoin gas depends on the storage a message commits, so in one linear run every operation is inflated by the storage its predecessors left behind.
The runner therefore snapshots the state after deployment and funding, and measures each operation from that same baseline, replaying only that operation's own prerequisites and reverting afterwards.
`evm_revert` restores the state root, epoch, and nonces, so a measurement cannot be moved by an unrelated operation: measuring `authorize(bob, ALL)` at the start of a run and again after 21 other transactions have executed and been reverted gives the same 5,084,136 both times.
Isolation is worth about 21% here, the contamination `authorize(operator, CREATE_RAIL)` picked up from the preceding ERC-6909 sequence.

A measurement is independent of other operations, not of its own prerequisites: `terminateRail` must settle a rail that exists, so it is measured over the storage `createRail` and `modifyRate` wrote.
Each step records the prerequisites it replayed in `prerequisites`.

Snapshots are consumed by the revert that uses them, and reverting discards the receipts and traces of the blocks it drops, so each revert re-takes its snapshot and every measurement is captured before its revert.

Isolation changes no EVM number: the `anvil` column is identical either way, because EVM gas does not price the size of the actor's committed storage.
That is why measuring in EVM gas never surfaced the ordering dependence in the first place.

`--cumulative` measures one linear run instead, demonstrating the the storage-growth effect below.

## Updating the snapshot

[`.filecoin-gas-snapshot`](../.filecoin-gas-snapshot) is the checked-in record: one sorted `sequence:operation (gas: n)` line per measurement, in the shape of forge's `.gas-snapshot`.
Regenerate it whenever a change could move Filecoin gas, so the pull request carries the delta as a line diff.

Build the node once, in the `fvm-anvil` checkout:

```bash
cargo build --release -p fvm-anvil
```

Then, for each update:

```bash
forge build                                # the runner deploys these artifacts
target/release/fvm-anvil --port 18546      # in the fvm-anvil checkout, own terminal

benchmarks/run.py --rpc-url http://127.0.0.1:18546 \
  --output benchmarks/results/filecoin-gas.json
git diff .filecoin-gas-snapshot
```

Restart the node before every update.
Filecoin gas is charged on the size of the storage a message commits, so a node that has already run the suite carries storage that inflates every number; the runner starts from genesis state and cannot undo that.

Do not pass `--cumulative` when updating.
It measures one linear run rather than isolating each operation, and deliberately does not write the snapshot.

A diff you did not expect from a contract change usually means the environment moved rather than the code.
The `fvm-anvil` revision, network version, actor bundle, solc version, and optimizer settings all shift every number; `benchmarks/results/filecoin-gas.json` records the ones a run used.

[`.github/workflows/gas.yml`](../.github/workflows/gas.yml) runs this same regeneration on every push and pull request, and fails if the result differs from the committed file.
It pins the `fvm-anvil` revision, because the ref-FVM and builtin-actor versions a node runs set every number, so bumping that pin and committing the regenerated snapshot belong in one change.
The job runs on `ubuntu-latest`, which is therefore the environment the committed snapshot has to match.

## Regenerating the tables below

The tables also need the EVM column, which comes from the same runner against `anvil`, and `report.py`, which reads both result files:

```bash
target/release/fvm-anvil --port 18546      # own terminal, freshly started
anvil --port 18545 --silent                # own terminal

benchmarks/run.py --rpc-url http://127.0.0.1:18546 \
  --output benchmarks/results/filecoin-gas.json
benchmarks/run.py --rpc-url http://127.0.0.1:18545 \
  --output benchmarks/results/evm-gas.json
benchmarks/report.py
```

The `anvil` run measures EVM gas, which `forge snapshot --isolate` already records, so it leaves the snapshot file alone.
Everything under `benchmarks/results/` is a generated artifact and is not checked in.

## Results

Recorded at `3af7910` against `fvm-anvil` `0fafabd` (network version 28, builtin actors 18.0.0) and `anvil` v1.9.0.
The sequences mirror `test/Auth.t.sol`, `test/ERC6909.t.sol`, and `test/Rail.t.sol`; every transaction succeeded and every trace total matched its receipt.
A repeated run from a fresh node reproduces every number exactly.

The six deployment and funding steps precede the baseline snapshot and so are measured linearly; the ERC-6909 and rail operations below them are each measured from that baseline.

| Step | EVM gas | Filecoin gas | Ratio |
| --- | ---: | ---: | ---: |
| `deploy FilecoinPayV2` | 1,371,452 | 39,116,223 | 29x |
| `deploy MockERC20` | 405,118 | 17,955,350 | 44x |
| `MockERC20.mint(alice)` | 67,798 | 4,701,734 | 69x |
| `MockERC20.mint(bob)` | 50,686 | 4,882,833 | 96x |
| `MockERC20.approve(alice)` | 46,136 | 5,191,567 | 113x |
| `MockERC20.approve(bob)` | 46,136 | 5,453,488 | 118x |
| `authorize(bob, ALL)` | 46,195 | 5,084,136 | 110x |
| `executeScript/pushSudoDepositPopDeposit` | 120,158 | 18,097,557 | 151x |
| `transfer` | 35,302 | 5,686,396 | 161x |
| `approve` | 46,599 | 5,676,325 | 122x |
| `transferFrom` | 60,179 | 6,131,552 | 102x |
| `setOperator` | 45,860 | 5,931,198 | 129x |
| `authorize(operator, CREATE_RAIL)` | 45,835 | 4,970,293 | 108x |
| `createRail` | 49,586 | 5,420,785 | 109x |
| `deposit (native)` | 45,885 | 5,268,018 | 115x |
| `modifyRate` | 39,501 | 6,162,075 | 156x |
| `settleRail` | 55,448 | 6,095,219 | 110x |
| `lock` | 33,478 | 5,921,064 | 177x |
| `disburse` | 35,393 | 5,877,524 | 166x |
| `unlock` | 32,972 | 5,778,253 | 175x |
| `terminateRail` | 37,785 | 6,176,455 | 163x |

| Step | State tree (IPLD blocks and actor records) | EVM interpreter (wasm) | Syscalls and invocation | Chain message |
| --- | ---: | ---: | ---: | ---: |
| `deploy FilecoinPayV2` | 68.8% | 6.0% | 3.0% | 22.3% |
| `deploy MockERC20` | 66.5% | 11.6% | 5.6% | 16.2% |
| `MockERC20.mint(alice)` | 57.6% | 16.6% | 8.1% | 17.7% |
| `MockERC20.mint(bob)` | 58.4% | 16.8% | 7.8% | 17.0% |
| `MockERC20.approve(alice)` | 59.7% | 16.2% | 7.4% | 16.8% |
| `MockERC20.approve(bob)` | 61.3% | 15.7% | 7.0% | 16.0% |
| `authorize(bob, ALL)` | 55.2% | 20.6% | 7.8% | 16.3% |
| `executeScript/pushSudoDepositPopDeposit` | 65.8% | 20.3% | 8.6% | 5.3% |
| `transfer` | 54.2% | 22.1% | 7.6% | 16.1% |
| `approve` | 56.8% | 19.8% | 7.3% | 16.1% |
| `transferFrom` | 54.8% | 22.0% | 7.6% | 15.6% |
| `setOperator` | 59.0% | 19.6% | 6.7% | 14.7% |
| `authorize(operator, CREATE_RAIL)` | 54.1% | 21.1% | 8.0% | 16.7% |
| `createRail` | 53.0% | 21.4% | 8.0% | 17.7% |
| `deposit (native)` | 57.4% | 20.7% | 7.6% | 14.2% |
| `modifyRate` | 50.4% | 25.7% | 8.3% | 15.5% |
| `settleRail` | 53.2% | 22.8% | 7.6% | 16.4% |
| `lock` | 55.1% | 21.9% | 6.8% | 16.1% |
| `disburse` | 55.5% | 21.1% | 7.1% | 16.3% |
| `unlock` | 56.2% | 20.5% | 6.7% | 16.5% |
| `terminateRail` | 49.7% | 26.5% | 8.3% | 15.5% |

## Findings

Filecoin gas is 102-177x EVM gas for the `FilecoinPayV2` operations, and the multiple is largest exactly where EVM gas is smallest: the two cheapest calls in EVM gas, `unlock` and `lock`, carry the two largest multiples.
FVM charges a per-message cost that swamps the differences between these operations.
Across the eight rail operations EVM gas spans 33k-55k, a 1.7x spread, while Filecoin gas spans 5.3M-6.2M, a 1.2x spread.
EVM gas does not rank them.

State-tree access is half or more of every call, from 49.7% to 68.8%, and EVM interpretation never exceeds 26.5%, so removing opcodes moves at most the `wasm` slice.
The lever is the number and size of the IPLD blocks a message touches.

Storage growth is charged to every later message, not just the one that writes it.
`OnBlockLink` prices the committed block by its size, and in a `--cumulative` run the per-message total rises monotonically, from 1,646 Mgas at `MockERC20.mint(alice)` to 3,081 Mgas at `lock`, while the charge count stays at two: each message commits the actor's whole storage block.
The paired funding steps isolate the effect.
`MockERC20.approve(bob)` costs 262k more Filecoin gas than `MockERC20.approve(alice)`, and `MockERC20.mint(bob)` 181k more than `MockERC20.mint(alice)`, differing only in the one extra storage slot already present.
A contract whose storage grows per rail therefore gets more expensive per operation, in a way EVM gas does not model.
