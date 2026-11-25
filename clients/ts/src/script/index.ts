/**
 * Build and decode scripts for `FilecoinPayV2.executeScript`.
 *
 * @example
 * ```ts
 * import * as Script from '@filoz/filecoin-pay-v2/script'
 * ```
 *
 * @module script
 */
export * from './builder.ts'
export * from './decode.ts'
export * from './describe.ts'
export { type Op, type OperandType, type OperandValue, type OpName, ops } from './ops.ts'
