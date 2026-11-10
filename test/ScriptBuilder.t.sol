// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {
    DEPOSIT,
    DEPOSITTO,
    DISBURSEALL,
    LOCK,
    POP,
    PUSH,
    RESET,
    SETTLERAIL,
    SETTOKEN,
    SUDO,
    ScriptBuilder,
    UNLOCK
} from "../src/lib/Script.sol";

contract ScriptBuilderTest is Test {
    using ScriptBuilder for bytes;

    address private constant ALICE = 0xA11cea11CEA11CEA11cEa11CeA11ceA11CEA11Ce;
    address private constant BOB = 0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb;
    // saturated operands would collide with the adjacent field if a shift were off by a byte
    address private constant MAX_ADDRESS = address(type(uint160).max);
    uint128 private constant MAX_AMOUNT = type(uint128).max;
    uint32 private constant MAX_NONCE = type(uint32).max;

    function testBuild() public pure {
        bytes memory script = ScriptBuilder.newScript()
            .setToken(MAX_ADDRESS)
            .push()
            .sudo(ALICE)
            .deposit(MAX_AMOUNT)
            .depositTo(MAX_AMOUNT, BOB)
            .lock(MAX_AMOUNT)
            .unlock(5)
            .disburseAll()
            .settleRail(MAX_ADDRESS, ALICE, MAX_ADDRESS, MAX_NONCE)
            .reset()
            .pop()
            .build();

        assertEq(
            script,
            abi.encodePacked(
                uint8(SETTOKEN),
                MAX_ADDRESS,
                uint8(PUSH),
                uint8(SUDO),
                ALICE,
                uint8(DEPOSIT),
                MAX_AMOUNT,
                uint8(DEPOSITTO),
                MAX_AMOUNT,
                BOB,
                uint8(LOCK),
                MAX_AMOUNT,
                uint8(UNLOCK),
                uint128(5),
                uint8(DISBURSEALL),
                uint8(SETTLERAIL),
                MAX_ADDRESS,
                ALICE,
                MAX_ADDRESS,
                MAX_NONCE,
                uint8(RESET),
                uint8(POP)
            )
        );
    }

    function testNewScriptIsEmpty() public pure {
        assertEq(ScriptBuilder.newScript().build(), "");
    }
}
