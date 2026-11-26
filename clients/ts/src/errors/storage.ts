import { FilecoinPayError, isFilecoinPayError } from './base.ts'

/**
 * Thrown when storage cannot be interpreted: a word that is not 32 bytes, or
 * an account state asked for an epoch before its checkpoint.
 */
export class StorageError extends FilecoinPayError {
  override name: 'StorageError' = 'StorageError'

  static is(value: unknown): value is StorageError {
    return isFilecoinPayError(value) && value.name === 'StorageError'
  }
}
