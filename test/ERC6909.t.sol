// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {stdError} from "forge-std/StdError.sol";
import {Test} from "forge-std/Test.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {FilecoinPayV2, INFINITE} from "../src/FilecoinPayV2.sol";

contract ERC6909Test is Test {
    uint256 private constant NATIVE_TOKEN = 0;

    FilecoinPayV2 private pay;
    address private owner;
    address private spender;
    address private recipient;

    function setUp() public {
        pay = new FilecoinPayV2();
        owner = makeAddr("owner");
        spender = makeAddr("spender");
        recipient = makeAddr("recipient");

        vm.deal(owner, 1000);
        vm.prank(owner);
        pay.deposit{value: 1000}();
    }

    function testSupportsInterface() public view {
        assertTrue(pay.supportsInterface(0x0f632fb3), "IERC6909");
        assertTrue(pay.supportsInterface(0x01ffc9a7), "IERC165");
        assertFalse(pay.supportsInterface(0xffffffff));
    }

    function testTransfer() public {
        vm.prank(owner);
        vm.expectEmit(address(pay));
        emit IERC6909.Transfer(owner, owner, recipient, NATIVE_TOKEN, 100);
        assertTrue(pay.transfer(recipient, NATIVE_TOKEN, 100));
        assertEq(pay.balanceOf(owner, NATIVE_TOKEN), 900);
        assertEq(pay.balanceOf(recipient, NATIVE_TOKEN), 100);

        vm.prank(owner);
        vm.expectRevert(FilecoinPayV2.InsufficientBalance.selector);
        pay.transfer(recipient, NATIVE_TOKEN, 901);
    }

    function testApproveTransferFrom() public {
        vm.prank(owner);
        vm.expectEmit(address(pay));
        emit IERC6909.Approval(owner, spender, NATIVE_TOKEN, 400);
        assertTrue(pay.approve(spender, NATIVE_TOKEN, 400));
        assertEq(pay.allowance(owner, spender, NATIVE_TOKEN), 400);
        assertFalse(pay.isOperator(owner, spender));

        vm.prank(spender);
        vm.expectEmit(address(pay));
        emit IERC6909.Transfer(spender, owner, recipient, NATIVE_TOKEN, 300);
        assertTrue(pay.transferFrom(owner, recipient, NATIVE_TOKEN, 300));
        assertEq(pay.allowance(owner, spender, NATIVE_TOKEN), 100);
        assertEq(pay.balanceOf(owner, NATIVE_TOKEN), 700);
        assertEq(pay.balanceOf(recipient, NATIVE_TOKEN), 300);

        vm.prank(spender);
        vm.expectRevert(stdError.arithmeticError);
        pay.transferFrom(owner, recipient, NATIVE_TOKEN, 101);

        vm.prank(owner);
        vm.expectEmit(address(pay));
        emit IERC6909.Approval(owner, spender, NATIVE_TOKEN, 50);
        pay.approve(spender, NATIVE_TOKEN, 50);
        assertEq(pay.allowance(owner, spender, NATIVE_TOKEN), 50);
    }

    function testInfiniteAllowance() public {
        vm.prank(owner);
        pay.approve(spender, NATIVE_TOKEN, INFINITE);

        vm.prank(spender);
        pay.transferFrom(owner, recipient, NATIVE_TOKEN, 600);
        assertEq(pay.allowance(owner, spender, NATIVE_TOKEN), INFINITE);

        vm.prank(spender);
        pay.transferFrom(owner, recipient, NATIVE_TOKEN, 400);
        assertEq(pay.allowance(owner, spender, NATIVE_TOKEN), INFINITE);
        assertEq(pay.balanceOf(owner, NATIVE_TOKEN), 0);
        assertEq(pay.balanceOf(recipient, NATIVE_TOKEN), 1000);

        vm.prank(spender);
        vm.expectRevert(FilecoinPayV2.InsufficientBalance.selector);
        pay.transferFrom(owner, recipient, NATIVE_TOKEN, 1);
    }

    function testSetOperator() public {
        vm.prank(owner);
        vm.expectEmit(address(pay));
        emit IERC6909.OperatorSet(owner, spender, true);
        assertTrue(pay.setOperator(spender, true));
        assertTrue(pay.isOperator(owner, spender));

        vm.prank(owner);
        pay.approve(spender, NATIVE_TOKEN, 10);

        vm.prank(spender);
        vm.expectEmit(address(pay));
        emit IERC6909.Transfer(spender, owner, recipient, NATIVE_TOKEN, 1000);
        assertTrue(pay.transferFrom(owner, recipient, NATIVE_TOKEN, 1000));
        assertEq(pay.allowance(owner, spender, NATIVE_TOKEN), 10, "operator spends without consuming allowance");

        vm.prank(owner);
        vm.expectEmit(address(pay));
        emit IERC6909.OperatorSet(owner, spender, false);
        assertTrue(pay.setOperator(spender, false));
        assertFalse(pay.isOperator(owner, spender));
    }
}
