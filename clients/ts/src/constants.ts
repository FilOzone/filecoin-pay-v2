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
 * Checks that every bit of `required` is set in `permissions`. No network call.
 *
 * @param permissions - The bits held, e.g. from `readPermissions`.
 * @param required - A combination of `Permissions` bits.
 *
 * @example
 * ```ts
 * hasPermissions(Permissions.ALL, Permissions.CREATE_RAIL | Permissions.TRANSFER) // true
 * ```
 */
export function hasPermissions(permissions: bigint, required: bigint): boolean {
  return (permissions & required) === required
}

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

/**
 * The address Multicall3 is deployed at on Filecoin mainnet and calibration,
 * as on most chains. `readSlots` falls back to it when the client's chain
 * defines none, which is the case for viem's stock `filecoinCalibration`.
 */
export const MULTICALL3_ADDRESS = '0xcA11bde05977b3631167028862bE2a173976CA11'
