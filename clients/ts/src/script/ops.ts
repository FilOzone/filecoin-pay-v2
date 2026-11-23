import type { Address } from 'viem'

/** Solidity type of an operand. It fixes the operand's width on the wire. */
export type OperandType = 'address' | 'uint8' | 'uint64' | 'uint88' | 'uint128'

/** TypeScript value of an operand: `Address` for `address`, `bigint` for integers. */
export type OperandValue<T extends OperandType = OperandType> = T extends 'address' ? Address : bigint

// TODO: move this table to the Solidity vectors (an `ops` section in vectors/script.json) and generate it from there
/**
 * The script wire format: one entry per op, in opcode order.
 *
 * An op is its opcode byte followed by its operands in the listed order, each
 * big-endian at its type's width, with no padding or length prefix. This
 * mirrors `ScriptBuilder` in `src/lib/Script.sol`.
 */
export const ops = [
  { name: 'pop', opcode: 0, operands: [] },
  { name: 'push', opcode: 1, operands: [] },
  { name: 'reset', opcode: 2, operands: [] },
  { name: 'sudo', opcode: 3, operands: [['who', 'address']] },
  { name: 'setToken', opcode: 4, operands: [['token', 'address']] },
  {
    name: 'authorize',
    opcode: 5,
    operands: [
      ['operator', 'address'],
      ['permissions', 'uint8'],
    ],
  },
  {
    name: 'setRail',
    opcode: 6,
    operands: [
      ['from', 'address'],
      ['recipient', 'address'],
      ['nonce', 'uint64'],
    ],
  },
  {
    name: 'createRail',
    opcode: 7,
    operands: [
      ['from', 'address'],
      ['recipient', 'address'],
      ['nonce', 'uint64'],
    ],
  },
  {
    name: 'settleRail',
    opcode: 8,
    operands: [
      ['from', 'address'],
      ['recipient', 'address'],
      ['nonce', 'uint64'],
      ['operator', 'address'],
    ],
  },
  { name: 'withdraw', opcode: 9, operands: [['amount', 'uint128']] },
  { name: 'deposit', opcode: 10, operands: [['amount', 'uint128']] },
  {
    name: 'withdrawTo',
    opcode: 11,
    operands: [
      ['amount', 'uint128'],
      ['recipient', 'address'],
    ],
  },
  {
    name: 'depositTo',
    opcode: 12,
    operands: [
      ['amount', 'uint128'],
      ['recipient', 'address'],
    ],
  },
  {
    name: 'transfer',
    opcode: 13,
    operands: [
      ['recipient', 'address'],
      ['amount', 'uint128'],
    ],
  },
  {
    name: 'transferFrom',
    opcode: 14,
    operands: [
      ['recipient', 'address'],
      ['amount', 'uint128'],
      ['owner', 'address'],
    ],
  },
  { name: 'transferAll', opcode: 15, operands: [['recipient', 'address']] },
  { name: 'increaseRate', opcode: 16, operands: [['rate', 'uint88']] },
  { name: 'decreaseRate', opcode: 17, operands: [['rate', 'uint88']] },
  { name: 'setRate', opcode: 18, operands: [['rate', 'uint88']] },
  { name: 'disburseAll', opcode: 19, operands: [] },
  { name: 'disburse', opcode: 20, operands: [['amount', 'uint128']] },
  { name: 'lock', opcode: 21, operands: [['amount', 'uint128']] },
  { name: 'unlock', opcode: 22, operands: [['amount', 'uint128']] },
  { name: 'setAvailable', opcode: 23, operands: [['amount', 'uint128']] },
  { name: 'terminateRail', opcode: 24, operands: [] },
  { name: 'terminateRailBy', opcode: 25, operands: [['operator', 'address']] },
] as const satisfies readonly {
  name: string
  opcode: number
  operands: readonly (readonly [name: string, type: OperandType])[]
}[]

/** An entry of {@link ops}. */
export type Op = (typeof ops)[number]

/** Name of a script op, which is also its builder method. */
export type OpName = Op['name']

/** Returns the number of bytes an operand of `type` takes on the wire. */
export function operandSize(type: OperandType): number {
  return type === 'address' ? 20 : Number(type.slice(4)) / 8
}
