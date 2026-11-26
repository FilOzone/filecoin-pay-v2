import { readFileSync } from 'node:fs'
import {
  type Address,
  type Chain,
  createClient,
  custom,
  decodeFunctionData,
  encodeFunctionResult,
  type Hex,
  maxUint256,
  multicall3Abi,
  numberToHex,
} from 'viem'
import { filecoin, filecoinCalibration } from 'viem/chains'
import { describe, expect, it } from 'vitest'
import { filecoinPayV2 } from '../src/abi/index.ts'
import { hasPermissions, MULTICALL3_ADDRESS, Permissions } from '../src/constants.ts'
import { StorageError } from '../src/errors/index.ts'
import {
  accountSlot,
  accountStateAt,
  extsloadCall,
  permissionsSlot,
  railId,
  readAccountState,
  readAccountStates,
  readCheckpoint,
  readPermissions,
  readRail,
  readSlots,
  unpackCheckpoint,
  unpackRail,
  userSlot,
} from '../src/storage/index.ts'

const VECTORS = new URL('../../../vectors/storage.json', import.meta.url)

type CheckpointVector = { word: Hex; balance: Hex; drainRate: Hex; modifiedEpoch: Hex }
type StreamVector = { word: Hex; incomingRate: Hex; settledUpTo: Hex; available: Hex }
type AccountVector = CheckpointVector & { owner: Address; token: Address; slot: Hex; balanceOf: Hex }
type RailVector = StreamVector & {
  operator: Address
  from: Address
  token: Address
  recipient: Address
  nonce: Hex
  railId: Hex
}
const vectors = JSON.parse(readFileSync(VECTORS, 'utf8')) as {
  block: Hex
  users: { owner: Address; slot: Hex }[]
  accounts: AccountVector[]
  permissions: { owner: Address; operator: Address; slot: Hex; word: Hex; permissions: Hex }[]
  rails: RailVector[]
  packing: { checkpoints: CheckpointVector[]; streams: StreamVector[] }
}
const block = BigInt(vectors.block)
const railKey = (rail: RailVector) => ({ ...rail, nonce: BigInt(rail.nonce) })

const PAY = '0x00000000000000000000000000000000000000fa'

// A client over the vectors' storage that records every request it answers.
function stubClient(chain?: Chain) {
  const words = new Map<Hex, Hex>([
    ...vectors.accounts.map(({ slot, word }) => [slot, word] as const),
    ...vectors.permissions.map(({ slot, word }) => [slot, word] as const),
    ...vectors.rails.map(({ railId, word }) => [railId, word] as const),
  ])
  const requests: { method: string; params: unknown[] }[] = []
  const client = createClient({
    chain,
    transport: custom({
      request: async ({ method, params }) => {
        requests.push({ method, params })
        if (method === 'eth_blockNumber') return vectors.block
        if (method === 'eth_getStorageAt') return words.get(params[1])
        const { args } = decodeFunctionData({ abi: multicall3Abi, data: params[0].data })
        const calls = args?.[0] as readonly { callData: Hex }[]
        return encodeFunctionResult({
          abi: multicall3Abi,
          functionName: 'aggregate3',
          result: calls.map(({ callData }) => {
            const slot = decodeFunctionData({ abi: filecoinPayV2, data: callData }).args?.[0] as Hex
            return { success: true, returnData: words.get(slot) ?? numberToHex(0, { size: 32 }) }
          }),
        })
      },
    }),
  })
  return { client, requests }
}

describe('slots', () => {
  it.each(vectors.users)('user $owner', ({ owner, slot }) => {
    expect(userSlot(owner)).toBe(slot)
  })

  it.each(vectors.accounts)('account $owner $token', ({ owner, token, slot }) => {
    expect(accountSlot(owner, token)).toBe(slot)
  })

  it.each(vectors.permissions)('permissions $owner $operator', ({ owner, operator, slot }) => {
    expect(permissionsSlot(owner, operator)).toBe(slot)
  })

  it.each(vectors.rails)('rail $from $recipient $nonce', (rail) => {
    expect(railId(railKey(rail))).toBe(rail.railId)
  })
})

