import { readFileSync } from 'node:fs'
import type { Hex } from 'viem'
import { describe, expect, it } from 'vitest'
import { FLAG_CALLBACK, NATIVE_TOKEN, Permissions } from '../src/constants.ts'
import { FilecoinPayError, isFilecoinPayError, ScriptError } from '../src/errors/index.ts'
import {
  createScript,
  decodeScript,
  describeScript,
  type OpName,
  ops,
  type ScriptBuilder,
} from '../src/script/index.ts'

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

describe('describeScript', () => {
  it.each(cases)('describes $name', ({ script }) => {
    expect(describeScript(script)).toMatchSnapshot()
  })

  it('describes a script that creates and funds a rail', () => {
    const script = createScript()
      .setToken(A)
      .createRail(A, B, FLAG_CALLBACK | 1n)
      .setRate(1_000n)
      .lock(500_000n)
      .build()
    expect(describeScript(script)).toEqual([
      `Select token ${A}.`,
      `Create the rail from ${A} to ${B} with nonce 9223372036854775809 (FLAG_CALLBACK | 1) and select it, with the current account as operator, on the selected token.`,
      "Set the selected rail's rate to 1000 per epoch.",
      "Move 500000 from the payer's balance into the selected rail's lockup.",
    ])
  })

  it('breaks down a rail nonce only when it carries the callback flag', () => {
    const nonce = (value: bigint) => describeScript(createScript().setRail(A, B, value).build())[0]
    expect(nonce(7n)).toContain('with nonce 7 for the rail operations')
    expect(nonce(FLAG_CALLBACK | 7n)).toContain('with nonce 9223372036854775815 (FLAG_CALLBACK | 7) for the rail')
    expect(nonce((1n << 62n) | 7n)).toContain(`with nonce ${(1n << 62n) | 7n} for the rail operations`)
  })

  it.each([
    [Permissions.TRANSFER, 'TRANSFER'],
    [Permissions.CREATE_RAIL | Permissions.TRANSFER, 'TRANSFER | CREATE_RAIL'],
    [Permissions.NONE, 'NONE'],
    [0xffn, 'DEPOSIT | WITHDRAW | TRANSFER | CREATE_RAIL | APPROVE | AUTHORIZE | 0xc0'],
  ])('names the permissions %i as %s', (permissions, names) => {
    const [sentence] = describeScript(createScript().authorize(A, permissions).build())
    expect(sentence).toContain(`to ${names}, up to`)
  })

  it('reports the ops after a pop outside any block as not run', () => {
    const script = createScript().lock(1n).pop().setToken(A).lock(2n).pop().build()
    expect(describeScript(script)).toEqual([
      "Move 1 from the payer's balance into the selected rail's lockup.",
      'End the script; the operations after it do not run.',
      `Not run (the script ended at the pop above): Select token ${A}.`,
      "Not run (the script ended at the pop above): Move 2 from the payer's balance into the selected rail's lockup.",
      'Not run (the script ended at the pop above): Close the current block.',
    ])
    expect(describeScript(script)).toHaveLength(decodeScript(script).length)
  })

  it('describes the ops after a pop that closes a block', () => {
    expect(describeScript(createScript().push().pop().lock(1n).build())).toEqual([
      'Open a block; changes to the account, token, and rail made inside it are undone at the matching pop.',
      'Close the current block.',
      "Move 1 from the payer's balance into the selected rail's lockup.",
    ])
  })

  it('throws where decodeScript does', () => {
    expect(thrown(() => describeScript('0x1a'))).toBeInstanceOf(ScriptError)
  })

  describe('formatAmount', () => {
    // Records the token each amount was formatted with, in script order.
    function tokens(script: Hex): string[] {
      const seen: string[] = []
      describeScript(script, {
        formatAmount: (amount, token) => {
          seen.push(`${amount}@${token}`)
          return ''
        },
      })
      return seen
    }

    it('receives the token selected when each op runs', () => {
      const script = createScript()
        .lock(1n)
        .setToken(A)
        .lock(2n)
        .push()
        .lock(3n)
        .setToken(B)
        .lock(4n)
        .reset()
        .lock(5n)
        .setToken(B)
        .pop()
        .lock(6n)
        .setToken(B)
        .reset()
        .lock(7n)
        .pop()
        .lock(8n)
        .build()
      expect(tokens(script)).toEqual([
        `1@${NATIVE_TOKEN}`,
        `2@${A}`,
        `3@${A}`,
        `4@${B}`,
        `5@${A}`,
        `6@${A}`,
        `7@${NATIVE_TOKEN}`,
      ])
    })

    it('is not called for ops after the script ended', () => {
      const script = createScript().lock(1n).pop().setToken(A).lock(2n).push().lock(3n).pop().lock(4n).build()
      expect(tokens(script)).toEqual([`1@${NATIVE_TOKEN}`])
    })

    it('keeps the token across sudo', () => {
      expect(tokens(createScript().setToken(A).sudo(B).lock(1n).build())).toEqual([`1@${A}`])
    })

    it('formats amounts and rates, and nothing else', () => {
      const script = createScript()
        .setToken(A)
        .authorize(B, Permissions.TRANSFER)
        .createRail(A, B, FLAG_CALLBACK | 7n)
        .setRate(1_000n)
        .transfer(B, 2_000n)
        .build()
      expect(tokens(script)).toEqual([`1000@${A}`, `2000@${A}`])
      expect(describeScript(script, { formatAmount: (amount) => `${amount / 1000n}k` })).toEqual([
        `Select token ${A}.`,
        `Set the permissions of ${B} over the current account to TRANSFER, up to those the script holds.`,
        `Create the rail from ${A} to ${B} with nonce 9223372036854775815 (FLAG_CALLBACK | 7) and select it, with the current account as operator, on the selected token.`,
        "Set the selected rail's rate to 1k per epoch.",
        `Transfer 2k of the selected token from the current account's balance to the balance of ${B}.`,
      ])
    })
  })
})
