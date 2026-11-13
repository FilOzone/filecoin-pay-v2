// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {
    AUTHORIZE,
    CREATERAIL,
    DECREASERATE,
    DEPOSIT,
    DEPOSITTO,
    DISBURSE,
    DISBURSEALL,
    INCREASERATE,
    LOCK,
    POP,
    PUSH,
    RESET,
    SETAVAILABLE,
    SETRAIL,
    SETRATE,
    SETTLERAIL,
    SETTOKEN,
    TERMINATERAIL,
    TERMINATERAILBY,
    SUDO,
    ScriptBuilder,
    TRANSFER,
    TRANSFERALL,
    TRANSFERFROM,
    UNLOCK,
    WITHDRAW,
    WITHDRAWTO
} from "../src/lib/Script.sol";
import {Permissions} from "../src/lib/Permissions.sol";

contract ScriptBuilderTest is Test {
    using ScriptBuilder for bytes;

    address private constant ALICE = 0xA11cea11CEA11CEA11cEa11CeA11ceA11CEA11Ce;
    address private constant BOB = 0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb;
    // saturated operands would collide with the adjacent field if a shift were off by a byte,
    // so each op pairs one with distinct operands, which a swapped pair would not survive
    address private constant MAX_ADDRESS = address(type(uint160).max);
    uint128 private constant MAX_AMOUNT = type(uint128).max;
    uint32 private constant MAX_NONCE = type(uint32).max;
    uint88 private constant MAX_RATE = type(uint88).max;

    function testBuild() public pure {
        bytes memory script = ScriptBuilder.newScript()
            .setToken(MAX_ADDRESS)
            .push()
            .sudo(ALICE)
            .authorize(ALICE, Permissions.wrap(type(uint256).max))
            .setRail(MAX_ADDRESS, BOB, MAX_NONCE)
            .createRail(BOB, MAX_ADDRESS, MAX_NONCE)
            .deposit(MAX_AMOUNT)
            .depositTo(MAX_AMOUNT, BOB)
            .withdraw(MAX_AMOUNT)
            .withdrawTo(MAX_AMOUNT, BOB)
            .transfer(BOB, MAX_AMOUNT)
            .transferFrom(MAX_ADDRESS, MAX_AMOUNT, ALICE)
            .lock(MAX_AMOUNT)
            .unlock(5)
            .increaseRate(MAX_RATE)
            .decreaseRate(7)
            .transferAll(MAX_ADDRESS)
            .disburseAll()
            .disburse(9)
            .settleRail(ALICE, BOB, MAX_NONCE, MAX_ADDRESS)
            .setRate(MAX_RATE)
            .setAvailable(MAX_AMOUNT)
            .terminateRail()
            .terminateRailBy(MAX_ADDRESS)
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
                uint8(AUTHORIZE),
                ALICE,
                // only the low byte of the permissions travels
                uint8(type(uint8).max),
                uint8(SETRAIL),
                MAX_ADDRESS,
                BOB,
                MAX_NONCE,
                uint8(CREATERAIL),
                BOB,
                MAX_ADDRESS,
                MAX_NONCE,
                uint8(DEPOSIT),
                MAX_AMOUNT,
                uint8(DEPOSITTO),
                MAX_AMOUNT,
                BOB,
                uint8(WITHDRAW),
                MAX_AMOUNT,
                uint8(WITHDRAWTO),
                MAX_AMOUNT,
                BOB,
                uint8(TRANSFER),
                BOB,
                MAX_AMOUNT,
                uint8(TRANSFERFROM),
                MAX_ADDRESS,
                MAX_AMOUNT,
                ALICE,
                uint8(LOCK),
                MAX_AMOUNT,
                uint8(UNLOCK),
                uint128(5),
                uint8(INCREASERATE),
                MAX_RATE,
                uint8(DECREASERATE),
                uint88(7),
                uint8(TRANSFERALL),
                MAX_ADDRESS,
                uint8(DISBURSEALL),
                uint8(DISBURSE),
                uint128(9),
                uint8(SETTLERAIL),
                ALICE,
                BOB,
                MAX_NONCE,
                MAX_ADDRESS,
                uint8(SETRATE),
                MAX_RATE,
                uint8(SETAVAILABLE),
                MAX_AMOUNT,
                uint8(TERMINATERAIL),
                uint8(TERMINATERAILBY),
                MAX_ADDRESS,
                uint8(RESET),
                uint8(POP)
            )
        );
    }

    function testNewScriptIsEmpty() public pure {
        assertEq(ScriptBuilder.newScript().build(), "");
    }
}
