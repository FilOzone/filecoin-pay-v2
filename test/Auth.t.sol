// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {stdError} from "forge-std/StdError.sol";

import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";
import {DEPOSIT, POP, PUSH, SETTOKEN, SUDO, newScript} from "../src/lib/Script.sol";
import {ALL, NONE, Permissions, TRANSFER, WITHDRAW} from "../src/lib/Permissions.sol";
import {UserLibrary} from "../src/lib/User.sol";

import {FilecoinPayTest} from "./FilecoinPayTest.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract AuthTest is FilecoinPayTest {
    using UserLibrary for FilecoinPayV2;

    address private constant ALICE = 0xA11cea11CEA11CEA11cEa11CeA11ceA11CEA11Ce;
    address private constant BOB = 0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb;
    address private CAROL = 0xCA401ca401Ca401CA401CA401cA401CA401ca401;

    function setUp() public override {
        super.setUp();
        token.mint(ALICE, 1000);
        token.mint(BOB, 1000);
        vm.prank(ALICE);
        token.approve(address(payments), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(payments), type(uint256).max);
    }

    function _authorize(address owner, address operator, Permissions permissions) internal {
        vm.prank(owner);
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.Authorized(owner, operator, permissions);
        vm.expectEmit(address(payments));
        emit IERC6909.OperatorSet(owner, operator, permissions.isOperator());
        payments.authorize(operator, permissions);
        assertPermissions(owner, operator, permissions);
    }

    function assertPermissions(address owner, address operator, Permissions expected) internal view {
        assertEq(Permissions.unwrap(payments.permissions(owner, operator)), Permissions.unwrap(expected));
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
        payments.executeScript(script);
        vm.stopSnapshotGas();

        assertEq(payments.balanceOf(ALICE, tokenId), 100);
        assertEq(payments.balanceOf(BOB, tokenId), 30);
        assertEq(token.balanceOf(ALICE), 900);
        assertEq(token.balanceOf(BOB), 970);
        assertEq(token.balanceOf(address(payments)), 130);
    }

    function testTransfer() public {
        vm.prank(ALICE);
        payments.deposit(address(token), 500);

        bytes memory script = newScript().setToken(address(token)).transfer(BOB, 200).build();
        vm.prank(ALICE);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(ALICE, ALICE, BOB, tokenId, 200);
        payments.executeScript(script);

        assertEq(payments.balanceOf(ALICE, tokenId), 300);
        assertEq(payments.balanceOf(BOB, tokenId), 200);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, ALICE, ALICE));
        payments.executeScript(ALL & ~TRANSFER, script);
    }

    function testTransferAll() public {
        vm.prank(ALICE);
        payments.deposit(address(token), 500);

        bytes memory script = newScript().setToken(address(token)).transferAll(BOB).build();

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, ALICE, ALICE));
        payments.executeScript(ALL & ~TRANSFER, script);

        vm.prank(ALICE);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(ALICE, ALICE, BOB, tokenId, 500);
        payments.executeScript(script);

        assertEq(payments.balanceOf(ALICE, tokenId), 0);
        assertEq(payments.balanceOf(BOB, tokenId), 500);

        vm.prank(ALICE);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(ALICE, ALICE, BOB, tokenId, 0);
        payments.executeScript(script);
    }

    function testAuthorizeNarrowsToTheScope() public {
        // ALICE hands BOB everything the script she signs is itself trusted with
        bytes memory grant = newScript().authorize(BOB, ALL).build();
        vm.prank(ALICE);
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.Authorized(ALICE, BOB, Permissions.wrap(0xff) & (ALL & ~WITHDRAW));
        vm.expectEmit(address(payments));
        emit IERC6909.OperatorSet(ALICE, BOB, true);
        payments.executeScript(ALL & ~WITHDRAW, grant);
        assertTrue(payments.isOperator(ALICE, BOB));
        assertPermissions(ALICE, BOB, Permissions.wrap(0xff) & (ALL & ~WITHDRAW));

        vm.prank(ALICE);
        payments.deposit(address(token), 500);

        bytes memory spend = newScript().setToken(address(token)).sudo(ALICE).transfer(CAROL, 200).build();
        vm.prank(BOB);
        payments.executeScript(spend);
        assertEq(payments.balanceOf(CAROL, tokenId), 200);

        // the grant never carried WITHDRAW, so nothing BOB runs can reach it
        bytes memory withdraw = newScript().setToken(address(token)).sudo(ALICE).withdraw(100).build();
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, ALICE, BOB));
        payments.executeScript(withdraw);

        // the operator flag follows the TRANSFER bit the scope let through
        vm.prank(ALICE);
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.Authorized(ALICE, CAROL, Permissions.wrap(0xff) & (ALL & ~TRANSFER));
        vm.expectEmit(address(payments));
        emit IERC6909.OperatorSet(ALICE, CAROL, false);
        payments.executeScript(ALL & ~TRANSFER, newScript().authorize(CAROL, ALL).build());
        assertFalse(payments.isOperator(ALICE, CAROL));
        assertPermissions(ALICE, CAROL, Permissions.wrap(0xff) & (ALL & ~TRANSFER));
    }

    function testTransferFrom() public {
        vm.prank(ALICE);
        payments.deposit(address(token), 500);
        vm.prank(ALICE);
        payments.approve(BOB, tokenId, 300);

        bytes memory script = newScript().setToken(address(token)).transferFrom(BOB, 200, ALICE).build();
        vm.prank(BOB);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(BOB, ALICE, BOB, tokenId, 200);
        payments.executeScript(script);

        assertEq(payments.balanceOf(ALICE, tokenId), 300);
        assertEq(payments.balanceOf(BOB, tokenId), 200);
        assertEq(payments.allowance(ALICE, BOB, tokenId), 100);

        vm.prank(BOB);
        vm.expectRevert(stdError.arithmeticError);
        payments.executeScript(script);
    }

    function testSudoTransferFromSpendsTheSudoedAllowance() public {
        vm.prank(ALICE);
        payments.deposit(address(token), 500);
        vm.prank(ALICE);
        payments.approve(CAROL, tokenId, 300);
        _authorize(CAROL, BOB, ALL);

        bytes memory script = newScript().setToken(address(token)).sudo(CAROL).transferFrom(BOB, 200, ALICE).build();
        vm.prank(BOB);
        payments.executeScript(script);

        assertEq(payments.balanceOf(ALICE, tokenId), 300);
        assertEq(payments.balanceOf(BOB, tokenId), 200);
        assertEq(payments.allowance(ALICE, CAROL, tokenId), 100);
        assertEq(payments.allowance(ALICE, BOB, tokenId), 0, "BOB spends as CAROL, never on his own allowance");
    }
}
