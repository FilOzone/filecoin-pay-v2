import { FilecoinPayError, isFilecoinPayError } from './base.ts'

/**
 * Thrown when a script cannot be built or decoded: an operand out of range,
 * an invalid address, an unknown opcode or a truncated op.
 */
export class ScriptError extends FilecoinPayError {
  override name: 'ScriptError' = 'ScriptError'

  static is(value: unknown): value is ScriptError {
    return isFilecoinPayError(value) && value.name === 'ScriptError'
  }
}
