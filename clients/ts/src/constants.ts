import { zeroAddress } from 'viem'

/**
 * Permission bits an account grants an operator with `authorize`, or a caller
 * narrows a script to with the scoped `executeScript`. Combine them with `|`.
 *
 * @example
 * ```ts
 * import { Permissions } from '@filoz/filecoin-pay-v2'
 *
 * const permissions = Permissions.DEPOSIT | Permissions.CREATE_RAIL
 * ```
 */
export const Permissions = {
  NONE: 0n,
  DEPOSIT: 1n << 0n,
  WITHDRAW: 1n << 1n,
  TRANSFER: 1n << 2n,
  /** Lets the operator open rails that draw from the account. */
  CREATE_RAIL: 1n << 3n,
  APPROVE: 1n << 4n,
  /** Lets the operator delegate permissions onward, never more than it holds. */
  AUTHORIZE: 1n << 5n,
  /** `DEPOSIT | TRANSFER` */
  DEPOSIT_TO: (1n << 0n) | (1n << 2n),
  /** `WITHDRAW | TRANSFER` */
  WITHDRAW_TO: (1n << 1n) | (1n << 2n),
  /** Every bit of a `uint256`. */
  ALL: 2n ** 256n - 1n,
} as const

/**
 * High bit of a rail nonce. A rail created with it settles through the
 * operator's callback.
 *
 * @example
 * ```ts
 * createScript().createRail(payer, provider, FLAG_CALLBACK | 1n)
 * ```
 */
export const FLAG_CALLBACK = 1n << 63n

/**
 * Token address that stands for native FIL. A script acts on it until its
 * first `setToken`.
 */
export const NATIVE_TOKEN = zeroAddress
