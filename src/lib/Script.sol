// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

uint256 constant POP = 0;
uint256 constant PUSH = 1;
uint256 constant RESET = 2;
uint256 constant SUDO = 3;
uint256 constant SETTOKEN = 4;
uint256 constant CREATERAIL = 5;
uint256 constant DEPOSIT = 6;
uint256 constant DEPOSITTO = 7;
uint256 constant WITHDRAW = 8;
uint256 constant WITHDRAWTO = 9;
uint256 constant TRANSFER = 10;
uint256 constant TRANSFERFROM = 11;
uint256 constant LOCK = 12;
uint256 constant UNLOCK = 13;
uint256 constant INCREASERATE = 14;
uint256 constant DECREASERATE = 15;
uint256 constant TRANSFERALL = 16;
uint256 constant SETTLERAIL = 17;
uint256 constant DISBURSEALL = 18;
uint256 constant DISBURSE = 19;

/// @dev Concatenate scripts without leaking memory, unlike concat(bytes, bytes)
/// @dev Important: do not allocate memory when building scripts

library ScriptBuilder {
    function newScript() internal pure returns (bytes memory scriptBuilder) {
        assembly ("memory-safe") {
            scriptBuilder := mload(0x40)
            mstore(0x40, add(0x20, scriptBuilder))
        }
    }

    function build(bytes memory scriptBuilder) internal pure returns (bytes memory script) {
        script = scriptBuilder;
        assembly ("memory-safe") {
            mstore(script, sub(mload(0x40), add(0x20, script)))
        }
    }

    // returning the builder ensures the evaluation order is deterministic

    // operands are stored left-aligned at ascending offsets, so each store overwrites the zero
    // padding of the previous one, and the next op overwrites the padding of the last

    function pop(bytes memory scriptBuilder) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore8(buf, POP)
            mstore(0x40, add(1, buf))
        }
        return scriptBuilder;
    }

    function push(bytes memory scriptBuilder) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore8(buf, PUSH)
            mstore(0x40, add(1, buf))
        }
        return scriptBuilder;
    }

    function reset(bytes memory scriptBuilder) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore8(buf, RESET)
            mstore(0x40, add(1, buf))
        }
        return scriptBuilder;
    }

    function sudo(bytes memory scriptBuilder, address who) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, SUDO), shl(88, who)))
            mstore(0x40, add(21, buf))
        }
        return scriptBuilder;
    }

    function setToken(bytes memory scriptBuilder, address token) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, SETTOKEN), shl(88, token)))
            mstore(0x40, add(21, buf))
        }
        return scriptBuilder;
    }

    function deposit(bytes memory scriptBuilder, uint128 amount) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, DEPOSIT), shl(120, amount)))
            mstore(0x40, add(17, buf))
        }
        return scriptBuilder;
    }

    function depositTo(bytes memory scriptBuilder, uint128 amount, address recipient)
        internal
        pure
        returns (bytes memory)
    {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, DEPOSITTO), shl(120, amount)))
            mstore(add(17, buf), shl(96, recipient))
            mstore(0x40, add(37, buf))
        }
        return scriptBuilder;
    }

    function lock(bytes memory scriptBuilder, uint128 amount) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, LOCK), shl(120, amount)))
            mstore(0x40, add(17, buf))
        }
        return scriptBuilder;
    }

    function unlock(bytes memory scriptBuilder, uint128 amount) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, UNLOCK), shl(120, amount)))
            mstore(0x40, add(17, buf))
        }
        return scriptBuilder;
    }

    function settleRail(bytes memory scriptBuilder, address operator, address from, address recipient, uint32 nonce)
        internal
        pure
        returns (bytes memory)
    {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, SETTLERAIL), shl(88, operator)))
            mstore(add(21, buf), shl(96, from))
            mstore(add(41, buf), or(shl(96, recipient), shl(64, nonce)))
            mstore(0x40, add(65, buf))
        }
        return scriptBuilder;
    }

    function disburseAll(bytes memory scriptBuilder) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore8(buf, DISBURSEALL)
            mstore(0x40, add(1, buf))
        }
        return scriptBuilder;
    }

    function disburse(bytes memory scriptBuilder, uint128 amount) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, DISBURSE), shl(120, amount)))
            mstore(0x40, add(17, buf))
        }
        return scriptBuilder;
    }
}
