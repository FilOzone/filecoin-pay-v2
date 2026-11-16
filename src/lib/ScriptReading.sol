// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

library ScriptReading {
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

    /// @dev the pair shares one word: address(20) nonce(8)
    function nextAddressU64(uint256 curr) internal pure returns (address next, uint64 value, uint256 newCurr) {
        assembly ("memory-safe") {
            let word := mload(curr)
            next := shr(96, word)
            value := shr(192, shl(160, word))
            newCurr := add(curr, 28)
        }
    }

    function nextU88(uint256 curr) internal pure returns (uint88 next, uint256 newCurr) {
        assembly ("memory-safe") {
            next := shr(168, mload(curr))
            newCurr := add(curr, 11)
        }
    }

    function nextU128(uint256 curr) internal pure returns (uint128 next, uint256 newCurr) {
        assembly ("memory-safe") {
            next := shr(128, mload(curr))
            newCurr := add(curr, 16)
        }
    }
}
