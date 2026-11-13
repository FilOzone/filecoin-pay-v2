// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Permissions} from "./Permissions.sol";

// ops that share a prologue are numbered adjacently, so that _dispatch reads the operands and
// runs the checks they have in common once: contract code costs Filecoin gas on every call

uint256 constant POP = 0;
uint256 constant PUSH = 1;
uint256 constant RESET = 2;
uint256 constant SUDO = 3;
uint256 constant SETTOKEN = 4;
uint256 constant AUTHORIZE = 5;
// SETRAIL names the same rail CREATERAIL does, without creating it
uint256 constant SETRAIL = 6;
uint256 constant CREATERAIL = 7;
uint256 constant SETTLERAIL = 8;
// _dispatch tells these four apart by order and parity: the bare pair leads the TO pair,
// and an even op deposits where an odd op withdraws
uint256 constant WITHDRAW = 9;
uint256 constant DEPOSIT = 10;
uint256 constant WITHDRAWTO = 11;
uint256 constant DEPOSITTO = 12;
uint256 constant TRANSFER = 13;
uint256 constant TRANSFERFROM = 14;
uint256 constant TRANSFERALL = 15;
uint256 constant INCREASERATE = 16;
uint256 constant DECREASERATE = 17;
uint256 constant SETRATE = 18;
uint256 constant DISBURSEALL = 19;
uint256 constant DISBURSE = 20;
uint256 constant LOCK = 21;
uint256 constant UNLOCK = 22;
uint256 constant SETAVAILABLE = 23;
// the operator terminates the rail its own identity derives; the payer names the operator instead
uint256 constant TERMINATERAIL = 24;
uint256 constant TERMINATERAILBY = 25;

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

    /// @dev only the low byte of the permissions travels, which the dispatcher narrows to its scope
    function authorize(bytes memory scriptBuilder, address operator, Permissions permissions)
        internal
        pure
        returns (bytes memory)
    {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(or(shl(248, AUTHORIZE), shl(88, operator)), shl(80, and(0xff, permissions))))
            mstore(0x40, add(22, buf))
        }
        return scriptBuilder;
    }

    function setRail(bytes memory scriptBuilder, address from, address recipient, uint32 nonce)
        internal
        pure
        returns (bytes memory)
    {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, SETRAIL), shl(88, from)))
            mstore(add(21, buf), or(shl(96, recipient), shl(64, nonce)))
            mstore(0x40, add(45, buf))
        }
        return scriptBuilder;
    }

    function createRail(bytes memory scriptBuilder, address from, address recipient, uint32 nonce)
        internal
        pure
        returns (bytes memory)
    {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, CREATERAIL), shl(88, from)))
            mstore(add(21, buf), or(shl(96, recipient), shl(64, nonce)))
            mstore(0x40, add(45, buf))
        }
        return scriptBuilder;
    }

    /// @dev the operator trails the rail CREATERAIL also names, which is what lets them share a read
    function settleRail(bytes memory scriptBuilder, address from, address recipient, uint32 nonce, address operator)
        internal
        pure
        returns (bytes memory)
    {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, SETTLERAIL), shl(88, from)))
            mstore(add(21, buf), or(shl(96, recipient), shl(64, nonce)))
            mstore(add(45, buf), shl(96, operator))
            mstore(0x40, add(65, buf))
        }
        return scriptBuilder;
    }

    function withdraw(bytes memory scriptBuilder, uint128 amount) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, WITHDRAW), shl(120, amount)))
            mstore(0x40, add(17, buf))
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

    function withdrawTo(bytes memory scriptBuilder, uint128 amount, address recipient)
        internal
        pure
        returns (bytes memory)
    {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, WITHDRAWTO), shl(120, amount)))
            mstore(add(17, buf), shl(96, recipient))
            mstore(0x40, add(37, buf))
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

    /// @dev the recipient leads, so TRANSFERALL shares the read
    function transfer(bytes memory scriptBuilder, address recipient, uint128 amount)
        internal
        pure
        returns (bytes memory)
    {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, TRANSFER), shl(88, recipient)))
            mstore(add(21, buf), shl(128, amount))
            mstore(0x40, add(37, buf))
        }
        return scriptBuilder;
    }

    /// @dev the owner trails what TRANSFER also names, which is what lets them share a read
    function transferFrom(bytes memory scriptBuilder, address recipient, uint128 amount, address owner)
        internal
        pure
        returns (bytes memory)
    {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, TRANSFERFROM), shl(88, recipient)))
            mstore(add(21, buf), shl(128, amount))
            mstore(add(37, buf), shl(96, owner))
            mstore(0x40, add(57, buf))
        }
        return scriptBuilder;
    }

    function transferAll(bytes memory scriptBuilder, address recipient) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, TRANSFERALL), shl(88, recipient)))
            mstore(0x40, add(21, buf))
        }
        return scriptBuilder;
    }

    function increaseRate(bytes memory scriptBuilder, uint88 rate) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, INCREASERATE), shl(160, rate)))
            mstore(0x40, add(12, buf))
        }
        return scriptBuilder;
    }

    function decreaseRate(bytes memory scriptBuilder, uint88 rate) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, DECREASERATE), shl(160, rate)))
            mstore(0x40, add(12, buf))
        }
        return scriptBuilder;
    }

    function setRate(bytes memory scriptBuilder, uint88 rate) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, SETRATE), shl(160, rate)))
            mstore(0x40, add(12, buf))
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

    function setAvailable(bytes memory scriptBuilder, uint128 amount) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, SETAVAILABLE), shl(120, amount)))
            mstore(0x40, add(17, buf))
        }
        return scriptBuilder;
    }

    function terminateRail(bytes memory scriptBuilder) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore8(buf, TERMINATERAIL)
            mstore(0x40, add(1, buf))
        }
        return scriptBuilder;
    }

    /// @dev for the payer, who is the authenticated party rather than an operand
    function terminateRailBy(bytes memory scriptBuilder, address operator) internal pure returns (bytes memory) {
        assembly ("memory-safe") {
            let buf := mload(0x40)
            mstore(buf, or(shl(248, TERMINATERAILBY), shl(88, operator)))
            mstore(0x40, add(21, buf))
        }
        return scriptBuilder;
    }
}
