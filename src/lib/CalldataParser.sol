pragma solidity ^0.8.37;

import {CalldataSlice} from "fvm-solidity/CalldataUtils.sol";
import {LibClone} from "solady/utils/LibClone.sol";

library CalldataParser {
    using LibClone for bytes32;

    function iter(bytes calldata data) internal pure returns (CalldataSlice memory remaining) {
        assembly ("memory-safe") {
            mstore(remaining, data.offset)
            mstore(add(remaining, 32), data.length)
        }
    }

    function nextByte(CalldataSlice memory slice) internal pure returns (uint256 next) {
        slice.length -= 1;
        uint256 off = slice.offset;
        unchecked {
            slice.offset = off + 1;
        }
        assembly ("memory-safe") {
            next := shr(248, calldataload(off))
        }
    }

    function nextAddress(CalldataSlice memory slice) internal pure returns (address next) {
        slice.length -= 20;
        uint256 off = slice.offset;
        unchecked {
            slice.offset = off + 20;
        }
        assembly ("memory-safe") {
            next := shr(96, calldataload(off))
        }
    }

    function nextU256(CalldataSlice memory slice) internal pure returns (uint256 next) {
        slice.length -= 32;
        uint256 off = slice.offset;
        unchecked {
            slice.offset = off + 32;
        }
        assembly ("memory-safe") {
            next := calldataload(off)
        }
    }

    function nextBytes32(CalldataSlice memory slice) internal pure returns (bytes32 next) {
        slice.length -= 32;
        uint256 off = slice.offset;
        unchecked {
            slice.offset = off + 32;
        }
        assembly ("memory-safe") {
            next := calldataload(off)
        }
    }

    function nextRailInfo(CalldataSlice memory slice)
        internal
        view
        returns (address rail, address from, address token, address operator)
    {
        slice.length -= 96;
        uint256 off = slice.offset;
        unchecked {
            slice.offset = off + 96;
        }
        bytes32 initcodeHash;
        bytes32 salt;
        assembly ("memory-safe") {
            calldatacopy(0, add(32, off), 64)
            initcodeHash := calldataload(off)
            from := shr(96, mload(0))
            token := shr(96, mload(20))
            operator := shr(96, mload(40))
            salt := keccak256(0, 64)
        }
        rail = initcodeHash.predictDeterministicAddress(salt, address(this));
    }
}
