# Filecoin gas benchmark

Filecoin charges FVM gas, which prices actor state-tree access rather than EVM opcodes.
EVM gas therefore does not rank Filecoin costs, and `forge test` measures only EVM gas.
This benchmark replays the operations the tests exercise as real transactions and records what the node charges.

[`run.py`](run.py) is node-agnostic: `gasUsed` is EVM gas against `anvil` and Filecoin gas against [`fvm-anvil`](https://github.com/Kubuxu/fvm-anvil).
Both nodes derive their accounts from the standard development mnemonic, so one script produces both columns.
Against `fvm-anvil` it also records `filecoin_getGasBreakdown` and the full `filecoin_getGasTrace`, aggregated by ref-FVM charge name.
[`report.py`](report.py) renders the tables below from the two result files.

`gasUsed` is per transaction and includes message and calldata overhead, so these numbers compare to each other but not to the inner-call figure in `snapshots/executeScript.json`.

## Ballast

A message that writes into a nearly empty state tree commits far fewer bytes than the same message against a contract in use, so the runner prefills 2048 accounts before measuring anything.

`fvm-anvil` keeps EVM storage in a KAMT keyed on the unhashed big-endian slot, five bits per level, one entry per bucket.
Two levels of five bits is 1024 buckets, and [`ballast.py`](ballast.py) puts exactly two accounts in each.
Covering every bucket is the point: a new slot anywhere in the key space lands in a populated one, so a measured write walks the same three nodes wherever keccak puts it, and rail storage benefits as much as account storage.

Keccak decides which owner lands where, so covering all 1024 buckets takes 12,633 candidates to yield 2048.
That search runs once and its result is the owner list in [`ballast.txt`](ballast.txt).

The first owner is funded by a real `depositTo`, which proves the recorded slots still match the contract's layout.
The other 2047 are written with `anvil_setStorageAt`, since 2048 transactions take over a minute to leave the same bytes behind.
A plain deposit writes the balance word and nothing else, so each patched word is what the transaction would have written; the contract is then credited the balances that were not deposited.

The ballast covers `FilecoinPayV2` only.
`MockERC20` stands in for a real token and keeps a nearly empty tree, so the `setup:` rows and the ERC-20 half of `executeScript` are still measured against one.

## Isolation

Filecoin gas depends on the storage a message commits, so measuring a sequence linearly would charge each operation for whatever its predecessors wrote.
The runner instead snapshots the state after deployment, funding, and prefill, then measures each operation from that baseline, replaying only its own prerequisites and reverting afterwards.
`evm_revert` restores the state root, epoch, and nonces: `authorize(bob, ALL)` measures 18,804,913 both at the start of a run and after 21 other transactions have executed and been reverted.

A measurement is independent of other operations, not of its own prerequisites.
`terminateRail` must settle a rail that exists, so it is measured over the storage `createRail` and `modifyRate` wrote, and each step records what it replayed in `prerequisites`.

`--cumulative` measures one linear run instead, and currently reproduces the isolated numbers exactly on every step.
That is a property of the prefilled tree rather than a guarantee: a new slot changes only a leaf, and the interior nodes above it hold fixed-size links.
Isolation stays the default because it enforces that independence rather than relying on it.

## Updating the snapshot

[`.filecoin-gas-snapshot`](../.filecoin-gas-snapshot) is the checked-in record, one sorted `sequence:operation (gas: n)` line per measurement in the shape of forge's `.gas-snapshot`.
Regenerate it whenever a change could move Filecoin gas, so the pull request carries the delta as a line diff.

Every state-changing external method has a row, and every opcode in [`src/lib/Script.sol`](../src/lib/Script.sol) appears in at least one `executeScript` row, so a new method or op needs a step here before its gas is tracked.
The script steps group several ops each (`moveOps`, `rateOps`, `lockupOps`, `settleReset`) instead of one op per row, because the runner replays every predecessor of each measured step, so a sequence of n steps costs about n²/2 transactions.
A step has to write something no earlier step already wrote: a message that rewrites a value already in place commits no blocks and prices nothing, which is worth about 14M here.

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

Restart the node first.
The runner prefills from genesis state and cannot undo storage a previous run left behind, which would inflate every number.
Do not pass `--cumulative`; it deliberately does not write the snapshot.

[`.github/workflows/gas.yml`](../.github/workflows/gas.yml) runs this same regeneration on every push and pull request and fails if the result differs from the committed file.
It pins the `fvm-anvil` revision, because the ref-FVM and builtin-actor versions set every number, so bumping that pin and committing the regenerated snapshot belong in one change.
The job runs on `ubuntu-latest`, which is therefore the environment the committed snapshot has to match.

An unexpected diff more often means the environment moved than the code.
The `fvm-anvil` revision, network version, actor bundle, solc version, and optimizer settings all shift every number, and `benchmarks/results/filecoin-gas.json` records the ones a run used.

`ballast.txt` is regenerated with `benchmarks/ballast.py`, taking about ten seconds, and only when the storage layout of `users` moves or the ballast parameters change.
A stale file cannot quietly weaken the measurement: the runner rejects an owner list that no longer covers the buckets evenly, and the opening `depositTo` fails if the recorded slots no longer match the contract.

## Regenerating the tables below

The tables also need the EVM column, from the same runner against `anvil`:

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
Everything under `benchmarks/results/` is generated and is not checked in.

## Results

Recorded against `fvm-anvil` `0fafabd` (network version 28, builtin actors 18.0.0) and `anvil` v1.9.0, from the contracts this tree builds.
The sequences mirror `test/Auth.t.sol`, `test/ERC6909.t.sol`, and `test/Rail.t.sol`; every transaction succeeded and every trace total matched its receipt.
A further run from a fresh node reproduced every number and every per-charge milligas aggregate exactly.

The six deployment and funding steps precede the prefill and the baseline snapshot, so they are measured linearly against an empty tree.
Each ERC-6909 and rail operation below them is measured from the baseline, with 2048 accounts already present.

| Step | EVM gas | Filecoin gas | Ratio |
| --- | ---: | ---: | ---: |
| `deploy FilecoinPayV2` | 1,237,172 | 36,155,668 | 29x |
| `deploy MockERC20` | 388,263 | 17,585,216 | 45x |
| `MockERC20.mint(alice)` | 67,798 | 4,698,928 | 69x |
| `MockERC20.mint(bob)` | 50,686 | 4,880,027 | 96x |
| `MockERC20.approve(alice)` | 46,136 | 5,188,761 | 112x |
| `MockERC20.approve(bob)` | 46,136 | 5,450,681 | 118x |
| `authorize(bob, ALL)` | 46,195 | 18,804,913 | 407x |
| `executeScript/pushSudoDepositPopDeposit` | 120,216 | 45,402,251 | 378x |
| `transfer` | 35,374 | 27,021,529 | 764x |
| `approve` | 46,599 | 18,791,187 | 403x |
| `transferFrom` | 60,263 | 35,949,095 | 597x |
| `setOperator` | 45,860 | 18,744,734 | 409x |
| `authorize(operator, CREATE_RAIL)` | 45,835 | 18,684,283 | 408x |
| `createRail` | 49,586 | 19,693,248 | 397x |
| `deposit (native)` | 45,907 | 18,625,075 | 406x |
| `modifyRate` | 39,501 | 28,302,323 | 716x |
| `settleRail` | 55,448 | 27,958,257 | 504x |
| `lock` | 33,478 | 27,065,505 | 808x |
| `disburse` | 35,393 | 26,846,001 | 759x |
| `unlock` | 32,972 | 26,855,469 | 814x |
| `terminateRail` | 37,785 | 34,564,236 | 915x |

| Step | State tree (IPLD blocks and actor records) | EVM interpreter (wasm) | Syscalls and invocation | Chain message |
| --- | ---: | ---: | ---: | ---: |
| `deploy FilecoinPayV2` | 68.6% | 6.4% | 3.1% | 21.9% |
| `deploy MockERC20` | 66.4% | 11.9% | 5.7% | 16.0% |
| `MockERC20.mint(alice)` | 57.6% | 16.6% | 8.1% | 17.7% |
| `MockERC20.mint(bob)` | 58.4% | 16.8% | 7.8% | 17.0% |
| `MockERC20.approve(alice)` | 59.7% | 16.1% | 7.4% | 16.8% |
| `MockERC20.approve(bob)` | 61.3% | 15.6% | 7.0% | 16.0% |
| `authorize(bob, ALL)` | 81.0% | 11.8% | 2.7% | 4.4% |
| `executeScript/pushSudoDepositPopDeposit` | 80.4% | 13.4% | 4.0% | 2.1% |
| `transfer` | 82.7% | 11.5% | 2.4% | 3.4% |
| `approve` | 80.4% | 11.9% | 2.8% | 4.9% |
| `transferFrom` | 83.4% | 11.5% | 2.4% | 2.7% |
| `setOperator` | 80.6% | 12.0% | 2.7% | 4.7% |
| `authorize(operator, CREATE_RAIL)` | 80.9% | 11.9% | 2.7% | 4.4% |
| `createRail` | 78.2% | 13.9% | 3.0% | 4.9% |
| `deposit (native)` | 81.2% | 12.0% | 2.8% | 4.0% |
| `modifyRate` | 80.3% | 13.5% | 2.8% | 3.4% |
| `settleRail` | 81.0% | 12.8% | 2.7% | 3.6% |
| `lock` | 82.5% | 11.6% | 2.3% | 3.5% |
| `disburse` | 82.8% | 11.2% | 2.4% | 3.6% |
| `unlock` | 83.1% | 11.0% | 2.3% | 3.6% |
| `terminateRail` | 83.0% | 11.9% | 2.4% | 2.8% |

## Findings

Filecoin gas is 378-916x EVM gas for the `FilecoinPayV2` operations, and the multiple is largest where EVM gas is smallest: `unlock` and `lock`, the two cheapest calls in EVM gas, carry two of the three largest multiples.
Across the nine rail operations EVM gas spans 33k-55k and Filecoin gas 18.7M-34.6M, comparable spreads in different orders.
`unlock` is the cheapest rail operation in EVM gas and the fifth cheapest in Filecoin gas; `settleRail` is the dearest in EVM gas and only the third dearest in Filecoin gas.

State-tree access is 78.1% to 83.4% of every `FilecoinPayV2` call and EVM interpretation never exceeds 14.0%, so removing opcodes moves at most the `wasm` slice.
What a message pays is set by how many distinct KAMT buckets it writes into, because each one costs a walk of fixed-size interior nodes.
An operation writing one slot commits three KAMT nodes, one writing two commits five, and `transferFrom`, which writes a balance, an allowance, and a second balance, commits seven: a root, then a level-one node and a leaf per branch.
`terminateRail` writes three slots but commits six rather than seven, two of them falling in the same level-one subtree.
Co-locating state that is written together is therefore worth more than shrinking it.

`block_persist_storage` charges 334,000 gas per committed block plus 3,340 per byte, and `block_persist_compute` another 172,000 per block.
A single-slot write commits four blocks totalling about 3.5 KB, against two blocks of about 200 bytes on an empty tree, which is why the same operations cost 2.5-5.9x less there.
The `anvil` column is identical with and without the 2048 prefilled accounts, because EVM gas does not price the size of the actor's committed storage.
That is why measuring in EVM gas never surfaced any of this.