describe('unpack', () => {
  it.each([...vectors.accounts, ...vectors.packing.checkpoints])('checkpoint $word', (vector) => {
    expect(unpackCheckpoint(vector.word)).toEqual({
      balance: BigInt(vector.balance),
      drainRate: BigInt(vector.drainRate),
      modifiedEpoch: BigInt(vector.modifiedEpoch),
    })
  })

  it.each([...vectors.rails, ...vectors.packing.streams])('rail $word', (vector) => {
    expect(unpackRail(vector.word)).toEqual({
      incomingRate: BigInt(vector.incomingRate),
      settledUpTo: BigInt(vector.settledUpTo),
      available: BigInt(vector.available),
      exists: BigInt(vector.settledUpTo) !== 0n,
    })
  })

  it.each(['0x', '0x00', `0x${'00'.repeat(33)}`, `0x${'zz'.repeat(32)}`])('rejects the word %s', (word) => {
    expect(() => unpackCheckpoint(word as Hex)).toThrow(StorageError)
    expect(() => unpackRail(word as Hex)).toThrow(StorageError)
  })
})

describe('accountStateAt', () => {
  it.each(vectors.accounts)('matches balanceOf for $owner $token', ({ word, balanceOf }) => {
    expect(accountStateAt(unpackCheckpoint(word), block).balance).toBe(BigInt(balanceOf))
  })

  it('reports the underfunded account as in debt', () => {
    const underfunded = vectors.accounts.filter(({ balanceOf }) => BigInt(balanceOf) === 0n)
    expect(underfunded).toHaveLength(1)
    const checkpoint = unpackCheckpoint(underfunded[0].word)
    expect(checkpoint.balance).toBeGreaterThan(0n)
    expect(checkpoint.drainRate).toBeGreaterThan(0n)
    const state = accountStateAt(checkpoint, block)
    expect(state.balance).toBe(0n)
    expect(state.debt).toBeGreaterThan(0n)
    expect(state.runway).toBe(0n)
    expect(state.fundedUntil).toBeLessThan(block)
  })

  const checkpoint = { balance: 100n, drainRate: 30n, modifiedEpoch: 1000n }

  it('has no limit without a drain rate', () => {
    expect(accountStateAt({ balance: 100n, drainRate: 0n, modifiedEpoch: 0n }, 5000n)).toEqual({
      balance: 100n,
      drainRate: 0n,
      fundedUntil: maxUint256,
      runway: maxUint256,
      debt: 0n,
      epoch: 5000n,
    })
  })

  it('is funded up to fundedUntil and in debt one epoch later', () => {
    expect(accountStateAt(checkpoint, 1001n)).toEqual({
      balance: 70n,
      drainRate: 30n,
      fundedUntil: 1003n,
      runway: 2n,
      debt: 0n,
      epoch: 1001n,
    })
    expect(accountStateAt(checkpoint, 1003n)).toMatchObject({ balance: 10n, runway: 0n, debt: 0n })
    expect(accountStateAt(checkpoint, 1004n)).toMatchObject({ balance: 0n, runway: 0n, debt: 20n })
    expect(accountStateAt({ ...checkpoint, balance: 90n }, 1004n)).toMatchObject({ balance: 0n, debt: 30n })
  })

  it('rejects an epoch before the checkpoint', () => {
    expect(() => accountStateAt(checkpoint, 999n)).toThrow(StorageError)
  })
})

it('hasPermissions needs every required bit', () => {
  expect(hasPermissions(Permissions.DEPOSIT_TO, Permissions.TRANSFER)).toBe(true)
  expect(hasPermissions(Permissions.DEPOSIT_TO, Permissions.DEPOSIT | Permissions.TRANSFER)).toBe(true)
  expect(hasPermissions(Permissions.DEPOSIT_TO, Permissions.TRANSFER | Permissions.CREATE_RAIL)).toBe(false)
  expect(hasPermissions(Permissions.NONE, Permissions.NONE)).toBe(true)
})

