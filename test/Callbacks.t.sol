// SPDX-License-Identifier: Apache-2.0 OR MIT
pragma solidity ^0.8.37;

import {stdError} from "forge-std/StdError.sol";
import {Test} from "forge-std/Test.sol";
import {IERC6909} from "forge-std/interfaces/IERC6909.sol";

import {FilecoinPayV2} from "../src/FilecoinPayV2.sol";
import {CREATE_RAIL} from "../src/lib/Permissions.sol";
import {ScriptBuilder} from "../src/lib/Script.sol";
import {FLAG_CALLBACK, RailId, RailIdLibrary} from "../src/lib/RailId.sol";

contract CallbacksTest is Test {
    using ScriptBuilder for bytes;
    using RailIdLibrary for FilecoinPayV2;

    uint256 private constant NATIVE_TOKEN = 0;

    event SettleRailParams(
        RailId railId, uint256 prevSettledEpoch, uint256 settledUpTo, uint256 prevBalance, uint256 addsBalance
    );

    bytes internal mockScript;

    function settleRail(
        RailId railId,
        uint256 prevSettledEpoch,
        uint256 settledUpTo,
        uint256 prevBalance,
        uint256 addsBalance
    ) external returns (bytes memory script) {
        emit SettleRailParams(railId, prevSettledEpoch, settledUpTo, prevBalance, addsBalance);
        return mockScript;
    }

    function expectSettleRail(
        RailId railId,
        uint256 prevSettledEpoch,
        uint256 settledUpTo,
        uint256 prevBalance,
        uint256 addsBalance
    ) internal {
        vm.expectEmit(address(this));
        emit SettleRailParams(railId, prevSettledEpoch, settledUpTo, prevBalance, addsBalance);
    }

    function expectNoSettleRail() internal {
        vm.expectEmit(false, false, false, false, address(this), 0);
        emit SettleRailParams(RailId.wrap(0), 0, 0, 0, 0);
    }

    function expectNativeTransfer(address from, address to, uint256 amount) internal {
        vm.expectEmit(address(payments));
        emit IERC6909.Transfer(address(this), from, to, NATIVE_TOKEN, amount);
    }

    FilecoinPayV2 internal payments;

    function setUp() public {
        payments = new FilecoinPayV2();
    }

    function testRateOps() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = FLAG_CALLBACK;

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);

        uint256 createdAt = vm.getBlockNumber();
        RailId railId = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.deal(alice, 1000);
        vm.prank(alice);
        payments.deposit{value: 1000}();

        // the settling rail is the script's authorization, so neither op names it
        vm.roll(createdAt + 1);
        mockScript = ScriptBuilder.newScript().increaseRate(10).build();
        expectSettleRail(railId, createdAt, createdAt + 1, 0, 0);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.getRail(railId).incomingRate, 10);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 1000);

        vm.roll(createdAt + 3);
        mockScript = ScriptBuilder.newScript().decreaseRate(4).build();
        expectSettleRail(railId, createdAt + 1, createdAt + 3, 0, 20);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.getRail(railId).incomingRate, 6);
        assertEq(payments.getRail(railId).available, 20);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 980);

        vm.roll(createdAt + 4);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 974);

        mockScript = ScriptBuilder.newScript().decreaseRate(7).build();
        vm.expectRevert(stdError.arithmeticError);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
    }

    function testSetOps() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = FLAG_CALLBACK;

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);

        uint256 createdAt = vm.getBlockNumber();
        RailId railId = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.deal(alice, 1000);
        vm.prank(alice);
        payments.deposit{value: 1000}();

        vm.roll(createdAt + 1);
        mockScript = ScriptBuilder.newScript().setRate(10).setAvailable(100).build();
        expectSettleRail(railId, createdAt, createdAt + 1, 0, 0);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.getRail(railId).incomingRate, 10);
        assertEq(payments.getRail(railId).available, 100);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 900);

        // settling adds 2 blocks at 10 to the lockup, which the target replaces rather than adds to
        vm.roll(createdAt + 3);
        mockScript = ScriptBuilder.newScript().setRate(4).setAvailable(50).build();
        expectSettleRail(railId, createdAt + 1, createdAt + 3, 100, 20);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.getRail(railId).incomingRate, 4, "the rate is set, not adjusted");
        assertEq(payments.getRail(railId).available, 50, "the lockup is set, not adjusted");
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 950, "unlocking 70 refunds what the target gave up");

        // the script runs after the settle it belongs to, so the target counts what that settle locked
        vm.roll(createdAt + 4);
        mockScript = ScriptBuilder.newScript().setAvailable(0).build();
        expectSettleRail(railId, createdAt + 3, createdAt + 4, 50, 4);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.getRail(railId).available, 0);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 1000);
    }

    function testCallback() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        uint32 nonce = FLAG_CALLBACK;

        vm.prank(alice);
        payments.authorize(address(this), CREATE_RAIL);

        uint256 createdAt = vm.getBlockNumber();
        RailId railId = payments.createRail(alice, bob, nonce, NATIVE_TOKEN);

        vm.roll(createdAt + 1);
        expectSettleRail(railId, createdAt, createdAt + 1, 0, 0);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);

        payments.modifyRate(alice, bob, nonce, NATIVE_TOKEN, 5);

        vm.roll(createdAt + 2);
        expectNoSettleRail();
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);

        vm.deal(alice, 500);
        vm.prank(alice);
        payments.deposit{value: 500}();
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 495);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 0);

        expectSettleRail(railId, createdAt + 1, createdAt + 2, 0, 5);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 495);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 0);

        vm.roll(createdAt + 4);
        expectSettleRail(railId, createdAt + 2, createdAt + 4, 5, 10);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 485);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 0);

        vm.roll(createdAt + 5);
        mockScript = ScriptBuilder.newScript().unlock(5).disburseAll().build();
        expectSettleRail(railId, createdAt + 4, createdAt + 5, 15, 5);
        expectNativeTransfer(alice, bob, 15);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.balanceOf(alice, NATIVE_TOKEN), 485);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 15);

        vm.roll(createdAt + 6);
        mockScript = ScriptBuilder.newScript().disburse(2).build();
        expectSettleRail(railId, createdAt + 5, createdAt + 6, 0, 5);
        expectNativeTransfer(alice, bob, 2);
        payments.settleRail(address(this), alice, bob, nonce, NATIVE_TOKEN);
        assertEq(payments.balanceOf(bob, NATIVE_TOKEN), 17);
        assertEq(payments.getRail(railId).available, 3);
    }
}
