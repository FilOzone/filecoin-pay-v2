// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {stdError} from "forge-std/StdError.sol";

import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";
import {DEPOSIT, POP, PUSH, SETTOKEN, SUDO, ScriptBuilder} from "../src/lib/Script.sol";
import {ALL, NONE, Permissions, TRANSFER} from "../src/lib/Permissions.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

contract AuthTest is Test {
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
            uint128(100),
            uint8(POP),
            uint8(DEPOSIT),
            uint128(30)
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

    function testTransfer() public {
        vm.prank(ALICE);
        pay.deposit(address(token), 500);

        bytes memory script = ScriptBuilder.newScript().setToken(address(token)).transfer(200, BOB).build();
        vm.prank(ALICE);
        vm.expectEmit(address(pay));
        emit IERC6909.Transfer(ALICE, ALICE, BOB, tokenId, 200);
        pay.executeScript(script);

        assertEq(pay.balanceOf(ALICE, tokenId), 300);
        assertEq(pay.balanceOf(BOB, tokenId), 200);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, ALICE, ALICE));
        pay.executeScript(ALL & ~TRANSFER, script);
    }

    function testTransferAll() public {
        vm.prank(ALICE);
        pay.deposit(address(token), 500);

        bytes memory script = ScriptBuilder.newScript().setToken(address(token)).transferAll(BOB).build();

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, ALICE, ALICE));
        pay.executeScript(ALL & ~TRANSFER, script);

        vm.prank(ALICE);
        vm.expectEmit(address(pay));
        emit IERC6909.Transfer(ALICE, ALICE, BOB, tokenId, 500);
        pay.executeScript(script);

        assertEq(pay.balanceOf(ALICE, tokenId), 0);
        assertEq(pay.balanceOf(BOB, tokenId), 500);

        vm.prank(ALICE);
        vm.expectEmit(address(pay));
        emit IERC6909.Transfer(ALICE, ALICE, BOB, tokenId, 0);
        pay.executeScript(script);
    }

    function testTransferFrom() public {
        vm.prank(ALICE);
        pay.deposit(address(token), 500);
        vm.prank(ALICE);
        pay.approve(BOB, tokenId, 300);

        bytes memory script = ScriptBuilder.newScript().setToken(address(token)).transferFrom(200, ALICE, BOB).build();
        vm.prank(BOB);
        vm.expectEmit(address(pay));
        emit IERC6909.Transfer(BOB, ALICE, BOB, tokenId, 200);
        pay.executeScript(script);

        assertEq(pay.balanceOf(ALICE, tokenId), 300);
        assertEq(pay.balanceOf(BOB, tokenId), 200);
        assertEq(pay.allowance(ALICE, BOB, tokenId), 100);

        vm.prank(BOB);
        vm.expectRevert(stdError.arithmeticError);
        pay.executeScript(script);
    }

    function testSudoTransferFromSpendsTheSudoedAllowance() public {
        vm.prank(ALICE);
        pay.deposit(address(token), 500);
        vm.prank(ALICE);
        pay.approve(CAROL, tokenId, 300);
        _authorize(CAROL, BOB, ALL);

        bytes memory script =
            ScriptBuilder.newScript().setToken(address(token)).sudo(CAROL).transferFrom(200, ALICE, BOB).build();
        vm.prank(BOB);
        pay.executeScript(script);

        assertEq(pay.balanceOf(ALICE, tokenId), 300);
        assertEq(pay.balanceOf(BOB, tokenId), 200);
        assertEq(pay.allowance(ALICE, CAROL, tokenId), 100);
        assertEq(pay.allowance(ALICE, BOB, tokenId), 0, "BOB spends as CAROL, never on his own allowance");
    }
}
