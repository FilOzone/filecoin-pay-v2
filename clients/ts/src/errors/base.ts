const symbol = Symbol.for('filecoin-pay-error')

/**
 * Checks whether a value is any error thrown by this package.
 *
 * The check also matches errors from another copy of the package.
 */
export function isFilecoinPayError(value: unknown): value is FilecoinPayError {
  return value instanceof Error && symbol in value
}

/**
 * Base class of every error this package throws on purpose. Match any of them
 * with {@link isFilecoinPayError}.
 */
export class FilecoinPayError extends Error {
  [symbol]: boolean = true

  override name = 'FilecoinPayError'
}
