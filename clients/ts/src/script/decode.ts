import { type Address, bytesToHex, getAddress, type Hex, hexToBigInt, hexToBytes, isHex } from 'viem'
import { ScriptError } from '../errors/script.ts'
import { type Op, type OperandValue, operandSize, ops } from './ops.ts'

/**
 * One decoded op: its name and its operands by name, in wire order.
 *
 * `authorize` reports `permissions` as the single byte that travels.
 */
export type DecodedOp = {
  [O in Op as O['name']]: {
    op: O['name']
    args: { [P in O['operands'][number] as P[0]]: OperandValue<P[1]> }
  }
}[Op['name']]

/**
 * Decodes a script into its ops.
 *
 * Decoding is stricter than the contract, which runs an unknown opcode as
 * `terminateRail` and reads a truncated op past the end of the script.
 *
 * @param script - The script bytes, as built by `createScript`.
 * @returns The ops in script order. Integers are `bigint`, addresses are checksummed.
 * @throws A {@link ScriptError} naming the byte offset of an unknown opcode or
 * of a truncated op, or if `script` is not a hex string of whole bytes.
 *
 * @example
 * ```ts
 * import { decodeScript } from '@filoz/filecoin-pay-v2/script'
 *
 * decodeScript('0x12000000000000000003e8')
 * // [{ op: 'setRate', args: { rate: 1000n } }]
 * ```
 */
export function decodeScript(script: Hex): DecodedOp[] {
  if (!isHex(script, { strict: true }) || script.length % 2 !== 0) {
    throw new ScriptError('Script must be a hex string of whole bytes')
  }
  const bytes = hexToBytes(script)
  const decoded: DecodedOp[] = []
  let offset = 0
  while (offset < bytes.length) {
    const start = offset
    const opcode = bytes[offset++]
    const op = ops.find((op) => op.opcode === opcode)
    if (!op) {
      throw new ScriptError(`Unknown opcode ${opcode} at byte offset ${start}`)
    }
    const args: Record<string, Address | bigint> = {}
    for (const [name, type] of op.operands) {
      const size = operandSize(type)
      if (offset + size > bytes.length) {
        throw new ScriptError(
          `Truncated ${op.name} at byte offset ${start}: ${name} needs ${size} bytes, ${bytes.length - offset} left`
        )
      }
      const hex = bytesToHex(bytes.subarray(offset, offset + size))
      args[name] = type === 'address' ? getAddress(hex) : hexToBigInt(hex)
      offset += size
    }
    decoded.push({ op: op.name, args } as DecodedOp)
  }
  return decoded
}
