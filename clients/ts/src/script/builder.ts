import { type Address, concat, type Hex, isAddress, numberToHex } from 'viem'
import { ScriptError } from '../errors/script.ts'
import { type Op, type OperandType, type OperandValue, operandSize, ops } from './ops.ts'

/**
 * Immutable builder of a script for `FilecoinPayV2.executeScript`.
 *
 * Each op method returns a new builder with that op appended and leaves the
 * receiver unchanged, so a partly built script can be extended more than once.
 * Ops run in the order they were appended.
 *
 * Every op method throws a {@link ScriptError} naming the op and the operand
 * when an integer is negative or exceeds its Solidity type, or when an address
 * is not valid.
 *
 * A script starts with its sender as the current account, on native FIL, with
 * no rail selected.
 */
export interface ScriptBuilder {
  /**
   * Ends the block opened by the last `push`, restoring the state from before it.
   *
   * Outside any block it ends the script: the ops after it do not run.
   */
  pop(): ScriptBuilder
  /** Opens a block. `sudo`, `setToken` and rail selections made inside it last until the matching `pop`. */
  push(): ScriptBuilder
  /** Restores the state the current block started with. */
  reset(): ScriptBuilder
  /**
   * Acts as `who` for the ops that follow, with the permissions `who` granted the current account
   * that the script also holds at that point.
   *
   * @param who - The account that authorized the current one.
   */
  sudo(who: Address): ScriptBuilder
  /**
   * Selects the token the ops that follow act on.
   *
   * @param token - The ERC-20 address, or `NATIVE_TOKEN` for native FIL.
   */
  setToken(token: Address): ScriptBuilder
  /**
   * Sets the permissions `operator` holds over the current account.
   *
   * Only the bits the script itself holds at that point are granted, which matters under the scoped
   * `executeScript` and after `sudo`.
   *
   * @param operator - The account receiving the permissions.
   * @param permissions - A combination of `Permissions` bits. Any `uint256` is
   * accepted, but only the low byte is encoded: higher bits are dropped.
   */
  authorize(operator: Address, permissions: bigint): ScriptBuilder
  /**
   * Selects an existing rail for the rail ops that follow, without creating it.
   *
   * The rail is the one the current account operates on the selected token.
   *
   * @param from - The payer.
   * @param recipient - The payee.
   * @param nonce - The rail's `uint64` nonce.
   */
  setRail(from: Address, recipient: Address, nonce: bigint): ScriptBuilder
  /**
   * Creates a rail operated by the current account and selects it for the rail ops that follow.
   *
   * The selected token is part of the rail's identity, along with the operator and the operands.
   *
   * @param from - The payer.
   * @param recipient - The payee.
   * @param nonce - A `uint64` that tells apart rails between the same parties.
   * Set `FLAG_CALLBACK` to settle the rail through the operator's callback.
   */
  createRail(from: Address, recipient: Address, nonce: bigint): ScriptBuilder
  /**
   * Settles the named rail on the selected token. It does not change the selected rail.
   *
   * @param from - The payer.
   * @param recipient - The payee.
   * @param nonce - The rail's `uint64` nonce.
   * @param operator - The rail's operator.
   */
  settleRail(from: Address, recipient: Address, nonce: bigint, operator: Address): ScriptBuilder
  /** Withdraws `amount` (`uint128`) of the token from the current account's balance to its own address. */
  withdraw(amount: bigint): ScriptBuilder
  /** Deposits `amount` (`uint128`) of the token from the current account's address into its balance. */
  deposit(amount: bigint): ScriptBuilder
  /** Withdraws `amount` (`uint128`) of the token from the current account's balance to `recipient`'s address. */
  withdrawTo(amount: bigint, recipient: Address): ScriptBuilder
  /** Deposits `amount` (`uint128`) of the token from the current account's address into `recipient`'s balance. */
  depositTo(amount: bigint, recipient: Address): ScriptBuilder
  /** Moves `amount` (`uint128`) of the token from the current account's balance to `recipient`'s. */
  transfer(recipient: Address, amount: bigint): ScriptBuilder
  /**
   * Moves `amount` (`uint128`) of the token from `owner`'s balance to `recipient`'s.
   *
   * The current account must be `owner`'s operator or hold an allowance from it.
   */
  transferFrom(recipient: Address, amount: bigint, owner: Address): ScriptBuilder
  /**
   * Moves the current account's whole spendable balance of the token to `recipient`.
   *
   * What its rails have accrued but not yet settled stays behind.
   */
  transferAll(recipient: Address): ScriptBuilder
  /** Raises the selected rail's rate by `rate` (`uint88`). */
  increaseRate(rate: bigint): ScriptBuilder
  /** Lowers the selected rail's rate by `rate` (`uint88`). */
  decreaseRate(rate: bigint): ScriptBuilder
  /** Sets the selected rail's rate to `rate` (`uint88`). */
  setRate(rate: bigint): ScriptBuilder
  /** Pays out the selected rail's whole lockup to its recipient. */
  disburseAll(): ScriptBuilder
  /** Pays out `amount` (`uint128`) of the selected rail's lockup to its recipient. */
  disburse(amount: bigint): ScriptBuilder
  /** Moves `amount` (`uint128`) from the payer's balance into the selected rail's lockup. */
  lock(amount: bigint): ScriptBuilder
  /** Moves `amount` (`uint128`) from the selected rail's lockup back to the payer's balance. */
  unlock(amount: bigint): ScriptBuilder
  /** Locks or unlocks the difference, so that the selected rail's lockup is exactly `amount` (`uint128`). */
  setAvailable(amount: bigint): ScriptBuilder
  /** Terminates the selected rail, as its operator. */
  terminateRail(): ScriptBuilder
  /** Terminates the selected rail, as its payer, naming its `operator`. */
  terminateRailBy(operator: Address): ScriptBuilder
  /** Returns the script bytes to pass to `executeScript`. An empty script is `0x`. */
  build(): Hex
}

