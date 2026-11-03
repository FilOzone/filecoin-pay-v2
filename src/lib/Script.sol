// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {LibClone} from "solady/utils/LibClone.sol";

library ScriptReading {
    using LibClone for bytes32;

    function memoryIter(bytes memory script) internal pure returns (uint256 curr, uint256 end) {
        assembly ("memory-safe") {
            curr := add(32, script)
            end := add(mload(script), curr)
        }
    }

    function calldataIter(bytes calldata script) internal pure returns (uint256 curr, uint256 end) {
        assembly ("memory-safe") {
            curr := mload(0x40)
            let size := script.length
            calldatacopy(curr, script.offset, size)
            end := add(size, curr)
            mstore(0x40, end)
        }
    }

    function nextByte(uint256 curr) internal pure returns (uint256 next, uint256 newCurr) {
        assembly ("memory-safe") {
            next := shr(248, mload(curr))
            newCurr := add(curr, 1)
        }
    }

    function nextAddress(uint256 curr) internal pure returns (address next, uint256 newCurr) {
        assembly ("memory-safe") {
            next := shr(96, mload(curr))
            newCurr := add(curr, 20)
        }
    }

    function nextU256(uint256 curr) internal pure returns (uint256 next, uint256 newCurr) {
        assembly ("memory-safe") {
            next := mload(curr)
            newCurr := add(curr, 32)
        }
    }

    function nextBytes32(uint256 curr) internal pure returns (bytes32 next, uint256 newCurr) {
        assembly ("memory-safe") {
            next := mload(curr)
            newCurr := add(curr, 32)
        }
    }

    function nextRailInfo(uint256 curr)
        internal
        view
        returns (address rail, address from, address token, address operator, uint256 newCurr)
    {
        bytes32 initcodeHash;
        bytes32 salt;
        assembly ("memory-safe") {
            newCurr := add(curr, 96)
            initcodeHash := mload(curr)
            mcopy(0, add(32, curr), 64)
            salt := keccak256(0, 64)
            from := shr(96, mload(0))
            token := shr(96, mload(20))
            operator := shr(96, mload(40))
        }
        rail = initcodeHash.predictDeterministicAddress(salt, address(this));
    }
}