describe('readers', () => {
  const account = vectors.accounts[1]
  const rail = vectors.rails[0]
  const grant = vectors.permissions[0]

  it('read one slot each with eth_getStorageAt at the given block', async () => {
    const { client, requests } = stubClient()
    const at = { address: PAY, blockNumber: 1055n } as const

    expect(await readCheckpoint(client, { ...at, ...account })).toEqual(unpackCheckpoint(account.word))
    expect(await readPermissions(client, { ...at, ...grant })).toBe(BigInt(grant.permissions))
    expect(await readRail(client, { ...at, ...railKey(rail) })).toEqual(unpackRail(rail.word))
    expect(requests).toEqual(
      [account.slot, grant.slot, rail.railId].map((slot) => ({
        method: 'eth_getStorageAt',
        params: [PAY, slot, numberToHex(1055n)],
      }))
    )
  })

  it('read an empty slot as zero', async () => {
    const { client } = stubClient()
    expect(await readRail(client, { address: PAY, ...railKey(rail), nonce: 99n })).toMatchObject({ exists: false })
  })

  it('readAccountState pins the storage read to the block it fetched', async () => {
    const { client, requests } = stubClient()
    const state = await readAccountState(client, { address: PAY, owner: account.owner, token: account.token })
    expect(state).toEqual(accountStateAt(unpackCheckpoint(account.word), block))
    expect(state.balance).toBe(BigInt(account.balanceOf))
    expect(requests).toEqual([
      { method: 'eth_blockNumber', params: undefined },
      { method: 'eth_getStorageAt', params: [PAY, account.slot, numberToHex(block)] },
    ])
  })

  it('readSlots returns the words in order from one Multicall3 call', async () => {
    const { client, requests } = stubClient()
    const slots = [rail.railId, account.slot, grant.slot]
    const words = await readSlots(client, { address: PAY, slots, blockNumber: 1055n })
    expect(words).toEqual([rail.word, account.word, grant.word])
    expect(requests).toHaveLength(1)
    expect(requests[0].method).toBe('eth_call')
    expect(requests[0].params).toMatchObject([{ to: MULTICALL3_ADDRESS }, numberToHex(1055n)])
  })

  it('readSlots pins the multicall to the block it fetched', async () => {
    const { client, requests } = stubClient()
    await readSlots(client, { address: PAY, slots: [rail.railId] })
    expect(requests.map(({ method }) => method)).toEqual(['eth_blockNumber', 'eth_call'])
    expect(requests[1].params).toMatchObject([{}, numberToHex(block)])
  })

  it('readSlots resolves Multicall3 from the option, then the chain, then the standard address', async () => {
    const other = '0x00000000000000000000000000000000000000aa'
    const onChain = '0x00000000000000000000000000000000000000bb'
    const chain = { ...filecoin, contracts: { multicall3: { address: onChain } } } as const
    const target = async (chain: Chain | undefined, multicallAddress?: Address) => {
      const { client, requests } = stubClient(chain)
      await readSlots(client, { address: PAY, slots: [rail.railId], blockNumber: 1055n, multicallAddress })
      return (requests[0].params[0] as { to: Address }).to
    }
    expect(await target(chain, other)).toBe(other)
    expect(await target(chain)).toBe(onChain)
    expect(await target(filecoinCalibration)).toBe(MULTICALL3_ADDRESS)
    expect(await target(undefined)).toBe(MULTICALL3_ADDRESS)
  })

  it('readAccountStates fetches the block once and keeps the order of tokens', async () => {
    const { client, requests } = stubClient()
    const [alice, token] = [vectors.accounts[0].owner, vectors.accounts[1].token]
    const states = await readAccountStates(client, {
      address: PAY,
      owner: alice,
      tokens: [token, vectors.accounts[0].token],
    })
    expect(states.map((state) => state.balance)).toEqual(
      [vectors.accounts[1], vectors.accounts[0]].map(({ balanceOf }) => BigInt(balanceOf))
    )
    expect(states.every((state) => state.epoch === block)).toBe(true)
    expect(requests.map(({ method }) => method)).toEqual(['eth_blockNumber', 'eth_call'])
    expect(requests[1].params).toMatchObject([{ to: MULTICALL3_ADDRESS }, numberToHex(block)])
  })

  it('an empty list makes no request', async () => {
    const { client, requests } = stubClient()
    expect(await readSlots(client, { address: PAY, slots: [] })).toEqual([])
    expect(await readAccountStates(client, { address: PAY, owner: account.owner, tokens: [] })).toEqual([])
    expect(requests).toEqual([])
  })

  it('extsloadCall returns the parameters of an extsload call', () => {
    expect(extsloadCall({ address: PAY, slot: rail.railId })).toEqual({
      abi: filecoinPayV2,
      address: PAY,
      functionName: 'extsload',
      args: [rail.railId],
    })
  })
})
