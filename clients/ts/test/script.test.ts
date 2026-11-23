import { readFileSync } from 'node:fs'
import type { Hex } from 'viem'
import { describe, expect, it } from 'vitest'
import { Permissions } from '../src/constants.ts'
import { FilecoinPayError, isFilecoinPayError, ScriptError } from '../src/errors/index.ts'
import { createScript, decodeScript, type OpName, ops, type ScriptBuilder } from '../src/script/index.ts'

const VECTORS = new URL('../../../vectors/script.json', import.meta.url)

type VectorOp = { op: OpName; args: Record<string, string> }
const { cases } = JSON.parse(readFileSync(VECTORS, 'utf8')) as {
  cases: { name: string; ops: VectorOp[]; script: Hex }[]
}

const A = '0xA11cea11CEA11CEA11cEa11CeA11ceA11CEA11Ce'
const B = '0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb'

// Addresses lowercased, integers as decimal strings: the form both sides are compared in.
function normalize(decoded: { op: string; args: Record<string, unknown> }[]) {
  return decoded.map(({ op, args }) => ({
    op,
    args: Object.fromEntries(Object.entries(args).map(([name, value]) => [name, String(value).toLowerCase()])),
  }))
}

function call(builder: ScriptBuilder, { op, args }: VectorOp): ScriptBuilder {
  const operands = ops.find((entry) => entry.name === op)?.operands ?? []
  const values = operands.map(([name, type]) => (type === 'address' ? args[name] : BigInt(args[name])))
  return (builder[op] as (...values: unknown[]) => ScriptBuilder)(...values)
}

function thrown(fn: () => unknown): Error {
  try {
    fn()
  } catch (error) {
    return error as Error
  }
  throw new Error('expected a throw')
}

describe('vectors', () => {
  it.each(cases)('builds $name', ({ ops, script }) => {
    expect(ops.reduce(call, createScript()).build()).toBe(script)
  })

  it.each(cases)('decodes $name', ({ ops, script }) => {
    expect(normalize(decodeScript(script))).toEqual(normalize(ops))
  })

  it('cover every op in the table', () => {
    const inVectors = new Set(cases.flatMap((c) => c.ops.map((op) => op.op)))
    expect(ops).toHaveLength(26)
    expect([...inVectors].sort()).toEqual(ops.map((op) => op.name).sort())
  })
})

describe('createScript', () => {
  it('authorize encodes only the low byte of permissions', () => {
    const permissions = (value: bigint) => createScript().authorize(A, value).build().slice(-2)
    expect(permissions(1n << 8n)).toBe('00')
    expect(permissions(Permissions.ALL)).toBe('ff')
    expect(permissions((1n << 200n) | Permissions.DEPOSIT_TO)).toBe('05')
  })

  it('leaves the builder it extends unchanged', () => {
    const base = createScript().setToken(A)
    const first = base.deposit(1n).build()
    const second = base.withdraw(2n).build()
    expect(base.build()).toBe(createScript().setToken(A).build())
    expect(first).toBe(createScript().setToken(A).deposit(1n).build())
    expect(second).toBe(createScript().setToken(A).withdraw(2n).build())
  })

  it.each([
    ['setRail', 'nonce', 64, (v: bigint) => createScript().setRail(A, B, v)],
    ['setRate', 'rate', 88, (v: bigint) => createScript().setRate(v)],
    ['lock', 'amount', 128, (v: bigint) => createScript().lock(v)],
    ['authorize', 'permissions', 256, (v: bigint) => createScript().authorize(A, v)],
  ] as const)('%s rejects a %s outside uint%i', (op, operand, bits, build) => {
    expect(() => build(0n)).not.toThrow()
    expect(() => build((1n << BigInt(bits)) - 1n)).not.toThrow()
    for (const value of [1n << BigInt(bits), -1n]) {
      const error = thrown(() => build(value))
      expect(error).toBeInstanceOf(ScriptError)
      expect(error).toBeInstanceOf(FilecoinPayError)
      expect(ScriptError.is(error)).toBe(true)
      expect(isFilecoinPayError(error)).toBe(true)
      expect(error.message).toContain(op)
      expect(error.message).toContain(operand)
    }
  })

  it.each([
    ['too short', '0x1234'],
    ['bad checksum', A.replace('A11c', 'a11C')],
    ['not a string', 1n],
  ])('rejects an address that is %s', (_, value) => {
    const error = thrown(() => createScript().transferFrom(A, 1n, value as Hex))
    expect(error).toBeInstanceOf(ScriptError)
    expect(error.message).toContain('transferFrom')
    expect(error.message).toContain('owner')
  })
})

it('isFilecoinPayError does not match a plain Error', () => {
  expect(isFilecoinPayError(new Error('plain'))).toBe(false)
  expect(ScriptError.is(new Error('plain'))).toBe(false)
})

describe('decodeScript', () => {
  it('rejects an unknown opcode with its offset', () => {
    const error = thrown(() => decodeScript('0x00011a'))
    expect(error).toBeInstanceOf(ScriptError)
    expect(error.message).toContain('opcode 26')
    expect(error.message).toContain('offset 2')
  })

  it('rejects a truncated op with its offset', () => {
    const script = createScript().pop().setRail(A, B, 1n).build()
    const error = thrown(() => decodeScript(script.slice(0, -2) as Hex))
    expect(error).toBeInstanceOf(ScriptError)
    expect(error.message).toContain('setRail')
    expect(error.message).toContain('offset 1')
  })

  it.each(['0x0', '0xzz', '00'])('rejects %s as not hex bytes', (script) => {
    expect(thrown(() => decodeScript(script as Hex))).toBeInstanceOf(ScriptError)
  })
})
