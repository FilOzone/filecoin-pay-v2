import {
  type Address,
  encodeAbiParameters,
  encodePacked,
  type Hex,
  hexToBigInt,
  isHex,
  keccak256,
  maxUint256,
  size,
} from 'viem'
import { StorageError } from '../errors/storage.ts'

/** The stored balance checkpoint of one account, as packed in its slot. */
export type Checkpoint = {
  /**
   * The balance as of `modifiedEpoch`, not the spendable one: what the
   * account's rails have drained since is still included.
   */
  balance: bigint
  /** Sum of the rates of the rails the account pays, per epoch. */
  drainRate: bigint
  /** The epoch `balance` was last written at. */
  modifiedEpoch: bigint
}

/** The stored state of one rail, as packed in its slot. */
export type Rail = {
  /** What the rail pays its recipient, per epoch. */
  incomingRate: bigint
  /** The epoch the rail is settled up to. Zero only for a rail that does not exist. */
  settledUpTo: bigint
  /**
   * The rail's own balance: funds locked from the payer and, on a rail with
   * `FLAG_CALLBACK`, the settled amounts the operator has not disbursed yet.
   */
  available: bigint
  /** Whether the rail has been created and not terminated. */
  exists: boolean
}

/** What names a rail. The same parties and token can share several rails, told apart by `nonce`. */
export type RailKey = {
  operator: Address
  /** The payer. */
  from: Address
  /** The ERC-20 address, or `NATIVE_TOKEN` for native FIL. */
  token: Address
  /** The payee. */
  recipient: Address
  /** The rail's `uint64` nonce, including `FLAG_CALLBACK` when set. */
  nonce: bigint
}

/**
 * An account at one epoch, derived from its {@link Checkpoint}.
 *
 * Filecoin Pay v2 has no account-level lockup: locked funds live in each
 * rail's `available`, outside the account's balance.
 */
export type AccountState = {
  /**
   * The spendable balance at `epoch`: the checkpoint's stored balance less
   * what the rails have drained since, floored at zero. Equal to the
   * contract's `balanceOf` at that block.
   */
  balance: bigint
  /** Sum of the rates of the rails the account pays, per epoch. */
  drainRate: bigint
  /**
   * The epoch the stored balance lasts to at `drainRate`, in the past when it
   * has already run out. `maxUint256` when `drainRate` is zero.
   */
  fundedUntil: bigint
  /**
   * Epochs from `epoch` to `fundedUntil`, zero when already past it.
   * `maxUint256` when `drainRate` is zero.
   */
  runway: bigint
  /**
   * What the rails are owed beyond the stored balance at `epoch`, zero while
   * the account is funded. Derived here; the contract stores no such field.
   */
  debt: bigint
  /** The epoch this state was computed at. */
  epoch: bigint
}

/**
 * Computes the base slot of a user. No network call.
 *
 * The user's accounts mapping is at this slot and its authorizations mapping
 * at the next one.
 *
 * @param owner - The user's address.
 * @returns The 32-byte slot.
 */
export function userSlot(owner: Address): Hex {
  return keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [owner, 0n]))
}

/**
 * Computes the slot of an account's balance checkpoint. No network call.
 *
 * @param owner - The account's owner.
 * @param token - The ERC-20 address, or `NATIVE_TOKEN` for native FIL.
 * @returns The 32-byte slot, whose word {@link unpackCheckpoint} reads.
 *
 * @example
 * ```ts
 * import { NATIVE_TOKEN } from '@filoz/filecoin-pay-v2'
 * import { accountSlot } from '@filoz/filecoin-pay-v2/storage'
 *
 * const slot = accountSlot(owner, NATIVE_TOKEN)
 * ```
 */
export function accountSlot(owner: Address, token: Address): Hex {
  return keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'bytes32' }], [token, userSlot(owner)]))
}

/**
 * Computes the slot of the permissions `owner` granted `operator`. No network call.
 *
 * @param owner - The account that granted the permissions.
 * @param operator - The account that holds them.
 * @returns The 32-byte slot, whose whole word is the `Permissions` bits.
 */
