// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

uint192 constant FLAG_CALLBACK = 1 << 191;

// TODO(perf) compare to mapping(uint256 token => Stream)
type RailId is uint256;
using RailIdLibrary for RailId global;

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
    function deriveRail(address operator, address from, uint192 flags) internal pure returns (RailId id) {
        assembly ("memory-safe") {
            mstore(0, shl(96, operator))
            mstore(20, shl(96, from))
            // assumption: top 8 bytes of fmp are zero
            mstore(40, shl(64, flags))
            // 72 bytes will not collide with any solidity mapping
            // So we can use it directly as the storage key
            id := keccak256(0, 72)
        }
    }

    function getStream(RailId id, uint256 token) internal pure returns (Stream storage stream) {
        assembly ("memory-safe") {
            mstore(0, token)
            mstore(32, id)
            stream.slot := keccak256(0, 64)
        }
    }
}
