# @filoz/filecoin-pay-v2

TypeScript client for Filecoin Pay v2. It builds and decodes the scripts that
`FilecoinPayV2.executeScript` runs, and exports the contract ABI. [viem](https://viem.sh) is the only
dependency.

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

## Notes

- The format follows `ScriptBuilder` in [`src/lib/Script.sol`](../../src/lib/Script.sol). The tests check
  the builder and the decoder against [`vectors/script.json`](../../vectors/script.json), which the
  Solidity builder generates.
- A script with no `setToken` acts on native FIL (`NATIVE_TOKEN`).
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
