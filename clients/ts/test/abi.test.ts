import { encodeFunctionData, toFunctionSelector } from 'viem'
import { expect, it } from 'vitest'
import { filecoinPayV2 } from '../src/abi/index.ts'
import { Permissions } from '../src/constants.ts'
import { createScript } from '../src/script/index.ts'

it('encodes both executeScript overloads', () => {
  const script = createScript().deposit(1n).build()

  const plain = encodeFunctionData({ abi: filecoinPayV2, functionName: 'executeScript', args: [script] })
  expect(plain.startsWith(toFunctionSelector('executeScript(bytes)'))).toBe(true)

  const scoped = encodeFunctionData({
    abi: filecoinPayV2,
    functionName: 'executeScript',
    args: [Permissions.DEPOSIT, script],
  })
  expect(scoped.startsWith(toFunctionSelector('executeScript(uint256,bytes)'))).toBe(true)
  expect(scoped).toContain(script.slice(2))
})
