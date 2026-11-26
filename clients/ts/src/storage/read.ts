import {
  type Address,
  type Chain,
  type Client,
  type ContractFunctionParameters,
  type Hex,
  hexToBigInt,
  pad,
  type Transport,
} from 'viem'
import { getBlockNumber, getStorageAt, multicall } from 'viem/actions'
import { filecoinPayV2 } from '../abi/index.ts'
import { MULTICALL3_ADDRESS } from '../constants.ts'
import {
  type AccountState,
  accountSlot,
  accountStateAt,
  type Checkpoint,
  permissionsSlot,
  type Rail,
  type RailKey,
  railId,
  unpackCheckpoint,
  unpackRail,
} from './layout.ts'

type ReadOptions = {
  /** The FilecoinPayV2 contract address. */
  address: Address
  /**
   * The block to read at. Defaults to the latest block. A Filecoin null round
   * given here makes the read fail on Lotus-based nodes.
   */
  blockNumber?: bigint
}

type MulticallOptions = {
  /** The Multicall3 address. Defaults to the client chain's, else `MULTICALL3_ADDRESS`. */
  multicallAddress?: Address
}

async function readSlot(client: Client<Transport, Chain | undefined>, options: ReadOptions & { slot: Hex }) {
  // Nodes may answer an empty slot with a short value.
  return pad((await getStorageAt(client, options)) ?? '0x', { size: 32 })
}

async function pinBlock(client: Client<Transport, Chain | undefined>, blockNumber?: bigint): Promise<bigint> {
  return blockNumber ?? (await getBlockNumber(client, { cacheTime: 0 }))
}

export namespace readCheckpoint {
  export type OptionsType = ReadOptions & {
    /** The account's owner. */
    owner: Address
    /** The ERC-20 address, or `NATIVE_TOKEN` for native FIL. */
    token: Address
  }
}

/**
 * Reads an account's stored balance checkpoint from the chain, with one `eth_getStorageAt`.
 *
 * The checkpoint's `balance` is the raw stored one. Use
 * {@link readAccountState} for the spendable balance.
 *
 * @param client - The client to read with.
 * @param options - {@link readCheckpoint.OptionsType}
 * @returns The stored {@link Checkpoint}.
 *
 * @example
 * ```ts
 * import { readCheckpoint } from '@filoz/filecoin-pay-v2/storage'
 *
 * const checkpoint = await readCheckpoint(client, { address: filecoinPay, owner: payer, token: USDFC })
 * ```
 */
export async function readCheckpoint(
  client: Client<Transport, Chain | undefined>,
  options: readCheckpoint.OptionsType
): Promise<Checkpoint> {
  return unpackCheckpoint(await readSlot(client, { ...options, slot: accountSlot(options.owner, options.token) }))
}

export namespace readPermissions {
  export type OptionsType = ReadOptions & {
    /** The account that granted the permissions. */
    owner: Address
    /** The account that holds them. */
    operator: Address
  }
}

/**
 * Reads the permissions `owner` granted `operator` from the chain, with one `eth_getStorageAt`.
 *
 * @param client - The client to read with.
 * @param options - {@link readPermissions.OptionsType}
 * @returns The `Permissions` bits, to test with `hasPermissions`.
 *
 * @example
 * ```ts
 * import { hasPermissions, Permissions } from '@filoz/filecoin-pay-v2'
 * import { readPermissions } from '@filoz/filecoin-pay-v2/storage'
 *
 * const permissions = await readPermissions(client, { address: filecoinPay, owner: payer, operator })
 * const canCreateRails = hasPermissions(permissions, Permissions.CREATE_RAIL)
 * ```
 */
export async function readPermissions(
  client: Client<Transport, Chain | undefined>,
  options: readPermissions.OptionsType
): Promise<bigint> {
  return hexToBigInt(await readSlot(client, { ...options, slot: permissionsSlot(options.owner, options.operator) }))
}

export namespace readRail {
  export type OptionsType = ReadOptions & RailKey
}

/**
 * Reads a rail's stored state from the chain, with one `eth_getStorageAt`.
 *
 * @param client - The client to read with.
 * @param options - {@link readRail.OptionsType}
 * @returns The stored {@link Rail}. `exists` is false for a rail never created or already terminated.
 *
 * @example
 * ```ts
 * import { readRail } from '@filoz/filecoin-pay-v2/storage'
 *
 * const rail = await readRail(client, {
 *   address: filecoinPay,
 *   operator,
 *   from: payer,
 *   token: USDFC,
 *   recipient: provider,
 *   nonce: 1n,
 * })
 * ```
 */
export async function readRail(
  client: Client<Transport, Chain | undefined>,
  options: readRail.OptionsType
): Promise<Rail> {
  return unpackRail(await readSlot(client, { ...options, slot: railId(options) }))
}

export namespace readAccountState {
  export type OptionsType = readCheckpoint.OptionsType
}

/**
 * Reads an account's state from the chain: its checkpoint, projected to the block it was read at.
 *
 * Without `blockNumber`, the latest block number is fetched first and the
 * storage read is pinned to it, so the state and its `epoch` always match.
 * Pass a block number you already hold to skip that extra call.
 *
 * @param client - The client to read with.
 * @param options - {@link readAccountState.OptionsType}
 * @returns The {@link AccountState} at that block.
 *
 * @example
 * ```ts
 * import { readAccountState } from '@filoz/filecoin-pay-v2/storage'
 *
 * const state = await readAccountState(client, { address: filecoinPay, owner: payer, token: USDFC })
 * console.log(state.balance, state.runway)
 * ```
 */
