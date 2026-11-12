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

    function nextU32(uint256 curr) internal pure returns (uint32 next, uint256 newCurr) {
        assembly ("memory-safe") {
            next := shr(224, mload(curr))
            newCurr := add(curr, 4)
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
