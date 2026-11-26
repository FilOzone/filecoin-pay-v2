import { encodeFunctionData, toFunctionSelector } from 'viem'
import { expect, it } from 'vitest'
import { filecoinPayV2 } from '../src/abi/index.ts'
import { Permissions } from '../src/constants.ts'
import { createScript } from '../src/script/index.ts'

const RECIPIENT = '0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb'

it('encodes both executeScript overloads', () => {
  // Native FIL, deposited as the transaction value.
  const script = createScript().transfer(RECIPIENT, 1n).build()

  const plain = encodeFunctionData({ abi: filecoinPayV2, functionName: 'executeScript', args: [script] })
  expect(plain.startsWith(toFunctionSelector('executeScript(bytes)'))).toBe(true)
  expect(plain).toContain(script.slice(2))

  const scoped = encodeFunctionData({
    abi: filecoinPayV2,
    functionName: 'executeScript',
    args: [Permissions.TRANSFER, script],
  })
  expect(scoped.startsWith(toFunctionSelector('executeScript(uint256,bytes)'))).toBe(true)
  expect(scoped).toContain(script.slice(2))
})

it('both executeScript overloads are payable, so a caller can attach native FIL', () => {
  const overloads = filecoinPayV2.filter((item) => item.type === 'function' && item.name === 'executeScript')
  expect(overloads.map((item) => item.stateMutability)).toEqual(['payable', 'payable'])
})