export async function readAccountState(
  client: Client<Transport, Chain | undefined>,
  options: readAccountState.OptionsType
): Promise<AccountState> {
  const blockNumber = await pinBlock(client, options.blockNumber)
  return accountStateAt(await readCheckpoint(client, { ...options, blockNumber }), blockNumber)
}

export namespace extsloadCall {
  export type OptionsType = {
    /** The FilecoinPayV2 contract address. */
    address: Address
    /** The slot to read, e.g. from `accountSlot`, `permissionsSlot` or `railId`. */
    slot: Hex
  }

  export type OutputType = ContractFunctionParameters<typeof filecoinPayV2, 'pure' | 'view', 'extsload'>
}

/**
 * Creates a call to the contract's `extsload` for one slot. No network call.
 *
 * Use it with viem's `multicall` or `readContract`, to read Filecoin Pay
 * slots next to calls to other contracts.
 *
 * @param options - {@link extsloadCall.OptionsType}
 * @returns The call parameters {@link extsloadCall.OutputType}. The call returns the 32-byte word.
 *
 * @example
 * ```ts
 * import { accountSlot, extsloadCall, unpackCheckpoint } from '@filoz/filecoin-pay-v2/storage'
 * import { erc20Abi } from 'viem'
 * import { multicall } from 'viem/actions'
 *
 * const [word, walletBalance] = await multicall(client, {
 *   allowFailure: false,
 *   contracts: [
 *     extsloadCall({ address: filecoinPay, slot: accountSlot(payer, USDFC) }),
 *     { address: USDFC, abi: erc20Abi, functionName: 'balanceOf', args: [payer] },
 *   ],
 * })
 * const checkpoint = unpackCheckpoint(word)
 * ```
 */
export function extsloadCall(options: extsloadCall.OptionsType) {
  return {
    abi: filecoinPayV2,
    address: options.address,
    functionName: 'extsload',
    args: [options.slot],
  } satisfies extsloadCall.OutputType
}

export namespace readSlots {
  export type OptionsType = ReadOptions &
    MulticallOptions & {
      /** The slots to read, e.g. from `accountSlot`, `permissionsSlot` or `railId`. */
      slots: readonly Hex[]
    }
}

/**
 * Reads several storage words from the chain at one block, through Multicall3 and the contract's `extsload`.
 *
 * Without `blockNumber`, the latest block number is fetched first and every
 * call is pinned to it; pass one you already hold to skip that extra call. A
 * short list goes out as one request; viem splits a long one into several,
 * all at that block. An empty list makes no request.
 *
 * The Multicall3 address is `multicallAddress` when given, else the one the
 * client's chain defines, else `MULTICALL3_ADDRESS`.
 *
 * @param client - The client to read with.
 * @param options - {@link readSlots.OptionsType}
 * @returns The 32-byte words, in the order of `slots`.
 *
 * @example
 * ```ts
 * import { accountSlot, railId, readSlots, unpackCheckpoint, unpackRail } from '@filoz/filecoin-pay-v2/storage'
 *
 * const [railWord, payerWord] = await readSlots(client, {
 *   address: filecoinPay,
 *   slots: [railId(rail), accountSlot(rail.from, rail.token)],
 * })
 * const state = unpackRail(railWord)
 * const payer = unpackCheckpoint(payerWord)
 * ```
 */
export async function readSlots(
  client: Client<Transport, Chain | undefined>,
  options: readSlots.OptionsType
): Promise<Hex[]> {
  if (options.slots.length === 0) return []
  return multicall(client, {
    allowFailure: false,
    blockNumber: await pinBlock(client, options.blockNumber),
    multicallAddress: options.multicallAddress ?? client.chain?.contracts?.multicall3?.address ?? MULTICALL3_ADDRESS,
    contracts: options.slots.map((slot) => extsloadCall({ address: options.address, slot })),
  })
}

export namespace readAccountStates {
  export type OptionsType = ReadOptions &
    MulticallOptions & {
      /** The accounts' owner. */
      owner: Address
      /** The tokens to read the owner's account for. `NATIVE_TOKEN` is native FIL. */
      tokens: readonly Address[]
    }
}

/**
 * Reads the state of one owner's accounts for several tokens from the chain, with one {@link readSlots}.
 *
 * Without `blockNumber`, the latest block number is fetched once and the
 * read is pinned to it; pass one you already hold to skip that extra call.
 * Needs Multicall3, resolved as `readSlots` does. An empty list makes no
 * request.
 *
 * @param client - The client to read with.
 * @param options - {@link readAccountStates.OptionsType}
 * @returns One {@link AccountState} per token, in the order of `tokens`.
 *
 * @example
 * ```ts
 * import { NATIVE_TOKEN } from '@filoz/filecoin-pay-v2'
 * import { readAccountStates } from '@filoz/filecoin-pay-v2/storage'
 *
 * const [fil, usdfc] = await readAccountStates(client, {
 *   address: filecoinPay,
 *   owner: payer,
 *   tokens: [NATIVE_TOKEN, USDFC],
 * })
 * ```
 */
export async function readAccountStates(
  client: Client<Transport, Chain | undefined>,
  options: readAccountStates.OptionsType
): Promise<AccountState[]> {
  if (options.tokens.length === 0) return []
  const blockNumber = await pinBlock(client, options.blockNumber)
  const words = await readSlots(client, {
    address: options.address,
    multicallAddress: options.multicallAddress,
    blockNumber,
    slots: options.tokens.map((token) => accountSlot(options.owner, token)),
  })
  return words.map((word) => accountStateAt(unpackCheckpoint(word), blockNumber))
}
