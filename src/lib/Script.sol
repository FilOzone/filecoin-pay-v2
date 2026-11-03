// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {LibClone} from "solady/utils/LibClone.sol";

// TODO(perf): try maintaining two fields instead of struct memory
struct ScriptIterator {
    uint256 curr;
    uint256 end;
}

library ScriptReading {
    using LibClone for bytes32;

    function memoryIter(bytes memory script) internal pure returns (ScriptIterator memory iter) {
        assembly ("memory-safe") {
            let size := mload(script)
            let dst := add(32, script)
            mstore(add(iter, 32), add(size, dst))
            mstore(iter, dst)
        }
    }

    function calldataIter(bytes calldata script) internal pure returns (ScriptIterator memory iter) {
        assembly ("memory-safe") {
            let dst := mload(0x40)
            let size := script.length
            calldatacopy(dst, script.offset, size)
            let end := add(size, dst)
            mstore(0x40, end)
            mstore(add(iter, 32), end)
            mstore(iter, dst)
        }
    }

    function nextByte(ScriptIterator memory slice) internal pure returns (uint256 next) {
        uint256 off = slice.curr;
        unchecked {
            slice.curr = off + 1;
        }
        assembly ("memory-safe") {
            next := shr(248, mload(off))
        }
    }

    function nextAddress(ScriptIterator memory slice) internal pure returns (address next) {
        uint256 off = slice.curr;
        unchecked {
            slice.curr = off + 20;
        }
        assembly ("memory-safe") {
            next := shr(96, mload(off))
        }
    }

    function nextU256(ScriptIterator memory slice) internal pure returns (uint256 next) {
        uint256 off = slice.curr;
        unchecked {
            slice.curr = off + 32;
        }
        assembly ("memory-safe") {
            next := mload(off)
        }
    }

    function nextBytes32(ScriptIterator memory slice) internal pure returns (bytes32 next) {
        uint256 off = slice.curr;
        unchecked {
            slice.curr = off + 32;
        }
        assembly ("memory-safe") {
            next := mload(off)
        }
    }

    function nextRailInfo(ScriptIterator memory slice)
        internal
        view
        returns (address rail, address from, address token, address operator)
    {
        uint256 off = slice.curr;
        unchecked {
            slice.curr = off + 96;
        }
        bytes32 initcodeHash;
        bytes32 salt;
        assembly ("memory-safe") {
            initcodeHash := mload(off)
            off := add(32, off)
            // TODO(perf) try mcopy to (0,64)
            salt := keccak256(off, add(64, off))
            from := shr(96, mload(off))
            off := add(20, off)
            token := shr(96, mload(off))
            off := add(20, off)
            operator := shr(96, mload(off))
        }
        rail = initcodeHash.predictDeterministicAddress(salt, address(this));
    }
}
