"""Keccak-256, as Solidity hashes mapping keys.

Only the benchmark runner needs it, to derive the storage slots of the accounts it prefills.
`hashlib` offers SHA3-256, which pads differently, and OpenSSL exposes `keccak-256` only
from 3.2 onwards, so neither covers every machine the benchmark has to run the same way on.
"""

from __future__ import annotations

MASK = (1 << 64) - 1
RATE = 136
ROUND_CONSTANTS = (
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
)
# lane x + 5y of the 5x5 state: rho rotations, and the destination pi sends each lane to
ROTATIONS = (
    0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39,
    41, 45, 15, 21, 8, 18, 2, 61, 56, 14,
)
DESTINATIONS = (
    0, 10, 20, 5, 15, 16, 1, 11, 21, 6, 7, 17, 2, 12, 22,
    23, 8, 18, 3, 13, 14, 24, 9, 19, 4,
)


def permute(state: list[int]) -> None:
    for constant in ROUND_CONSTANTS:
        c0 = state[0] ^ state[5] ^ state[10] ^ state[15] ^ state[20]
        c1 = state[1] ^ state[6] ^ state[11] ^ state[16] ^ state[21]
        c2 = state[2] ^ state[7] ^ state[12] ^ state[17] ^ state[22]
        c3 = state[3] ^ state[8] ^ state[13] ^ state[18] ^ state[23]
        c4 = state[4] ^ state[9] ^ state[14] ^ state[19] ^ state[24]
        parity = (
            c4 ^ ((c1 << 1 | c1 >> 63) & MASK),
            c0 ^ ((c2 << 1 | c2 >> 63) & MASK),
            c1 ^ ((c3 << 1 | c3 >> 63) & MASK),
            c2 ^ ((c4 << 1 | c4 >> 63) & MASK),
            c3 ^ ((c0 << 1 | c0 >> 63) & MASK),
        )
        rotated = [0] * 25
        for lane in range(25):
            value = state[lane] ^ parity[lane % 5]
            turn = ROTATIONS[lane]
            rotated[DESTINATIONS[lane]] = (
                ((value << turn | value >> (64 - turn)) & MASK) if turn else value
            )
        for row in range(0, 25, 5):
            b0, b1, b2, b3, b4 = rotated[row:row + 5]
            state[row] = b0 ^ (~b1 & b2)
            state[row + 1] = b1 ^ (~b2 & b3)
            state[row + 2] = b2 ^ (~b3 & b4)
            state[row + 3] = b3 ^ (~b4 & b0)
            state[row + 4] = b4 ^ (~b0 & b1)
        state[0] ^= constant


def keccak256(data: bytes) -> bytes:
    padding = RATE - len(data) % RATE
    # Keccak's 0x01 domain tag, unlike SHA-3's 0x06; both ends collapse into one byte when alone
    padded = data + (b"\x81" if padding == 1 else b"\x01" + bytes(padding - 2) + b"\x80")
    state = [0] * 25
    for offset in range(0, len(padded), RATE):
        for lane in range(17):
            state[lane] ^= int.from_bytes(padded[offset + 8 * lane:offset + 8 * lane + 8], "little")
        permute(state)
    return b"".join(lane.to_bytes(8, "little") for lane in state[:4])


EMPTY = "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
if keccak256(b"").hex() != EMPTY:
    raise RuntimeError("keccak256 does not reproduce the hash of the empty string")
