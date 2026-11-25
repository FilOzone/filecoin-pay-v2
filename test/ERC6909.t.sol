// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {stdError} from "forge-std/StdError.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {FilecoinPayTest} from "./FilecoinPayTest.sol";

import {FilecoinPayV2, INFINITE} from "../src/FilecoinPayV2.sol";
import {NONE, TRANSFER} from "../src/lib/Permissions.sol";

contract ERC6909Test is FilecoinPayTest {
    address private owner;
    address private spender;
    address private recipient;

    function setUp() public override {
        super.setUp();
        owner = makeAddr("owner");
        spender = makeAddr("spender");
        recipient = makeAddr("recipient");

        vm.deal(owner, 1000);
        vm.prank(owner);
        payments.deposit{value: 1000}();
    }

    function testSupportsInterface() public view {
        assertTrue(payments.supportsInterface(0x0f632fb3), "IERC6909");
        assertTrue(payments.supportsInterface(0x01ffc9a7), "IERC165");
        assertFalse(payments.supportsInterface(0xffffffff));
    }

    function testTransfer() public {
        vm.prank(owner);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(owner, owner, recipient, NATIVE_TOKEN, 100);
        assertTrue(payments.transfer(recipient, NATIVE_TOKEN, 100));
        assertEq(payments.balanceOf(owner, NATIVE_TOKEN), 900);
        assertEq(payments.balanceOf(recipient, NATIVE_TOKEN), 100);

        vm.prank(owner);
        vm.expectRevert(FilecoinPayV2.InsufficientBalance.selector);
        payments.transfer(recipient, NATIVE_TOKEN, 901);
    }

    function testApproveTransferFrom() public {
        vm.prank(owner);
        vm.expectEmit(address(payments));
        emit IERC6909.Approval(owner, spender, NATIVE_TOKEN, 400);
        assertTrue(payments.approve(spender, NATIVE_TOKEN, 400));
        assertEq(payments.allowance(owner, spender, NATIVE_TOKEN), 400);
        assertFalse(payments.isOperator(owner, spender));

        vm.prank(spender);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(spender, owner, recipient, NATIVE_TOKEN, 300);
        assertTrue(payments.transferFrom(owner, recipient, NATIVE_TOKEN, 300));
        assertEq(payments.allowance(owner, spender, NATIVE_TOKEN), 100);
        assertEq(payments.balanceOf(owner, NATIVE_TOKEN), 700);
        assertEq(payments.balanceOf(recipient, NATIVE_TOKEN), 300);

        vm.prank(spender);
        vm.expectRevert(stdError.arithmeticError);
        payments.transferFrom(owner, recipient, NATIVE_TOKEN, 101);

        vm.prank(owner);
        vm.expectEmit(address(payments));
        emit IERC6909.Approval(owner, spender, NATIVE_TOKEN, 50);
        payments.approve(spender, NATIVE_TOKEN, 50);
        assertEq(payments.allowance(owner, spender, NATIVE_TOKEN), 50);
    }

    function testInfiniteAllowance() public {
        vm.prank(owner);
        payments.approve(spender, NATIVE_TOKEN, INFINITE);

        vm.prank(spender);
        payments.transferFrom(owner, recipient, NATIVE_TOKEN, 600);
        assertEq(payments.allowance(owner, spender, NATIVE_TOKEN), INFINITE);

        vm.prank(spender);
        payments.transferFrom(owner, recipient, NATIVE_TOKEN, 400);
        assertEq(payments.allowance(owner, spender, NATIVE_TOKEN), INFINITE);
        assertEq(payments.balanceOf(owner, NATIVE_TOKEN), 0);
        assertEq(payments.balanceOf(recipient, NATIVE_TOKEN), 1000);

        vm.prank(spender);
        vm.expectRevert(FilecoinPayV2.InsufficientBalance.selector);
        payments.transferFrom(owner, recipient, NATIVE_TOKEN, 1);
    }

    function testSetOperator() public {
        vm.prank(owner);
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.Authorized(owner, spender, TRANSFER);
        vm.expectEmit(address(payments));
        emit IERC6909.OperatorSet(owner, spender, true);
        assertTrue(payments.setOperator(spender, true));
        assertTrue(payments.isOperator(owner, spender));

        vm.prank(owner);
        payments.approve(spender, NATIVE_TOKEN, 10);

        vm.prank(spender);
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(spender, owner, recipient, NATIVE_TOKEN, 1000);
        assertTrue(payments.transferFrom(owner, recipient, NATIVE_TOKEN, 1000));
        assertEq(payments.allowance(owner, spender, NATIVE_TOKEN), 10, "operator spends without consuming allowance");

        vm.prank(owner);
        vm.expectEmit(address(payments));
        emit FilecoinPayV2.Authorized(owner, spender, NONE);
        vm.expectEmit(address(payments));
        emit IERC6909.OperatorSet(owner, spender, false);
        assertTrue(payments.setOperator(spender, false));
        assertFalse(payments.isOperator(owner, spender));
    }
}
