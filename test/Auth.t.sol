// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";
import {DEPOSIT, POP, PUSH, SETTOKEN, SUDO} from "../src/lib/Script.sol";
import {ALL, NONE, Permissions, TRANSFER} from "../src/lib/Permissions.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

contract AuthTest is Test {
    address private constant ALICE = 0xA11cea11CEA11CEA11cEa11CeA11ceA11CEA11Ce;
    address private constant BOB = 0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb;

    FilecoinPayV2 private pay;
    MockERC20 private token;
    uint256 private tokenId;

    function setUp() public {
        pay = new FilecoinPayV2();
        token = new MockERC20();
        tokenId = uint256(uint160(address(token)));

        token.mint(ALICE, 1000);
        token.mint(BOB, 1000);
        vm.prank(ALICE);
        token.approve(address(pay), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(pay), type(uint256).max);
    }

    function _authorize(address owner, address operator, Permissions permissions) internal {
        vm.prank(owner);
        vm.expectEmit(address(pay));
        emit IERC6909.OperatorSet(owner, operator, permissions.isOperator());
        pay.authorize(operator, permissions);
    }

    function testPushSudoDepositPopDeposit() public {
        _authorize(ALICE, BOB, ALL);

        bytes memory script = abi.encodePacked(
            uint8(SETTOKEN),
            address(token),
            uint8(PUSH),
            uint8(SUDO),
            ALICE,
            uint8(DEPOSIT),
            uint256(100),
            uint8(POP),
            uint8(DEPOSIT),
            uint256(30)
        );
        vm.prank(BOB);
        vm.startSnapshotGas("executeScript", "pushSudoDepositPopDeposit");
        pay.executeScript(script);
        vm.stopSnapshotGas();

        assertEq(pay.balanceOf(ALICE, tokenId), 100);
        assertEq(pay.balanceOf(BOB, tokenId), 30);
        assertEq(token.balanceOf(ALICE), 900);
        assertEq(token.balanceOf(BOB), 970);
        assertEq(token.balanceOf(address(pay)), 130);
    }
}
