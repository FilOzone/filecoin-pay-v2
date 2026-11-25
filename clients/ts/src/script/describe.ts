import type { Address, Hex } from 'viem'
import { FLAG_CALLBACK, NATIVE_TOKEN, Permissions } from '../constants.ts'
import { type DecodedOp, decodeScript } from './decode.ts'
import type { OpName } from './ops.ts'

const PERMISSION_BITS = ['DEPOSIT', 'WITHDRAW', 'TRANSFER', 'CREATE_RAIL', 'APPROVE', 'AUTHORIZE'] as const

function permissionNames(permissions: bigint): string {
  const names: string[] = PERMISSION_BITS.filter((name) => permissions & Permissions[name])
  const unnamed = PERMISSION_BITS.reduce((rest, name) => rest & ~Permissions[name], permissions)
  if (unnamed) names.push(`0x${unnamed.toString(16)}`)
  return names.join(' | ') || 'NONE'
}

function rail(from: Address, recipient: Address, nonce: bigint): string {
  // The flag is part of the nonce in the rail id and in events, so the whole number comes first.
  const breakdown = nonce & FLAG_CALLBACK ? ` (FLAG_CALLBACK | ${nonce ^ FLAG_CALLBACK})` : ''
  return `rail from ${from} to ${recipient} with nonce ${nonce}${breakdown}`
}

// Amounts and rates reach the templates already formatted.
type Args<N extends OpName> = Extract<DecodedOp, { op: N }>['args']
type Shown<T> = { [K in keyof T]: K extends 'amount' | 'rate' ? string : T[K] }

const descriptions: { [N in OpName]: (args: Shown<Args<N>>) => string } = {
  pop: () => 'Close the current block.',
  push: () => 'Open a block; changes to the account, token, and rail made inside it are undone at the matching pop.',
  reset: () => 'Restore the account, token, and rail to what they were when the current block started.',
  sudo: ({ who }) =>
    `Act as ${who}, using the permissions it granted to the current account, up to those the script holds.`,
  setToken: ({ token }) => (token === NATIVE_TOKEN ? 'Select native FIL.' : `Select token ${token}.`),
  authorize: ({ operator, permissions }) =>
    `Set the permissions of ${operator} over the current account to ${permissionNames(permissions)}, up to those the script holds.`,
  setRail: ({ from, recipient, nonce }) =>
    `Select the ${rail(from, recipient, nonce)} for the rail operations that follow.`,
  createRail: ({ from, recipient, nonce }) =>
    `Create the ${rail(from, recipient, nonce)} and select it, with the current account as operator, on the selected token.`,
  settleRail: ({ from, recipient, nonce, operator }) =>
    `Settle the ${rail(from, recipient, nonce)} on the selected token, with ${operator} as operator.`,
  withdraw: ({ amount }) =>
    `Withdraw ${amount} of the selected token from the current account's balance to the current account's address.`,
  deposit: ({ amount }) =>
    `Deposit ${amount} of the selected token from the current account's address into the current account's balance.`,
  withdrawTo: ({ amount, recipient }) =>
    `Withdraw ${amount} of the selected token from the current account's balance to the address ${recipient}.`,
  depositTo: ({ amount, recipient }) =>
    `Deposit ${amount} of the selected token from the current account's address into the balance of ${recipient}.`,
  transfer: ({ recipient, amount }) =>
    `Transfer ${amount} of the selected token from the current account's balance to the balance of ${recipient}.`,
  transferFrom: ({ recipient, amount, owner }) =>
    `Transfer ${amount} of the selected token from the balance of ${owner} to the balance of ${recipient}, with the current account spending as an operator or through an allowance.`,
  transferAll: ({ recipient }) =>
    `Transfer the current account's entire spendable balance of the selected token to the balance of ${recipient}.`,
  increaseRate: ({ rate }) => `Increase the selected rail's rate by ${rate} per epoch.`,
  decreaseRate: ({ rate }) => `Decrease the selected rail's rate by ${rate} per epoch.`,
  setRate: ({ rate }) => `Set the selected rail's rate to ${rate} per epoch.`,
  disburseAll: () => "Pay out the selected rail's entire lockup to its recipient.",
  disburse: ({ amount }) => `Pay out ${amount} of the selected rail's lockup to its recipient.`,
  lock: ({ amount }) => `Move ${amount} from the payer's balance into the selected rail's lockup.`,
  unlock: ({ amount }) => `Move ${amount} from the selected rail's lockup back to the payer's balance.`,
  setAvailable: ({ amount }) => `Lock or unlock funds so the selected rail's lockup becomes exactly ${amount}.`,
  terminateRail: () => 'Terminate the selected rail, acting as its operator.',
  terminateRailBy: ({ operator }) =>
    `Terminate the rail paid by the current account on the selected token, using the selected recipient and nonce, with ${operator} as its operator.`,
}

/**
 * Describes a script in plain English, one sentence per op.
 *
 * Each sentence describes its op on its own: it says "the current account",
 * "the selected token" and "the selected rail" without resolving them. Only
 * the selected token is tracked, through `setToken`, `push`, `pop` and
 * `reset`, to hand it to `formatAmount`.
 *
 * A `pop` outside any block ends the script. The ops after it are marked as
 * not run and still described, with raw amounts: they are not passed to
 * `formatAmount`. The result has one entry per decoded op.
 *
 * @param script - The script bytes, as built by `createScript`.
 * @param options.formatAmount - Formats every amount and rate operand. `token` is the token selected
 * when the op runs, `NATIVE_TOKEN` for native FIL. Defaults to the raw integer.
 * @returns One sentence per decoded op, in script order. An empty script gives `[]`.
 * @throws A {@link ScriptError} where `decodeScript` does.
 *
 * @example
 * ```ts
 * import { describeScript } from '@filoz/filecoin-pay-v2/script'
 * import { formatUnits } from 'viem'
 *
 * describeScript(createScript().setToken(USDFC).setRate(1_000n).lock(5n * 10n ** 18n).build(), {
 *   formatAmount: (amount, token) => (token === USDFC ? `${formatUnits(amount, 18)} USDFC` : `${amount}`),
 * })
 * // [
 * //   'Select token 0x….',
 * //   "Set the selected rail's rate to 0.000000000000001 USDFC per epoch.",
 * //   "Move 5 USDFC from the payer's balance into the selected rail's lockup.",
 * // ]
 * ```
 */
export function describeScript(
  script: Hex,
  options: { formatAmount?: (amount: bigint, token: Address) => string } = {}
): string[] {
  // The token each open block started with; the script itself starts on native FIL.
  const starts: Address[] = [NATIVE_TOKEN]
  let token: Address = NATIVE_TOKEN
  let ended = false
  return decodeScript(script).map((decoded) => {
    const sentence = (format: (amount: bigint, token: Address) => string = String) =>
      (descriptions[decoded.op] as (args: never) => string)(
        Object.fromEntries(
          Object.entries(decoded.args).map(([name, value]) => [
            name,
            name === 'amount' || name === 'rate' ? format(value as bigint, token) : value,
          ])
        ) as never
      )
    if (ended) return `Not run (the script ended at the pop above): ${sentence()}`
    if (decoded.op === 'pop' && starts.length === 1) {
      ended = true
      return 'End the script; the operations after it do not run.'
    }
    if (decoded.op === 'setToken') token = decoded.args.token
    else if (decoded.op === 'push') starts.push(token)
    else if (decoded.op === 'reset') token = starts[starts.length - 1]
    else if (decoded.op === 'pop') token = starts.pop() as Address
    return sentence(options.formatAmount)
  })
}
