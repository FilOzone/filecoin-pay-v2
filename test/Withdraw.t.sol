// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {MockFVMTest} from "fvm-solidity/mocks/MockFVMTest.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";
import {ALL, WITHDRAW, WITHDRAW_TO} from "../src/lib/Permissions.sol";
import {ScriptBuilder} from "../src/lib/Script.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

contract WithdrawTest is MockFVMTest {
    using ScriptBuilder for bytes;

    uint256 private constant NATIVE_TOKEN = 0;

    FilecoinPayV2 private pay;
    MockERC20 private token;
    uint256 private tokenId;
    address private alice;
    address private bob;

    function setUp() public override {
        super.setUp();
        pay = new FilecoinPayV2();
        token = new MockERC20();
        tokenId = uint256(uint160(address(token)));
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.deal(alice, 500);
        vm.prank(alice);
        pay.deposit{value: 500}();

        token.mint(alice, 1000);
        vm.startPrank(alice);
        token.approve(address(pay), type(uint256).max);
        pay.deposit(address(token), 1000);
        vm.stopPrank();
    }

    function testWithdraw() public {
        vm.prank(alice);
        vm.expectEmit(address(pay));
        emit IERC6909.Transfer(alice, alice, address(0), NATIVE_TOKEN, 200);
        vm.startSnapshotGas("withdraw", "native");
        pay.withdraw(address(0), 200);
        vm.stopSnapshotGas();

        assertEq(pay.balanceOf(alice, NATIVE_TOKEN), 300);
        assertEq(alice.balance, 200);
        assertEq(address(pay).balance, 300);

        vm.prank(alice);
        vm.expectEmit(address(pay));
        emit IERC6909.Transfer(alice, alice, address(0), tokenId, 250);
        vm.startSnapshotGas("withdraw", "token");
        pay.withdraw(address(token), 250);
        vm.stopSnapshotGas();

        assertEq(pay.balanceOf(alice, tokenId), 750);
        assertEq(token.balanceOf(alice), 250);

        vm.prank(alice);
        vm.expectRevert(FilecoinPayV2.InsufficientBalance.selector);
        pay.withdraw(address(0), 301);
    }

    function testWithdrawTo() public {
        vm.prank(alice);
        vm.expectEmit(address(pay));
        emit IERC6909.Transfer(alice, alice, address(0), NATIVE_TOKEN, 500);
        pay.withdrawTo(address(0), bob, 500);

        assertEq(pay.balanceOf(alice, NATIVE_TOKEN), 0);
        assertEq(bob.balance, 500);
        assertEq(address(pay).balance, 0);

        vm.prank(alice);
        pay.withdrawTo(address(token), bob, 1000);

        assertEq(pay.balanceOf(alice, tokenId), 0);
        assertEq(token.balanceOf(bob), 1000);
        assertEq(token.balanceOf(address(pay)), 0);

        vm.prank(bob);
        vm.expectRevert(FilecoinPayV2.InsufficientBalance.selector);
        pay.withdrawTo(address(0), alice, 1);
    }

    function testWithdrawNative() public {
        bytes memory script = ScriptBuilder.newScript().withdraw(200).build();
        vm.prank(alice);
        vm.expectEmit(address(pay));
        emit IERC6909.Transfer(alice, alice, address(0), NATIVE_TOKEN, 200);
        vm.startSnapshotGas("executeScript", "withdrawNative");
        pay.executeScript(script);
        vm.stopSnapshotGas();

        assertEq(pay.balanceOf(alice, NATIVE_TOKEN), 300);
        assertEq(alice.balance, 200);
        assertEq(address(pay).balance, 300);

        script = ScriptBuilder.newScript().withdraw(301).build();
        vm.prank(alice);
        vm.expectRevert(FilecoinPayV2.InsufficientBalance.selector);
        pay.executeScript(script);
    }

    function testWithdrawToken() public {
        bytes memory script = ScriptBuilder.newScript().setToken(address(token)).withdrawTo(600, bob).build();
        vm.prank(alice);
        vm.expectEmit(address(pay));
        emit IERC6909.Transfer(alice, alice, address(0), tokenId, 600);
        pay.executeScript(script);

        assertEq(pay.balanceOf(alice, tokenId), 400);
        assertEq(token.balanceOf(bob), 600);
        assertEq(token.balanceOf(address(pay)), 400);
    }

    function testWithdrawToSudo() public {
        bytes memory script = ScriptBuilder.newScript().sudo(alice).withdrawTo(100, bob).build();

        vm.prank(alice);
        pay.authorize(bob, WITHDRAW);
        vm.prank(bob);
        // withdrawing elsewhere takes WITHDRAW_TO, which WITHDRAW alone does not cover
        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, alice, bob));
        pay.executeScript(script);

        vm.prank(alice);
        pay.authorize(bob, WITHDRAW_TO);
        vm.prank(bob);
        pay.executeScript(script);

        assertEq(pay.balanceOf(alice, NATIVE_TOKEN), 400);
        assertEq(bob.balance, 100);
    }

    function testWithdrawOutsideScope() public {
        bytes memory script = ScriptBuilder.newScript().withdraw(100).build();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FilecoinPayV2.Unauthorized.selector, alice, alice));
        pay.executeScript(ALL & ~WITHDRAW, script);

        assertEq(pay.balanceOf(alice, NATIVE_TOKEN), 500);
    }
}
