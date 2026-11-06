// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

uint192 constant FLAG_CALLBACK = 1 << 191;

type RailId is uint256;

// TODO(perf): compare to type StreamState is uint256
struct StreamState {
    uint88 incomingRate;
    uint40 settledUpTo;
    uint128 available;
}

struct Stream {
    StreamState state;
}

library RailIdLibrary {
    function deriveRail(address operator, address from, uint256 token, uint192 flags)
        internal
        pure
        returns (Stream storage stream)
    {
        assembly ("memory-safe") {
            let fmp := mload(0x40)
            // TODO(perf): can probably remove shl
            mstore(0, shl(96, operator))
            mstore(20, shl(96, from))
            mstore(40, shl(96, token))
            mstore(60, shl(64, flags))
            // 84 bytes will not collide with any solidity mapping
            // So we can use it directly as the storage key
            stream.slot := keccak256(0, 84)
            // restore free memory pointer
            mstore(0x40, fmp)
        }
    }

    function getRailId(Stream storage stream) internal pure returns (RailId railId) {
        assembly ("memory-safe") {
            railId := stream.slot
        }
    }
}
