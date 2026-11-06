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
            let fmp := mload(64)
            mstore(64, flags)
            mstore(40, token)
            mstore(20, from)
            mstore(0, operator)
            // 84 bytes will not collide with any solidity mapping
            // So we can use it directly as the storage key
            stream.slot := keccak256(12, 84)
            // restore free memory pointer
            mstore(64, fmp)
        }
    }

    function getRailId(Stream storage stream) internal pure returns (RailId railId) {
        assembly ("memory-safe") {
            railId := stream.slot
        }
    }

    function exists(Stream storage stream) internal view returns (bool exists) {
        assembly ("memory-safe") {
            exists := iszero(iszero(sload(stream.slot)))
        }
    }
}
