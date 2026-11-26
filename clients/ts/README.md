# @filoz/filecoin-pay-v2

TypeScript client for Filecoin Pay v2. It builds and decodes the scripts that
`FilecoinPayV2.executeScript` runs, reads the contract's state from storage, and exports the contract
ABI. [viem](https://viem.sh) is the only dependency.

## Install

```sh
pnpm add @filoz/filecoin-pay-v2 viem
```

## Usage

```ts
import { FLAG_CALLBACK } from '@filoz/filecoin-pay-v2'
import { filecoinPayV2 } from '@filoz/filecoin-pay-v2/abi'
import { createScript, decodeScript } from '@filoz/filecoin-pay-v2/script'
import { encodeFunctionData } from 'viem'

const script = createScript()
  .setToken(USDFC)
  .createRail(payer, provider, FLAG_CALLBACK | 1n)
  .setRate(1_000n)
  .lock(500_000n)
  .build() // Hex

const data = encodeFunctionData({ abi: filecoinPayV2, functionName: 'executeScript', args: [script] })

decodeScript(script)
// [{ op: 'setToken', args: { token: '0x…' } }, { op: 'createRail', args: { from, recipient, nonce } }, …]
```

The builder is immutable: every method returns a new builder, so a partly built script can be reused.
Integers are `bigint` and are checked against the width of their Solidity type. Every error the package
throws is a `ScriptError` (from `@filoz/filecoin-pay-v2/errors`).

`decodeScript` throws on an unknown opcode and on a truncated op. The contract does neither: it runs an
unknown opcode as `terminateRail` and reads a truncated op past the end of the script.

### Describing a script

`describeScript` returns one plain-English sentence per op, in script order. For the script above:

```ts
describeScript(script)
// [
//   'Select token 0x….',
//   'Create the rail from 0x… to 0x… with nonce 9223372036854775809 (FLAG_CALLBACK | 1) and select it, with the current account as operator, on the selected token.',
//   "Set the selected rail's rate to 1000 per epoch.",
//   "Move 500000 from the payer's balance into the selected rail's lockup.",
// ]
```

It describes each op on its own and does not resolve the account or rail the op applies to. Addresses
are printed in full; they are shortened here. A `pop` outside any block ends the script: the ops
after it are marked as not run and still described, with raw amounts, so the result has one entry per op.

Amounts and rates are raw integers unless you pass `formatAmount`, which also receives the token
selected when the op runs (`NATIVE_TOKEN` for native FIL):

```ts
describeScript(script, {
  formatAmount: (amount, token) => (token === USDFC ? `${formatUnits(amount, 18)} USDFC` : `${amount}`),
})
// [..., "Set the selected rail's rate to 0.000000000000001 USDFC per epoch.", ...]
```

## Ops

A script is a concatenation of ops. Each op is one opcode byte followed by its operands in the order
below, big-endian and tightly packed.

| Op | Method | Operands | Bytes |
|---|---|---|---|
| 0 | `pop` | none | 1 |
| 1 | `push` | none | 1 |
| 2 | `reset` | none | 1 |
| 3 | `sudo` | who: address | 21 |
| 4 | `setToken` | token: address | 21 |
| 5 | `authorize` | operator: address, permissions: uint8 | 22 |
| 6 | `setRail` | from: address, recipient: address, nonce: uint64 | 49 |
| 7 | `createRail` | from: address, recipient: address, nonce: uint64 | 49 |
| 8 | `settleRail` | from: address, recipient: address, nonce: uint64, operator: address | 69 |
| 9 | `withdraw` | amount: uint128 | 17 |
| 10 | `deposit` | amount: uint128 | 17 |
| 11 | `withdrawTo` | amount: uint128, recipient: address | 37 |
| 12 | `depositTo` | amount: uint128, recipient: address | 37 |
| 13 | `transfer` | recipient: address, amount: uint128 | 37 |
| 14 | `transferFrom` | recipient: address, amount: uint128, owner: address | 57 |
| 15 | `transferAll` | recipient: address | 21 |
| 16 | `increaseRate` | rate: uint88 | 12 |
| 17 | `decreaseRate` | rate: uint88 | 12 |
| 18 | `setRate` | rate: uint88 | 12 |
| 19 | `disburseAll` | none | 1 |
| 20 | `disburse` | amount: uint128 | 17 |
| 21 | `lock` | amount: uint128 | 17 |
| 22 | `unlock` | amount: uint128 | 17 |
| 23 | `setAvailable` | amount: uint128 | 17 |
| 24 | `terminateRail` | none | 1 |
| 25 | `terminateRailBy` | operator: address | 21 |

`authorize` takes the full `Permissions` value and encodes its low byte; higher bits are dropped, as in
Solidity.

## Reading state

Rails, balance checkpoints and permissions have no view function. They are read from storage, with
`eth_getStorageAt` or the contract's `extsload(bytes32)`. `@filoz/filecoin-pay-v2/storage` computes the
slots, unpacks the words and reads them.

| Value | Slot | Word (bit offsets from the low end) |
|---|---|---|
| user base (`userSlot`) | `keccak256(abi.encode(owner, uint256(0)))` | accounts mapping at the base, authorizations mapping at base + 1 |
| account checkpoint (`accountSlot`) | `keccak256(abi.encode(token, userSlot))`, native FIL is token 0 | `balance` uint128 @0, `drainRate` uint88 @128, `modifiedEpoch` uint40 @216 |
| permissions (`permissionsSlot`) | `keccak256(abi.encode(operator, userSlot + 1))` | the whole word is the permission bits |
| rail (`railId`) | `keccak256(abi.encodePacked(operator, from, token, recipient, uint64 nonce))`; the rail id is the slot | `incomingRate` uint88 @0, `settledUpTo` uint40 @88, `available` uint128 @128 |

The layout follows `src/lib/User.sol` and `src/lib/RailId.sol`. The tests check it against
[`vectors/storage.json`](../../vectors/storage.json), which is generated from the contract.

Which balance to read:

- The contract's `balanceOf(owner, token)` gives the spendable balance now, and nothing else.
- `readCheckpoint` gives the stored checkpoint: `balance` as of `modifiedEpoch`, which still includes what
  the account's rails have drained since, and the `drainRate`.
- `readAccountState` projects the checkpoint to the block it was read at: the spendable `balance` (equal
  to `balanceOf`), `fundedUntil`, `runway` and `debt`. `fundedUntil` and `runway` are `maxUint256` when
  nothing drains the account. `accountStateAt` does the same from a checkpoint you already hold, with no
  network call.

`readCheckpoint`, `readPermissions`, `readRail` and `readAccountState` each use one `eth_getStorageAt`.
`readSlots` and `readAccountStates` read several slots at one block through Multicall3, in one request
for a short list. The Multicall3 address is `multicallAddress` when given, else the one the client's
chain defines, else `MULTICALL3_ADDRESS`, the standard address. viem's stock `filecoinCalibration` has
no Multicall3 entry, and the fallback covers it.

Reads that must be consistent with each other take the same `blockNumber`. A `blockNumber` that lands
on a Filecoin null round makes the read fail on Lotus-based nodes; the default, the latest block, is
safe. Without `blockNumber`, `readSlots`, `readAccountState` and `readAccountStates` first ask for the
latest block number; pass one you already hold to skip that call.

A rail, its payer's account and the operator's permissions in one request:

```ts
import { hasPermissions, Permissions } from '@filoz/filecoin-pay-v2'
import {
  accountSlot,
  accountStateAt,
  permissionsSlot,
  railId,
  readSlots,
  unpackCheckpoint,
  unpackRail,
} from '@filoz/filecoin-pay-v2/storage'
import { hexToBigInt } from 'viem'
import { getBlockNumber } from 'viem/actions'

const key = { operator, from: payer, token: USDFC, recipient: provider, nonce: 1n }
const blockNumber = await getBlockNumber(client)
const [railWord, payerWord, permissionsWord] = await readSlots(client, {
  address: filecoinPay,
  blockNumber,
  slots: [railId(key), accountSlot(payer, USDFC), permissionsSlot(payer, operator)],
})

const rail = unpackRail(railWord) // { incomingRate, settledUpTo, available, exists }
const payerState = accountStateAt(unpackCheckpoint(payerWord), blockNumber)
const canCreateRails = hasPermissions(hexToBigInt(permissionsWord), Permissions.CREATE_RAIL)
```

`rail.available` is the rail's own balance: funds locked from the payer and, on a rail created with
`FLAG_CALLBACK`, the settled amounts the operator has not disbursed yet.

`extsloadCall` gives the same slot read as a plain call, to mix into your own `multicall` next to calls
to other contracts:

```ts
const [payerWord, walletBalance] = await multicall(client, {
  allowFailure: false,
  contracts: [
    extsloadCall({ address: filecoinPay, slot: accountSlot(payer, USDFC) }),
    { address: USDFC, abi: erc20Abi, functionName: 'balanceOf', args: [payer] },
  ],
})
```

Differences from Filecoin Pay v1:

- There is no account-level lockup. Locked funds live in each rail's `available`, outside the account's
  balance.
- A payer's rails cannot be listed from storage. Get rail ids from `RailCreated` events or an indexer.

## Notes

- The format follows `ScriptBuilder` in [`src/lib/Script.sol`](../../src/lib/Script.sol). The tests check
  the builder and the decoder against [`vectors/script.json`](../../vectors/script.json), which the
  Solidity builder generates.
- A script starts on native FIL (`NATIVE_TOKEN`), so one that only uses native FIL needs no `setToken`.
- `deposit` and `depositTo` are for ERC-20 tokens and revert on native FIL. To deposit native FIL, send
  it as the value of the `executeScript` transaction. It is credited to the sender's balance before the
  script runs, so the script can spend it:

  ```ts
  await walletClient.writeContract({
    address: filecoinPay,
    abi: filecoinPayV2,
    functionName: 'executeScript',
    args: [createScript().transfer(provider, parseEther('0.25')).build()],
    value: parseEther('1'),
  })
  ```
- Rail ops (`increaseRate`, `decreaseRate`, `setRate`, `disburseAll`, `disburse`, `lock`, `unlock`,
  `setAvailable`, `terminateRail`, `terminateRailBy`) act on the rail named by the last `setRail` or
  `createRail`.

## Development

```sh
pnpm install
pnpm lint
pnpm build
pnpm test
pnpm check:package
```

`src/abi/generated.ts` is generated from the contract and is not edited by hand. After the contract's
ABI changes, regenerate it with [Foundry](https://getfoundry.sh) installed and commit the result:

```sh
pnpm generate:abi
```

Nothing else needs Foundry.
