# Filecoin gas benchmark

`forge test` and `vm.snapshotGas` measure EVM gas.
Filecoin charges FVM gas, which prices actor state-tree access rather than EVM opcodes, so EVM gas does not rank Filecoin costs.
This benchmark replays the operations the tests exercise as real transactions and records the gas the node charges.

[`run.py`](run.py) is node-agnostic: `gasUsed` is EVM gas against `anvil` and Filecoin gas against [`fvm-anvil`](https://github.com/Kubuxu/fvm-anvil).
Against `fvm-anvil` it additionally records `filecoin_getGasBreakdown` and the complete `filecoin_getGasTrace`, aggregated by ref-FVM charge name.
Both nodes derive the same accounts from the standard development mnemonic, so one script produces both columns.
[`report.py`](report.py) renders the tables below from the two result files.

Transaction `gasUsed` includes message and calldata overhead, so these numbers are not comparable to the inner-call figure in `snapshots/executeScript.json`; they are comparable to each other.

## Ballast

A freshly deployed contract has an almost empty state tree, and a message that writes into one commits far fewer bytes than the same message would against a contract in use.
Measuring against that tree understates every number, so the runner prefills accounts before it measures anything.

`fvm-anvil` stores EVM storage in a KAMT keyed on the unhashed big-endian slot, five bits per level, one entry per bucket.
Two levels of five bits is 1024 buckets, and [`ballast.py`](ballast.py) fills each of them with exactly two accounts.
Covering every bucket is the point: a new slot anywhere in the key space then lands in a populated bucket, so a measured write walks the same three nodes wherever keccak puts it, and rail storage benefits as much as account storage.

Which owner lands in which bucket is keccak's business, so a set that covers all 1024 buckets takes several times more candidates than it keeps — 12,633 to choose 2048.
That search runs once; its result is the owner list in [`ballast.txt`](ballast.txt), and the benchmark reads it rather than searching again.

The first owner is funded by a real `depositTo`, which proves the recorded slots still match the contract's layout.
The other 2047 are written straight into the actor's storage with `anvil_setStorageAt`, because 2048 transactions take over a minute to leave the same bytes behind.
A plain deposit writes the account's balance and nothing else, so each patched word is exactly what the transaction would have written; the contract is then credited the balances that were not deposited, so the prefilled accounts are backed.

The effect is large and it is the state tree, not the interpreter.
A single-slot write commits four blocks totalling about 3.5 KB, against two blocks and about 200 bytes before the prefill, and each further slot in a different bucket adds two blocks and about 1.7 KB.
`block_persist_storage` charges 334,000 gas per block plus 3,340 per byte, and `block_persist_compute` another 172,000 per block, which accounts for the whole increase.

The ballast covers `FilecoinPayV2` only.
`MockERC20` stands in for a real token and keeps a nearly empty tree, so the `setup:` rows and the ERC-20 half of `executeScript` are still measured against one.

## Isolation

Filecoin gas depends on the storage a message commits, so the runner snapshots the state after deployment, funding, and prefill, and measures each operation from that same baseline, replaying only that operation's own prerequisites and reverting afterwards.
`evm_revert` restores the state root, epoch, and nonces, so a measurement cannot be moved by an unrelated operation: measuring `authorize(bob, ALL)` at the start of a run and again after 21 other transactions have executed and been reverted gives the same 18,840,936 both times.

A measurement is independent of other operations, not of its own prerequisites: `terminateRail` must settle a rail that exists, so it is measured over the storage `createRail` and `modifyRate` wrote.
Each step records the prerequisites it replayed in `prerequisites`.

Snapshots are consumed by the revert that uses them, and reverting discards the receipts and traces of the blocks it drops, so each revert re-takes its snapshot and every measurement is captured before its revert.

With the ballast in place, `--cumulative` reproduces the isolated numbers exactly, on every step.
The ordering dependence isolation was built to remove turns out to be an artifact of the empty tree: without the prefill, one linear run inflated `authorize(operator, CREATE_RAIL)` by 21%, because every message there committed a single root block that each new slot made bigger.
Once the tree is deep, a new slot changes only a leaf, and the interior nodes above it hold fixed-size links.
Isolation is kept because it guarantees that property rather than assuming it.

Isolation changes no EVM number, and neither does the ballast: the `anvil` column is identical with and without 2048 prefilled accounts, because EVM gas does not price the size of the actor's committed storage.
That is why measuring in EVM gas never surfaced any of this.

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
Filecoin gas is charged on the size of the storage a message commits, so a node that has already run the suite carries storage that inflates every number; the runner prefills from genesis state and cannot undo that.

Do not pass `--cumulative` when updating.
It measures one linear run rather than isolating each operation, and deliberately does not write the snapshot.

`ballast.txt` is regenerated only when the storage layout of `users` moves or the ballast parameters change, with `benchmarks/ballast.py`; it takes about ten seconds and rewrites the file in place.
The runner rejects a list that no longer covers the buckets evenly, and the opening `depositTo` fails loudly if the recorded slots no longer match the contract, so a stale file cannot quietly weaken the measurement.

A diff you did not expect from a contract change usually means the environment moved rather than the code.
The `fvm-anvil` revision, network version, actor bundle, solc version, and optimizer settings all shift every number; `benchmarks/results/filecoin-gas.json` records the ones a run used, including the ballast parameters.

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

Recorded at `eaf6149` against `fvm-anvil` `0fafabd` (network version 28, builtin actors 18.0.0) and `anvil` v1.9.0.
The sequences mirror `test/Auth.t.sol`, `test/ERC6909.t.sol`, and `test/Rail.t.sol`; every transaction succeeded and every trace total matched its receipt.
Two further runs from fresh nodes reproduced every number and every per-charge milligas aggregate exactly.

The six deployment and funding steps precede the prefill and the baseline snapshot, and so are measured linearly against an empty tree; the ERC-6909 and rail operations below them are each measured from that baseline, with 2048 accounts already present.

| Step | EVM gas | Filecoin gas | Ratio |
| --- | ---: | ---: | ---: |
| `deploy FilecoinPayV2` | 1,371,452 | 39,116,223 | 29x |
| `deploy MockERC20` | 405,118 | 17,955,350 | 44x |
| `MockERC20.mint(alice)` | 67,798 | 4,701,734 | 69x |
| `MockERC20.mint(bob)` | 50,686 | 4,882,833 | 96x |
| `MockERC20.approve(alice)` | 46,136 | 5,191,567 | 113x |
| `MockERC20.approve(bob)` | 46,136 | 5,453,488 | 118x |
| `authorize(bob, ALL)` | 46,195 | 18,840,936 | 408x |
| `executeScript/pushSudoDepositPopDeposit` | 120,158 | 45,437,191 | 378x |
| `transfer` | 35,302 | 27,046,708 | 766x |
| `approve` | 46,599 | 18,827,210 | 404x |
| `transferFrom` | 60,179 | 35,972,942 | 598x |
| `setOperator` | 45,860 | 18,780,757 | 410x |
| `authorize(operator, CREATE_RAIL)` | 45,835 | 18,720,306 | 408x |
| `createRail` | 49,586 | 19,729,271 | 398x |
| `deposit (native)` | 45,885 | 18,660,455 | 407x |
| `modifyRate` | 39,501 | 28,338,346 | 717x |
| `settleRail` | 55,448 | 27,994,280 | 505x |
| `lock` | 33,478 | 27,101,528 | 810x |
| `disburse` | 35,393 | 26,882,024 | 760x |
| `unlock` | 32,972 | 26,891,492 | 816x |
| `terminateRail` | 37,785 | 34,600,259 | 916x |

| Step | State tree (IPLD blocks and actor records) | EVM interpreter (wasm) | Syscalls and invocation | Chain message |
| --- | ---: | ---: | ---: | ---: |
| `deploy FilecoinPayV2` | 68.8% | 6.0% | 3.0% | 22.3% |
| `deploy MockERC20` | 66.5% | 11.6% | 5.6% | 16.2% |
| `MockERC20.mint(alice)` | 57.6% | 16.6% | 8.1% | 17.7% |
| `MockERC20.mint(bob)` | 58.4% | 16.8% | 7.8% | 17.0% |
| `MockERC20.approve(alice)` | 59.7% | 16.2% | 7.4% | 16.8% |
| `MockERC20.approve(bob)` | 61.3% | 15.7% | 7.0% | 16.0% |
| `authorize(bob, ALL)` | 80.9% | 12.0% | 2.7% | 4.4% |
| `executeScript/pushSudoDepositPopDeposit` | 80.4% | 13.5% | 4.0% | 2.1% |
| `transfer` | 82.7% | 11.5% | 2.4% | 3.4% |
| `approve` | 80.3% | 12.0% | 2.8% | 4.9% |
| `transferFrom` | 83.4% | 11.6% | 2.4% | 2.7% |
| `setOperator` | 80.5% | 12.1% | 2.7% | 4.7% |
| `authorize(operator, CREATE_RAIL)` | 80.8% | 12.0% | 2.7% | 4.4% |
| `createRail` | 78.1% | 14.0% | 3.0% | 4.9% |
| `deposit (native)` | 81.1% | 12.1% | 2.8% | 4.0% |
| `modifyRate` | 80.3% | 13.6% | 2.8% | 3.4% |
| `settleRail` | 80.9% | 12.9% | 2.7% | 3.6% |
| `lock` | 82.5% | 11.7% | 2.3% | 3.5% |
| `disburse` | 82.8% | 11.3% | 2.4% | 3.6% |
| `unlock` | 83.0% | 11.1% | 2.3% | 3.6% |
| `terminateRail` | 82.9% | 11.9% | 2.4% | 2.8% |

## Findings

Filecoin gas is 378-916x EVM gas for the `FilecoinPayV2` operations, and the multiple is largest exactly where EVM gas is smallest: the two cheapest calls in EVM gas, `unlock` and `lock`, carry two of the three largest multiples.
Across the nine rail operations EVM gas spans 33k-55k, a 1.7x spread, while Filecoin gas spans 18.7M-34.6M, a 1.9x spread.
The orderings disagree: `unlock` is the cheapest rail operation in EVM gas and the fifth cheapest in Filecoin gas, while `settleRail` is the dearest in EVM gas and only the third dearest in Filecoin gas.

State-tree access is 78.1% to 83.4% of every `FilecoinPayV2` call, and EVM interpretation never exceeds 14.0%, so removing opcodes moves at most the `wasm` slice.
The lever is the number and size of the IPLD blocks a message touches.

What a message pays is set by how many distinct KAMT buckets it writes into, because each one costs a walk of fixed-size interior nodes.
Operations writing one slot commit three KAMT nodes, those writing two commit five, and `transferFrom`, which writes a balance, an allowance, and a second balance, commits seven: a root, then a level-one node and a leaf per branch.
`terminateRail` writes three slots but commits six nodes rather than seven, because two of them fall in the same level-one subtree.
Co-locating state that is written together is therefore worth more than shrinking it.

Prefilling is what makes any of this visible.
Against a near-empty contract the same operations cost 2.5-5.9x less, and `transferFrom` is the extreme: 6,131,552 against an empty tree and 35,972,942 once 2048 accounts exist, because each of its three slots goes from sharing one small root block to walking its own branch.
Ranking also changes — against the empty tree `transferFrom` was the cheapest ERC-6909 write per EVM gas, and with ballast it is the second most expensive operation measured.
