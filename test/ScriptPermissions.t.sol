// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";

import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";
import {ALL, DEPOSIT, DEPOSIT_TO, Permissions, TRANSFER, WITHDRAW, WITHDRAW_TO} from "../src/lib/Permissions.sol";
import {ScriptBuilder} from "../src/lib/Script.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev the dispatcher reads what an op requires out of one packed table, so every entry needs a case
contract ScriptPermissionsTest is Test {
    using ScriptBuilder for bytes;

    address private constant ALICE = 0xA11cea11CEA11CEA11cEa11CeA11ceA11CEA11Ce;
    address private constant BOB = 0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb;
    address private constant CAROL = 0xCA401ca401Ca401CA401CA401cA401CA401ca401;

    FilecoinPayV2 private pay;
    MockERC20 private token;
    uint256 private tokenId;

    function setUp() public {
        pay = new FilecoinPayV2();
        token = new MockERC20();
        tokenId = uint256(uint160(address(token)));

        token.mint(ALICE, 1000);
        token.mint(BOB, 1000);
        vm.startPrank(ALICE);
        token.approve(address(pay), type(uint256).max);
        pay.deposit(address(token), 500);
        vm.stopPrank();
        vm.startPrank(BOB);
        token.approve(address(pay), type(uint256).max);
        pay.deposit(address(token), 500);
        pay.approve(ALICE, tokenId, 100);
        vm.stopPrank();
    }

    function _script() internal view returns (bytes memory) {
        return ScriptBuilder.newScript().setToken(address(token));
    }

    function _rejects(Permissions scope, bytes memory script) internal {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, ALICE, ALICE));
        pay.executeScript(scope, script);
    }

    function _allows(Permissions scope, bytes memory script) internal {
        vm.prank(ALICE);
        pay.executeScript(scope, script);
    }

    function testDeposit() public {
        bytes memory script = _script().deposit(100).build();
        _rejects(ALL & ~DEPOSIT, script);
        _allows(DEPOSIT, script);
        assertEq(pay.balanceOf(ALICE, tokenId), 600);
    }

    function testDepositTo() public {
        bytes memory script = _script().depositTo(100, BOB).build();
        // paying someone else takes both halves of DEPOSIT_TO
        _rejects(DEPOSIT, script);
        _rejects(TRANSFER, script);
        _allows(DEPOSIT_TO, script);
        assertEq(pay.balanceOf(BOB, tokenId), 600);
    }

    function testWithdraw() public {
        bytes memory script = _script().withdraw(100).build();
        _rejects(ALL & ~WITHDRAW, script);
        _allows(WITHDRAW, script);
        assertEq(token.balanceOf(ALICE), 600);
    }

    function testWithdrawTo() public {
        bytes memory script = _script().withdrawTo(100, BOB).build();
        _rejects(WITHDRAW, script);
        _rejects(TRANSFER, script);
        _allows(WITHDRAW_TO, script);
        assertEq(token.balanceOf(BOB), 600);
    }

    function testTransfer() public {
        bytes memory script = _script().transfer(BOB, 100).build();
        _rejects(ALL & ~TRANSFER, script);
        _allows(TRANSFER, script);
        assertEq(pay.balanceOf(BOB, tokenId), 600);
    }

    function testTransferFrom() public {
        bytes memory script = _script().transferFrom(CAROL, 100, BOB).build();
        _rejects(ALL & ~TRANSFER, script);
        _allows(TRANSFER, script);
        assertEq(pay.balanceOf(CAROL, tokenId), 100);
        assertEq(pay.allowance(BOB, ALICE, tokenId), 0);
    }

    function testTransferAll() public {
        bytes memory script = _script().transferAll(BOB).build();
        _rejects(ALL & ~TRANSFER, script);
        _allows(TRANSFER, script);
        assertEq(pay.balanceOf(ALICE, tokenId), 0);
        assertEq(pay.balanceOf(BOB, tokenId), 1000);
    }
}
