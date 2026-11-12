// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {IExtsload} from "../interfaces/IExtsload.sol";

uint32 constant FLAG_CALLBACK = 1 << 31;

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
    function deriveRail(address operator, address from, address recipient, uint256 token, uint32 nonce)
        internal
        pure
        returns (Stream storage stream)
    {
        assembly ("memory-safe") {
            let fmp := mload(64)
            // preimage [12,96): operator(20) from(20) token(20) recipient(20) nonce(4)
            // offsets strictly decrease, so each store overwrites the zero padding of the previous one
            mstore(64, nonce)
            mstore(60, recipient)
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

    function getRail(IExtsload payments, RailId railId) internal view returns (StreamState memory state) {
        uint256 streamInfo = uint256(payments.extsload(bytes32(RailId.unwrap(railId))));
        state.incomingRate = uint88(streamInfo);
        state.settledUpTo = uint40(streamInfo >> 88);
        state.available = uint128(streamInfo >> 128);
    }

    function exists(Stream storage stream) internal view returns (bool exists) {
        assembly ("memory-safe") {
            exists := iszero(iszero(sload(stream.slot)))
        }
    }

    /// @dev init() stamps the creation epoch, which never returns to zero
    function exists(StreamState memory state) internal pure returns (bool) {
        return state.settledUpTo != 0;
    }

    function init(Stream storage stream) internal {
        assembly ("memory-safe") {
            sstore(stream.slot, shl(88, number()))
        }
    }
}