export function permissionsSlot(owner: Address, operator: Address): Hex {
  return keccak256(
    encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [operator, hexToBigInt(userSlot(owner)) + 1n])
  )
}

/**
 * Computes a rail's id, which is also the slot of its state. No network call.
 *
 * @param rail - {@link RailKey}
 * @returns The 32-byte rail id, whose word {@link unpackRail} reads.
 *
 * @example
 * ```ts
 * import { railId } from '@filoz/filecoin-pay-v2/storage'
 *
 * const id = railId({ operator, from: payer, token: USDFC, recipient: provider, nonce: 1n })
 * ```
 */
export function railId(rail: RailKey): Hex {
  return keccak256(
    encodePacked(
      ['address', 'address', 'address', 'address', 'uint64'],
      [rail.operator, rail.from, rail.token, rail.recipient, rail.nonce]
    )
  )
}

function wordToBigInt(word: Hex): bigint {
  if (!isHex(word, { strict: true }) || size(word) !== 32) {
    throw new StorageError(`Storage word must be 32 bytes of hex, got ${word}`)
  }
  return hexToBigInt(word)
}

/**
 * Unpacks the word at an {@link accountSlot}. No network call.
 *
 * @param word - The 32-byte storage word.
 * @returns The stored {@link Checkpoint}.
 * @throws A {@link StorageError} if `word` is not 32 bytes of hex.
 */
export function unpackCheckpoint(word: Hex): Checkpoint {
  const packed = wordToBigInt(word)
  return {
    balance: BigInt.asUintN(128, packed),
    drainRate: BigInt.asUintN(88, packed >> 128n),
    modifiedEpoch: packed >> 216n,
  }
}

/**
 * Unpacks the word at a {@link railId}. No network call.
 *
 * @param word - The 32-byte storage word.
 * @returns The stored {@link Rail}. A zero word gives a rail that does not exist.
 * @throws A {@link StorageError} if `word` is not 32 bytes of hex.
 */
export function unpackRail(word: Hex): Rail {
  const packed = wordToBigInt(word)
  const settledUpTo = BigInt.asUintN(40, packed >> 88n)
  return {
    incomingRate: BigInt.asUintN(88, packed),
    settledUpTo,
    available: packed >> 128n,
    exists: settledUpTo !== 0n,
  }
}

/**
 * Computes an account's state at an epoch from its checkpoint. No network call.
 *
 * The result's `balance` is the spendable balance, as the contract's
 * `balanceOf` reports it at that block, while the checkpoint's `balance` is
 * the raw stored one.
 *
 * @param checkpoint - The account's stored {@link Checkpoint}.
 * @param epoch - The epoch (block number) to compute the state at.
 * @returns The {@link AccountState} at `epoch`.
 * @throws A {@link StorageError} if `epoch` is before the checkpoint's `modifiedEpoch`.
 *
 * @example
 * ```ts
 * import { accountStateAt, unpackCheckpoint } from '@filoz/filecoin-pay-v2/storage'
 *
 * const state = accountStateAt(unpackCheckpoint(word), blockNumber)
 * if (state.debt > 0n) console.log('underfunded since epoch', state.fundedUntil)
 * ```
 */
export function accountStateAt(checkpoint: Checkpoint, epoch: bigint): AccountState {
  const { balance, drainRate, modifiedEpoch } = checkpoint
  if (epoch < modifiedEpoch) {
    throw new StorageError(`Epoch ${epoch} is before the checkpoint's modifiedEpoch ${modifiedEpoch}`)
  }
  const drained = drainRate * (epoch - modifiedEpoch)
  const fundedUntil = drainRate === 0n ? maxUint256 : modifiedEpoch + balance / drainRate
  return {
    balance: drained < balance ? balance - drained : 0n,
    drainRate,
    fundedUntil,
    runway: drainRate === 0n ? maxUint256 : fundedUntil > epoch ? fundedUntil - epoch : 0n,
    debt: drained > balance ? drained - balance : 0n,
    epoch,
  }
}