type Values<T extends readonly (readonly [string, OperandType])[]> = { -readonly [I in keyof T]: OperandValue<T[I][1]> }
type OpMethods = { [O in Op as O['name']]: (...args: Values<O['operands']>) => ScriptBuilder }

// Fails to compile unless the hand-written op methods and the op table have the same names, each with
// the same operand count and types. Operand names and the order of same-typed operands are not compared.
type Signatures<T> = { [K in keyof T]: T[K] extends (...args: infer A) => unknown ? A : never }
type Same<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false
type Assert<T extends true> = T
type _MethodsMatchTable = Assert<Same<Signatures<OpMethods>, Signatures<Omit<ScriptBuilder, 'build'>>>>

/**
 * Starts an empty script.
 *
 * @returns An immutable {@link ScriptBuilder}.
 *
 * @example
 * ```ts
 * import { FLAG_CALLBACK } from '@filoz/filecoin-pay-v2'
 * import { createScript } from '@filoz/filecoin-pay-v2/script'
 *
 * const script = createScript()
 *   .setToken(USDFC)
 *   .createRail(payer, provider, FLAG_CALLBACK | 1n)
 *   .setRate(1_000n)
 *   .lock(500_000n)
 *   .build()
 * ```
 */
export function createScript(): ScriptBuilder {
  return builder('0x')
}

function builder(script: Hex): ScriptBuilder {
  const methods = Object.fromEntries(
    ops.map((op) => [op.name, (...args: unknown[]) => builder(concat([script, encodeOp(op, args)]))])
  ) as unknown as OpMethods
  return { ...methods, build: () => script }
}

function encodeOp(op: Op, args: readonly unknown[]): Hex {
  return concat([
    numberToHex(op.opcode, { size: 1 }),
    ...op.operands.map(([name, type], i) => encodeOperand(op.name, name, type, args[i])),
  ])
}

function encodeOperand(op: string, name: string, type: OperandType, value: unknown): Hex {
  if (type === 'address') {
    if (typeof value !== 'string' || !isAddress(value)) {
      throw new ScriptError(`${op}: ${name} must be an address, got ${String(value)}`)
    }
    return value.toLowerCase() as Hex
  }
  const size = operandSize(type)
  // Solidity's authorize takes the uint256 Permissions and keeps its low byte.
  const bits = op === 'authorize' ? 256 : size * 8
  if (typeof value !== 'bigint' || value < 0n || value >> BigInt(bits) !== 0n) {
    throw new ScriptError(`${op}: ${name} must be a uint${bits}, got ${String(value)}`)
  }
  return numberToHex(BigInt.asUintN(size * 8, value), { size })
}
