## Comments

Self-documenting code. Comment only what the code cannot state — an invariant, a non-obvious
reason, a layout that must not drift — and do it tersely. Prefer a named `error` to a sentence
explaining an unnamed one. Explain the change in the PR, not the source.

Cut; the `error` already says it:

```solidity
// A token id with any bit set above 160 is not an address, so no asset backs it.
// deriveRail hashes only the low 20 bytes of token, so such an id aliases the
// rail for its truncated value while accounts[] keys on the full uint256.
vm.expectRevert(FilecoinPayV2.InvalidToken.selector);
```

Keep; not recoverable from the code:

```solidity
// preimage [12,96): operator(20) from(20) token(20) recipient(20) nonce(4)
// offsets strictly decrease, so each store overwrites the zero padding of the previous one
```
